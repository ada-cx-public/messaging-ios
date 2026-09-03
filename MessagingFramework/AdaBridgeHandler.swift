//
//  AdaBridgeHandler.swift
//  AdaMessaging
//
//  Bridges the Ada messaging SDK WebView to native iOS code.
//
//  Responsibilities:
//   • Receives `sdk.event`, `sdk.ready`, `sdk.state.cache`, and `sdk.error`
//     messages posted by the in-WebView bridge adapter script.
//   • Caches the latest state snapshot to UserDefaults so it can be injected
//     back into a new WebView via a WKUserScript at document start, eliminating
//     the loading spinner on WebView kill-and-restart.
//   • Sends typed commands to the SDK via evaluateJavaScript without any
//     string interpolation of user-supplied values — all payloads are
//     JSON-encoded by the native side before dispatch.
//
//  Security notes:
//   • WKWebView exposes `window.webkit.messageHandlers` to every frame, so
//     incoming messages are accepted only from the main frame whose security
//     origin equals `trustedOrigin` — a custom-app `appUrl` iframe cannot forge
//     `sdk.event` / `sdk.ready` or poison the persisted state cache.
//   • The persisted state cache is filtered to `persistableStateKeys` before it is
//     written, so it holds startup/branding config and no credentials. Clear it on sign-out
//     or when your app should discard recoverable chat state.
//   • evaluateJavaScript is called with a fixed template; the JSON payload is
//     a single argument passed through the window.__ADA_BRIDGE_DISPATCH__ function
//     which the in-WebView adapter owns and validates.
//

import Foundation
import WebKit

// ---------------------------------------------------------------------------

// MARK: - AdaDocumentTicket

// ---------------------------------------------------------------------------

/// The authority to write into the document a request was accepted from.
///
/// One value answers every question a deferred injection has to ask:
///  - which WebView, so a rebuilt one (``AdaWebHost/hardResetWebView()``) cannot be written
///    into with a ticket minted against its predecessor;
///  - which main document, by its full URL — the start parameters this run was launched with
///    ride the query, and an in-place main-frame navigation replaces the document without
///    touching the WebView at all.
///
/// Minted only for the entry document the wrapper loaded — pinned `trustedOrigin`, same entry
/// path, same query signature — so a page that was never the Ada runtime mints nothing and no
/// deferred reply can reach it.
struct AdaDocumentTicket: Equatable {
    let webView: ObjectIdentifier
    let documentUrl: String
}

// ---------------------------------------------------------------------------

// MARK: - AdaBridgeDelegate

// ---------------------------------------------------------------------------

/// Implement this protocol to receive callbacks from the Ada bridge.
@objc @MainActor public protocol AdaBridgeDelegate: AnyObject {
    /// Called for every SDK event the WebView publishes.
    func adaBridge(_ bridge: AdaBridgeHandler, didReceiveEvent key: String, data: Any?)

    /// Called once when the SDK signals it is ready to accept commands.
    @objc optional func adaBridgeDidBecomeReady(_ bridge: AdaBridgeHandler)

    /// Called when the bridge adapter reports a fatal error.
    @objc optional func adaBridge(_ bridge: AdaBridgeHandler, didEncounterError error: String)

    /// Called when the runtime page reports that one of its subresources
    /// (script, stylesheet, image, frame) failed to load. `details` carries the
    /// failed `url` and the loading `element` tag name. The main-frame load is
    /// unaffected — navigation failures arrive through `WKNavigationDelegate`.
    @objc optional func adaBridge(_ bridge: AdaBridgeHandler, didFailSubresourceLoad details: [String: Any])

    /// Called when the Messaging runtime asks the native host for a Zendesk Chat chatter-auth
    /// token. The host must answer with `sendZendeskChatterAuthResponse(token:to:)` exactly
    /// once — core's wait is bounded at 10s, and a host that never answers burns that 10s timeout
    /// on every refresh cycle for the whole handoff rather than failing fast.
    @objc optional func adaBridgeDidRequestZendeskChatterAuth(_ bridge: AdaBridgeHandler)
}

// ---------------------------------------------------------------------------

// MARK: - AdaBridgeHandler

// ---------------------------------------------------------------------------

/// A `WKScriptMessageHandler` that receives messages from the Ada SDK bridge
/// adapter running inside a WKWebView.
///
/// ## Integration
///
/// ```swift
/// let handler = AdaBridgeHandler()
/// handler.delegate = self
/// // Origin of the page you load below — messages from any other origin
/// // (or from a subframe) are dropped.
/// handler.trustedOrigin = "https://example.ada.support"
/// // The exact document you load below, query included. Commands are injected only
/// // into that document; leaving it unset injects nothing.
/// handler.trustedDocumentUrl = "https://example.ada.support/sdk/webview.html?handle=example"
///
/// let config = WKWebViewConfiguration()
/// config.userContentController.add(handler, name: "adaBridge")
///
/// // Restore cached state on next load so the chat UI appears immediately.
/// if let script = handler.makeInitialStateScript() {
///     config.userContentController.addUserScript(script)
/// }
///
/// let webView = WKWebView(frame: .zero, configuration: config)
/// ```
@objcMembers @MainActor public class AdaBridgeHandler: NSObject, WKScriptMessageHandler {
    // -----------------------------------------------------------------------
    // Public
    // -----------------------------------------------------------------------

    /// Delegate that receives event and lifecycle callbacks.
    public weak var delegate: AdaBridgeDelegate?

    /// Origin of the host page the WebView is configured to load, in
    /// `scheme://host[:port]` form with the port omitted when it is the scheme
    /// default (`AdaWebHost.pageOrigin(ofUrl:)` produces this shape). WKWebView
    /// exposes `window.webkit.messageHandlers` to every frame — including a
    /// custom-app `appUrl` iframe — so an incoming message is dropped unless it
    /// arrives from the main frame with exactly this origin. `nil` fails closed:
    /// every message is dropped (mirrors Android's `trustedBridgeOriginRules`
    /// scoping and `isMainFrame` gate on `addWebMessageListener`).
    public var trustedOrigin: String?

    /// Full URL of the entry document the WebView was pointed at, query included
    /// (`AdaWebHost.entryDocumentUrl` supplies it). ``trustedOrigin`` alone is not identity: it is
    /// the whole Ada CDN root, which serves every bot's run of `sdk/webview.html` and a second
    /// top-level entry (`sdk/chat.html`) besides, while the parameters that decide WHOSE session a
    /// document boots — `handle`, `ada_handle`, `cluster`, `ada_cluster`, metaFields — ride the
    /// query. Without this, a subframe that navigates the main frame to another same-origin
    /// document is minted a fresh ticket and receives the host's `setSensitiveMetaFields` /
    /// `setDeviceToken` and the session-mirror seed. `nil` fails closed: no ticket is minted at all.
    public var trustedDocumentUrl: String? {
        didSet {
            // Binding a document resets the diagnostic dedupe, matching Android's
            // `bindDocument`. The dedupe is per DOCUMENT, not per host: a fresh
            // document can hit the same failure again, and a host that never hears
            // the second one cannot tell a one-off from a persistent degradation —
            // which matters most for `adapter-removeItem-failed`, whose documented
            // contract is that the host retries the sign-out.
            reportedSessionMirrorDiagnostics.removeAll()
        }
    }

    // -----------------------------------------------------------------------
    // Private
    // -----------------------------------------------------------------------

    private let userDefaultsKey = "com.ada.bridge.cachedState"
    private let cachedAtKey = "com.ada.bridge.cachedAt"
    private static let stateCacheTtlSeconds: TimeInterval = 10 * 60 // 10 minutes
    private let userDefaults: UserDefaults
    private var cachedState: [String: Any]?

    /// Keychain-backed native session mirror (EXP-1082) — a separate channel
    /// from the branding cache above: no TTL, wiped only by explicit clears.
    let sessionMirrorStore: AdaSessionMirrorStore

    /// `"ada-session-mirror:legacy:<handle>:"` — the prefix every Legacy-run
    /// scope key for this instance's handle carries, so a Messaging-pinned
    /// runtime can refuse a legacy-shaped scope key.
    var sessionMirrorLegacyScopePrefix: String?

    /// The runtime the wrapper pinned for this webview — the authority for
    /// classifying `sdk.session.mirror(Clear)` messages. A message's own
    /// `scopeKey` is page-supplied and must match this runtime's
    /// natively-computed grammar or the message is dropped. `nil` fails
    /// closed: every mirror write and clear is dropped.
    var sessionMirrorRuntime: AdaSessionMirrorRuntime?

    /// WebView the session-mirror command replies are dispatched into — the
    /// `ada.sessionMirrorClearAck` and the pull `sdk.sessionMirror.seed` reply.
    weak var sessionMirrorCommandWebView: WKWebView?

    /// Host event key carrying an ``AdaSessionMirrorDiagnosticReason``. Shared with
    /// Android and React Native's `ada.sessionMirror.diagnostic`, so one host handler
    /// reads every wrapper.
    static let sessionMirrorDiagnosticEventKey = "ada.sessionMirror.diagnostic"

    /// Reasons already reported, so a Keychain failing on every mirror message reports
    /// once rather than once per message.
    var reportedSessionMirrorDiagnostics: Set<AdaSessionMirrorDiagnosticReason> = []

    /// Upper bound on how long ``AdaWebHostCommands/clearPersistedStateDurably()`` blocks its
    /// caller — the main thread, since ``AdaWebHost`` is `@MainActor` — waiting for the off-thread
    /// mirror wipe to report. A wipe that has not settled within this window returns `false`
    /// rather than stranding the caller. It bounds the freeze; it does not avoid one, which is why
    /// ``AdaWebHostCommands/clearPersistedStateDurably(completion:)`` exists.
    static let sessionMirrorClearDurablyTimeout: TimeInterval = 3

    /// How much of ``sessionMirrorClearDurablyTimeout`` a durable clear may spend waiting for
    /// its wipe to reach the head of the mirror queue, as opposed to waiting for the wipe
    /// itself. The queue below is process-wide, so the wipe can sit behind a Keychain write
    /// another mount already accepted — correct ordering, but a wait worth cutting short, because
    /// the wipe could not have been confirmed inside it anyway. Past this grace the caller is
    /// answered `false` (its documented retry signal) while the wipe stays queued and still runs
    /// in order. Wide enough to absorb thread wake-up plus one ordinary Keychain round-trip ahead
    /// of the wipe.
    ///
    /// It does NOT make the blocking call main-actor-safe: once the wipe reaches the head of the
    /// queue this grace is satisfied, and a wipe that then stalls blocks for the remainder of
    /// ``sessionMirrorClearDurablyTimeout``.
    static let sessionMirrorClearDurablyStartGrace: TimeInterval = 0.25

    /// Serial queue that carries every session-mirror Keychain mutation (store,
    /// clear, clearAll) off the `WKScriptMessageHandler` main-thread delivery.
    /// `SecItemAdd`/`SecItemUpdate`/`SecItemDelete` are synchronous disk I/O; a
    /// slow keychain daemon would otherwise hitch the UI. Ordering is FIFO, so a
    /// clear runs after every write already enqueued.
    ///
    /// Process-wide, because the store it orders is: the Keychain is app-scoped
    /// while a handler is per mount, and unmounting a handler does not cancel the
    /// work it already enqueued. A queue per handler orders each mount's own
    /// messages and nothing else, so a second mount's pending write runs
    /// concurrently with the app-scoped sign-out wipe — the wipe verifies the
    /// store empty, reports success, and that write then re-commits the
    /// signed-out session's blob behind it. One shared queue is what makes the
    /// FIFO guarantee above hold against every handler in the process.
    private nonisolated static let sessionMirrorKeychainQueue = DispatchQueue(
        label: "cx.ada.messaging.session-mirror.keychain",
    )

    /// Runs a session-mirror Keychain mutation off the main thread. Default is
    /// the shared serial queue above; tests substitute an inline runner so the
    /// delete-before-ack ordering is observable synchronously.
    var sessionMirrorKeychainRunner: (@escaping () -> Void) -> Void = { work in
        AdaBridgeHandler.sessionMirrorKeychainQueue.async(execute: work)
    }

    /// Marshals a session-mirror command reply — the clear ack and the pull seed
    /// reply, both of which call `evaluateJavaScript` — back to the main thread.
    /// Tests substitute an inline runner.
    var sessionMirrorMainRunner: (@escaping () -> Void) -> Void = { work in
        DispatchQueue.main.async(execute: work)
    }

    // -----------------------------------------------------------------------

    // MARK: - Initialisers

    // -----------------------------------------------------------------------

    /// Default initialiser — uses `UserDefaults.standard`.
    override public init() {
        userDefaults = .standard
        sessionMirrorStore = AdaSessionMirrorStore()
        super.init()
    }

    /// Testing initialiser — injects a custom `UserDefaults` suite so tests
    /// run in isolation without touching `UserDefaults.standard`.
    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        sessionMirrorStore = AdaSessionMirrorStore(userDefaults: userDefaults)
        super.init()
    }

    /// Testing initialiser — additionally injects the session-mirror store so
    /// tests can substitute an in-memory Keychain fake.
    init(userDefaults: UserDefaults, sessionMirrorStore: AdaSessionMirrorStore) {
        self.userDefaults = userDefaults
        self.sessionMirrorStore = sessionMirrorStore
        super.init()
    }

    // -----------------------------------------------------------------------

    // MARK: - Internal static helpers (exposed for unit testing)

    // -----------------------------------------------------------------------

    /// The only keys written to `UserDefaults`.
    ///
    /// An allowlist, not a denylist: a denylist re-opens the hole the first time a new
    /// sensitive key appears upstream, whereas an unrecognized key here is simply not
    /// persisted. Mirrors `PERSISTABLE_NATIVE_STATE_KEYS` in
    /// `packages/sdk/src/frame-channel/types.ts`, which is the canonical list — a drift
    /// test reads this declaration and fails if the two disagree.
    ///
    /// `__ada_cached_at__` is load-bearing: it bounds the hydration snapshot to a 10-minute
    /// TTL on the web side. Dropping it does not disable rehydration — the bridge accepts an
    /// undated snapshot — it removes that bound. This class keeps its own `cachedAtKey`
    /// timestamp, so native still discards a stale snapshot before injecting it.
    nonisolated static let persistableStateKeys: Set<String> = [
        "advancedColorsEnabled",
        "allowedProtocols",
        "button",
        "chatEnabled",
        "fallbackUi",
        "features",
        "intro",
        "proactiveConversations",
        "textOverAccentColor",
        "tintColor",
        "__ada_cached_at__",
    ]

    /// Returns a copy of `state` suitable for persistence, dropping every key outside
    /// `persistableStateKeys`.
    nonisolated static func stateForPersistence(_ state: [String: Any]) -> [String: Any] {
        state.filter { persistableStateKeys.contains($0.key) }
    }

    /// Filters a `sdk.subresourceLoadFailed` bridge message down to its
    /// string-typed fields — a page script could post arbitrary shapes at the
    /// handler.
    nonisolated static func subresourceLoadDetails(from body: [String: Any]) -> [String: Any] {
        var details: [String: Any] = [:]
        if let url = body["url"] as? String {
            details["url"] = url
        }
        if let element = body["element"] as? String {
            details["element"] = element
        }
        return details
    }

    /// Trust decision for an incoming bridge message: main frame only, and the
    /// sender's security origin must equal `trustedOrigin` exactly — a
    /// suffix-lookalike host is foreign. Only http(s) origins are comparable.
    /// `WKSecurityOrigin` reports a scheme-default port as 0, and an explicit
    /// default port normalizes to the omitted form, so `https://host:443` and
    /// `https://host` agree.
    nonisolated static func isTrustedBridgeMessage(
        frameIsMain: Bool,
        originProtocol: String,
        originHost: String,
        originPort: Int,
        trustedOrigin: String?,
    ) -> Bool {
        guard frameIsMain, let trustedOrigin else { return false }
        // Delegate normalization to pageOrigin — the same function that
        // produced trustedOrigin — so the two sides cannot drift.
        // WKSecurityOrigin.host reports IPv6 unbracketed, but URL(string:)
        // rejects an unbracketed IPv6 authority, so re-bracket before parsing;
        // pageOrigin then lowercases and strips default ports on both sides.
        let bareHost = originHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let urlHost = bareHost.contains(":") ? "[\(bareHost)]" : bareHost
        let raw = originPort > 0
            ? "\(originProtocol)://\(urlHost):\(originPort)"
            : "\(originProtocol)://\(urlHost)"
        return AdaWebHost.pageOrigin(ofUrl: raw) == trustedOrigin
    }

    /// Escapes a JSON string so it is safe to pass as a JS template-literal argument.
    ///
    /// Escapes `\` → `\\`, `` ` `` → `` \` ``, and `${` → `\${` to prevent
    /// template-expression injection when the string is used inside backtick
    /// quotes in `evaluateJavaScript`.
    nonisolated static func escapedForTemplateLiteral(_ json: String) -> String {
        json
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")
    }

    // -----------------------------------------------------------------------

    // MARK: - WKScriptMessageHandler

    // -----------------------------------------------------------------------

    public func userContentController(
        _: WKUserContentController,
        didReceive message: WKScriptMessage,
    ) {
        guard message.name == "adaBridge",
              isTrustedSource(of: message),
              let body = message.body as? [String: Any]
        else { return }

        handleBridgeMessage(body)
    }

    /// Whether `message` was posted by the main frame of the trusted host page.
    /// Instance-level so tests can substitute it — `WKFrameInfo` and
    /// `WKSecurityOrigin` cannot be fabricated off-device; the decision itself
    /// lives in `isTrustedBridgeMessage`.
    func isTrustedSource(of message: WKScriptMessage) -> Bool {
        let frameInfo = message.frameInfo
        let origin = frameInfo.securityOrigin
        let trusted = Self.isTrustedBridgeMessage(
            frameIsMain: frameInfo.isMainFrame,
            originProtocol: origin.protocol,
            originHost: origin.host,
            originPort: origin.port,
            trustedOrigin: trustedOrigin,
        )
        if !trusted {
            // Fail-closed with a diagnostic (Android parity: it logs both a
            // missing trusted origin and a rejected sender). A silent drop
            // presents as "chat never becomes ready" with no evidence.
            if trustedOrigin == nil {
                debugPrint(
                    "AdaBridgeHandler: bridge messaging disabled — no trustedOrigin is set; dropping \(message.name) message",
                )
            } else {
                let sender = "\(origin.protocol)://\(origin.host):\(origin.port)"
                debugPrint(
                    "AdaBridgeHandler: rejected bridge message from untrusted source \(sender) (mainFrame: \(frameInfo.isMainFrame))",
                )
            }
        }
        return trusted
    }

    /// Routes a source-validated bridge message body. Split from
    /// `userContentController(_:didReceive:)` so unit tests can drive routing
    /// without fabricating `WKScriptMessage.frameInfo`.
    func handleBridgeMessage(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }

        switch type {
        case "sdk.event":
            let key = body["key"] as? String ?? ""
            delegate?.adaBridge(self, didReceiveEvent: key, data: body["data"])

        case "sdk.ready":
            delegate?.adaBridgeDidBecomeReady?(self)

        case "sdk.state.cache":
            if let state = body["state"] as? [String: Any] {
                persistState(state)
            }

        case "sdk.session.mirror", "sdk.session.mirrorClear", "sdk.session.mirrorRequest",
             "sdk.session.mirrorDiagnostic":
            routeSessionMirrorMessage(type: type, body: body)

        case "sdk.zdChatterAuthRequest":
            delegate?.adaBridgeDidRequestZendeskChatterAuth?(self)

        case "sdk.error":
            let error = body["error"] as? String ?? "Unknown bridge error"
            delegate?.adaBridge?(self, didEncounterError: error)

        case "sdk.subresourceLoadFailed":
            delegate?.adaBridge?(self, didFailSubresourceLoad: Self.subresourceLoadDetails(from: body))

        default:
            break
        }
    }

    // -----------------------------------------------------------------------

    // MARK: - Initial state injection

    // -----------------------------------------------------------------------

    /// Returns a `WKUserScript` that injects the last cached state into
    /// `window.__ADA_INITIAL_STATE__` before the page's document starts loading.
    ///
    /// Add this script to a new `WKWebViewConfiguration` immediately before
    /// creating the `WKWebView` so the chat UI can rehydrate without a spinner.
    ///
    /// Returns `nil` if no state has been cached yet.
    public func makeInitialStateScript() -> WKUserScript? {
        guard let state = cachedState ?? loadPersistedState(),
              let jsonData = try? JSONSerialization.data(withJSONObject: state),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else { return nil }

        // Reject stale cache — prevents rehydrating with outdated state after the
        // app has been backgrounded for more than stateCacheTtlSeconds.
        let cachedAt = userDefaults.double(forKey: cachedAtKey)
        if cachedAt > 0, Date().timeIntervalSince1970 - cachedAt > AdaBridgeHandler.stateCacheTtlSeconds {
            clearPersistedState()
            return nil
        }

        let source = "window.__ADA_INITIAL_STATE__ = \(jsonString);"
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
        )
    }

    // -----------------------------------------------------------------------

    // MARK: - Command dispatch

    // -----------------------------------------------------------------------

    /// Sends a structured command to the SDK running inside the given WebView.
    ///
    /// The command is JSON-encoded and dispatched through
    /// `window.__ADA_BRIDGE_DISPATCH__`, which the in-WebView bridge adapter owns
    /// and validates. No user-supplied values are interpolated into the script
    /// string — the entire payload travels as a single JSON argument.
    ///
    /// - Parameters:
    ///   - command: A `Codable` value matching the `NativeToWebCommand` union
    ///              defined in the bridge adapter TypeScript source.
    ///   - webView: The `WKWebView` hosting the Ada SDK.
    public func sendCommand(
        _ command: some Encodable,
        to webView: WKWebView,
    ) {
        guard let data = try? JSONEncoder().encode(command),
              let json = String(data: data, encoding: .utf8)
        else { return }
        dispatchCommandJson(json, to: webView, ticket: captureDocumentTicket(for: webView))
    }

    // -----------------------------------------------------------------------

    // MARK: - Document ticketing

    // -----------------------------------------------------------------------

    /// The live main-document URL of `webView`. Instance-level so tests can simulate a
    /// main-frame navigation — `WKWebView.url` is read-only and a test bundle cannot load a
    /// document into a WebView.
    func liveDocumentUrl(of webView: WKWebView) -> String? {
        webView.url?.absoluteString
    }

    /// Mints the authority of the document currently occupying `webView`'s main frame, or
    /// `nil` when there is no document worth writing into. Call it when a request is
    /// ACCEPTED and redeem the result at injection time: WebKit reports the live main-document
    /// URL, so a document swapped in between the two mints a different ticket and the
    /// injection is dropped.
    ///
    /// Minted only for the document this mount actually loaded — origin, entry and query
    /// signature all compared (``AdaWebHost/isRuntimeDocumentUrl(_:entryDocumentUrl:)``). Comparing
    /// the origin alone would let a replacement document mint its OWN fresh ticket, so an attacker
    /// would need no outstanding ticket at all: the redemption check, which compares the full URL,
    /// only catches a swap that happens after a mint.
    func captureDocumentTicket(for webView: WKWebView) -> AdaDocumentTicket? {
        guard let trustedOrigin,
              let trustedDocumentUrl,
              let documentUrl = liveDocumentUrl(of: webView),
              AdaWebHost.pageOrigin(ofUrl: documentUrl) == trustedOrigin,
              AdaWebHost.isRuntimeDocumentUrl(documentUrl, entryDocumentUrl: trustedDocumentUrl)
        else { return nil }
        return AdaDocumentTicket(webView: ObjectIdentifier(webView), documentUrl: documentUrl)
    }

    /// The only `evaluateJavaScript` call site in this class, so a new injection sink cannot
    /// half-implement the guard: without a ticket it has nothing to inject through. Re-mints
    /// on redemption and refuses anything but an exact match.
    @discardableResult
    func injectIntoDocument(_ ticket: AdaDocumentTicket?, script: String, to webView: WKWebView) -> Bool {
        guard let ticket, ticket == captureDocumentTicket(for: webView) else { return false }
        webView.evaluateJavaScript(script, completionHandler: nil)
        return true
    }

    /// Dispatches a session-mirror reply and reports the refusal when the document that asked is
    /// gone. Ordinary commands stay on the silent ``dispatchCommand(_:to:ticket:)`` path: a dropped
    /// `ada.setLanguage` is not a mirror degradation, and reporting it under the mirror's event key
    /// would cost that channel its meaning.
    private func dispatchSessionMirrorReply(
        _ command: [String: Any],
        to webView: WKWebView,
        ticket: AdaDocumentTicket?,
    ) {
        if !dispatchCommand(command, to: webView, ticket: ticket) {
            emitSessionMirrorDiagnostic(.documentMismatch)
        }
    }

    // -----------------------------------------------------------------------

    // MARK: - Typed command convenience methods

    // -----------------------------------------------------------------------

    /// Answer a `sdk.zdChatterAuthRequest` with the host's Zendesk Chat chatter-auth token.
    ///
    /// Pass `nil` when the host has no token configured: core resolves immediately instead of
    /// waiting out the SDK's 10s auth timeout, which it would otherwise do on every cycle.
    public func sendZendeskChatterAuthResponse(token: String?, to webView: WKWebView) {
        dispatchCommand(
            [
                "type": "ada.zdChatterAuthResponse",
                "payload": ["token": token.map { $0 as Any } ?? NSNull()],
            ],
            to: webView,
            ticket: captureDocumentTicket(for: webView),
        )
    }

    /// Update meta-fields without resetting the session.
    public func setMetaFields(_ fields: [String: Any], to webView: WKWebView) {
        dispatchCommand(
            [
                "type": "ada.setMetaFields",
                "payload": ["fields": fields],
            ],
            to: webView,
            ticket: captureDocumentTicket(for: webView),
        )
    }

    /// Update sensitive meta-fields without resetting the session.
    public func setSensitiveMetaFields(_ fields: [String: Any], to webView: WKWebView) {
        dispatchCommand(
            [
                "type": "ada.setSensitiveMetaFields",
                "payload": ["fields": fields],
            ],
            to: webView,
            ticket: captureDocumentTicket(for: webView),
        )
    }

    /// Set the push-notification device token.
    public func setDeviceToken(_ token: String, to webView: WKWebView) {
        dispatchCommand(
            ["type": "ada.setDeviceToken", "payload": ["token": token]],
            to: webView,
            ticket: captureDocumentTicket(for: webView),
        )
    }

    /// Change the display language.
    public func setLanguage(_ language: String, to webView: WKWebView) {
        dispatchCommand(
            ["type": "ada.setLanguage", "payload": ["language": language]],
            to: webView,
            ticket: captureDocumentTicket(for: webView),
        )
    }

    /// Programmatically send a user message into the conversation.
    public func sendMessage(_ body: String, to webView: WKWebView) {
        dispatchCommand(
            ["type": "ada.sendMessage", "payload": ["body": body]],
            to: webView,
            ticket: captureDocumentTicket(for: webView),
        )
    }

    /// Delete chat history and reset the session.
    public func deleteHistory(to webView: WKWebView) {
        dispatchCommand(
            ["type": "ada.deleteHistory"],
            to: webView,
            ticket: captureDocumentTicket(for: webView),
        )
    }

    /// Reset the Ada session with optional language, greeting, meta-fields, and history flags.
    ///
    /// `resetChatHistory` is tri-state: `true` and `false` are sent explicitly —
    /// an omitted `false` would let the SDK's missing-key default silently destroy
    /// the conversation and mint a new end user instead of taking the
    /// history-preserving path. `nil` omits the key so the runtime applies its own
    /// default (currently a full reset), matching Android and React Native. The
    /// parameter default stays `true` so a plain `reset` keeps requesting the full
    /// reset explicitly rather than depending on that runtime default.
    public func reset(
        language: String? = nil,
        greeting: String? = nil,
        metaFields: [String: Any]? = nil,
        sensitiveMetaFields: [String: Any]? = nil,
        resetChatHistory: Bool? = true,
        to webView: WKWebView,
    ) {
        var payload: [String: Any] = [:]
        if let language { payload["language"] = language }
        if let greeting { payload["greeting"] = greeting }
        if let metaFields { payload["metaFields"] = metaFields }
        if let sensitiveMetaFields { payload["sensitiveMetaFields"] = sensitiveMetaFields }
        if let resetChatHistory { payload["resetChatHistory"] = resetChatHistory }
        dispatchCommand(
            ["type": "ada.reset", "payload": payload],
            to: webView,
            ticket: captureDocumentTicket(for: webView),
        )
    }

    /// Acknowledges a durably committed session-mirror clear back into the web
    /// runtime. Must only be called AFTER the store delete returned success —
    /// the web-side MES-1376 barrier treats this ack as proof the native blob
    /// can no longer resurrect the cleared session, so a failed or unverified
    /// delete must time out unacked instead.
    ///
    /// `ticket` is the document that asked. The delete runs off the main thread, so by the
    /// time it reports, the asking document may be gone; a dropped ack times the web side
    /// out, which tombstones the blob — the safe direction.
    func acknowledgeSessionMirrorClear(requestId: String, ticket: AdaDocumentTicket?) {
        guard let webView = sessionMirrorCommandWebView else { return }
        dispatchSessionMirrorReply(
            ["type": "ada.sessionMirrorClearAck", "requestId": requestId],
            to: webView,
            ticket: ticket,
        )
    }

    /// Dispatches the session-mirror pull response into the web runtime through the same typed
    /// command path the clear-ack uses. On the Messaging page the SDK bridge adapter routes
    /// `sdk.sessionMirror.seed`; on the Legacy page the injected bootstrap script defines its
    /// own `__ADA_BRIDGE_DISPATCH__` receiver for it. An absent blob is sent as an explicit
    /// `null` seed; `ticket` pins the reply to the document that asked.
    ///
    /// Lives in the class body rather than beside its caller in `AdaSessionMirrorStore.swift`
    /// because a ticket is not ObjC-representable, so the method is not implicitly `@objc` and
    /// an extension declaration could not be overridden by the test spy.
    func deliverSessionMirrorSeed(requestId: String, seed: [String: Any]?, ticket: AdaDocumentTicket?) {
        guard let webView = sessionMirrorCommandWebView else { return }
        dispatchSessionMirrorReply(
            ["type": "sdk.sessionMirror.seed", "requestId": requestId, "seed": seed ?? NSNull()],
            to: webView,
            ticket: ticket,
        )
    }

    /// Serialise a `[String: Any]` command dict and dispatch it to the WebView.
    /// Used by typed convenience methods; `sendCommand<T: Encodable>` is
    /// preferred when a `Codable` command struct is available.
    ///
    /// `ticket` has no default on purpose. A caller answering a request the page made
    /// captures it when the request is accepted and passes that value here; a caller issuing
    /// a host command mints one inline, which is what makes the command apply to whatever
    /// runtime document is live rather than a departed one.
    @discardableResult
    func dispatchCommand(_ command: [String: Any], to webView: WKWebView, ticket: AdaDocumentTicket?) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: command),
              let json = String(data: data, encoding: .utf8)
        else { return false }
        return dispatchCommandJson(json, to: webView, ticket: ticket)
    }

    @discardableResult
    private func dispatchCommandJson(_ json: String, to webView: WKWebView, ticket: AdaDocumentTicket?) -> Bool {
        let escaped = AdaBridgeHandler.escapedForTemplateLiteral(json)
        return injectIntoDocument(
            ticket,
            script: "if(window.__ADA_BRIDGE_DISPATCH__){window.__ADA_BRIDGE_DISPATCH__(`\(escaped)`)}true;",
            to: webView,
        )
    }

    // -----------------------------------------------------------------------

    // MARK: - State persistence (private)

    // -----------------------------------------------------------------------

    private func persistState(_ state: [String: Any]) {
        let persistedState = AdaBridgeHandler.stateForPersistence(state)
        cachedState = persistedState
        // Serialize to JSON Data so NSNull values (JSON null) are stored correctly.
        // UserDefaults.set(_:forKey:) rejects raw [String: Any] dicts containing NSNull.
        guard let data = try? JSONSerialization.data(withJSONObject: persistedState) else { return }
        userDefaults.set(data, forKey: userDefaultsKey)
        userDefaults.set(Date().timeIntervalSince1970, forKey: cachedAtKey)
    }

    private func loadPersistedState() -> [String: Any]? {
        guard let data = userDefaults.data(forKey: userDefaultsKey),
              let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        cachedState = state
        return state
    }

    /// Removes the persisted state cache from UserDefaults (e.g. on sign-out).
    public func clearPersistedState() {
        cachedState = nil
        userDefaults.removeObject(forKey: userDefaultsKey)
        userDefaults.removeObject(forKey: cachedAtKey)
    }
}
