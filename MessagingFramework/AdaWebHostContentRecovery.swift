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
        view.onVisibilityChanged = { [weak self] _ in self?.reportViewVisibility() }
        return view
    }

    func reportViewVisibility() {
        guard webSdk == .messaging, webHostLoaded,
              let view = webView as? AdaRecoverableWebView else { return }
        bridgeHandler.dispatchCommand(
            ["type": "ada.viewVisibility.set", "payload": ["isVisible": !headless && view.isVisibleInWindow]],
            to: view,
            ticket: bridgeHandler.captureDocumentTicket(for: view),
        )
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
        (webView as? AdaRecoverableWebView)?.onVisibilityChanged = nil
    }
}

class AdaRecoverableWebView: WKWebView {
    var onAttached: (() -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    private var visibilityObservations: [NSKeyValueObservation] = []
    private var observedAncestors: [ObjectIdentifier] = []
    private var lastReportedVisibility: Bool?
    // KVO can arrive off the main queue, so protect the pending flag with a lock.
    private nonisolated let visibilityReportLock = NSLock()
    private nonisolated(unsafe) var visibilityReportPending = false
    private var applicationInForeground = UIApplication.shared.applicationState != .background
    private var sceneInForeground: Bool?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private let lifecycleNotificationCenter: NotificationCenter
    // Hostless unit tests have no connected UIWindowScene, so they supply the scene identity.
    private let windowSceneOverride: (() -> AnyObject?)?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        lifecycleNotificationCenter = .default
        windowSceneOverride = nil
        super.init(frame: frame, configuration: configuration)
    }

    init(
        frame: CGRect,
        lifecycleNotificationCenter: NotificationCenter,
        windowScene: (() -> AnyObject?)? = nil,
    ) {
        self.lifecycleNotificationCenter = lifecycleNotificationCenter
        windowSceneOverride = windowScene
        super.init(frame: frame, configuration: WKWebViewConfiguration())
    }

    required init?(coder: NSCoder) {
        lifecycleNotificationCenter = .default
        windowSceneOverride = nil
        super.init(coder: coder)
    }

    deinit {
        lifecycleObservers.forEach(lifecycleNotificationCenter.removeObserver)
    }

    var isVisibleInWindow: Bool {
        guard let window, applicationInForeground else { return false }
        let sceneState = window.windowScene?.activationState
        let foregroundScene = sceneInForeground ??
            (sceneState == nil || sceneState == .foregroundActive || sceneState == .foregroundInactive)
        guard foregroundScene else { return false }
        var visibleRect = convert(bounds, to: window).intersection(window.bounds)
        guard !visibleRect.isEmpty else { return false }
        var effectiveAlpha: CGFloat = 1
        var ancestor: UIView? = self
        while let view = ancestor {
            let frameInWindow = view.convert(view.bounds, to: window)
            effectiveAlpha *= view.alpha
            if view.isHidden || effectiveAlpha <= 0.01 || view.bounds.width <= 0 || view.bounds.height <= 0 ||
                frameInWindow.width <= 0 || frameInWindow.height <= 0 { return false }
            if view.clipsToBounds {
                visibleRect = visibleRect.intersection(frameInWindow)
                if visibleRect.isEmpty { return false }
            }
            ancestor = view.superview
        }
        return true
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        observeVisibility()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        observeVisibility()
    }

    private func observeVisibility() {
        observeApplicationLifecycle()
        var ancestors: [UIView] = []
        var ancestor: UIView? = self
        while let view = ancestor {
            ancestors.append(view)
            ancestor = view.superview
        }
        let identities = ancestors.map(ObjectIdentifier.init)
        if identities != observedAncestors {
            visibilityObservations.removeAll()
            observedAncestors = identities
            visibilityObservations = ancestors.flatMap { view in
                let changed: (UIView, NSKeyValueObservedChange<Bool>) -> Void = { [weak self] _, _ in
                    self?.scheduleVisibilityReport()
                }
                return [
                    view.observe(\.isHidden, options: [.new], changeHandler: changed),
                    view.observe(\.clipsToBounds, options: [.new], changeHandler: changed),
                    view.observe(\.alpha, options: [.new]) { [weak self] _, _ in
                        self?.scheduleVisibilityReport()
                    },
                    view.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                        self?.scheduleVisibilityReport()
                    },
                    view.observe(\.frame, options: [.new]) { [weak self] _, _ in
                        self?.scheduleVisibilityReport()
                    },
                    view.observe(\.transform, options: [.new]) { [weak self] _, _ in
                        self?.scheduleVisibilityReport()
                    },
                ]
            }
        }
        reportVisibilityIfChanged()
    }

    private func observeApplicationLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        applicationInForeground = UIApplication.shared.applicationState != .background
        let transitions: [(Notification.Name, Bool)] = [
            (UIApplication.didEnterBackgroundNotification, false),
            (UIApplication.willEnterForegroundNotification, true),
            (UIApplication.didBecomeActiveNotification, true),
            (UIScene.didEnterBackgroundNotification, false),
            (UIScene.willEnterForegroundNotification, true),
            (UIScene.didActivateNotification, true),
        ]
        lifecycleObservers = transitions.map { name, foreground in
            let isScene = name == UIScene.didEnterBackgroundNotification ||
                name == UIScene.willEnterForegroundNotification || name == UIScene.didActivateNotification
            return lifecycleNotificationCenter.addObserver(
                forName: name,
                object: isScene ? nil : UIApplication.shared,
                queue: .main,
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if isScene {
                        guard let scene = notification.object as AnyObject?,
                              scene === (self.windowSceneOverride?() ?? self.window?.windowScene) else { return }
                        self.sceneInForeground = foreground
                    } else {
                        self.applicationInForeground = foreground
                    }
                    self.reportVisibilityIfChanged()
                }
            }
        }
    }

    private nonisolated func scheduleVisibilityReport() {
        let shouldSchedule = visibilityReportLock.withLock {
            guard !visibilityReportPending else { return false }
            visibilityReportPending = true
            return true
        }
        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.visibilityReportLock.withLock {
                    self.visibilityReportPending = false
                }
                self.reportVisibilityIfChanged()
            }
        }
    }

    private func reportVisibilityIfChanged() {
        let visible = isVisibleInWindow
        guard visible != lastReportedVisibility else { return }
        lastReportedVisibility = visible
        onVisibilityChanged?(visible)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sceneInForeground = nil
        observeVisibility()
        if window != nil { onAttached?() }
    }
}
