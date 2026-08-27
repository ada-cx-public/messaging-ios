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

    // -----------------------------------------------------------------------
    // Private
    // -----------------------------------------------------------------------

    private let userDefaultsKey = "com.ada.bridge.cachedState"
    private let cachedAtKey = "com.ada.bridge.cachedAt"
    private static let stateCacheTtlSeconds: TimeInterval = 10 * 60 // 10 minutes
    private let userDefaults: UserDefaults
    private var cachedState: [String: Any]?

    // -----------------------------------------------------------------------

    // MARK: - Initialisers

    // -----------------------------------------------------------------------

    /// Default initialiser — uses `UserDefaults.standard`.
    override public init() {
        userDefaults = .standard
        super.init()
    }

    /// Testing initialiser — injects a custom `UserDefaults` suite so tests
    /// run in isolation without touching `UserDefaults.standard`.
    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
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

        let escaped = AdaBridgeHandler.escapedForTemplateLiteral(json)
        let script = "if(window.__ADA_BRIDGE_DISPATCH__){window.__ADA_BRIDGE_DISPATCH__(`\(escaped)`)}true;"
        webView.evaluateJavaScript(script, completionHandler: nil)
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
        )
    }

    /// Set the push-notification device token.
    public func setDeviceToken(_ token: String, to webView: WKWebView) {
        dispatchCommand(["type": "ada.setDeviceToken", "payload": ["token": token]], to: webView)
    }

    /// Change the display language.
    public func setLanguage(_ language: String, to webView: WKWebView) {
        dispatchCommand(["type": "ada.setLanguage", "payload": ["language": language]], to: webView)
    }

    /// Programmatically send a user message into the conversation.
    public func sendMessage(_ body: String, to webView: WKWebView) {
        dispatchCommand(["type": "ada.sendMessage", "payload": ["body": body]], to: webView)
    }

    /// Delete chat history and reset the session.
    public func deleteHistory(to webView: WKWebView) {
        dispatchCommand(["type": "ada.deleteHistory"], to: webView)
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
        dispatchCommand(["type": "ada.reset", "payload": payload], to: webView)
    }

    /// Serialise a `[String: Any]` command dict and dispatch it to the WebView.
    /// Used by typed convenience methods; `sendCommand<T: Encodable>` is
    /// preferred when a `Codable` command struct is available.
    func dispatchCommand(_ command: [String: Any], to webView: WKWebView) {
        guard let data = try? JSONSerialization.data(withJSONObject: command),
              let json = String(data: data, encoding: .utf8)
        else { return }
        let escaped = AdaBridgeHandler.escapedForTemplateLiteral(json)
        let script = "if(window.__ADA_BRIDGE_DISPATCH__){window.__ADA_BRIDGE_DISPATCH__(`\(escaped)`)}true;"
        webView.evaluateJavaScript(script, completionHandler: nil)
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
