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

/// Opaque registration token returned by ``AdaWebHost/addEventCallback(_:callback:)``
/// and ``AdaWebHost/addSdkEventCallback(_:)``. Pass it back to the matching remove
/// method to unsubscribe exactly that callback.
public final class AdaEventSubscription {}

enum AdaResourceBundle {
    static let storyboardName = "AdaWebHostViewController"

    static var current: Bundle {
        #if SWIFT_PACKAGE
            return .module
        #else
            let frameworkBundle = Bundle(for: BundleLocator.self)

            if let resourceBundleURL = frameworkBundle.url(forResource: "AdaMessaging", withExtension: "bundle"),
               let resourceBundle = Bundle(url: resourceBundleURL)
            {
                return resourceBundle
            }

            return frameworkBundle
        #endif
    }

    private final class BundleLocator {}
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

    /// Style overrides. On the Legacy runtime this is a raw CSS string passed to
    /// `adaEmbed.start`. On the Messaging runtime it must be a JSON object of
    /// string style tokens (e.g. `{"tintColor": "#520497"}`), sent as the
    /// `styles` query param on the `sdk/webview.html` URL — any other shape is
    /// dropped with a debug log. Read during init — set this at init.
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

    /// Multi-subscriber per-event-name callbacks registered through
    /// ``addEventCallback(_:callback:)``. Lives alongside the single-closure
    /// ``eventCallbacks`` dictionary, which keeps its one-closure-per-key
    /// semantics for source compatibility.
    var eventCallbackSubscriptions: [String: [(token: ObjectIdentifier, callback: (_ event: [String: Any]) -> Void)]] =
        [:]

    /// Raw sinks registered through ``addSdkEventCallback(_:)`` — every SDK
    /// event as (key, JSON-encoded data), mirroring Android's `addSdkEventCallback`.
    var sdkEventCallbackSubscriptions: [(token: ObjectIdentifier, callback: (_ key: String, _ data: String?) -> Void)] =
        []

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

    /// Opts this host into the Messaging runtime's programmatic-control API.
    ///
    /// Off by default, so existing integrations are unchanged. While it is off, core rejects
    /// `sdk.message.send`, `sdk.conversation.get`, `sdk.messages.get` and
    /// `sdk.composerText.set` with `ProgrammaticControlNotEnabled` — an error naming a
    /// `start()` option this SDK previously gave the host no way to set.
    ///
    /// Named to match the React Native wrapper and the web SDK's `adaSettings` key. Ignored
    /// on the Legacy runtime, which has no such gate.
    public var enableProgrammaticControl = false

    /// Suppresses the Messaging runtime's default chat UI so the host app can render
    /// its own with native components, driven by ``eventCallbacks`` and
    /// ``sendMessage(_:)``. Sent as the `headless=true` query param on the
    /// `sdk/webview.html` URL, which is built during init — set this at init.
    /// Ignored on the Legacy runtime. Pair with ``launchHeadlessWebSupport(in:)``
    /// to run the WebView without presenting it; that method forces this flag on
    /// (rebuilding the WebView when the host was created without it).
    public var headless = false

    /// Short-lived identity token minted by your backend (`POST /v2/auth/tokens/`)
    /// to authenticate the end user before the session starts. Delivered to the web
    /// runtime through the one-shot `window.__ADA_WEBVIEW_CONFIG__` global injected
    /// at document start — never through the URL, so it stays out of request logs.
    /// The runtime consumes and deletes the global on read. Read during init — set
    /// this at init. Never persisted natively. Ignored on the Legacy runtime.
    public var identityToken: String = ""

    /// Overrides the app frame URL the Messaging runtime mounts. The handle's
    /// Allowed Websites list gates custom apps; add your app's origin in the
    /// Ada dashboard (Channels > Chat). A URL whose origin the list does not
    /// allow is dropped and the default app mounts. Leave blank for the standard app.
    /// Delivered through the one-shot `window.__ADA_WEBVIEW_CONFIG__` global
    /// alongside ``identityToken``. Read during init — set this at init.
    /// Ignored on the Legacy runtime.
    public var appUrl: String = ""

    /// Pins the legacy remote host page (`/mobile-sdk-webview/`) to a specific
    /// embed-2 build. Rendered as the `?__ada-embed-version=<sha>` query param
    /// (read by `embed-loader`). Used for PR verification; leave blank for the
    /// stable rollout. Ignored when `webSdk != .legacy` or for the local-legacy
    /// bridge runtime.
    public var embedVersion: String = ""

    /// Pins the legacy remote host page to a specific chat build. Rendered as
    /// the `?__ada-chat-version=<sha>` query param (read by `embed-2`'s
    /// chat-versioning). Used for PR verification; leave blank for the stable
    /// rollout. Ignored when `webSdk != .legacy` or for the local-legacy bridge
    /// runtime.
    public var version: String = ""

    /// Time-bound demo access token for Messaging preprod assets. Applied only
    /// when `environment` is `.preprod` and `webSdk` is `.messaging`.
    public var preprodDemoToken: String = ""

    /// Here's where we do our business
    var webView: WKWebView?

    /// Identifies the most recent Zendesk chatter-auth request.
    ///
    /// The runtime re-requests on every refresh cycle, so a per-invocation "already
    /// responded" flag only dedupes a double-callback *within* one cycle. A host that
    /// answers a cycle late would otherwise inject that stale token as the answer to the
    /// current request. Only the latest cycle may respond.
    var zdChatterAuthRequestSeq: UInt64 = 0

    /// Key an eye on the network.
    /// `nonisolated(unsafe)` so `deinit` (which is non-isolated) can call
    /// `stopNotifier()`. Safe because teardown is the final access point and
    /// `Reachability` manages its own internal thread safety.
    private nonisolated(unsafe) var reachability: Reachability?

    /// Keep a reference to the OfflineViewController
    var offlineViewController: OfflineViewController?

    /// Retains the hidden zero-sized container created by
    /// ``launchHeadlessWebSupport(in:)`` when the caller supplies no host view,
    /// so the WebView stays alive without any presented UI.
    var headlessContainer: UIView?

    /// The armed `window.__ADA_WEBVIEW_CONFIG__` document-start script, kept so
    /// `disarmWebviewConfigScript()` can remove exactly it — and nothing else —
    /// once the runtime reports ready and the one-shot identity token is spent.
    var webviewConfigUserScript: WKUserScript?

    /// The identity token the runtime consumed (single-use — an exchange attempt
    /// spends it even when it fails downstream). A WebView rebuild re-arms the
    /// document-start config script against a FRESH sessionStorage, so this
    /// native memo — not the in-script consumed-marker guard — is what keeps a
    /// spent token from being replayed into the failed-exchange storage wipe
    /// (mirrors Android's `consumedIdentityToken`).
    var consumedIdentityToken: String?

    /// The live `WKUserContentController` the WebView was created with.
    /// `webView.configuration` returns a copy on access, so mutating
    /// `webView.configuration.userContentController` would not reach the
    /// running WebView — `disarmWebviewConfigScript()` must use this reference.
    var webviewUserContentController: WKUserContentController?

    /// Keep track of whether the host is loaded
    var webHostLoaded = false {
        didSet {
            if webHostLoaded == true {
                if usesLegacyRemoteHostPage {
                    // Legacy path: call adaEmbed.start() once the remote page is ready.
                    initializeWebView()
                }
                let commands = pendingCommands
                pendingCommands.removeAll()
                commands.forEach { $0() }
            }
        }
    }

    /// Keep track of whether we're showing offline view
    var isInOfflineMode = false

    /// Commands queued while the SDK is not yet ready, flushed once sdk.ready fires.
    var pendingCommands = [() -> Void]()

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
        enableProgrammaticControl: Bool = false,
        headless: Bool = false,
        identityToken: String = "",
        appUrl: String = "",
        embedVersion: String = "",
        version: String = "",
        preprodDemoToken: String = "",
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
        self.enableProgrammaticControl = enableProgrammaticControl
        self.headless = headless
        self.identityToken = identityToken
        self.appUrl = appUrl
        self.embedVersion = embedVersion
        self.version = version
        self.preprodDemoToken = preprodDemoToken

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

    /// Run the web runtime without presenting any Ada UI.
    ///
    /// Attaches the WebView to `hostView` when one is supplied (keep it hidden or
    /// zero-sized), or to an internal hidden zero-sized container otherwise.
    /// Create the host with `headless: true` so the runtime suppresses its own
    /// chat UI, then drive the conversation natively: subscribe through
    /// ``eventCallbacks`` and send with ``sendMessage(_:)``.
    ///
    /// Lifecycle constraints (see `docs/headless.md`): iOS suspends the WebView's
    /// content process with the app, so there is no background execution; if the
    /// app terminates, the session rehydrates from web persistence on the next
    /// mount; tokens are never persisted natively.
    ///
    /// Messaging runtime only: the Legacy runtime has no headless mode, so the
    /// call traps on it (`precondition`, the Swift equivalent of Android's
    /// throwing `require`) instead of silently mounting the full legacy chat UI
    /// inside a hidden container. Forces ``headless`` on: a host created with
    /// `headless: false` gets its WebView rebuilt so the `headless=true` query
    /// param reaches the runtime (Android parity: `headlessLaunchSettings`
    /// normalizes the flag before the view loads).
    func launchHeadlessWebSupport(in hostView: UIView? = nil) {
        precondition(
            webSdk == .messaging,
            "[AdaWebHost] launchHeadlessWebSupport requires webSdk: .messaging — "
                + "the Legacy runtime has no headless mode.",
        )
        if !headless {
            // headless rides the webview.html URL built during init, so flipping
            // the flag alone would change nothing. Teardown first: a replaced-but-
            // live WebView spends the identityToken — see teardownWebView().
            headless = true
            teardownWebView()
            setupWebView()
        }
        guard let webView else { return }

        let container: UIView
        if let hostView {
            container = hostView
        } else {
            let offscreenContainer = UIView(frame: .zero)
            offscreenContainer.isHidden = true
            headlessContainer = offscreenContainer
            container = offscreenContainer
        }

        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: webView.topAnchor),
            container.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
        ])
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
