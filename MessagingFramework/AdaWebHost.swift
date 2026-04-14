//
//  AdaWebHost.swift
//  AdaSDK
//

import Foundation
import SafariServices
import WebKit

extension UIColor {
    convenience init(red: Int, green: Int, blue: Int) {
        assert(red >= 0 && red <= 255, "Invalid red component")
        assert(green >= 0 && green <= 255, "Invalid green component")
        assert(blue >= 0 && blue <= 255, "Invalid blue component")

        self.init(red: CGFloat(red) / 255.0, green: CGFloat(green) / 255.0, blue: CGFloat(blue) / 255.0, alpha: 1.0)
    }

    convenience init(rgb: Int) {
        self.init(
            red: (rgb >> 16) & 0xFF,
            green: (rgb >> 8) & 0xFF,
            blue: rgb & 0xFF,
        )
    }
}

/// Selects which web runtime the native WebView should mount.
public enum AdaWebSdk: String, CaseIterable, Sendable {
    case messaging
    case legacy
}

@MainActor
public class AdaWebHost: NSObject {
    public enum AdaWebHostError: Error {
        case webViewFailedToLoad
        case webViewTimeout

        /// Legacy alias — use `webViewFailedToLoad` instead.
        @available(*, deprecated, renamed: "webViewFailedToLoad")
        public static var WebViewFailedToLoad: AdaWebHostError {
            .webViewFailedToLoad
        }

        /// Legacy alias — use `webViewTimeout` instead.
        @available(*, deprecated, renamed: "webViewTimeout")
        public static var WebViewTimeout: AdaWebHostError {
            .webViewTimeout
        }
    }

    var hasError = false
    public var handle = ""
    public var domain = ""
    public var cluster = ""
    public var language = ""
    public var styles = ""
    public var greeting = ""
    public var deviceToken = ""
    public var webViewTimeout = 30.0

    /// Metafields can be passed in during init; use `setMetaFields()` and `setSensitiveMetafields()`
    /// to send values in at runtime
    var metafields: [String: Any] = [:]
    var sensitiveMetafields: [String: Any] = [:]

    public var openWebLinksInSafari = false
    public var appScheme = ""

    public var webViewLoadingErrorCallback: ((Error) -> Void)?
    public var zdChatterAuthCallback: ((@escaping (_ token: String) -> Void) -> Void)?
    public var eventCallbacks: [String: (_ event: [String: Any]) -> Void]?

    /// Set modal navigation bar and status bar to grey by default
    public var navigationBarOpaqueBackground = false

    /// Deployment environment. Messaging and localhost Legacy load the remote
    /// `sdk/webview.html` host page from the corresponding Ada CDN. Non-local Legacy
    /// uses the historical `/mobile-sdk-webview/` host page for parity with the older
    /// iOS SDK. Takes precedence over ``cluster`` for host-page resolution.
    ///
    /// Set to ``AdaEnvironment/production`` for production apps, ``AdaEnvironment/preprod(branch:)``
    /// for internal testing, or ``AdaEnvironment/local(port:)`` for local development.
    public var environment: AdaEnvironment?

    /// Selects which web runtime the native WebView should mount.
    public var webSdk: AdaWebSdk = .legacy

    /// Here's where we do our business
    var webView: WKWebView?

    /// Key an eye on the network.
    /// `nonisolated(unsafe)` so `deinit` (which is non-isolated) can call
    /// `stopNotifier()`. Safe because teardown is the final access point and
    /// `Reachability` manages its own internal thread safety.
    private nonisolated(unsafe) var reachability: Reachability?

    /// Keep a reference to the OfflineViewController
    var offlineViewController: OfflineViewController?

    /// Keep track of whether the host is loaded
    var webHostLoaded = false {
        didSet {
            if webHostLoaded == true {
                if usesLegacyRemoteHostPage {
                    // Legacy path: call adaEmbed.start() once the remote page is ready.
                    initializeWebView()
                    for command in pendingCommands {
                        evalJS(command)
                    }
                }
                pendingCommands.removeAll()
            }
        }
    }

    /// Keep track of whether we're showing offline view
    var isInOfflineMode = false

    /// Commands queued while the SDK is not yet ready, flushed once sdk.ready fires.
    var pendingCommands = [String]()

    /// Bridge handler for state caching and injection-safe command dispatch.
    let bridgeHandler = AdaBridgeHandler()

    /// Messaging and localhost Legacy use the bridge-backed `sdk/webview.html`
    /// runtime. Non-local Legacy keeps using the historical remote
    /// `/mobile-sdk-webview/` host page for parity with the previous iOS SDK.
    var usesBridgeRuntime: Bool {
        guard let environment else { return false }
        if webSdk != .legacy {
            return true
        }
        if case .local = environment {
            return true
        }
        return false
    }

    var usesLegacyRemoteHostPage: Bool {
        !usesBridgeRuntime
    }

    var effectiveLegacyCluster: String {
        let explicitCluster = cluster.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicitCluster.isEmpty {
            return explicitCluster
        }
        return environment?.webviewCluster ?? ""
    }

    public init(
        handle: String,
        cluster: String = "",
        language: String = "",
        domain: String = "",
        styles: String = "",
        greeting: String = "",
        metafields: [String: Any] = [:],
        sensitiveMetafields: [String: Any] = [:],
        openWebLinksInSafari: Bool = false,
        appScheme: String = "",
        zdChatterAuthCallback: ((@escaping (_ token: String) -> Void) -> Void)? = nil,
        webViewLoadingErrorCallback: ((Error) -> Void)? = nil,
        eventCallbacks: [String: (_ event: [String: Any]) -> Void]? = nil,
        webViewTimeout: Double = 30.0,
        deviceToken: String = "",
        navigationBarOpaqueBackground: Bool = false,
        environment: AdaEnvironment? = nil,
        webSdk: AdaWebSdk = .legacy,
    ) {
        self.handle = handle
        self.cluster = cluster
        self.language = language
        self.styles = styles
        self.domain = domain
        self.greeting = greeting
        self.metafields = metafields
//        we always want to append the sdkType
        self.metafields["sdkType"] = "IOS"
        self.metafields["sdkSupportsDownloadLink"] = true
        self.sensitiveMetafields = sensitiveMetafields
        self.openWebLinksInSafari = openWebLinksInSafari
        self.appScheme = appScheme
        self.zdChatterAuthCallback = zdChatterAuthCallback
        self.webViewLoadingErrorCallback = webViewLoadingErrorCallback
        self.eventCallbacks = eventCallbacks
        self.webViewTimeout = webViewTimeout
        hasError = false
        self.deviceToken = deviceToken
        self.navigationBarOpaqueBackground = navigationBarOpaqueBackground
        self.environment = environment
        self.webSdk = webSdk

        reachability = Reachability()
        super.init()
        bridgeHandler.delegate = self

        reachability?.whenReachable = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isInOfflineMode = false
            }
        }

        reachability?.whenUnreachable = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let strongSelf = self,
                      let webView = strongSelf.webView else { return }

                strongSelf.isInOfflineMode = true

                if webView.superview != nil {
                    strongSelf.offlineViewController = OfflineViewController.create()
                    if let offlineVC = strongSelf.offlineViewController {
                        offlineVC.retryBlock = { [weak self] in
                            self?.returnToOnline()
                        }
                        strongSelf.pinSubview(offlineVC.view, to: webView)
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(AdaWebHost.keyboardWillHide(notification:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil,
        )

        do {
            try reachability?.startNotifier()
        } catch {
            debugPrint("Unable to start reachability notifier: \(error)")
        }

        setupWebView()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        reachability?.stopNotifier()
    }

    private func pinSubview(_ subview: UIView, to container: UIView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: container.topAnchor),
            subview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            subview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }
}

// MARK: - Presentation

public extension AdaWebHost {
    /// Provide a view controller to launch web support from
    /// this will present the chat view modally
    func launchModalWebSupport(from viewController: UIViewController) {
        guard let webView else { return }
        webView.translatesAutoresizingMaskIntoConstraints = true
        let webNavController = AdaWebHostViewController.createNavController(with: webView)
        webNavController.modalPresentationStyle = .overFullScreen
        if navigationBarOpaqueBackground {
            webNavController.modalPresentationStyle = .fullScreen
            if #available(iOS 13.0, *) {
                let navBarAppearance = UINavigationBarAppearance()
                navBarAppearance.configureWithOpaqueBackground()
                navBarAppearance.backgroundColor = UIColor(rgb: 0xF3F3F3)
                webNavController.navigationBar.standardAppearance = navBarAppearance
                webNavController.navigationBar.scrollEdgeAppearance = navBarAppearance
            }
        }
        viewController.present(webNavController, animated: true, completion: nil)
    }

    /// Provide a navigation controller to push web support onto the stack
    func launchNavWebSupport(from navController: UINavigationController) {
        guard let webView else { return }
        webView.translatesAutoresizingMaskIntoConstraints = true
        let webController = AdaWebHostViewController.createWebController(with: webView)
        navController.pushViewController(webController, animated: true)
    }

    /// Provide a view to inject the web support into
    func launchInjectingWebSupport(into view: UIView) {
        guard let webView else { return }
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: webView.topAnchor),
            view.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
        ])
    }
}
