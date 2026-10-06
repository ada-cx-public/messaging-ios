import Foundation
import UIKit
import WebKit

extension AdaWebHost {
    private static let contentRecoveryStabilityMs = 60000.0

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard self.webView === webView, !contentProcessRecoveryPending, !contentProcessRecoveryFailed else { return }
        cancelContentRecoveryReset?()
        cancelContentRecoveryReset = nil
        stopLoadWatchdog()
        contentProcessRecoveryInFlight = false
        webHostLoaded = false
        zdChatterAuthRequestSeq &+= 1
        bridgeHandler.cancelPendingBridgeRequests(reason: "The Ada WebView content process terminated")
        bridgeHandler.sessionMirrorCommandWebView = nil
        bridgeHandler.trustedDocumentUrl = nil
        bridgeHandler.contentProcessGeneration &+= 1
        if contentProcessRecoveries >= 2 {
            contentProcessRecoveryFailed = true
            var event: [String: Any] = ["event_name": "ada.webview.contentProcessTerminated"]
            if let url = webView.url ?? entryDocumentUrl { event["url"] = url.absoluteString }
            dispatchEventToSubscribers(event, rawData: rawSdkEventData(event))
            eventCallbacks?["*"]?(event)
            self.webView(webView, didFailProvisionalNavigation: nil, withError: AdaWebHostError.webViewFailedToLoad)
            return
        }
        contentProcessRecoveryPending = true
        recoverContentProcessIfNeeded()
    }

    func recoverContentProcessIfNeeded() {
        guard contentProcessRecoveryPending, applicationIsActive, let webView else { return }
        contentProcessRecoveryPending = false
        contentProcessRecoveryInFlight = true
        contentProcessRecoveries += 1
        hasError = false
        restoreBridgeBindings(to: webView)
        startLoadWatchdog(for: webView)
        if webView.url == nil || webView.url?.absoluteString == "about:blank" {
            if let initialWebViewRequest { webView.load(initialWebViewRequest) }
        } else {
            webView.reload()
        }
    }

    func restoreBridgeBindings(to webView: WKWebView) {
        bridgeHandler.sessionMirrorCommandWebView = webView
        bridgeHandler.trustedDocumentUrl = entryDocumentUrl?.absoluteString
    }

    func observeApplicationLifecycle() {
        guard !observesApplicationLifecycle else { return }
        observesApplicationLifecycle = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil,
        )
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(applicationBecameInactive),
                name: name,
                object: nil,
            )
        }
    }

    @objc private func applicationDidBecomeActive() {
        applicationIsActive = true
        loadWatchdog.sample()
        recoverContentProcessIfNeeded()
    }

    @objc private func applicationBecameInactive() {
        applicationIsActive = false
    }

    func makeRecoverableWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let view = AdaRecoverableWebView(frame: .zero, configuration: configuration)
        view.onAttached = { [weak self] in self?.recoverContentProcessIfNeeded() }
        return view
    }

    func prepareEntryRequest(_ request: URLRequest, into webView: WKWebView) -> @MainActor @Sendable () -> Void {
        initialWebViewRequest = request
        let generation = bridgeHandler.contentProcessGeneration
        return { [weak self, weak webView] in
            guard let self, let webView, self.webView === webView,
                  bridgeHandler.contentProcessGeneration == generation else { return }
            webView.load(request)
        }
    }

    func loadEntryRequest(_ request: URLRequest, into webView: WKWebView) {
        initialWebViewRequest = request
        webView.load(request)
    }

    func scheduleStableContentRecoveryReset(for webView: WKWebView) {
        cancelContentRecoveryReset?()
        guard contentProcessRecoveries > 0 else { return }
        let delayMs = Self.contentRecoveryStabilityMs
        cancelContentRecoveryReset = scheduleContentRecoveryReset(delayMs) { [weak self, weak webView] in
            guard let self, let webView, self.webView === webView else { return }
            contentProcessRecoveries = 0
            cancelContentRecoveryReset = nil
        }
    }

    func resetContentProcessRecovery() {
        cancelContentRecoveryReset?()
        cancelContentRecoveryReset = nil
        for name in [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
        ] {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
        }
        observesApplicationLifecycle = false
        contentProcessRecoveryPending = false
        contentProcessRecoveryInFlight = false
        contentProcessRecoveryFailed = false
        hasDisplayedPage = false
        contentProcessRecoveries = 0
        initialWebViewRequest = nil
        (webView as? AdaRecoverableWebView)?.onAttached = nil
    }
}

class AdaRecoverableWebView: WKWebView {
    var onAttached: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onAttached?() }
    }
}
