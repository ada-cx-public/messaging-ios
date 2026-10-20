@testable import AdaMessaging
import Foundation
import Testing
import UIKit
import WebKit

@MainActor
struct ContentProcessReadinessTests {
    @Test func `retry before sixty seconds preserves the new recovery budget`() {
        let fixture = LoadWatchdogHost(webSdk: .messaging, environment: .production)
        let host = fixture.host
        defer { host.teardownWebView() }
        let displayed = fixture.webView
        let window = UIWindow()
        host.launchInjectingWebSupport(into: window)
        var terminalEvents = 0
        host.addEventCallback("ada.webview.contentProcessTerminated") { _ in terminalEvents += 1 }
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        host.webViewWebContentProcessDidTerminate(displayed)
        host.webView(displayed, didFinish: nil)
        #expect(!host.webHostLoaded)
        fixture.scheduler.advance(to: 59999)

        host.returnToOnline()

        #expect(host.webView === displayed)
        #expect(displayed.window === window)
        #expect(host.contentProcessRecoveries == 1)
        fixture.scheduler.advance(to: 60000)
        #expect(host.contentProcessRecoveryInFlight)
        #expect(host.contentProcessRecoveries == 1)
        var terminations = 0
        while terminalEvents == 0, terminations < 4 {
            host.webViewWebContentProcessDidTerminate(displayed)
            terminations += 1
        }
        #expect(terminalEvents == 1)
        #expect(terminations == 2)
        #expect(displayed.loads == 3)
    }

    @Test(arguments: ["didCommit", "didFinish"])
    func `offline retry reloads a displayed page that never became ready`(stage: String) throws {
        let fixture = LoadWatchdogHost(webSdk: .messaging, environment: .production)
        let host = fixture.host
        defer { host.teardownWebView() }
        let displayed = fixture.webView
        let window = UIWindow()
        host.launchInjectingWebSupport(into: window)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        if stage == "didCommit" {
            host.webView(displayed, didCommit: nil)
        } else {
            host.webView(displayed, didFinish: nil)
        }
        #expect(host.hasDisplayedPage)
        #expect(!host.webHostLoaded)
        #expect(!host.contentProcessRecoveryInFlight)
        #expect(!host.contentProcessRecoveryFailed)
        let offline = try #require(OfflineViewController.create())
        host.offlineViewController = offline
        displayed.addSubview(offline.view)
        host.isInOfflineMode = false

        host.returnToOnline()

        #expect(host.webView === displayed)
        #expect(displayed.window === window)
        #expect(displayed.loads == 1)
        #expect(host.contentProcessRecoveryInFlight)
        #expect(offline.view.superview == nil)
        #expect(host.offlineViewController == nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(displayed.loads == 1)
    }

    @Test(arguments: ["watchdog", "didFail", "didFailProvisionalNavigation", "terminal"], ["sdk.ready", "embedReady"])
    func `trusted readiness after failure lets the next termination recover or report`(
        failure: String,
        signal: String,
    ) async throws {
        let fixture = LoadWatchdogHost(webSdk: signal == "sdk.ready" ? .messaging : .legacy, environment: .production)
        let host = fixture.host
        defer { host.teardownWebView() }
        let origin = try #require(host.bridgeHandler.trustedOrigin)
        fixture.webView
            .currentURL = URL(string: origin + (signal == "sdk.ready" ? "/sdk/webview.html" : "/mobile-sdk-webview/"))
        host.entryDocumentUrl = fixture.webView.url
        var terminalEvents = 0
        host.addEventCallback("ada.webview.contentProcessTerminated") { _ in terminalEvents += 1 }
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        host.webViewWebContentProcessDidTerminate(fixture.webView)
        switch failure {
        case "watchdog":
            fixture.scheduler.advance(to: 30000)
        case "didFail":
            host.webView(fixture.webView, didFail: nil, withError: URLError(.notConnectedToInternet))
        case "didFailProvisionalNavigation":
            host.webView(
                fixture.webView,
                didFailProvisionalNavigation: nil,
                withError: URLError(.notConnectedToInternet),
            )
        default:
            host.webViewWebContentProcessDidTerminate(fixture.webView)
            host.webViewWebContentProcessDidTerminate(fixture.webView)
            host.webView(fixture.webView, didCommit: nil)
        }
        #expect(host.contentProcessRecoveryFailed)
        #expect(!host.contentProcessRecoveryInFlight)
        let loads = fixture.webView.loads
        let terminals = terminalEvents

        await sendReadiness(signal, to: fixture)

        #expect(host.webHostLoaded)
        #expect(!host.contentProcessRecoveryFailed)
        #expect(!host.hasError)
        #expect(host.contentProcessRecoveries == loads)
        host.webViewWebContentProcessDidTerminate(fixture.webView)
        if failure == "terminal" {
            #expect(fixture.webView.loads == loads)
            #expect(terminalEvents == terminals + 1)
        } else {
            #expect(fixture.webView.loads == loads + 1)
            #expect(host.contentProcessRecoveryInFlight)
            #expect(terminalEvents == terminals)
        }
    }

    private func sendReadiness(_ signal: String, to fixture: LoadWatchdogHost) async {
        if signal == "sdk.ready" {
            fixture.host.bridgeHandler.handleBridgeMessage(["type": "sdk.ready"])
            return
        }
        await withCheckedContinuation { continuation in
            let controller = fixture.webView.configuration.userContentController
            controller.add(ReadinessMessageHandler { message in
                fixture.host.userContentController(controller, didReceive: message)
                controller.removeScriptMessageHandler(forName: "embedReady")
                continuation.resume()
            }, name: "embedReady")
            fixture.webView.loadHTMLString(
                "<script>window.webkit.messageHandlers.embedReady.postMessage({})</script>",
                baseURL: fixture.webView.url,
            )
        }
    }
}

@MainActor
private final class ReadinessMessageHandler: NSObject, WKScriptMessageHandler {
    let receive: (WKScriptMessage) -> Void

    init(receive: @escaping (WKScriptMessage) -> Void) {
        self.receive = receive
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(message)
    }
}

@MainActor
private final class VisibilityAncestor: UIView {
    var observationCount = 0

    override func addObserver(
        _ observer: NSObject,
        forKeyPath keyPath: String,
        options: NSKeyValueObservingOptions = [],
        context: UnsafeMutableRawPointer?,
    ) {
        observationCount += 1
        super.addObserver(observer, forKeyPath: keyPath, options: options, context: context)
    }
}

@Suite(.serialized)
@MainActor
struct ViewVisibilityTests {
    @Test func `application lifecycle reports visibility changes on the main queue`() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.isHidden = false
        let center = NotificationCenter()
        let view = AdaRecoverableWebView(frame: window.bounds, lifecycleNotificationCenter: center)
        window.addSubview(view)
        var reports: [Bool] = []
        view.onVisibilityChanged = {
            #expect(Thread.isMainThread)
            reports.append($0)
        }
        let application = UIApplication.shared
        for name in [
            UIApplication.didEnterBackgroundNotification,
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willEnterForegroundNotification,
            UIApplication.didBecomeActiveNotification,
        ] {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    center.post(name: name, object: application)
                    continuation.resume()
                }
            }
            await drainVisibilityReports()
        }
        #expect(view.isVisibleInWindow)
        #expect(reports == [false, true])
    }

    @Test func `effective alpha includes every ancestor`() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.isHidden = false
        let container = UIView(frame: window.bounds)
        let view = AdaRecoverableWebView(frame: window.bounds)
        container.alpha = 0.1
        view.alpha = 0.05
        var reports: [Bool] = []
        view.onVisibilityChanged = { reports.append($0) }
        container.addSubview(view)
        window.addSubview(container)
        await drainVisibilityReports()
        #expect(reports == [false])
        container.alpha = 1
        await drainVisibilityReports()
        #expect(reports == [false, true])
    }

    @Test func `ancestor geometry changes report without a webview layout`() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.isHidden = false
        let container = UIView(frame: window.bounds)
        let view = AdaRecoverableWebView(frame: window.bounds)
        container.addSubview(view)
        window.addSubview(container)
        var reports: [Bool] = []
        view.onVisibilityChanged = { reports.append($0) }
        container.bounds.size.height = 0
        await drainVisibilityReports()
        #expect(!view.isVisibleInWindow)
        #expect(reports == [false])
        container.bounds.size.height = 640
        await drainVisibilityReports()
        #expect(reports == [false, true])
        container.transform = CGAffineTransform(scaleX: 0, y: 1)
        await drainVisibilityReports()
        #expect(reports == [false, true, false])
        container.transform = .identity
        await drainVisibilityReports()
        #expect(reports == [false, true, false, true])
    }

    @Test(arguments: ["view alpha", "ancestor alpha", "view width", "container height", "window frame"])
    func `preloaded invisible views report visible once when shown`(hiddenBy: String) async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.isHidden = false
        let container = UIView(frame: window.bounds)
        let view = AdaRecoverableWebView(frame: container.bounds)
        switch hiddenBy {
        case "view alpha": view.alpha = 0
        case "ancestor alpha": container.alpha = 0.01
        case "view width": view.frame.size.width = 0
        case "container height": container.frame.size.height = 0
        default: view.transform = CGAffineTransform(scaleX: 0, y: 1)
        }
        var reports: [Bool] = []
        view.onVisibilityChanged = { reports.append($0) }
        container.addSubview(view)
        window.addSubview(container)
        await drainVisibilityReports()
        #expect(!view.isVisibleInWindow)
        #expect(reports == [false])
        view.alpha = 1
        container.alpha = 1
        view.transform = .identity
        container.frame = window.bounds
        view.frame = container.bounds
        if hiddenBy == "view alpha" || hiddenBy == "ancestor alpha" {
            await drainVisibilityReports()
            #expect(reports == [false, true])
        }
        view.layoutSubviews()
        view.layoutSubviews()
        await drainVisibilityReports()
        #expect(view.isVisibleInWindow)
        #expect(reports == [false, true])
    }

    @Test(arguments: [AdaWebSdk.messaging, .legacy])
    func `factory wiring dispatches visibility changes only for Messaging`(webSdk: AdaWebSdk) async throws {
        let host = AdaWebHost(handle: "visibility-test", environment: .production, webSdk: webSdk)
        host.teardownWebView()
        defer { host.teardownWebView() }
        let configuration = WKWebViewConfiguration()
        let view = host.makeRecoverableWebView(configuration: configuration)
        host.webView = view
        let entry =
            try #require(URL(string: "https://messaging-assets.ada.support/sdk/webview.html?handle=visibility-test"))
        host.entryDocumentUrl = entry
        host.bridgeHandler.trustedOrigin = "https://messaging-assets.ada.support"
        await withCheckedContinuation { continuation in
            configuration.userContentController.add(ReadinessMessageHandler { _ in
                configuration.userContentController.removeScriptMessageHandler(forName: "visibilityReady")
                continuation.resume()
            }, name: "visibilityReady")
            view.loadHTMLString("""
            <script>
            window.visibilityReports = [];
            window.__ADA_BRIDGE_DISPATCH__ = raw => {
                const command = JSON.parse(raw);
                if (command.type === "ada.viewVisibility.set") window.visibilityReports.push(command.payload.isVisible);
            };
            window.webkit.messageHandlers.visibilityReady.postMessage({});
            </script>
            """, baseURL: entry)
        }
        host.restoreBridgeBindings(to: view)
        #expect(host.bridgeHandler.captureDocumentTicket(for: view) != nil)
        host.webHostLoaded = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.isHidden = false
        view.frame = window.bounds
        window.addSubview(view)
        await drainVisibilityReports()
        let shown = try await view.evaluateJavaScript("window.visibilityReports") as? [Bool]
        #expect(shown == (webSdk == .messaging ? [true] : []))
        view.alpha = 0
        await drainVisibilityReports()
        view.alpha = 1
        await drainVisibilityReports()
        let reports = try await view.evaluateJavaScript("window.visibilityReports") as? [Bool]
        #expect(reports == (webSdk == .messaging ? [true, false, true] : []))
    }

    @Test func `repeated layout preserves observations and dispatches only visibility changes`() async {
        let fixture = LoadWatchdogHost(webSdk: .messaging, environment: .production)
        let host = fixture.host
        defer { host.teardownWebView() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.isHidden = false
        let ancestor = VisibilityAncestor(frame: window.bounds)
        window.addSubview(ancestor)
        let view = fixture.webView
        view.frame = window.bounds
        view.onVisibilityChanged = { [weak host] _ in host?.reportViewVisibility() }
        ancestor.addSubview(view)
        host.restoreBridgeBindings(to: view)
        host.adaBridgeDidBecomeReady(host.bridgeHandler)
        await drainVisibilityReports()
        let observations = ancestor.observationCount
        let initialReports = view.capturedScripts.count(where: { $0.contains("ada.viewVisibility.set") })
        #expect(observations > 0)
        #expect(initialReports == 1)
        for _ in 0 ..< 5 {
            view.layoutSubviews()
        }
        ancestor.isHidden = false
        await drainVisibilityReports()
        #expect(ancestor.observationCount == observations)
        #expect(view.capturedScripts.count(where: { $0.contains("ada.viewVisibility.set") }) == initialReports)
        ancestor.isHidden = true
        await drainVisibilityReports()
        #expect(view.capturedScripts.count(where: { $0.contains("ada.viewVisibility.set") }) == initialReports + 1)
        host.adaBridgeDidBecomeReady(host.bridgeHandler)
        #expect(view.capturedScripts.count(where: { $0.contains("ada.viewVisibility.set") }) == initialReports + 2)
    }

    @Test func `background ancestor hidden changes report on the main queue`() async {
        let webView = AdaRecoverableWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.isHidden = false
        let ancestor = UIView(frame: window.bounds)
        window.addSubview(ancestor)
        ancestor.addSubview(webView)
        var reports: [Bool] = []
        webView.onVisibilityChanged = {
            #expect(Thread.isMainThread)
            reports.append($0)
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                ancestor.setValue(true, forKey: "hidden")
                continuation.resume()
            }
        }
        await drainVisibilityReports()
        #expect(reports.last == false)
        ancestor.isHidden = false
        await drainVisibilityReports()
        #expect(reports.last == true)
    }

    @Test func `layout observes a reparented ancestor in the same window`() async {
        let webView = AdaRecoverableWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.isHidden = false
        let original = VisibilityAncestor(frame: window.bounds)
        let replacement = VisibilityAncestor(frame: window.bounds)
        let container = UIView(frame: window.bounds)
        window.addSubview(original)
        window.addSubview(replacement)
        original.addSubview(container)
        container.addSubview(webView)
        var reports: [Bool] = []
        webView.onVisibilityChanged = { reports.append($0) }
        replacement.isHidden = true
        replacement.addSubview(container)
        webView.setNeedsLayout()
        webView.layoutIfNeeded()
        await drainVisibilityReports()
        #expect(reports.last == false)
        replacement.isHidden = false
        await drainVisibilityReports()
        #expect(reports.last == true)
        #expect(replacement.observationCount > 0)
        let observations = replacement.observationCount
        let reportCount = reports.count
        webView.layoutSubviews()
        await drainVisibilityReports()
        #expect(replacement.observationCount == observations)
        original.isHidden = true
        await drainVisibilityReports()
        #expect(reports.count == reportCount)
    }

    private func drainVisibilityReports() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func `visibility follows attachment and hidden ancestors`() async {
        let webView = AdaRecoverableWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var reports: [Bool] = []
        webView.onVisibilityChanged = { reports.append($0) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.isHidden = false
        let container = UIView(frame: window.bounds)
        container.addSubview(webView)
        #expect(reports.last == false)
        window.addSubview(container)
        #expect(reports.last == true)
        container.isHidden = true
        await drainVisibilityReports()
        #expect(reports.last == false)
        container.isHidden = false
        await drainVisibilityReports()
        #expect(reports.last == true)
        webView.isHidden = true
        await drainVisibilityReports()
        #expect(reports.last == false)
        webView.isHidden = false
        await drainVisibilityReports()
        #expect(reports.last == true)
        container.removeFromSuperview()
        #expect(reports.last == false)
    }

    @Test(arguments: [false, true])
    func `readiness replays current visibility and headless never engages`(headless: Bool) throws {
        let fixture = LoadWatchdogHost(webSdk: .messaging, headless: headless, environment: .production)
        let host = fixture.host
        defer { host.teardownWebView() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.isHidden = false
        fixture.webView.frame = window.bounds
        window.addSubview(fixture.webView)
        host.restoreBridgeBindings(to: fixture.webView)
        #expect(!fixture.webView.capturedScripts.contains { $0.contains("ada.viewVisibility.set") })
        host.adaBridgeDidBecomeReady(host.bridgeHandler)
        let script = try #require(fixture.webView.capturedScripts.last { $0.contains("ada.viewVisibility.set") })
        #expect(script.contains("\"isVisible\":\(!headless)"))
        fixture.webView.isHidden = true
        host.adaBridgeDidBecomeReady(host.bridgeHandler)
        let replay = try #require(fixture.webView.capturedScripts.last { $0.contains("ada.viewVisibility.set") })
        #expect(replay.contains("\"isVisible\":false"))
    }
}
