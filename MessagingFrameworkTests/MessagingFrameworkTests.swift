//
//  MessagingFrameworkTests.swift
//  AdaMessagingTests
//
//  Unit tests for AdaBridgeHandler using Swift Testing.
//
// swiftlint:disable file_length

@testable import AdaMessaging
import Foundation
import JavaScriptCore
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
        func `drops csat.chatterToken`() {
            let input: [String: Any] = ["csat.chatterToken": "secret", "tintColor": "#000"]
            let result = AdaBridgeHandler.stateForPersistence(input)
            #expect(result["csat.chatterToken"] == nil)
            #expect(result["tintColor"] as? String == "#000")
        }

        @Test
        func `drops csat.sessionToken`() {
            let input: [String: Any] = ["csat.sessionToken": "tok", "chatEnabled": true]
            let result = AdaBridgeHandler.stateForPersistence(input)
            #expect(result["csat.sessionToken"] == nil)
            #expect(result["chatEnabled"] as? Bool == true)
        }

        /// The transcript is the payload that makes an unenforced contract dangerous: if the
        /// cache shape ever widened to the display state, conversation content would land in
        /// `UserDefaults` with nothing in the path to stop it.
        @Test
        func `drops an unrecognized key rather than persisting it`() {
            let input: [String: Any] = [
                "chat.messages": ["a transcript"],
                "session.chatterToken": "tok",
                "somethingAddedLater": "value",
            ]
            let result = AdaBridgeHandler.stateForPersistence(input)
            #expect(result.isEmpty)
        }

        /// The 10-minute cache has to keep working: the branding/config snapshot is the whole
        /// point of persisting anything.
        @Test
        func `round-trips the startup config snapshot`() {
            let input: [String: Any] = [
                "advancedColorsEnabled": false,
                "button": ["size": 64],
                "chatEnabled": true,
                "fallbackUi": NSNull(),
                "features": ["csatProPostChat": true],
                "intro": NSNull(),
                "proactiveConversations": NSNull(),
                "textOverAccentColor": "#fff",
                "tintColor": "#3ED1FF",
                "__ada_cached_at__": 1_700_000_000_000,
            ]
            let result = AdaBridgeHandler.stateForPersistence(input)
            #expect(result.count == input.count)
            #expect(result["chatEnabled"] as? Bool == true)
            #expect(result["tintColor"] as? String == "#3ED1FF")
        }

        /// Load-bearing: the bridge client validates the hydration snapshot against it, so
        /// stripping it removes the bridge-side TTL bound, and nothing fails loudly.
        @Test
        func `keeps the cache-age marker`() {
            let input: [String: Any] = ["__ada_cached_at__": 1_700_000_000_000]
            let result = AdaBridgeHandler.stateForPersistence(input)
            #expect(result["__ada_cached_at__"] as? Int == 1_700_000_000_000)
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

    // MARK: - isTrustedBridgeMessage

    // -----------------------------------------------------------------------

    struct IsTrustedBridgeMessageTests {
        private func isTrusted(
            frameIsMain: Bool = true,
            originProtocol: String = "https",
            originHost: String = "example.ada.support",
            originPort: Int = 0,
            trustedOrigin: String? = "https://example.ada.support",
        ) -> Bool {
            AdaBridgeHandler.isTrustedBridgeMessage(
                frameIsMain: frameIsMain,
                originProtocol: originProtocol,
                originHost: originHost,
                originPort: originPort,
                trustedOrigin: trustedOrigin,
            )
        }

        @Test
        func `main-frame message from the trusted origin is trusted`() {
            #expect(isTrusted())
        }

        @Test
        func `subframe message is dropped even from the trusted origin`() {
            #expect(!isTrusted(frameIsMain: false))
        }

        @Test
        func `foreign host is dropped`() {
            #expect(!isTrusted(originHost: "evil.example.com"))
        }

        @Test
        func `suffix-lookalike host is dropped`() {
            #expect(!isTrusted(originHost: "example.ada.support.evil.com"))
        }

        @Test
        func `scheme downgrade is dropped`() {
            #expect(!isTrusted(originProtocol: "http"))
        }

        @Test
        func `non-http scheme is dropped`() {
            #expect(!isTrusted(originProtocol: "file", originHost: ""))
        }

        /// `nil` fails closed: a handler never told its trusted origin trusts nothing.
        @Test
        func `missing trusted origin drops every message`() {
            #expect(!isTrusted(trustedOrigin: nil))
        }

        /// WKSecurityOrigin reports a scheme-default port as 0, and an explicit
        /// default port means the same origin.
        @Test
        func `explicit default port matches the omitted-port origin`() {
            #expect(isTrusted(originPort: 443))
        }

        @Test
        func `localhost dev origin matches with its explicit port`() {
            #expect(isTrusted(
                originHost: "localhost",
                originPort: 4900,
                trustedOrigin: "https://localhost:4900",
            ))
        }

        @Test
        func `non-default port must be part of the trusted origin`() {
            #expect(!isTrusted(originPort: 8443))
        }

        @Test
        func `scheme and host compare case-insensitively`() {
            #expect(isTrusted(originProtocol: "HTTPS", originHost: "Example.ADA.Support"))
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
               let expectedVersion
            {
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

/// `AdaBridgeHandler` whose source-trust gate is stubbed: unit tests cannot
/// fabricate the `WKFrameInfo`/`WKSecurityOrigin` a real message carries, so
/// the gate's decision logic is covered via `isTrustedBridgeMessage` and the
/// wiring through `frameInfo` is exercised only on-device.
@MainActor
private final class StubbedTrustBridgeHandler: AdaBridgeHandler {
    var trusted = true

    override func isTrustedSource(of _: WKScriptMessage) -> Bool {
        trusted
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

    var zendeskChatterAuthRequests = 0

    func adaBridgeDidRequestZendeskChatterAuth(_: AdaBridgeHandler) {
        zendeskChatterAuthRequests += 1
    }

    func adaBridge(_: AdaBridgeHandler, didEncounterError error: String) {
        errors.append(error)
    }

    var subresourceLoadFailures: [[String: Any]] = []

    func adaBridge(_: AdaBridgeHandler, didFailSubresourceLoad details: [String: Any]) {
        subresourceLoadFailures.append(details)
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
            StubbedTrustBridgeHandler(userDefaults: defaults ?? makeIsolatedDefaults())
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

        // MARK: sdk.zdChatterAuthRequest

        /// Previously unhandled on the Messaging runtime: the request was posted and dropped,
        /// so core waited out its 10s timeout, PATCHed without a token, and repeated for the
        /// whole handoff.
        @Test
        func `sdk.zdChatterAuthRequest reaches the delegate`() {
            let handler = makeHandler()
            let spy = SpyDelegate()
            handler.delegate = spy
            send(["type": "sdk.zdChatterAuthRequest"], to: handler)
            #expect(spy.zendeskChatterAuthRequests == 1)
        }

        /// The runtime re-requests at every `expireIn`, so each cycle must reach the host.
        @Test
        func `a repeated sdk.zdChatterAuthRequest reaches the delegate each time`() {
            let handler = makeHandler()
            let spy = SpyDelegate()
            handler.delegate = spy
            send(["type": "sdk.zdChatterAuthRequest"], to: handler)
            send(["type": "sdk.zdChatterAuthRequest"], to: handler)
            #expect(spy.zendeskChatterAuthRequests == 2)
        }

        // MARK: sdk.state.cache

        @Test
        func `sdk.state.cache strips session keys before persisting`() throws {
            let handler = makeHandler()
            send([
                "type": "sdk.state.cache",
                "state": [
                    "tintColor": "#3ED1FF",
                    "botName": "Ada",
                    "csat.chatterToken": "secret",
                    "csat.sessionToken": "tok",
                ],
            ], to: handler)
            let script = try #require(handler.makeInitialStateScript())
            #expect(!script.source.contains("chatterToken"))
            #expect(!script.source.contains("sessionToken"))
            #expect(!script.source.contains("secret"))
            #expect(!script.source.contains("tok"))
            // `botName` is not part of the cached startup config, so it is not persistable
            // either — the allowlist admits keys, it does not merely reject known-bad ones.
            #expect(!script.source.contains("Ada"))
            #expect(script.source.contains("#3ED1FF"))
        }

        @Test
        func `sdk.state.cache populates in-memory cache so makeInitialStateScript succeeds`() throws {
            let handler = makeHandler()
            send(["type": "sdk.state.cache", "state": ["chatEnabled": true]], to: handler)
            let script = try #require(handler.makeInitialStateScript())
            #expect(script.source.hasPrefix("window.__ADA_INITIAL_STATE__"))
            #expect(script.source.contains("chatEnabled"))
        }

        @Test
        func `sdk.state.cache writes a cachedAt timestamp to UserDefaults`() {
            let defaults = makeIsolatedDefaults()
            let handler = makeHandler(defaults: defaults)
            let before = Date().timeIntervalSince1970
            send(["type": "sdk.state.cache", "state": ["chatEnabled": true]], to: handler)
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

        // MARK: sdk.subresourceLoadFailed

        @Test
        func `sdk.subresourceLoadFailed forwards url and element to delegate`() throws {
            let handler = makeHandler()
            let spy = SpyDelegate()
            handler.delegate = spy
            send(
                [
                    "type": "sdk.subresourceLoadFailed",
                    "url": "https://messaging-assets.ada.support/sdk/core.js",
                    "element": "script",
                ],
                to: handler,
            )
            let details = try #require(spy.subresourceLoadFailures.first)
            #expect(details["url"] as? String == "https://messaging-assets.ada.support/sdk/core.js")
            #expect(details["element"] as? String == "script")
        }

        /// Only string-typed fields may cross the bridge — a page script could post
        /// arbitrary shapes at the handler.
        @Test
        func `sdk.subresourceLoadFailed drops non-string fields`() throws {
            let handler = makeHandler()
            let spy = SpyDelegate()
            handler.delegate = spy
            send(
                ["type": "sdk.subresourceLoadFailed", "url": 42, "element": ["script"]],
                to: handler,
            )
            let details = try #require(spy.subresourceLoadFailures.first)
            #expect(details["url"] == nil)
            #expect(details["element"] == nil)
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

        /// A subframe (e.g. the custom-app `appUrl` iframe) or a foreign origin can
        /// post to `window.webkit.messageHandlers.adaBridge` too — nothing it sends
        /// may reach the delegate or the persisted state cache.
        @Test
        func `message from an untrusted source is dropped before any handling`() {
            let defaults = makeIsolatedDefaults()
            let handler = StubbedTrustBridgeHandler(userDefaults: defaults)
            handler.trusted = false
            let spy = SpyDelegate()
            handler.delegate = spy
            send(["type": "sdk.event", "key": "ada:conversation_start"], to: handler)
            send(["type": "sdk.ready"], to: handler)
            send(["type": "sdk.state.cache", "state": ["chatEnabled": true]], to: handler)
            #expect(spy.events.isEmpty)
            #expect(!spy.readyCalled)
            #expect(handler.makeInitialStateScript() == nil)
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
        func `sendMessage convenience method emits correct type and body`() throws {
            let handler = makeHandler()
            let webView = ScriptCapturingWebView()
            handler.sendMessage("hello from native", to: webView)
            let script = try #require(webView.capturedScripts.first)
            #expect(script.contains("ada.sendMessage"))
            #expect(script.contains("hello from native"))
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
            #expect(script.contains("\"resetChatHistory\":true"))
        }

        /// The SDK treats a MISSING resetChatHistory key as a full reset — only an
        /// explicit `false` takes the history-preserving path. Dropping the key here
        /// silently destroyed the conversation and minted a new end user.
        @Test
        func `reset with resetChatHistory false sends the explicit false`() throws {
            let handler = makeHandler()
            let webView = ScriptCapturingWebView()
            handler.reset(resetChatHistory: false, to: webView)
            let script = try #require(webView.capturedScripts.first)
            #expect(script.contains("ada.reset"))
            #expect(script.contains("\"resetChatHistory\":false"))
        }

        /// A bare reset keeps its historical behavior: a full reset, stated explicitly.
        @Test
        func `reset with no arguments defaults to a full reset`() throws {
            let handler = makeHandler()
            let webView = ScriptCapturingWebView()
            handler.reset(to: webView)
            let script = try #require(webView.capturedScripts.first)
            #expect(script.contains("ada.reset"))
            #expect(script.contains("\"resetChatHistory\":true"))
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

    /// The public API documents `resetChatHistory: Bool? = true`; a customer passing
    /// `false` must reach the SDK as an explicit `false`, not an omitted key that the
    /// SDK reads as a full reset.
    @Test
    static func `bridge runtime forwards an explicit resetChatHistory false`() throws {
        let host = AdaWebHost(handle: "ada-example", environment: .production, webSdk: .messaging)
        let webView = ScriptCapturingWebView()
        host.webView = webView
        host.webHostLoaded = true

        host.reset(resetChatHistory: false)

        let script = try #require(webView.capturedScripts.last)
        #expect(script.contains("ada.reset"))
        #expect(script.contains("\"resetChatHistory\":false"))
    }

    /// Tri-state parity with Android and React Native: `nil` omits the key so the
    /// runtime applies its own default, instead of the old iOS-only coercion to `true`.
    @Test
    static func `bridge runtime omits the resetChatHistory key for an explicit nil`() throws {
        let host = AdaWebHost(handle: "ada-example", environment: .production, webSdk: .messaging)
        let webView = ScriptCapturingWebView()
        host.webView = webView
        host.webHostLoaded = true

        host.reset(resetChatHistory: nil)

        let script = try #require(webView.capturedScripts.last)
        #expect(script.contains("ada.reset"))
        #expect(!script.contains("resetChatHistory"))
    }

    @Test
    static func `bridge runtime defaults resetChatHistory to an explicit true`() throws {
        let host = AdaWebHost(handle: "ada-example", environment: .production, webSdk: .messaging)
        let webView = ScriptCapturingWebView()
        host.webView = webView
        host.webHostLoaded = true

        host.reset()

        let script = try #require(webView.capturedScripts.last)
        #expect(script.contains("ada.reset"))
        #expect(script.contains("\"resetChatHistory\":true"))
    }

    /// Only the legacy `adaEmbed.start(...)` payload carried init-time sensitive
    /// meta-fields; the Messaging runtime silently dropped them, breaking parity with
    /// Android and React Native.
    @Test
    static func `bridge runtime delivers init-time sensitive meta fields once ready`() {
        let host = AdaWebHost(
            handle: "ada-example",
            sensitiveMetafields: ["authToken": "sensitive-value"],
            environment: .production,
            webSdk: .messaging,
        )
        let webView = ScriptCapturingWebView()
        host.webView = webView
        host.webHostLoaded = false

        host.adaBridgeDidBecomeReady(AdaBridgeHandler())

        let matchingScripts = webView.capturedScripts.filter { $0.contains("ada.setSensitiveMetaFields") }
        #expect(matchingScripts.count == 1)
        #expect(matchingScripts[0].contains("authToken"))
        #expect(matchingScripts[0].contains("sensitive-value"))
    }

    @Test
    static func `bridge runtime sends no sensitive meta fields command when none were given`() {
        let host = AdaWebHost(handle: "ada-example", environment: .production, webSdk: .messaging)
        let webView = ScriptCapturingWebView()
        host.webView = webView
        host.webHostLoaded = false

        host.adaBridgeDidBecomeReady(AdaBridgeHandler())

        #expect(!webView.capturedScripts.contains(where: { $0.contains("ada.setSensitiveMetaFields") }))
    }

    /// Sensitive values ride the bridge, never the URL, where they would land in
    /// request logs.
    @Test
    static func `init-time sensitive meta fields never appear in the webview url`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            sensitiveMetafields: ["authToken": "sensitive-value"],
            environment: .production,
            webSdk: .messaging,
        )

        let url = try #require(host.buildWebviewUrl(environment: .production))

        #expect(!url.absoluteString.contains("sensitive-value"))
        #expect(!url.absoluteString.contains("authToken"))
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

    /// The gate's error names a `start()` option this SDK gave the host no way to set, so a
    /// native customer who can drive the conversation from React Native could not from iOS.
    @Test
    static func `programmatic control is off by default`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
        )

        let url = try #require(host.buildWebviewUrl(environment: .production))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.queryItems?.first(where: { $0.name == "enableProgrammaticControl" }) == nil)
    }

    @Test
    static func `programmatic control is sent when the host opts in`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            enableProgrammaticControl: true,
        )

        let url = try #require(host.buildWebviewUrl(environment: .production))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let item = components.queryItems?.first(where: { $0.name == "enableProgrammaticControl" })

        #expect(item?.value == "true")
    }

    /// Legacy has no such gate, so sending the param there would be meaningless noise on the
    /// URL rather than a behavior change.
    @Test
    static func `programmatic control is not sent on the legacy runtime`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .legacy,
            enableProgrammaticControl: true,
        )

        let url = try #require(host.buildWebviewUrl(environment: .production))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.queryItems?.first(where: { $0.name == "enableProgrammaticControl" }) == nil)
    }

    @Test
    static func `headless is off by default`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
        )

        let url = try #require(host.buildWebviewUrl(environment: .production))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.queryItems?.first(where: { $0.name == "headless" }) == nil)
    }

    @Test
    static func `headless is sent when the host opts in`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            headless: true,
        )

        let url = try #require(host.buildWebviewUrl(environment: .production))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let item = components.queryItems?.first(where: { $0.name == "headless" })

        #expect(item?.value == "true")
    }

    @Test
    static func `headless is not sent on the legacy runtime`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .legacy,
            headless: true,
        )

        let url = try #require(host.buildWebviewUrl(environment: .production))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.queryItems?.first(where: { $0.name == "headless" }) == nil)
    }

    /// The identity token is a credential: it must ride the one-shot
    /// `__ADA_WEBVIEW_CONFIG__` global, never the URL, where it would land in logs.
    @Test
    static func `identity token never appears in the webview url`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            identityToken: "secret-jwt-token",
        )

        let url = try #require(host.buildWebviewUrl(environment: .production))

        #expect(!url.absoluteString.contains("secret-jwt-token"))
        #expect(!url.absoluteString.contains("identityToken"))
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

@MainActor
enum AdaWebViewConfigScriptTests {
    /// Splits the guarded config script into the trusted origin it checks, the
    /// full payload it delivers to a fresh document, and (for token-bearing
    /// scripts) the retained payload it delivers once the token was consumed.
    /// Both guards are load-bearing: a WKUserScript re-executes on every
    /// main-frame document of any origin, so the origin guard keeps the token
    /// off foreign pages and the consumed-marker guard keeps the spent one-shot
    /// token off later documents of the trusted origin.
    private static func configScriptParts(
        from script: WKUserScript,
    ) throws -> (origin: String, payload: [String: Any], retained: [String: Any]?) {
        let source = script.source
        let guardPrefix = "if (window.location.origin === "
        #expect(source.hasPrefix(guardPrefix))

        let plainAssignment = ") { window.__ADA_WEBVIEW_CONFIG__ = "
        let guardedAssignment = ") { window.__ADA_WEBVIEW_CONFIG__ = (function () { "
            + "try { if (window.sessionStorage.getItem(\"__ada_identity_token_consumed__\") === "

        if let assignmentRange = source.range(of: guardedAssignment) {
            let suffix = "; })(); }"
            #expect(source.hasSuffix(suffix))
            let originStart = source.index(source.startIndex, offsetBy: guardPrefix.count)
            let originJson = String(source[originStart ..< assignmentRange.lowerBound])
            let retainedMarker = ") { return "
            let retainedRange = try #require(
                source.range(of: retainedMarker, range: assignmentRange.upperBound ..< source.endIndex),
            )
            let retainedEnd = try #require(
                source.range(of: "; } } catch (e) {} return ", range: retainedRange.upperBound ..< source.endIndex),
            )
            let retainedJson = String(source[retainedRange.upperBound ..< retainedEnd.lowerBound])
            let payloadJson = String(source[retainedEnd.upperBound...].dropLast(suffix.count))
            let origin = try JSONSerialization.jsonObject(
                with: Data(originJson.utf8),
                options: .fragmentsAllowed,
            )
            let payload = try JSONSerialization.jsonObject(with: Data(payloadJson.utf8))
            let retained = try JSONSerialization.jsonObject(with: Data(retainedJson.utf8))
            return try (
                #require(origin as? String),
                #require(payload as? [String: Any]),
                #require(retained as? [String: Any]),
            )
        }

        let suffix = "; }"
        #expect(source.hasSuffix(suffix))
        let assignmentRange = try #require(source.range(of: plainAssignment))
        let originStart = source.index(source.startIndex, offsetBy: guardPrefix.count)
        let originJson = String(source[originStart ..< assignmentRange.lowerBound])
        let payloadJson = String(source[assignmentRange.upperBound...].dropLast(suffix.count))
        let origin = try JSONSerialization.jsonObject(
            with: Data(originJson.utf8),
            options: .fragmentsAllowed,
        )
        let payload = try JSONSerialization.jsonObject(with: Data(payloadJson.utf8))
        return try (#require(origin as? String), #require(payload as? [String: Any]), nil)
    }

    private static func configPayload(from script: WKUserScript) throws -> [String: Any] {
        try configScriptParts(from: script).payload
    }

    @Test
    static func `returns nil when there is nothing to send`() {
        let host = AdaWebHost(handle: "ada-example", environment: .production, webSdk: .messaging)
        #expect(host.makeWebviewConfigScript() == nil)
    }

    @Test
    static func `guards injection to the production webview origin`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            identityToken: "secret-jwt-token",
        )

        let script = try #require(host.makeWebviewConfigScript())
        let parts = try configScriptParts(from: script)

        #expect(parts.origin == "https://messaging-assets.ada.support")
        #expect(parts.payload["identityToken"] as? String == "secret-jwt-token")
    }

    /// `location.origin` keeps a non-default port, so the guard must too or it
    /// would never match in local dev.
    @Test
    static func `guards injection to the local webview origin including its port`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .local(port: 4900),
            webSdk: .messaging,
            identityToken: "secret-jwt-token",
        )

        let script = try #require(host.makeWebviewConfigScript())
        let parts = try configScriptParts(from: script)

        #expect(parts.origin == "https://localhost:4900")
    }

    /// The preprod branch is a path segment, never part of the origin.
    @Test
    static func `guards injection to the preprod origin regardless of branch`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .preprod(branch: "feature-x"),
            webSdk: .messaging,
            identityToken: "secret-jwt-token",
        )

        let script = try #require(host.makeWebviewConfigScript())
        let parts = try configScriptParts(from: script)

        #expect(parts.origin == "https://messaging-assets.ada-dev2.support")
    }

    /// Fail closed: with no environment there is no trusted origin to scope the
    /// guard to, so the token must not be injected at all (mirrors Android, which
    /// refuses to inject when no trusted origin rule resolves).
    @Test
    static func `returns nil without an environment to derive a trusted origin`() {
        let host = AdaWebHost(
            handle: "ada-example",
            webSdk: .messaging,
            identityToken: "secret-jwt-token",
        )
        #expect(host.makeWebviewConfigScript() == nil)
    }

    /// `location.origin` omits a scheme-default port, so the guard must normalize
    /// an explicit `:443` away or it would never match.
    @Test
    static func `page origin drops a scheme-default port and keeps a custom one`() {
        #expect(
            AdaWebHost.pageOrigin(ofUrl: "https://cdn.example.com:443/sdk/webview.html")
                == "https://cdn.example.com",
        )
        #expect(
            AdaWebHost.pageOrigin(ofUrl: "https://cdn.example.com:8443/sdk/webview.html")
                == "https://cdn.example.com:8443",
        )
        #expect(AdaWebHost.pageOrigin(ofUrl: "not a url") == nil)
    }

    /// Only http(s) documents have a guardable `location.origin`; any other scheme
    /// must yield no origin so the token is never injected (RN parity: fail closed).
    @Test
    static func `page origin rejects non-http schemes`() {
        #expect(AdaWebHost.pageOrigin(ofUrl: "ftp://cdn.example.com/sdk/webview.html") == nil)
        #expect(AdaWebHost.pageOrigin(ofUrl: "file:///sdk/webview.html") == nil)
        #expect(AdaWebHost.pageOrigin(ofUrl: "javascript:alert(1)") == nil)
        #expect(AdaWebHost.pageOrigin(ofUrl: "HTTP://CDN.Example.com/sdk/webview.html") == "http://cdn.example.com")
    }

    /// A custom environment whose assets origin is not http(s) cannot be origin-guarded,
    /// so no config script may be built at all — the token must not ride unguarded.
    @Test
    static func `returns nil for a custom environment without an http origin`() throws {
        let assetsOrigin = try #require(URL(string: "ftp://cdn.example.com"))
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .custom(assetsOrigin: assetsOrigin),
            webSdk: .messaging,
            identityToken: "secret-jwt-token",
        )
        #expect(host.makeWebviewConfigScript() == nil)
    }

    @Test
    static func `returns nil on the legacy runtime even with a token`() {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .legacy,
            identityToken: "secret-jwt-token",
        )
        #expect(host.makeWebviewConfigScript() == nil)
    }

    @Test
    static func `injects the identity token at document start on the main frame only`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            identityToken: "secret-jwt-token",
        )

        let script = try #require(host.makeWebviewConfigScript())

        #expect(script.injectionTime == .atDocumentStart)
        #expect(script.isForMainFrameOnly)

        let payload = try configPayload(from: script)
        #expect(payload["identityToken"] as? String == "secret-jwt-token")
        #expect(payload["appUrl"] == nil)
    }

    @Test
    static func `includes the app url when set`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            identityToken: "secret-jwt-token",
            appUrl: "https://apps.example.com/custom-app/index.html",
        )

        let script = try #require(host.makeWebviewConfigScript())
        let payload = try configPayload(from: script)

        #expect(payload["identityToken"] as? String == "secret-jwt-token")
        #expect(payload["appUrl"] as? String == "https://apps.example.com/custom-app/index.html")
    }

    @Test
    static func `sends the app url without a token`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            appUrl: "https://apps.example.com/custom-app/index.html",
        )

        let script = try #require(host.makeWebviewConfigScript())
        let payload = try configPayload(from: script)

        #expect(payload["identityToken"] == nil)
        #expect(payload["appUrl"] as? String == "https://apps.example.com/custom-app/index.html")
    }

    @Test
    static func `treats a whitespace-only token as absent`() {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            identityToken: "   ",
        )
        #expect(host.makeWebviewConfigScript() == nil)
    }

    /// A token holding JS-hostile characters must survive as data, not become code.
    @Test
    static func `token with quotes and backslashes round-trips through JSON`() throws {
        let hostileToken = "a\"b\\c${d}`e"
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            identityToken: hostileToken,
        )

        let script = try #require(host.makeWebviewConfigScript())
        let payload = try configPayload(from: script)

        #expect(payload["identityToken"] as? String == hostileToken)
    }

    /// The token is single-use — an exchange attempt spends it even when it fails
    /// downstream — so once the runtime records consumption the script must hand
    /// later documents only the retained (non-credential) config.
    @Test
    static func `retained payload withholds the token but keeps appUrl`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            identityToken: "secret-jwt-token",
            appUrl: "https://apps.example.com/custom-app/index.html",
        )

        let script = try #require(host.makeWebviewConfigScript())
        let parts = try configScriptParts(from: script)
        let retained = try #require(parts.retained)

        #expect(parts.payload["identityToken"] as? String == "secret-jwt-token")
        #expect(
            parts.payload["injectionId"] as? String
                == AdaWebHost.identityTokenInjectionId("secret-jwt-token"),
        )
        #expect(retained["identityToken"] == nil)
        #expect(retained["injectionId"] == nil)
        #expect(retained["appUrl"] as? String == "https://apps.example.com/custom-app/index.html")
    }

    @Test
    static func `retained payload is empty for a token-only config`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            identityToken: "secret-jwt-token",
        )

        let script = try #require(host.makeWebviewConfigScript())
        let retained = try #require(configScriptParts(from: script).retained)

        #expect(retained.isEmpty)
    }

    /// appUrl is plain config every document (re-)mount needs, so an appUrl-only
    /// script carries no consumption guard.
    @Test
    static func `appUrl-only script has no consumption guard`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            appUrl: "https://apps.example.com/custom-app/index.html",
        )

        let script = try #require(host.makeWebviewConfigScript())

        #expect(!script.source.contains("sessionStorage"))
        #expect(try configScriptParts(from: script).retained == nil)
    }

    @Test
    static func `injection id is stable, distinguishing, and never the token`() {
        #expect(
            AdaWebHost.identityTokenInjectionId("secret-jwt-token")
                == AdaWebHost.identityTokenInjectionId("secret-jwt-token"),
        )
        #expect(
            AdaWebHost.identityTokenInjectionId("secret-jwt-token")
                != AdaWebHost.identityTokenInjectionId("other-jwt-token"),
        )
        #expect(!AdaWebHost.identityTokenInjectionId("secret-jwt-token").contains("secret"))
    }
}

// ---------------------------------------------------------------------------

// MARK: - AdaWebViewConfigScriptExecutionTests

// ---------------------------------------------------------------------------

/// Executes the emitted document-start script in JavaScriptCore against a fake
/// `window`, pinning the behavior the parse-based tests can only approximate.
@MainActor
enum AdaWebViewConfigScriptExecutionTests {
    /// Runs `script` for a document at `origin`; `consumedMarker` seeds the
    /// sessionStorage value the runtime writes after consuming a token, and
    /// `"throws"` simulates a storage-disabled webview. Returns the config the
    /// script delivered, or nil when it delivered nothing.
    private static func runConfigScript(
        _ script: WKUserScript,
        origin: String,
        consumedMarker: String? = nil,
    ) throws -> [String: Any]? {
        let context = try #require(JSContext())
        let originJson = try String(
            data: JSONSerialization.data(withJSONObject: origin, options: .fragmentsAllowed),
            encoding: .utf8,
        ) ?? "\"\""
        let getItemBody = if consumedMarker == "throws" {
            "throw new Error(\"storage disabled\");"
        } else if let consumedMarker {
            "return key === \"__ada_identity_token_consumed__\" ? \"\(consumedMarker)\" : null;"
        } else {
            "return null;"
        }
        context.evaluateScript(
            "var window = { location: { origin: \(originJson) }, "
                + "sessionStorage: { getItem: function (key) { \(getItemBody) } } };",
        )
        context.evaluateScript(script.source)
        let json = context.evaluateScript(
            "JSON.stringify(window.__ADA_WEBVIEW_CONFIG__ === undefined ? null : window.__ADA_WEBVIEW_CONFIG__)",
        )?.toString() ?? "null"
        let parsed = try JSONSerialization.jsonObject(
            with: Data(json.utf8),
            options: .fragmentsAllowed,
        )
        return parsed as? [String: Any]
    }

    private static func makeHost() -> AdaWebHost {
        AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            identityToken: "secret-jwt-token",
            appUrl: "https://apps.example.com/custom-app/index.html",
        )
    }

    private static let trustedOrigin = "https://messaging-assets.ada.support"

    @Test
    static func `delivers the full config to a fresh trusted document`() throws {
        let script = try #require(makeHost().makeWebviewConfigScript())

        let config = try #require(try runConfigScript(script, origin: trustedOrigin))

        #expect(config["identityToken"] as? String == "secret-jwt-token")
        #expect(config["appUrl"] as? String == "https://apps.example.com/custom-app/index.html")
        #expect(
            config["injectionId"] as? String
                == AdaWebHost.identityTokenInjectionId("secret-jwt-token"),
        )
    }

    @Test
    static func `withholds the consumed token from a later document but keeps appUrl`() throws {
        let script = try #require(makeHost().makeWebviewConfigScript())

        let config = try #require(try runConfigScript(
            script,
            origin: trustedOrigin,
            consumedMarker: AdaWebHost.identityTokenInjectionId("secret-jwt-token"),
        ))

        #expect(config["identityToken"] == nil)
        #expect(config["appUrl"] as? String == "https://apps.example.com/custom-app/index.html")
    }

    @Test
    static func `still delivers after a DIFFERENT token was consumed`() throws {
        let script = try #require(makeHost().makeWebviewConfigScript())

        let config = try #require(try runConfigScript(
            script,
            origin: trustedOrigin,
            consumedMarker: AdaWebHost.identityTokenInjectionId("other-jwt-token"),
        ))

        #expect(config["identityToken"] as? String == "secret-jwt-token")
    }

    @Test
    static func `degrades to delivering the token when sessionStorage throws`() throws {
        let script = try #require(makeHost().makeWebviewConfigScript())

        let config = try #require(try runConfigScript(
            script,
            origin: trustedOrigin,
            consumedMarker: "throws",
        ))

        #expect(config["identityToken"] as? String == "secret-jwt-token")
    }

    @Test
    static func `delivers nothing to a foreign document`() throws {
        let script = try #require(makeHost().makeWebviewConfigScript())

        #expect(try runConfigScript(script, origin: "https://evil.example") == nil)
        #expect(
            try runConfigScript(
                script,
                origin: "https://messaging-assets.ada.support.evil.example",
            ) == nil,
        )
    }
}

// ---------------------------------------------------------------------------

// MARK: - AdaWebViewConfigScriptDisarmTests

// ---------------------------------------------------------------------------

@MainActor
enum AdaWebViewConfigScriptDisarmTests {
    /// Once the bridge reports ready the one-shot token is spent; the
    /// document-start registration must go away while every other user script
    /// (cached-state hydration, error interceptor) survives the rebuild.
    @Test
    static func `removes only the config script once the bridge reports ready`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            identityToken: "secret-jwt-token",
        )
        // The live controller the WebView was created with — webView.configuration
        // returns a copy on access, so it cannot be used to observe mutations.
        // Snapshot the sources eagerly: the bridged userScripts array can alias
        // WebKit's live storage, so a bare `let scripts = controller.userScripts`
        // would silently observe later mutations.
        let controller = try #require(host.webviewUserContentController)
        let sourcesBefore = controller.userScripts.map(\.source)
        #expect(sourcesBefore.contains(where: { $0.contains("__ADA_WEBVIEW_CONFIG__") }))
        // The error interceptor must be present so the rebuild provably keeps it.
        #expect(sourcesBefore.contains(where: { $0.contains("reportBridgeError") }))

        host.adaBridgeDidBecomeReady(host.bridgeHandler)

        let sourcesAfter = controller.userScripts.map(\.source)
        #expect(!sourcesAfter.contains(where: { $0.contains("__ADA_WEBVIEW_CONFIG__") }))
        #expect(sourcesAfter.contains(where: { $0.contains("reportBridgeError") }))
        #expect(sourcesAfter.count == sourcesBefore.count - 1)
        #expect(host.webviewConfigUserScript == nil)

        // Idempotent: a second ready (or a ready with nothing armed) is a no-op.
        host.adaBridgeDidBecomeReady(host.bridgeHandler)
        #expect(controller.userScripts.count == sourcesAfter.count)
    }
}

@MainActor
enum AdaWebHostSendMessageTests {
    @Test
    static func `bridge runtime queues sendMessage until sdk ready`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            enableProgrammaticControl: true,
        )
        let webView = ScriptCapturingWebView()
        host.webView = webView
        host.webHostLoaded = false

        host.sendMessage("I need help with my order")

        #expect(webView.capturedScripts.isEmpty)

        host.webHostLoaded = true

        let script = try #require(webView.capturedScripts.last)
        #expect(script.contains("ada.sendMessage"))
        #expect(script.contains("I need help with my order"))
    }

    @Test
    static func `bridge runtime dispatches sendMessage immediately when ready`() throws {
        let host = AdaWebHost(handle: "ada-example", environment: .production, webSdk: .messaging)
        let webView = ScriptCapturingWebView()
        host.webView = webView
        host.webHostLoaded = true

        host.sendMessage("hello")

        let script = try #require(webView.capturedScripts.last)
        #expect(script.contains("ada.sendMessage"))
        #expect(script.contains("hello"))
    }

    /// The legacy remote host page has no send command, so the call must be dropped
    /// instead of evaluating a script the page cannot handle.
    @Test
    static func `legacy remote host page drops sendMessage`() {
        let host = AdaWebHost(handle: "ada-example", environment: .production, webSdk: .legacy)
        let webView = ScriptCapturingWebView()
        host.webView = webView
        host.webHostLoaded = true

        host.sendMessage("hello")

        #expect(!webView.capturedScripts.contains(where: { $0.contains("sendMessage") }))
    }
}

@MainActor
enum AdaWebHostHeadlessLaunchTests {
    @Test
    static func `attaches the webview to a caller-provided container`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            headless: true,
        )
        let container = UIView(frame: .zero)

        host.launchHeadlessWebSupport(in: container)

        let webView = try #require(host.webView)
        #expect(webView.superview === container)
        #expect(host.headlessContainer == nil)
    }

    @Test
    static func `creates a retained hidden offscreen container when no host view is given`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            headless: true,
        )

        host.launchHeadlessWebSupport()

        let webView = try #require(host.webView)
        let container = try #require(host.headlessContainer)
        #expect(webView.superview === container)
        #expect(container.isHidden)
    }

    @Test
    static func `keeps the existing webview when headless was already set at init`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            headless: true,
        )
        let originalWebView = try #require(host.webView)

        host.launchHeadlessWebSupport()

        #expect(host.webView === originalWebView)
    }

    /// `headless` rides the webview.html URL built during init, so a host created
    /// without the flag would otherwise run the FULL chat UI invisibly. The launch
    /// must normalize the flag and rebuild the WebView (Android parity:
    /// `headlessLaunchSettings` forces `headless = true` before the view loads).
    /// The Legacy-runtime guard is a `precondition` (Android's `require`), which
    /// cannot be exercised in-process.
    @Test
    static func `force-sets headless and rebuilds the webview when launched without the flag`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
        )
        let originalWebView = try #require(host.webView)
        #expect(!host.headless)

        host.launchHeadlessWebSupport()

        #expect(host.headless)
        let rebuiltWebView = try #require(host.webView)
        #expect(rebuiltWebView !== originalWebView)
        #expect(rebuiltWebView.superview === host.headlessContainer)

        let url = try #require(host.buildWebviewUrl(environment: .production))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first(where: { $0.name == "headless" })?.value == "true")
    }

    /// `setupWebView()` only swaps references, so the flip-to-headless rebuild
    /// must neutralize the replaced WebView first: a detached WKWebView keeps
    /// loading and executing JS, so a live orphan would spend the single-use
    /// identityToken (401 `identity_token_already_used` for the document the
    /// customer actually uses) and fire a premature sdk.ready through the
    /// shared bridgeHandler.
    @Test
    static func `tears the replaced webview down when the rebuild flips headless on`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            identityToken: "secret-jwt-token",
        )
        let replacedWebView = try #require(host.webView)
        let replacedController = try #require(host.webviewUserContentController)
        #expect(!replacedController.userScripts.isEmpty)

        host.launchHeadlessWebSupport()

        // stopLoading() is also part of the teardown, but WKWebView.isLoading
        // settles asynchronously in the web-content process, so the teardown is
        // asserted through its synchronous observables: detachment, delegate
        // cuts, and the stripped user-content controller (no config script — no
        // orphan document can spend the token; no message handler — no orphan
        // sdk.ready can reach the shared bridgeHandler).
        #expect(replacedWebView.superview == nil)
        #expect(replacedWebView.navigationDelegate == nil)
        #expect(replacedWebView.uiDelegate == nil)
        #expect(replacedController.userScripts.isEmpty)
    }

    /// The still-unconsumed identityToken must survive the flip: the config
    /// script is re-armed against the NEW controller — and only there — so the
    /// rebuilt headless document receives it, and the URL still flags the
    /// expected injection.
    @Test
    static func `re-arms the identity config script on the rebuilt webview only`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            identityToken: "secret-jwt-token",
        )
        let replacedController = try #require(host.webviewUserContentController)

        host.launchHeadlessWebSupport()

        let rebuiltController = try #require(host.webviewUserContentController)
        #expect(rebuiltController !== replacedController)
        let armedScript = try #require(host.webviewConfigUserScript)
        #expect(rebuiltController.userScripts.contains(where: { $0 === armedScript }))

        let url = try #require(host.buildWebviewUrl(environment: .production))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first(where: { $0.name == "expectsIdentityToken" })?.value == "true")
    }

    /// A ready report from the replaced runtime died with it: the flip must
    /// drop readiness so commands queue for the rebuilt runtime's own
    /// sdk.ready — not flush into a document whose bridge does not exist yet.
    @Test
    static func `resets readiness on the flip rebuild so commands queue for the new runtime`() {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
        )
        host.webHostLoaded = true

        host.launchHeadlessWebSupport()

        #expect(!host.webHostLoaded)
        host.sendMessage("hello")
        #expect(host.pendingCommands.count == 1)
    }
}

// ---------------------------------------------------------------------------

// MARK: - AdaWebHostExpectedIdentityFlagTests

// ---------------------------------------------------------------------------

@MainActor
enum AdaWebHostExpectedIdentityFlagTests {
    private static func queryItem(_ url: URL, _ name: String) -> URLQueryItem? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })
    }

    /// The flag lets the runtime report a lost injection instead of silently
    /// starting anonymous. Boolean only — the token itself must never ride the URL.
    @Test
    static func `flags an expected identity token without ever carrying it`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            identityToken: "secret-jwt-token",
        )

        let url = try #require(host.buildWebviewUrl(environment: .production))

        #expect(queryItem(url, "expectsIdentityToken")?.value == "true")
        #expect(!url.absoluteString.contains("secret-jwt-token"))
    }

    @Test
    static func `omits the flag without a token and on the legacy runtime`() throws {
        let noTokenHost = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
        )
        let noTokenUrl = try #require(noTokenHost.buildWebviewUrl(environment: .production))
        #expect(queryItem(noTokenUrl, "expectsIdentityToken") == nil)

        let legacyHost = AdaWebHost(
            handle: "ada-example",
            environment: .local(port: 4900),
            webSdk: .legacy,
            identityToken: "secret-jwt-token",
        )
        let legacyUrl = try #require(legacyHost.buildWebviewUrl(environment: .local(port: 4900)))
        #expect(queryItem(legacyUrl, "expectsIdentityToken") == nil)
    }
}

// ---------------------------------------------------------------------------

// MARK: - AdaWebHostStylesQueryParamTests

// ---------------------------------------------------------------------------

@MainActor
enum AdaWebHostStylesQueryParamTests {
    private static func stylesQueryValue(of host: AdaWebHost) throws -> String? {
        let url = try #require(host.buildWebviewUrl(environment: .production))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return components.queryItems?.first(where: { $0.name == "styles" })?.value
    }

    @Test
    static func `sends messaging styles as a json object query param`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            styles: ##"{"tintColor": "#520497", "surfaceColor": "#FFFFFF"}"##,
            environment: .production,
            webSdk: .messaging,
        )

        let value = try #require(try stylesQueryValue(of: host))
        let parsed = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: String]

        #expect(parsed == ["tintColor": "#520497", "surfaceColor": "#FFFFFF"])
    }

    @Test
    static func `omits styles when none were given`() throws {
        let host = AdaWebHost(handle: "ada-example", environment: .production, webSdk: .messaging)

        #expect(try stylesQueryValue(of: host) == nil)
    }

    /// The Legacy runtime's `styles` shape is a raw CSS string; the Messaging
    /// runtime cannot interpret it, so it must be dropped rather than sent malformed.
    @Test
    static func `drops a legacy css string on the messaging runtime`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            styles: "#ada-button { background: red; }",
            environment: .production,
            webSdk: .messaging,
        )

        #expect(try stylesQueryValue(of: host) == nil)
    }

    /// The runtime contract is `Record<string, string>` — non-string values would
    /// be dropped there anyway, so fail fast natively.
    @Test
    static func `drops a json object holding non-string values`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            styles: #"{"tintColor": 5}"#,
            environment: .production,
            webSdk: .messaging,
        )

        #expect(try stylesQueryValue(of: host) == nil)
    }

    @Test
    static func `is not sent on the legacy runtime`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            styles: ##"{"tintColor": "#520497"}"##,
            environment: .local(port: 4900),
            webSdk: .legacy,
        )

        let url = try #require(host.buildWebviewUrl(environment: .local(port: 4900)))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.queryItems?.first(where: { $0.name == "styles" }) == nil)
    }
}

// ---------------------------------------------------------------------------

// MARK: - AdaWebHostEventSubscriptionTests

// ---------------------------------------------------------------------------

@MainActor
enum AdaWebHostEventSubscriptionTests {
    private static func makeHost(
        eventCallbacks: [String: (_ event: [String: Any]) -> Void]? = nil,
    ) -> AdaWebHost {
        AdaWebHost(
            handle: "ada-example",
            eventCallbacks: eventCallbacks,
            environment: .production,
            webSdk: .messaging,
        )
    }

    @Test
    static func `multiple subscribers on one event all receive it`() {
        let host = makeHost()
        var first: [[String: Any]] = []
        var second: [[String: Any]] = []
        host.addEventCallback("ada:message:received") { first.append($0) }
        host.addEventCallback("ada:message:received") { second.append($0) }

        host.adaBridge(host.bridgeHandler, didReceiveEvent: "ada:message:received", data: ["body": "hi"])

        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(first.first?["event_name"] as? String == "ada:message:received")
        #expect((first.first?["data"] as? [String: Any])?["body"] as? String == "hi")
    }

    @Test
    static func `catch-all subscription receives keyed events`() {
        let host = makeHost()
        var received: [[String: Any]] = []
        host.addEventCallback { received.append($0) }

        host.adaBridge(host.bridgeHandler, didReceiveEvent: "ada:conversation_start", data: nil)

        #expect(received.count == 1)
        #expect(received.first?["event_name"] as? String == "ada:conversation_start")
    }

    @Test
    static func `removeEventCallback removes exactly the returned subscription`() {
        let host = makeHost()
        var first = 0
        var second = 0
        let subscription = host.addEventCallback("ada:msg") { _ in first += 1 }
        host.addEventCallback("ada:msg") { _ in second += 1 }

        host.removeEventCallback(subscription)
        host.adaBridge(host.bridgeHandler, didReceiveEvent: "ada:msg", data: nil)

        #expect(first == 0)
        #expect(second == 1)
    }

    @Test
    static func `removeEventCallbacks clears every subscription for the key`() {
        let host = makeHost()
        var keyed = 0
        var wildcard = 0
        host.addEventCallback("ada:msg") { _ in keyed += 1 }
        host.addEventCallback("ada:msg") { _ in keyed += 1 }
        host.addEventCallback { _ in wildcard += 1 }

        host.removeEventCallbacks("ada:msg")
        host.adaBridge(host.bridgeHandler, didReceiveEvent: "ada:msg", data: nil)

        #expect(keyed == 0)
        #expect(wildcard == 1)
    }

    /// The single-closure dictionary keeps working unchanged next to the
    /// multi-subscriber registry.
    @Test
    static func `dictionary callbacks and subscriptions coexist`() {
        var dictionaryEvents: [[String: Any]] = []
        let host = makeHost(eventCallbacks: ["*": { dictionaryEvents.append($0) }])
        var subscribed: [[String: Any]] = []
        host.addEventCallback("ada:msg") { subscribed.append($0) }

        host.adaBridge(host.bridgeHandler, didReceiveEvent: "ada:msg", data: nil)

        #expect(dictionaryEvents.count == 1)
        #expect(subscribed.count == 1)
    }

    /// Android parity: the raw sink hears bridge errors under their key, which the
    /// single-closure dictionary only surfaces on `"*"`.
    @Test
    static func `bridge errors reach keyed subscriptions`() {
        let host = makeHost()
        var received: [[String: Any]] = []
        host.addEventCallback("ada.bridge.error") { received.append($0) }

        host.adaBridge(host.bridgeHandler, didEncounterError: "boom")

        #expect(received.count == 1)
        #expect(received.first?["error"] as? String == "boom")
    }

    @Test
    static func `webview load failure reaches keyed subscriptions`() throws {
        let host = makeHost()
        var received: [[String: Any]] = []
        host.addEventCallback("ada.webview.loadFailed") { received.append($0) }
        let webView = try #require(host.webView)

        host.webView(
            webView,
            didFailProvisionalNavigation: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
        )

        #expect(received.count == 1)
        #expect(received.first?["event_name"] as? String == "ada.webview.loadFailed")
    }

    @Test
    static func `raw sdk event sink receives key and json data`() throws {
        let host = makeHost()
        var received: [(key: String, data: String?)] = []
        host.addSdkEventCallback { key, data in received.append((key: key, data: data)) }

        host.adaBridge(host.bridgeHandler, didReceiveEvent: "ada:msg", data: ["id": "42"])
        host.adaBridge(host.bridgeHandler, didReceiveEvent: "ada:plain", data: "plain-string")
        host.adaBridge(host.bridgeHandler, didReceiveEvent: "ada:empty", data: nil)

        #expect(received.count == 3)
        #expect(received[0].key == "ada:msg")
        #expect(try #require(received[0].data).contains("\"id\":\"42\""))
        #expect(received[1].data == "plain-string")
        #expect(received[2].data == nil)
    }

    @Test
    static func `raw sink hears the synthetic sdk ready event`() throws {
        let host = makeHost()
        var received: [(key: String, data: String?)] = []
        host.addSdkEventCallback { key, data in received.append((key: key, data: data)) }

        host.adaBridgeDidBecomeReady(host.bridgeHandler)

        let readyEvent = try #require(received.first(where: { $0.key == "sdk.ready" }))
        #expect(try #require(readyEvent.data).contains("web_sdk"))
    }

    @Test
    static func `removeSdkEventCallback stops delivery`() {
        let host = makeHost()
        var received = 0
        let subscription = host.addSdkEventCallback { _, _ in received += 1 }

        host.removeSdkEventCallback(subscription)
        host.adaBridge(host.bridgeHandler, didReceiveEvent: "ada:msg", data: nil)

        #expect(received == 0)
    }
}

// ---------------------------------------------------------------------------

// MARK: - AdaWebHostSubresourceEventTests

// ---------------------------------------------------------------------------

@MainActor
enum AdaWebHostSubresourceEventTests {
    /// Wildcard-only dictionary delivery mirrors `ada.webview.loadFailed`; keyed
    /// delivery is available through the multi-subscriber registry.
    @Test
    static func `emits the subresource failure event to wildcard dictionary and keyed subscriptions`() throws {
        var wildcard: [[String: Any]] = []
        var keyedDictionary: [[String: Any]] = []
        let host = AdaWebHost(
            handle: "ada-example",
            eventCallbacks: [
                "*": { wildcard.append($0) },
                "ada.webview.subresourceLoadFailed": { keyedDictionary.append($0) },
            ],
            environment: .production,
            webSdk: .messaging,
        )
        var subscribed: [[String: Any]] = []
        host.addEventCallback("ada.webview.subresourceLoadFailed") { subscribed.append($0) }

        host.adaBridge(
            host.bridgeHandler,
            didFailSubresourceLoad: [
                "url": "https://messaging-assets.ada.support/sdk/core.js",
                "element": "script",
            ],
        )

        let event = try #require(wildcard.first)
        #expect(event["event_name"] as? String == "ada.webview.subresourceLoadFailed")
        #expect(event["url"] as? String == "https://messaging-assets.ada.support/sdk/core.js")
        #expect(event["element"] as? String == "script")
        #expect(event["error"] as? String == "WKWebView failed to load an Ada runtime subresource")
        #expect(subscribed.count == 1)
        #expect(keyedDictionary.isEmpty)
    }

    /// A subresource failure is not a main-frame load failure: the typed
    /// load-error callback must stay silent.
    @Test
    static func `does not fire the webview loading error callback`() {
        var loadErrors: [Error] = []
        let host = AdaWebHost(
            handle: "ada-example",
            webViewLoadingErrorCallback: { loadErrors.append($0) },
            environment: .production,
            webSdk: .messaging,
        )

        host.adaBridge(host.bridgeHandler, didFailSubresourceLoad: ["url": "https://x/a.js"])

        #expect(loadErrors.isEmpty)
    }
}

// ---------------------------------------------------------------------------

// MARK: - AdaErrorInterceptorScriptTests

// ---------------------------------------------------------------------------

/// Executes the injected error-interceptor script in JavaScriptCore against a
/// fake `window` to pin the subresource-failure reporting behavior.
@MainActor
enum AdaErrorInterceptorScriptTests {
    private static func makeContext() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var posts = [];
        var listeners = {};
        var window = {
            addEventListener: function(type, listener, capture) {
                listeners[type] = { listener: listener, capture: capture === true };
            },
            webkit: {
                messageHandlers: {
                    adaBridge: {
                        postMessage: function(message) { posts.push(message); }
                    }
                }
            }
        };
        """)
        let host = AdaWebHost(handle: "ada-example", environment: .production, webSdk: .messaging)
        context.evaluateScript(host.errorInterceptorScript().source)
        return context
    }

    private static func posts(in context: JSContext) throws -> [[String: Any]] {
        let json = context.evaluateScript("JSON.stringify(posts)")?.toString() ?? "[]"
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(parsed as? [[String: Any]])
    }

    /// Resource load errors do not bubble; only a capture-phase listener sees them.
    @Test
    static func `registers a capture-phase error listener`() throws {
        let context = try makeContext()

        #expect(context.evaluateScript("listeners.error.capture")?.toBool() == true)
    }

    @Test
    static func `reports a failed subresource once per url`() throws {
        let context = try makeContext()

        context.evaluateScript(
            "listeners.error.listener({ target: { tagName: 'SCRIPT', src: 'https://cdn.example/app.js' } });",
        )
        context.evaluateScript(
            "listeners.error.listener({ target: { tagName: 'SCRIPT', src: 'https://cdn.example/app.js' } });",
        )

        let reported = try posts(in: context)
        #expect(reported.count == 1)
        #expect(reported.first?["type"] as? String == "sdk.subresourceLoadFailed")
        #expect(reported.first?["url"] as? String == "https://cdn.example/app.js")
        #expect(reported.first?["element"] as? String == "script")
    }

    @Test
    static func `reports stylesheet failures through href`() throws {
        let context = try makeContext()

        context.evaluateScript(
            "listeners.error.listener({ target: { tagName: 'LINK', href: 'https://cdn.example/app.css' } });",
        )

        let reported = try posts(in: context)
        #expect(reported.first?["url"] as? String == "https://cdn.example/app.css")
        #expect(reported.first?["element"] as? String == "link")
    }

    /// Uncaught runtime errors also dispatch `error` events at the window; those
    /// belong to `window.onerror`, not the subresource reporter.
    @Test
    static func `ignores window-target and tagless error events`() throws {
        let context = try makeContext()

        context.evaluateScript("listeners.error.listener({ target: window });")
        context.evaluateScript("listeners.error.listener({ target: {} });")
        context.evaluateScript("listeners.error.listener({});")
        context.evaluateScript(
            "listeners.error.listener({ target: { tagName: 'USE', href: { baseVal: 'x' } } });",
        )

        #expect(try posts(in: context).isEmpty)
    }

    @Test
    static func `still reports runtime errors through window onerror`() throws {
        let context = try makeContext()

        context.evaluateScript("window.onerror('boom', 'https://cdn.example/app.js', 12);")

        let reported = try posts(in: context)
        #expect(reported.count == 1)
        #expect(reported.first?["type"] as? String == "sdk.error")
        #expect(reported.first?["error"] as? String == "https://cdn.example/app.js:12 boom")
    }
}

// ---------------------------------------------------------------------------

// MARK: - AdaWebHostConsumedIdentityTokenTests

// ---------------------------------------------------------------------------

@MainActor
enum AdaWebHostConsumedIdentityTokenTests {
    /// A rebuilt WebView has fresh sessionStorage, so the in-script consumed-marker
    /// guard cannot withhold a spent token there — the native memo must.
    @Test
    static func `a spent token never re-arms the config script`() {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            identityToken: "secret-jwt-token",
        )
        #expect(host.makeWebviewConfigScript() != nil)

        host.adaBridgeDidBecomeReady(host.bridgeHandler)

        #expect(host.consumedIdentityToken == "secret-jwt-token")
        #expect(host.makeWebviewConfigScript() == nil)
    }

    /// Flagging a consumed (no longer armed) token would make the runtime report
    /// a false injection loss.
    @Test
    static func `a spent token drops the expectsIdentityToken flag from a rebuilt url`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            identityToken: "secret-jwt-token",
        )

        host.adaBridgeDidBecomeReady(host.bridgeHandler)

        let url = try #require(host.buildWebviewUrl(environment: .production))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first(where: { $0.name == "expectsIdentityToken" }) == nil)
    }

    /// appUrl is plain config every document needs; only the credential is one-shot.
    @Test
    static func `retained config still rides after the token was spent`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            identityToken: "secret-jwt-token",
            appUrl: "https://apps.example.com/custom-app/index.html",
        )

        host.adaBridgeDidBecomeReady(host.bridgeHandler)

        let script = try #require(host.makeWebviewConfigScript())
        #expect(!script.source.contains("secret-jwt-token"))
        #expect(!script.source.contains("sessionStorage"))
        // JSONSerialization escapes "/" in the emitted source, so match on the
        // slash-free host rather than the full URL.
        #expect(script.source.contains("appUrl"))
        #expect(script.source.contains("apps.example.com"))
    }

    @Test
    static func `a fresh token re-arms after an old one was consumed`() throws {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .production,
            webSdk: .messaging,
            identityToken: "old-jwt-token",
        )
        host.adaBridgeDidBecomeReady(host.bridgeHandler)
        #expect(host.makeWebviewConfigScript() == nil)

        host.identityToken = "new-jwt-token"

        let script = try #require(host.makeWebviewConfigScript())
        #expect(script.source.contains("new-jwt-token"))
        let url = try #require(host.buildWebviewUrl(environment: .production))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(
            components.queryItems?.first(where: { $0.name == "expectsIdentityToken" })?.value
                == "true",
        )
    }

    /// Without an environment no config script is armed, so the token was never
    /// delivered — ready must not memo it as consumed.
    @Test
    static func `ready without an armed config script records no consumption`() {
        let host = AdaWebHost(
            handle: "ada-example",
            webSdk: .messaging,
            identityToken: "secret-jwt-token",
        )

        host.adaBridgeDidBecomeReady(host.bridgeHandler)

        #expect(host.consumedIdentityToken == nil)
    }
}

// ---------------------------------------------------------------------------

// MARK: - AdaWebHostTrustedOriginWiringTests

// ---------------------------------------------------------------------------

@MainActor
enum AdaWebHostTrustedOriginWiringTests {
    /// WKSecurityOrigin reports IPv6 hosts unbracketed; the trust check must
    /// still match a trustedOrigin derived from the bracketed page URL.
    @Test
    static func `IPv6 loopback origin matches its bracketed trusted origin`() {
        #expect(
            AdaBridgeHandler.isTrustedBridgeMessage(
                frameIsMain: true,
                originProtocol: "https",
                originHost: "::1",
                originPort: 4900,
                trustedOrigin: AdaWebHost.pageOrigin(ofUrl: "https://[::1]:4900"),
            ),
        )
        // Pin the output shape too: routing both #expect sides through
        // pageOrigin would mask a change that mangles them identically.
        #expect(AdaWebHost.pageOrigin(ofUrl: "https://[::1]:4900") == "https://::1:4900")
    }

    /// The gate fails closed, so this wiring — not the extracted pure
    /// function — is where a regression kills the whole native bridge: it
    /// pins that `pageOrigin`'s output shape agrees with
    /// `isTrustedBridgeMessage`'s port normalization for every environment.
    @Test
    static func `wires the trusted bridge origin from the environment's host page`() {
        #expect(
            AdaWebHost(handle: "ada-example", environment: .production, webSdk: .messaging)
                .bridgeHandler.trustedOrigin == "https://messaging-assets.ada.support",
        )
        #expect(
            AdaWebHost(handle: "ada-example", environment: .preprod(branch: "main"), webSdk: .messaging)
                .bridgeHandler.trustedOrigin == "https://messaging-assets.ada-dev2.support",
        )
        #expect(
            AdaWebHost(handle: "ada-example", environment: .local(port: 4900), webSdk: .messaging)
                .bridgeHandler.trustedOrigin == "https://localhost:4900",
        )
    }

    @Test
    static func `fails closed for a non-http custom assets origin`() {
        let host = AdaWebHost(
            handle: "ada-example",
            environment: .custom(assetsOrigin: URL(string: "file:///tmp/assets")!),
            webSdk: .messaging,
        )
        #expect(host.bridgeHandler.trustedOrigin == nil)
    }
}

// ---------------------------------------------------------------------------

// MARK: - AdaWebHostClearPersistedStateTests

// ---------------------------------------------------------------------------

@MainActor
enum AdaWebHostClearPersistedStateTests {
    /// The documented sign-out flow: the host clears the natively persisted
    /// (allowlisted, non-sensitive) state so the next session starts cold.
    @Test
    static func `clears the natively persisted state cache`() {
        let host = AdaWebHost(handle: "ada-example", environment: .production, webSdk: .messaging)
        host.bridgeHandler.handleBridgeMessage([
            "type": "sdk.state.cache",
            "state": ["chatEnabled": true],
        ])
        #expect(host.bridgeHandler.makeInitialStateScript() != nil)

        host.clearPersistedState()

        #expect(host.bridgeHandler.makeInitialStateScript() == nil)
    }
}
