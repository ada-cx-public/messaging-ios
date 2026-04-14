//
//  MessagingFrameworkTests.swift
//  AdaMessagingTests
//
//  Unit tests for AdaBridgeHandler using Swift Testing.
//
// swiftlint:disable file_length

@testable import AdaMessaging
import Foundation
import Testing
import UIKit
import WebKit

// ---------------------------------------------------------------------------

// MARK: - AdaBridgeHandlerTests

// ---------------------------------------------------------------------------

enum AdaBridgeHandlerTests {
    // -----------------------------------------------------------------------

    // MARK: - stripSensitiveKeys

    // -----------------------------------------------------------------------

    struct StripSensitiveKeysTests {
        @Test
        func `removes csat.chatterToken`() {
            let input: [String: Any] = ["csat.chatterToken": "secret", "other": "keep"]
            let result = AdaBridgeHandler.stripSensitiveKeys(input)
            #expect(result["csat.chatterToken"] == nil)
            #expect(result["other"] as? String == "keep")
        }

        @Test
        func `removes csat.sessionToken`() {
            let input: [String: Any] = ["csat.sessionToken": "tok", "name": "Ada"]
            let result = AdaBridgeHandler.stripSensitiveKeys(input)
            #expect(result["csat.sessionToken"] == nil)
            #expect(result["name"] as? String == "Ada")
        }

        @Test
        func `preserves non-sensitive keys`() {
            let input: [String: Any] = ["foo": "bar", "count": 42]
            let result = AdaBridgeHandler.stripSensitiveKeys(input)
            #expect(result["foo"] as? String == "bar")
            #expect(result["count"] as? Int == 42)
        }

        @Test
        func `returns empty dict unchanged`() {
            let result = AdaBridgeHandler.stripSensitiveKeys([:])
            #expect(result.isEmpty)
        }
    }

    // -----------------------------------------------------------------------

    // MARK: - escapedForTemplateLiteral

    // -----------------------------------------------------------------------

    struct EscapedForTemplateLiteralTests {
        @Test
        func `escapes backslashes`() {
            let result = AdaBridgeHandler.escapedForTemplateLiteral("a\\b")
            #expect(result == "a\\\\b")
        }

        @Test
        func `escapes backticks`() {
            let result = AdaBridgeHandler.escapedForTemplateLiteral("he said `hi`")
            #expect(result == "he said \\`hi\\`")
        }

        @Test
        func `escapes template expressions`() {
            // Input: ${evil}  →  Output: \${evil}
            let result = AdaBridgeHandler.escapedForTemplateLiteral("${evil}")
            #expect(result == "\\${evil}")
        }

        @Test
        func `leaves plain JSON unchanged`() {
            let json = #"{"key":"value","n":1}"#
            let result = AdaBridgeHandler.escapedForTemplateLiteral(json)
            #expect(result == json)
        }

        @Test
        func `escapes backslash before backtick correctly`() {
            // Input: \`  →  should become \\` (backslash escaping happens first)
            let result = AdaBridgeHandler.escapedForTemplateLiteral("\\`")
            #expect(result == "\\\\\\`")
        }
    }

    // -----------------------------------------------------------------------

    // MARK: - State persistence

    // -----------------------------------------------------------------------

    @MainActor struct StatePersistenceTests {
        private static let userDefaultsKey = "com.ada.bridge.cachedState"
        private static let cachedAtKey = "com.ada.bridge.cachedAt"

        private func makeIsolatedDefaults() -> UserDefaults {
            let suite = "com.ada.bridge.test.\(UUID().uuidString)"
            return UserDefaults(suiteName: suite)!
        }

        /// Seeds `defaults` with the given state dict serialised as JSON Data,
        /// matching the format written by `AdaBridgeHandler.persistState`.
        private func seedState(_ state: [String: Any], in defaults: UserDefaults) {
            guard let data = try? JSONSerialization.data(withJSONObject: state) else {
                return
            }
            defaults.set(data, forKey: Self.userDefaultsKey)
        }

        @Test
        func `makeInitialStateScript returns nil with empty UserDefaults`() {
            let handler = AdaBridgeHandler(userDefaults: makeIsolatedDefaults())
            #expect(handler.makeInitialStateScript() == nil)
        }

        @Test
        func `makeInitialStateScript returns script after state seeded in UserDefaults`() throws {
            let defaults = makeIsolatedDefaults()
            seedState(["botName": "Ada", "sessionId": "abc"], in: defaults)
            let handler = AdaBridgeHandler(userDefaults: defaults)
            let script = try #require(handler.makeInitialStateScript())
            #expect(script.source.hasPrefix("window.__ADA_INITIAL_STATE__"))
            #expect(script.injectionTime == .atDocumentStart)
        }

        @Test
        func `clearPersistedState causes makeInitialStateScript to return nil`() {
            let defaults = makeIsolatedDefaults()
            seedState(["x": "y"], in: defaults)
            let handler = AdaBridgeHandler(userDefaults: defaults)
            handler.clearPersistedState()
            #expect(handler.makeInitialStateScript() == nil)
        }

        // MARK: TTL behaviour

        @Test
        func `makeInitialStateScript returns nil for stale cache (older than 10 min TTL)`() {
            let defaults = makeIsolatedDefaults()
            seedState(["botName": "Ada"], in: defaults)
            // 11 minutes in the past — past the 10-minute TTL
            defaults.set(Date().timeIntervalSince1970 - 11 * 60, forKey: Self.cachedAtKey)
            let handler = AdaBridgeHandler(userDefaults: defaults)
            #expect(handler.makeInitialStateScript() == nil)
        }

        @Test
        func `makeInitialStateScript returns script for fresh cache (within 10 min TTL)`() throws {
            let defaults = makeIsolatedDefaults()
            seedState(["botName": "Ada"], in: defaults)
            // 5 minutes in the past — within the 10-minute TTL
            defaults.set(Date().timeIntervalSince1970 - 5 * 60, forKey: Self.cachedAtKey)
            let handler = AdaBridgeHandler(userDefaults: defaults)
            let script = try #require(handler.makeInitialStateScript())
            #expect(script.source.hasPrefix("window.__ADA_INITIAL_STATE__"))
        }

        @Test
        func `clearPersistedState also removes the cachedAt timestamp key`() {
            let defaults = makeIsolatedDefaults()
            seedState(["x": "y"], in: defaults)
            defaults.set(Date().timeIntervalSince1970, forKey: Self.cachedAtKey)
            let handler = AdaBridgeHandler(userDefaults: defaults)
            handler.clearPersistedState()
            // After clearing, double(forKey:) returns 0 when the key is absent
            #expect(defaults.double(forKey: Self.cachedAtKey) == 0)
            #expect(handler.makeInitialStateScript() == nil)
        }

        @Test
        func `makeInitialStateScript produces the correct assignment statement`() throws {
            let defaults = makeIsolatedDefaults()
            seedState(["botName": "Ada"], in: defaults)
            let handler = AdaBridgeHandler(userDefaults: defaults)
            let script = try #require(handler.makeInitialStateScript())
            #expect(script.source.hasPrefix("window.__ADA_INITIAL_STATE__ = "))
            #expect(script.source.hasSuffix(";"))
            #expect(script.source.contains("Ada"))
        }

        @Test
        func `makeInitialStateScript targets main frame only`() throws {
            let defaults = makeIsolatedDefaults()
            seedState(["x": "y"], in: defaults)
            let handler = AdaBridgeHandler(userDefaults: defaults)
            let script = try #require(handler.makeInitialStateScript())
            #expect(script.isForMainFrameOnly)
        }
    }
}

@MainActor
enum AdaWebHostDefaultsTests {
    @Test
    static func `defaults to the legacy web runtime`() {
        let host = AdaWebHost(handle: "ada-example")
        #expect(host.webSdk == .legacy)
    }
}

@MainActor
enum AdaResourceLoadingTests {
    @Test
    static func `loads web controller storyboard resources`() {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let controller = AdaWebHostViewController.createWebController(with: webView)

        #expect(controller.webView === webView)
    }

    @Test
    static func `loads offline controller storyboard resources`() throws {
        let controller = try #require(OfflineViewController.create())

        controller.loadViewIfNeeded()

        #expect(controller.container != nil)
        #expect(controller.retryButton != nil)
    }
}

enum AdaEnvironmentTests {
    @Test
    static func `local environment uses localhost loopback origins`() {
        let environment = AdaEnvironment.local()
        #expect(environment.cdnOrigin == "https://localhost:4900")
        #expect(environment.sdkUrl == "https://localhost:4900/sdk/index.js")
        #expect(environment.webviewHtmlUrl == "https://localhost:4900/sdk/webview.html")
        #expect(environment.webviewCluster == "localhost")
        #expect(environment.cspConnectSrc == "https://localhost:4900 https: wss:")
    }

    @Test
    static func `local environment respects custom ports`() {
        let environment = AdaEnvironment.local(port: 5123)
        #expect(environment.cdnOrigin == "https://localhost:5123")
        #expect(environment.sdkUrl == "https://localhost:5123/sdk/index.js")
        #expect(environment.webviewHtmlUrl == "https://localhost:5123/sdk/webview.html")
        #expect(environment.cspConnectSrc == "https://localhost:5123 https: wss:")
    }
}

// ---------------------------------------------------------------------------

// MARK: - Shared test doubles

// ---------------------------------------------------------------------------

/// `WKScriptMessage` subclass that allows injecting arbitrary `name` / `body`
/// in unit tests. Both properties are `open` in WebKit — this override is supported.
private final class FakeScriptMessage: WKScriptMessage {
    private let _name: String
    private let _body: Any

    init(name: String = "adaBridge", body: Any) {
        _name = name
        _body = body
    }

    override var name: String {
        _name
    }

    override var body: Any {
        _body
    }
}

/// Spy delegate that records all callbacks.
private final class SpyDelegate: NSObject, AdaBridgeDelegate {
    var events: [(key: String, data: Any?)] = []
    var readyCalled = false
    var errors: [String] = []

    func adaBridge(_: AdaBridgeHandler, didReceiveEvent key: String, data: Any?) {
        events.append((key: key, data: data))
    }

    func adaBridgeDidBecomeReady(_: AdaBridgeHandler) {
        readyCalled = true
    }

    func adaBridge(_: AdaBridgeHandler, didEncounterError error: String) {
        errors.append(error)
    }
}

/// `WKWebView` subclass that captures `evaluateJavaScript` calls without executing them.
/// `evaluateJavaScript` is `open` in WebKit — this override is supported.
private final class ScriptCapturingWebView: WKWebView {
    var capturedScripts: [String] = []

    init() {
        super.init(frame: .zero, configuration: WKWebViewConfiguration())
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Not used in tests")
    }

    override func evaluateJavaScript(
        _ javaScriptString: String,
        completionHandler _: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil,
    ) {
        capturedScripts.append(javaScriptString)
    }
}

// ---------------------------------------------------------------------------

// MARK: - WKScriptMessageHandler routing

// ---------------------------------------------------------------------------

extension AdaBridgeHandlerTests {
    @MainActor struct MessageRoutingTests {
        private func makeIsolatedDefaults() -> UserDefaults {
            UserDefaults(suiteName: "com.ada.bridge.test.\(UUID().uuidString)")!
        }

        private func makeHandler(defaults: UserDefaults? = nil) -> AdaBridgeHandler {
            AdaBridgeHandler(userDefaults: defaults ?? makeIsolatedDefaults())
        }

        private func send(_ body: [String: Any], name: String = "adaBridge", to handler: AdaBridgeHandler) {
            handler.userContentController(
                WKUserContentController(),
                didReceive: FakeScriptMessage(name: name, body: body),
            )
        }

        // MARK: sdk.event

        @Test
        func `sdk.event forwards key to delegate`() {
            let handler = makeHandler()
            let spy = SpyDelegate()
            handler.delegate = spy
            send(["type": "sdk.event", "key": "ada:conversation_start"], to: handler)
            #expect(spy.events.count == 1)
            #expect(spy.events[0].key == "ada:conversation_start")
        }

        @Test
        func `sdk.event with missing key defaults to empty string`() {
            let handler = makeHandler()
            let spy = SpyDelegate()
            handler.delegate = spy
            send(["type": "sdk.event"], to: handler)
            #expect(spy.events.count == 1)
            #expect(spy.events[0].key.isEmpty)
        }

        @Test
        func `sdk.event passes data payload to delegate`() {
            let handler = makeHandler()
            let spy = SpyDelegate()
            handler.delegate = spy
            send(["type": "sdk.event", "key": "ada:msg", "data": ["id": "42"]], to: handler)
            #expect(spy.events.count == 1)
            let data = spy.events[0].data as? [String: Any]
            #expect(data?["id"] as? String == "42")
        }

        // MARK: sdk.ready

        @Test
        func `sdk.ready calls adaBridgeDidBecomeReady on delegate`() {
            let handler = makeHandler()
            let spy = SpyDelegate()
            handler.delegate = spy
            send(["type": "sdk.ready"], to: handler)
            #expect(spy.readyCalled)
        }

        // MARK: sdk.state.cache

        @Test
        func `sdk.state.cache strips sensitive keys before persisting`() throws {
            let handler = makeHandler()
            send([
                "type": "sdk.state.cache",
                "state": ["botName": "Ada", "csat.chatterToken": "secret", "csat.sessionToken": "tok"],
            ], to: handler)
            let script = try #require(handler.makeInitialStateScript())
            #expect(!script.source.contains("chatterToken"))
            #expect(!script.source.contains("sessionToken"))
            #expect(script.source.contains("Ada"))
        }

        @Test
        func `sdk.state.cache populates in-memory cache so makeInitialStateScript succeeds`() throws {
            let handler = makeHandler()
            send(["type": "sdk.state.cache", "state": ["x": "y"]], to: handler)
            let script = try #require(handler.makeInitialStateScript())
            #expect(script.source.hasPrefix("window.__ADA_INITIAL_STATE__"))
        }

        @Test
        func `sdk.state.cache writes a cachedAt timestamp to UserDefaults`() {
            let defaults = makeIsolatedDefaults()
            let handler = makeHandler(defaults: defaults)
            let before = Date().timeIntervalSince1970
            send(["type": "sdk.state.cache", "state": ["x": "y"]], to: handler)
            let after = Date().timeIntervalSince1970
            let cachedAt = defaults.double(forKey: "com.ada.bridge.cachedAt")
            #expect(cachedAt >= before)
            #expect(cachedAt <= after)
        }

        @Test
        func `sdk.state.cache with missing state field is a no-op`() {
            let handler = makeHandler()
            send(["type": "sdk.state.cache"], to: handler)
            #expect(handler.makeInitialStateScript() == nil)
        }

        // MARK: sdk.error

        @Test
        func `sdk.error forwards error string to delegate`() {
            let handler = makeHandler()
            let spy = SpyDelegate()
            handler.delegate = spy
            send(["type": "sdk.error", "error": "fatal bridge error"], to: handler)
            #expect(spy.errors == ["fatal bridge error"])
        }

        @Test
        func `sdk.error with missing error key uses fallback message`() {
            let handler = makeHandler()
            let spy = SpyDelegate()
            handler.delegate = spy
            send(["type": "sdk.error"], to: handler)
            #expect(spy.errors == ["Unknown bridge error"])
        }

        // MARK: Guard conditions

        @Test
        func `unknown message type is silently ignored`() {
            let handler = makeHandler()
            let spy = SpyDelegate()
            handler.delegate = spy
            send(["type": "sdk.unknown"], to: handler)
            #expect(spy.events.isEmpty)
            #expect(!spy.readyCalled)
            #expect(spy.errors.isEmpty)
        }

        @Test
        func `wrong handler name (not adaBridge) is ignored`() {
            let handler = makeHandler()
            let spy = SpyDelegate()
            handler.delegate = spy
            send(["type": "sdk.ready"], name: "otherHandler", to: handler)
            #expect(!spy.readyCalled)
        }

        @Test
        func `non-dictionary body is silently ignored`() {
            let handler = makeHandler()
            let spy = SpyDelegate()
            handler.delegate = spy
            handler.userContentController(
                WKUserContentController(),
                didReceive: FakeScriptMessage(body: "not a dict"),
            )
            #expect(!spy.readyCalled)
            #expect(spy.events.isEmpty)
        }
    }
}

// ---------------------------------------------------------------------------

// MARK: - dispatchCommand script format

// ---------------------------------------------------------------------------

extension AdaBridgeHandlerTests {
    @MainActor struct DispatchCommandTests {
        private func makeHandler() -> AdaBridgeHandler {
            AdaBridgeHandler(userDefaults: UserDefaults(suiteName: "com.ada.bridge.test.\(UUID().uuidString)")!)
        }

        @Test
        func `script uses the __ADA_BRIDGE_DISPATCH__ template`() throws {
            let handler = makeHandler()
            let webView = ScriptCapturingWebView()
            handler.dispatchCommand(["type": "ada.setLanguage", "payload": ["language": "fr"]], to: webView)
            let script = try #require(webView.capturedScripts.first)
            #expect(script.hasPrefix("if(window.__ADA_BRIDGE_DISPATCH__)"))
            #expect(script.contains("window.__ADA_BRIDGE_DISPATCH__(`"))
            #expect(script.hasSuffix("}true;"))
        }

        @Test
        func `command dict is serialised as JSON inside the script`() throws {
            let handler = makeHandler()
            let webView = ScriptCapturingWebView()
            handler.dispatchCommand(["type": "ada.deleteHistory"], to: webView)
            let script = try #require(webView.capturedScripts.first)
            #expect(script.contains("ada.deleteHistory"))
        }

        @Test
        func `backtick in value is escaped to prevent template-literal injection`() throws {
            let handler = makeHandler()
            let webView = ScriptCapturingWebView()
            handler.dispatchCommand(["type": "ada.setLanguage", "payload": ["language": "fr`x"]], to: webView)
            let script = try #require(webView.capturedScripts.first)
            #expect(script.contains("\\`"))
        }

        @Test
        func `dollar-brace in value is escaped to prevent template expression injection`() throws {
            let handler = makeHandler()
            let webView = ScriptCapturingWebView()
            handler.dispatchCommand(["type": "ada.setLanguage", "payload": ["language": "${evil}"]], to: webView)
            let script = try #require(webView.capturedScripts.first)
            #expect(script.contains("\\${"))
        }

        @Test
        func `setLanguage convenience method emits correct type and language`() throws {
            let handler = makeHandler()
            let webView = ScriptCapturingWebView()
            handler.setLanguage("de", to: webView)
            let script = try #require(webView.capturedScripts.first)
            #expect(script.contains("ada.setLanguage"))
            #expect(script.contains("de"))
        }

        @Test
        func `triggerAnswer convenience method emits correct type and responseId`() throws {
            let handler = makeHandler()
            let webView = ScriptCapturingWebView()
            handler.triggerAnswer(responseId: "resp-1", to: webView)
            let script = try #require(webView.capturedScripts.first)
            #expect(script.contains("ada.triggerAnswer"))
            #expect(script.contains("resp-1"))
        }

        @Test
        func `deleteHistory convenience method emits correct type`() throws {
            let handler = makeHandler()
            let webView = ScriptCapturingWebView()
            handler.deleteHistory(to: webView)
            let script = try #require(webView.capturedScripts.first)
            #expect(script.contains("ada.deleteHistory"))
        }

        @Test
        func `reset with language and resetChatHistory emits correct payload`() throws {
            let handler = makeHandler()
            let webView = ScriptCapturingWebView()
            handler.reset(language: "fr", resetChatHistory: true, to: webView)
            let script = try #require(webView.capturedScripts.first)
            #expect(script.contains("ada.reset"))
            #expect(script.contains("fr"))
            #expect(script.contains("resetChatHistory"))
        }

        @Test
        func `reset with no arguments emits type only (empty payload)`() throws {
            let handler = makeHandler()
            let webView = ScriptCapturingWebView()
            handler.reset(to: webView)
            let script = try #require(webView.capturedScripts.first)
            #expect(script.contains("ada.reset"))
        }
    }
}
