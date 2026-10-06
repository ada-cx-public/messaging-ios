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
