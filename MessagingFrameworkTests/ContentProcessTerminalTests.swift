@testable import AdaMessaging
import Foundation
import Testing
import UIKit
import WebKit

@MainActor
struct ContentProcessStabilityTests {
    @Test func `crashes after successful loads exhaust two recoveries within sixty seconds`() {
        let fixture = LoadWatchdogHost(webSdk: .messaging, environment: .production)
        var events: [String] = []
        fixture.host.eventCallbacks = ["*": { event in
            if let name = event["event_name"] as? String { events.append(name) }
        }]
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        for _ in 0 ..< 3 {
            fixture.host.webView(fixture.webView, didFinish: nil)
            fixture.scheduler.advance(to: fixture.scheduler.nowMs + 59999)
            fixture.host.webViewWebContentProcessDidTerminate(fixture.webView)
        }
        fixture.host.webViewWebContentProcessDidTerminate(fixture.webView)
        #expect(fixture.webView.loads == 2)
        #expect(events == [
            "ada.webview.loaded", "ada.webview.loaded", "ada.webview.loaded",
            "ada.webview.contentProcessTerminated", "ada.webview.loadFailed",
        ])
        #expect(fixture.errors == [.webViewFailedToLoad])
        #expect(fixture.scheduler.entries.isEmpty)
        fixture.host.teardownWebView()
    }

    @Test func `sixty seconds loaded restores automatic recovery`() {
        let fixture = LoadWatchdogHost(webSdk: .messaging, environment: .production)
        var events: [String] = []
        fixture.host.eventCallbacks = ["*": { event in
            if let name = event["event_name"] as? String { events.append(name) }
        }]
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        fixture.host.webView(fixture.webView, didFinish: nil)
        fixture.host.webViewWebContentProcessDidTerminate(fixture.webView)
        fixture.host.webView(fixture.webView, didFinish: nil)
        fixture.scheduler.advance(to: 60000)
        fixture.host.webViewWebContentProcessDidTerminate(fixture.webView)
        fixture.host.webView(fixture.webView, didFinish: nil)
        fixture.host.webViewWebContentProcessDidTerminate(fixture.webView)
        #expect(fixture.webView.loads == 3)
        #expect(events == ["ada.webview.loaded", "ada.webview.loaded", "ada.webview.loaded"])
        #expect(fixture.errors.isEmpty)
        fixture.host.teardownWebView()
    }

    @Test func `teardown cancels the recovery stability timer`() {
        let fixture = LoadWatchdogHost(webSdk: .messaging, environment: .production)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        fixture.host.webViewWebContentProcessDidTerminate(fixture.webView)
        fixture.host.webView(fixture.webView, didFinish: nil)
        #expect(fixture.webView.loads == 1)
        #expect(fixture.scheduler.entries.count == 1)
        fixture.host.teardownWebView()
        #expect(fixture.scheduler.entries.isEmpty)
    }

    @Test func `deinit cancels the recovery stability timer`() throws {
        var fixture: LoadWatchdogHost? = LoadWatchdogHost(webSdk: .messaging, environment: .production)
        let scheduler = try #require(fixture?.scheduler)
        weak var host = try #require(fixture?.host)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try fixture?.host.webViewWebContentProcessDidTerminate(#require(fixture?.webView))
        try fixture?.host.webView(#require(fixture?.webView), didFinish: nil)
        #expect(scheduler.entries.count == 1)
        fixture = nil
        #expect(host == nil)
        #expect(scheduler.entries.isEmpty)
    }
}

@MainActor
struct ContentProcessTerminalTests {
    @Test(arguments: [false, true])
    func `host load after terminal failure restores bridge requests and mirror replies`(buildRedirect: Bool) throws {
        let fixture = LoadWatchdogHost(webSdk: .messaging, environment: .production)
        let host = fixture.host
        defer { host.teardownWebView() }
        let window = UIWindow()
        host.launchInjectingWebSupport(into: window)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        for _ in 0 ..< 3 {
            host.webViewWebContentProcessDidTerminate(fixture.webView)
        }
        #expect(host.contentProcessRecoveryFailed)
        #expect(host.bridgeHandler.trustedDocumentUrl == nil)
        #expect(host.bridgeHandler.sessionMirrorCommandWebView == nil)

        host.webView(WatchdogWebView(), didCommit: nil)
        #expect(host.bridgeHandler.trustedDocumentUrl == nil)
        #expect(host.bridgeHandler.sessionMirrorCommandWebView == nil)
        let entryUrl = try #require(host.entryDocumentUrl)
        fixture.webView.load(URLRequest(url: entryUrl))
        if buildRedirect {
            fixture.webView.currentURL = URL(string: entryUrl.absoluteString.replacingOccurrences(
                of: "/sdk/webview.html", with: "/abcdef0/sdk/webview.html",
            ))
        }
        host.webView(fixture.webView, didCommit: nil)
        try expectSessionMirrorReply(from: fixture)
        host.webView(fixture.webView, didFinish: nil)
        host.bridgeHandler.handleBridgeMessage(["type": "sdk.ready"])
        try expectGetInfoResponse(from: fixture)
        #expect(host.webView === fixture.webView)
        #expect(fixture.webView.window === window)
        #expect(!host.contentProcessRecoveryFailed)
    }

    @Test(arguments: [
        "https://untrusted.example/sdk/webview.html?handle=watchdog-test",
        "https://messaging-assets.ada.support/sdk/chat.html?handle=watchdog-test",
        "https://messaging-assets.ada.support/sdk/webview.html?handle=other",
    ])
    func `only a trusted host load ends terminal failure and restores recovery`(url: String) throws {
        let fixture = LoadWatchdogHost(webSdk: .messaging, environment: .production)
        let host = fixture.host
        defer { host.teardownWebView() }
        var loaded: [[String: Any]] = []
        host.addEventCallback("ada.webview.loaded") { loaded.append($0) }
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        for _ in 0 ..< 3 {
            host.webViewWebContentProcessDidTerminate(fixture.webView)
        }
        #expect(host.contentProcessRecoveryFailed)
        try fixture.webView.load(URLRequest(url: #require(URL(string: url))))
        host.webView(fixture.webView, didCommit: nil)
        #expect(host.contentProcessRecoveryFailed)
        #expect(host.contentProcessRecoveries == 2)
        #expect(host.bridgeHandler.trustedDocumentUrl == nil)
        #expect(host.bridgeHandler.sessionMirrorCommandWebView == nil)
        host.webView(fixture.webView, didFinish: nil)
        #expect(host.contentProcessRecoveryFailed)
        #expect(host.contentProcessRecoveries == 2)
        #expect(host.hasError)
        #expect(loaded.isEmpty)
        #expect(host.bridgeHandler.trustedDocumentUrl == nil)
        #expect(host.bridgeHandler.sessionMirrorCommandWebView == nil)
        #expect(host.bridgeHandler.captureDocumentTicket(for: fixture.webView) == nil)
        #expect(fixture.webView.capturedScripts.isEmpty)

        host.webViewWebContentProcessDidTerminate(fixture.webView)
        #expect(fixture.webView.loads == 3)
        #expect(fixture.errors == [.webViewFailedToLoad])

        let entryUrl = try #require(host.entryDocumentUrl)
        fixture.webView.load(URLRequest(url: entryUrl))
        host.webView(fixture.webView, didCommit: nil)
        try expectSessionMirrorReply(from: fixture)
        host.webView(fixture.webView, didFinish: nil)
        host.bridgeHandler.handleBridgeMessage(["type": "sdk.ready"])
        try expectGetInfoResponse(from: fixture)
        #expect(!host.contentProcessRecoveryFailed)
        #expect(host.contentProcessRecoveries == 2)
        #expect(!host.hasError)
        #expect(loaded.count == 1)
        #expect(loaded.first?["url"] as? String == entryUrl.absoluteString)
        fixture.scheduler.advance(to: 60000)
        host.webViewWebContentProcessDidTerminate(fixture.webView)
        #expect(fixture.webView.loads == 5)
        #expect(host.contentProcessRecoveries == 1)
    }

    private func expectSessionMirrorReply(from fixture: LoadWatchdogHost) throws {
        let handler = fixture.host.bridgeHandler
        handler.sessionMirrorKeychainRunner = { $0() }
        handler.sessionMirrorMainRunner = { $0() }
        handler.handleBridgeMessage([
            "type": "sdk.session.mirrorRequest", "version": 1,
            "scopeKey": "ada-session-mirror:watchdog-test:\(UUID().uuidString)", "requestId": "terminal-seed",
        ])
        guard let script = fixture.webView.capturedScripts.first(where: { $0.contains("sdk.sessionMirror.seed") })
        else {
            Issue.record("Expected a session-mirror seed reply before the host load finishes")
            return
        }
        let command = try dispatchedCommand(from: script)
        #expect(command["requestId"] as? String == "terminal-seed")
        #expect(command["seed"] is NSNull)
    }

    private func expectGetInfoResponse(from fixture: LoadWatchdogHost) throws {
        var results: [AdaBridgeRequestResult] = []
        fixture.host.getInfo { results.append($0) }
        let script = try #require(fixture.webView.capturedScripts.first { $0.contains("ada.request") })
        let command = try dispatchedCommand(from: script)
        #expect(command["method"] as? String == "getInfo")
        try fixture.host.bridgeHandler.handleBridgeMessage([
            "type": "sdk.response", "requestId": #require(command["requestId"] as? String),
            "result": ["isChatOpen": true],
        ])
        #expect(results.count == 1)
        guard case let .success(value) = try #require(results.first) else {
            Issue.record("Expected getInfo to succeed after the host load")
            return
        }
        #expect((value as? [String: Any])?["isChatOpen"] as? Bool == true)
    }

    @Test func `host load after terminal failure emits loaded and restores automatic recovery`() throws {
        let fixture = LoadWatchdogHost(webSdk: .messaging, environment: .production)
        let host = fixture.host
        defer { host.teardownWebView() }
        let window = UIWindow()
        host.launchInjectingWebSupport(into: window)
        var loaded: [[String: Any]] = []
        host.addEventCallback("ada.webview.loaded") { loaded.append($0) }
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        for _ in 0 ..< 4 {
            host.webViewWebContentProcessDidTerminate(fixture.webView)
        }
        #expect(fixture.webView.loads == 2)
        #expect(fixture.errors == [.webViewFailedToLoad])

        let request = try URLRequest(url: #require(host.entryDocumentUrl))
        fixture.webView.load(request)
        host.startLoadWatchdog(for: fixture.webView)
        host.webView(fixture.webView, didFinish: nil)

        #expect(loaded.count == 1)
        #expect(loaded.first?["url"] as? String == request.url?.absoluteString)
        #expect(!host.hasError)
        #expect(!host.contentProcessRecoveryFailed)
        fixture.scheduler.advance(to: 90000)
        #expect(fixture.scheduler.entries.isEmpty)
        #expect(fixture.errors == [.webViewFailedToLoad])
        for _ in 0 ..< 2 {
            host.webViewWebContentProcessDidTerminate(fixture.webView)
        }
        #expect(host.webView === fixture.webView)
        #expect(fixture.webView.window === window)
        #expect(fixture.webView.loads == 5)
        #expect(fixture.errors == [.webViewFailedToLoad])
        for _ in 0 ..< 2 {
            host.webViewWebContentProcessDidTerminate(fixture.webView)
        }
        #expect(loaded.count == 1)
        #expect(fixture.errors == [.webViewFailedToLoad, .webViewFailedToLoad])
    }

    @Test(arguments: [nil, "about:blank", "https://messaging-assets.ada.support/sdk/webview.html?handle=watchdog-test"])
    func `retry keeps the displayed webview and reports one timeout if its load stalls`(_ url: String?) throws {
        let fixture = LoadWatchdogHost(webSdk: .messaging)
        let host = fixture.host
        defer { host.teardownWebView() }
        let controller = AdaWebHostViewController.createWebController(with: fixture.webView)
        let window = UIWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let originalURL = fixture.webView.url
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        for _ in 0 ..< 3 {
            host.webViewWebContentProcessDidTerminate(fixture.webView)
        }
        #expect(fixture.webView.loads == 2)
        #expect(fixture.errors == [.webViewFailedToLoad])
        fixture.webView.currentURL = url.flatMap(URL.init(string:))
        let offline = try #require(OfflineViewController.create())
        host.offlineViewController = offline
        fixture.webView.addSubview(offline.view)
        host.isInOfflineMode = false

        host.returnToOnline()

        #expect(host.webView === fixture.webView)
        #expect(controller.view === fixture.webView)
        #expect(fixture.webView.window === window)
        #expect(fixture.webView.loads == 3)
        #expect(fixture.webView.url == originalURL)
        #expect(offline.view.superview == nil)
        #expect(host.offlineViewController == nil)
        fixture.scheduler.advance(to: 29999)
        #expect(fixture.errors == [.webViewFailedToLoad])
        fixture.scheduler.advance(to: 30000)
        #expect(fixture.errors == [.webViewFailedToLoad, .webViewTimeout])
        fixture.scheduler.advance(to: 90000)
        #expect(fixture.errors == [.webViewFailedToLoad, .webViewTimeout])
    }

    @Test(arguments: [false, true])
    func `retry removes the offline view while pending recovery waits for an active app`(isActive: Bool) throws {
        let fixture = LoadWatchdogHost(webSdk: .messaging, environment: .production)
        let host = fixture.host
        defer { host.teardownWebView() }
        let window = UIWindow()
        host.launchInjectingWebSupport(into: window)
        let offline = try #require(OfflineViewController.create())
        host.offlineViewController = offline
        fixture.webView.addSubview(offline.view)
        host.isInOfflineMode = true
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        host.webViewWebContentProcessDidTerminate(fixture.webView)
        #expect(host.contentProcessRecoveryPending)
        #expect(fixture.webView.loads == 0)
        host.isInOfflineMode = false
        host.applicationIsActive = isActive

        host.returnToOnline()

        #expect(offline.view.superview == nil)
        #expect(host.offlineViewController == nil)
        #expect(host.webView === fixture.webView)
        #expect(fixture.webView.window === window)
        #expect(fixture.webView.loads == (isActive ? 1 : 0))
        #expect(host.contentProcessRecoveryPending == !isActive)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(fixture.webView.loads == 1)
        #expect(!host.contentProcessRecoveryPending)
    }

    @Test func `successful retry restores two automatic recoveries on the displayed webview`() {
        let fixture = LoadWatchdogHost(webSdk: .messaging, environment: .production)
        defer { fixture.host.teardownWebView() }
        let window = UIWindow()
        fixture.host.launchInjectingWebSupport(into: window)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        for _ in 0 ..< 3 {
            fixture.host.webViewWebContentProcessDidTerminate(fixture.webView)
        }

        fixture.host.returnToOnline()
        #expect(fixture.webView.loads == 3)
        fixture.host.webView(fixture.webView, didFinish: nil)
        fixture.host.adaBridgeDidBecomeReady(fixture.host.bridgeHandler)
        fixture.scheduler.advance(to: 90000)
        #expect(fixture.errors == [.webViewFailedToLoad])
        fixture.host.returnToOnline()
        #expect(fixture.webView.loads == 3)
        for _ in 0 ..< 2 {
            fixture.host.webViewWebContentProcessDidTerminate(fixture.webView)
        }
        #expect(fixture.host.webView === fixture.webView)
        #expect(fixture.webView.window === window)
        #expect(fixture.webView.loads == 5)
        #expect(fixture.errors == [.webViewFailedToLoad])
        fixture.host.webViewWebContentProcessDidTerminate(fixture.webView)
        #expect(fixture.errors == [.webViewFailedToLoad, .webViewFailedToLoad])
    }

    @Test func `offline launch retry sets up the webview before presentation`() throws {
        let host = AdaWebHost(handle: "offline-launch-test", webSdk: .messaging)
        defer { host.teardownWebView() }
        let initial = try #require(host.webView)
        host.isInOfflineMode = true
        host.returnToOnline()
        #expect(host.webView === initial)
        host.isInOfflineMode = false

        host.returnToOnline()

        let replacement = try #require(host.webView)
        #expect(replacement !== initial)
        #expect(replacement.navigationDelegate === host)
        #expect(host.initialWebViewRequest?.url == host.entryDocumentUrl)
        let window = UIWindow()
        host.launchInjectingWebSupport(into: window)
        #expect(replacement.window === window)
    }

    @Test func `terminal recovery publishes once through each event channel`() throws {
        let host = AdaWebHost(handle: "termination-test", webSdk: .messaging)
        defer { host.teardownWebView() }
        let webView = try #require(host.webView)
        var errors: [AdaWebHost.AdaWebHostError] = []
        host.webViewLoadingErrorCallback = { if let error = $0 as? AdaWebHost.AdaWebHostError { errors.append(error) } }
        let key = "ada.webview.contentProcessTerminated"
        var named: [[String: Any]] = []
        var wildcard: [[String: Any]] = []
        var raw: [String] = []
        var legacy: [[String: Any]] = []
        host.addEventCallback(key) { named.append($0) }
        host.addEventCallback("*") { if $0["event_name"] as? String == key { wildcard.append($0) } }
        host.addSdkEventCallback { name, data in if name == key, let data { raw.append(data) } }
        host.eventCallbacks = ["*": { if $0["event_name"] as? String == key { legacy.append($0) } }]
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        for _ in 0 ..< 4 {
            host.webViewWebContentProcessDidTerminate(webView)
        }
        #expect(named.count == 1)
        #expect(wildcard.count == 1)
        #expect(raw.count == 1)
        #expect(legacy.count == 1)
        let expected = try ["event_name": key, "url": #require(host.entryDocumentUrl?.absoluteString)]
        #expect(named.first as? [String: String] == expected)
        #expect(legacy.first as? [String: String] == expected)
        #expect(errors == [.webViewFailedToLoad])
    }
}

@MainActor
extension ContentProcessTerminalTests {
    @Test(arguments: ["didFinish", "sdk.ready"])
    func `completed recovery keeps the displayed webview without another retry load`(completion: String) {
        let fixture = LoadWatchdogHost(webSdk: .messaging, environment: .production)
        let host = fixture.host
        defer { host.teardownWebView() }
        let window = UIWindow()
        host.launchInjectingWebSupport(into: window)
        host.webView(fixture.webView, didFinish: nil)
        host.bridgeHandler.handleBridgeMessage(["type": "sdk.ready"])
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        host.webViewWebContentProcessDidTerminate(fixture.webView)
        if completion == "didFinish" {
            host.webView(fixture.webView, didFinish: nil)
            host.bridgeHandler.handleBridgeMessage(["type": "sdk.ready"])
        } else {
            host.bridgeHandler.handleBridgeMessage(["type": "sdk.ready"])
        }

        host.returnToOnline()

        #expect(host.webView === fixture.webView)
        #expect(fixture.webView.window === window)
        #expect(fixture.webView.loads == 1)
        fixture.scheduler.advance(to: 90000)
        #expect(fixture.errors.isEmpty)
        #expect(fixture.scheduler.entries.isEmpty)
    }

    @Test(arguments: ["loading", "didFail", "didFailProvisionalNavigation", "watchdog"])
    func `offline retry reloads the displayed webview during or after failed recovery`(stage: String) throws {
        let fixture = LoadWatchdogHost(webSdk: .messaging, environment: .production)
        let host = fixture.host
        defer { host.teardownWebView() }
        let displayed = fixture.webView
        let controller = AdaWebHostViewController.createWebController(with: displayed)
        let window = UIWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        host.webView(displayed, didFinish: nil)
        host.bridgeHandler.handleBridgeMessage(["type": "sdk.ready"])
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        host.webViewWebContentProcessDidTerminate(displayed)
        #expect(displayed.loads == 1)
        switch stage {
        case "didFail":
            host.webView(displayed, didFail: nil, withError: URLError(.notConnectedToInternet))
        case "didFailProvisionalNavigation":
            host.webView(displayed, didFailProvisionalNavigation: nil, withError: URLError(.notConnectedToInternet))
        case "watchdog":
            fixture.scheduler.advance(to: 30000)
        default:
            break
        }
        let offline = try #require(OfflineViewController.create())
        host.offlineViewController = offline
        displayed.addSubview(offline.view)
        host.isInOfflineMode = false

        host.returnToOnline()

        #expect(host.webView === displayed)
        #expect(controller.view === displayed)
        #expect(host.webView?.window === window)
        #expect(displayed.window === window)
        #expect(displayed.loads == 2)
        #expect(offline.view.superview == nil)
        #expect(host.offlineViewController == nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(displayed.loads == 2)
    }
}
