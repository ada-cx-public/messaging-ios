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
//   • The persisted state cache may contain session credentials and other
//     sensitive session fields needed for fast rehydration. Clear it on sign-out
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

    /// Returns a copy of `state` suitable for persistence.
    nonisolated static func stateForPersistence(_ state: [String: Any]) -> [String: Any] {
        state
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
              let body = message.body as? [String: Any],
              let type = body["type"] as? String
        else { return }

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

        case "sdk.error":
            let error = body["error"] as? String ?? "Unknown bridge error"
            delegate?.adaBridge?(self, didEncounterError: error)

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

    /// Delete chat history and reset the session.
    public func deleteHistory(to webView: WKWebView) {
        dispatchCommand(["type": "ada.deleteHistory"], to: webView)
    }

    /// Reset the Ada session with optional language, greeting, meta-fields, and history flags.
    public func reset(
        language: String? = nil,
        greeting: String? = nil,
        metaFields: [String: Any]? = nil,
        sensitiveMetaFields: [String: Any]? = nil,
        resetChatHistory: Bool = false,
        to webView: WKWebView,
    ) {
        var payload: [String: Any] = [:]
        if let language { payload["language"] = language }
        if let greeting { payload["greeting"] = greeting }
        if let metaFields { payload["metaFields"] = metaFields }
        if let sensitiveMetaFields { payload["sensitiveMetaFields"] = sensitiveMetaFields }
        if resetChatHistory { payload["resetChatHistory"] = true }
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
