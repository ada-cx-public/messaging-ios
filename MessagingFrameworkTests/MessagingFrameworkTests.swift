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

private let semverPattern = #"^\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"#

private func packageVersionFromSourceCheckout(filePath: String = #filePath) -> String? {
    let testsDirectory = URL(fileURLWithPath: filePath).deletingLastPathComponent()
    let iosDirectory = testsDirectory.deletingLastPathComponent()
    let packageManifestPath = iosDirectory.appendingPathComponent("package.json")

    guard let data = try? Data(contentsOf: packageManifestPath),
          let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let version = manifest["version"] as? String
    else {
        return nil
    }

    return version
}

private func makeTemporaryBundle(version: String) throws -> (url: URL, bundle: Bundle) {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("bundle")
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

    let info: [String: Any] = [
        "CFBundleIdentifier": "cx.ada.messaging.tests.\(UUID().uuidString)",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "AdaMessagingTestBundle",
        "CFBundlePackageType": "BNDL",
        "CFBundleShortVersionString": version,
    ]
    let data = try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .xml,
        options: 0,
    )
    try data.write(to: bundleURL.appendingPathComponent("Info.plist"))

    guard let bundle = Bundle(url: bundleURL) else {
        throw CocoaError(.fileReadInvalidFileName)
    }

    return (bundleURL, bundle)
}

// ---------------------------------------------------------------------------

// MARK: - AdaBridgeHandlerTests

// ---------------------------------------------------------------------------

enum AdaBridgeHandlerTests {
    // -----------------------------------------------------------------------

    // MARK: - stateForPersistence

    // -----------------------------------------------------------------------

    struct StateForPersistenceTests {
        @Test
        func `preserves csat.chatterToken`() {
            let input: [String: Any] = ["csat.chatterToken": "secret", "other": "keep"]
            let result = AdaBridgeHandler.stateForPersistence(input)
            #expect(result["csat.chatterToken"] as? String == "secret")
            #expect(result["other"] as? String == "keep")
        }

        @Test
        func `preserves csat.sessionToken`() {
            let input: [String: Any] = ["csat.sessionToken": "tok", "name": "Ada"]
            let result = AdaBridgeHandler.stateForPersistence(input)
            #expect(result["csat.sessionToken"] as? String == "tok")
            #expect(result["name"] as? String == "Ada")
        }

        @Test
        func `preserves non-session keys`() {
            let input: [String: Any] = ["foo": "bar", "count": 42]
            let result = AdaBridgeHandler.stateForPersistence(input)
            #expect(result["foo"] as? String == "bar")
            #expect(result["count"] as? Int == 42)
        }

        @Test
        func `returns empty dict unchanged`() {
            let result = AdaBridgeHandler.stateForPersistence([:])
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

    @Test
    static func `host telemetry includes the package semver version`() {
        let host = AdaWebHost(handle: "ada-example")
        let payload = host.hostTelemetryPayload()
        let actualVersion = payload["mobileVersion"]
        let expectedVersion = ProcessInfo.processInfo.environment["ADA_MESSAGING_PACKAGE_VERSION"] ??
            packageVersionFromSourceCheckout()

        #expect(payload["mobilePackage"] == "messaging-ios")

        // Source-package checkouts intentionally keep a `0.0.0` placeholder.
        // Release staging stamps AdaMessagingVersion.swift with the public
        // package version; binary framework builds fall back to MARKETING_VERSION.
        if let actualVersion {
            #expect(actualVersion.range(of: semverPattern, options: .regularExpression) != nil)
            if actualVersion != AdaMessagingVersion.placeholderVersion,
               let expectedVersion {
                #expect(actualVersion == expectedVersion)
            }
        }
    }
}

enum AdaMessagingVersionTests {
    @Test
    static func `prefers a stamped package version over bundle versions`() throws {
        let framework = try makeTemporaryBundle(version: "6.81.0")
        let main = try makeTemporaryBundle(version: "7.0.0")
        defer {
            try? FileManager.default.removeItem(at: framework.url)
            try? FileManager.default.removeItem(at: main.url)
        }

        let version = AdaMessagingVersion.resolve(
            packageVersion: "1.1.0",
            frameworkBundle: framework.bundle,
            mainBundle: main.bundle,
        )

        #expect(version == "1.1.0")
    }

    @Test
    static func `falls back to framework bundle version for binary builds`() throws {
        let framework = try makeTemporaryBundle(version: "1.1.0")
        let main = try makeTemporaryBundle(version: "6.81.0")
        defer {
            try? FileManager.default.removeItem(at: framework.url)
            try? FileManager.default.removeItem(at: main.url)
        }

        let version = AdaMessagingVersion.resolve(
            packageVersion: AdaMessagingVersion.placeholderVersion,
            frameworkBundle: framework.bundle,
            mainBundle: main.bundle,
        )

        #expect(version == "1.1.0")
    }

    @Test
    static func `does not read the host app bundle version for source builds`() throws {
        let hostApp = try makeTemporaryBundle(version: "6.81.0")
        defer {
            try? FileManager.default.removeItem(at: hostApp.url)
        }

        let version = AdaMessagingVersion.resolve(
            packageVersion: AdaMessagingVersion.placeholderVersion,
            frameworkBundle: hostApp.bundle,
            mainBundle: hostApp.bundle,
        )

        #expect(version == AdaMessagingVersion.placeholderVersion)
    }

    @Test
    static func `rejects malformed prerelease versions`() {
        #expect(AdaMessagingVersion.normalizeSemver("1.2.3-rc.1") == "1.2.3-rc.1")
        #expect(AdaMessagingVersion.normalizeSemver("1.2.3-rc..1") == nil)
        #expect(AdaMessagingVersion.normalizeSemver("1.2.3-.rc") == nil)
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
        #expect(environment.webviewEdgeCluster == "localhost")
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
        func `sdk.state.cache preserves recoverable session keys before persisting`() throws {
            let handler = makeHandler()
            send([
                "type": "sdk.state.cache",
                "state": ["botName": "Ada", "csat.chatterToken": "secret", "csat.sessionToken": "tok"],
            ], to: handler)
            let script = try #require(handler.makeInitialStateScript())
            #expect(script.source.contains("chatterToken"))
            #expect(script.source.contains("sessionToken"))
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

@MainActor
enum AdaWebHostBridgeRuntimeTests {
    @Test
    static func `bridge runtime queues commands until sdk ready`() throws {
        let host = AdaWebHost(handle: "ada-example", environment: .production, webSdk: .messaging)
        let webView = ScriptCapturingWebView()
        host.webView = webView
        host.webHostLoaded = false

        host.setLanguage(language: "fr")

        #expect(webView.capturedScripts.isEmpty)

        host.webHostLoaded = true

        let script = try #require(webView.capturedScripts.last)
        #expect(script.contains("ada.setLanguage"))
        #expect(script.contains("fr"))
    }

    @Test
    static func `bridge runtime sends device token only once after a pre-ready update`() {
        let host = AdaWebHost(handle: "ada-example", environment: .production, webSdk: .messaging)
        let webView = ScriptCapturingWebView()
        host.webView = webView
        host.webHostLoaded = false

        host.setDeviceToken(deviceToken: "abc123")
        #expect(webView.capturedScripts.isEmpty)

        host.adaBridgeDidBecomeReady(AdaBridgeHandler())

        let matchingScripts = webView.capturedScripts.filter { $0.contains("ada.setDeviceToken") }
        #expect(matchingScripts.count == 1)
        #expect(matchingScripts[0].contains("abc123"))
    }

    @Test
    static func `bridge runtime surfaces sdk ready through event callbacks`() throws {
        var receivedEvents: [[String: Any]] = []
        let host = AdaWebHost(
            handle: "ada-example",
            eventCallbacks: ["*": { event in receivedEvents.append(event) }],
            environment: .production,
            webSdk: .messaging,
        )

        host.adaBridgeDidBecomeReady(AdaBridgeHandler())

        let event = try #require(receivedEvents.first)
        #expect(event["event_name"] as? String == "sdk.ready")
        #expect(event["web_sdk"] as? String == AdaWebSdk.messaging.rawValue)
    }

    @Test
    static func `bridge runtime webview url ignores whitespace-only cluster`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            cluster: "   ",
            environment: .production,
            webSdk: .messaging,
        )

        let url = try #require(host.buildWebviewUrl(environment: .production))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let clusterQueryItem = components.queryItems?.first(where: { $0.name == "cluster" })
        let edgeClusterQueryItem = components.queryItems?.first(where: { $0.name == "ada_cluster" })

        #expect(clusterQueryItem == nil)
        #expect(edgeClusterQueryItem?.value == "ada.support")
    }

    @Test
    static func `bridge runtime webview url excludes preprod demo token for messaging preprod`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .preprod(branch: "feature-x"),
            webSdk: .messaging,
            preprodDemoToken: "demo-token",
        )

        let url = try #require(host.buildWebviewUrl(environment: .preprod(branch: "feature-x")))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let demoToken = components.queryItems?.first(where: { $0.name == "ada_demo_token" })?.value
        let edgeHandle = components.queryItems?.first(where: { $0.name == "ada_handle" })?.value
        let edgeCluster = components.queryItems?.first(where: { $0.name == "ada_cluster" })?.value

        #expect(demoToken == nil)
        #expect(edgeHandle == "ada-example")
        #expect(edgeCluster == "ada-dev2.support")
    }

    @Test
    static func `bridge runtime preprod messaging request sends demo auth headers`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .preprod(branch: "feature-x"),
            webSdk: .messaging,
            preprodDemoToken: "demo-token",
        )
        let url = try #require(host.buildWebviewUrl(environment: .preprod(branch: "feature-x")))
        let request = host.buildWebviewRequest(url: url, environment: .preprod(branch: "feature-x"))

        #expect(request.value(forHTTPHeaderField: "Referer") == "https://messaging-demo.ada-dev2.support/")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "ada_demo_token=demo-token")
    }

    @Test
    static func `bridge runtime request skips demo host referer outside preprod messaging`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
        )
        let url = try #require(host.buildWebviewUrl(environment: .production))
        let request = host.buildWebviewRequest(url: url, environment: .production)

        #expect(request.value(forHTTPHeaderField: "Referer") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    }
}

@MainActor
enum AdaWebHostLegacyCommandQueueTests {
    @Test
    static func `legacy runtime queues commands until the host page is ready`() {
        let host = AdaWebHost(handle: "ada-example", environment: .production, webSdk: .legacy)
        let webView = ScriptCapturingWebView()
        host.webView = webView
        host.webHostLoaded = false

        host.setLanguage(language: "fr")

        #expect(webView.capturedScripts.isEmpty)

        host.webHostLoaded = true

        #expect(webView.capturedScripts.contains(where: { $0.contains("adaEmbed.setLanguage") && $0.contains("fr") }))
    }
}
