//
//  AdaEnvironment.swift
//  AdaMessaging
//
//  The deployment environment for the Ada Messaging SDK.
//  Controls which CDN origin is used to host the WebView entry page
//  and which Ada cluster is passed to AdaMessagingClient.
//

import Foundation

/// The deployment environment for the Ada Messaging SDK.
///
/// Pass this to ``AdaWebHost`` to control which Ada CDN hosts the WebView
/// entry page (`sdk/webview.html`) and the SDK assets.
/// When not specified, ``AdaWebHost`` falls back to the legacy `cluster`
/// property and maps it to a CDN origin for backward compatibility.
public enum AdaEnvironment: Equatable {
    /// Production — loads assets from `messaging-assets.ada.support` (default).
    case production

    /// Pre-production — loads assets from `messaging-assets.ada-dev2.support`.
    ///
    /// - Parameter branch: The branch path segment on the CDN.
    ///   Defaults to `"main"` (loads `/main/sdk/webview.html`).
    case preprod(branch: String = "main")

    /// Local development — loads assets from `https://localhost:{port}`.
    ///
    /// **TLS handling:** In DEBUG builds, local WebView navigations accept the
    /// self-signed certificates served by the local Vite dev servers. JS fetch/XHR
    /// trust still relies on installing the generated certs into the simulator via
    /// `scripts/trust-dev-cert-ios.sh`.
    ///
    /// - Parameter port: The local assets server port. Defaults to `4900`.
    case local(port: Int = 4900)

    /// Custom CDN origin — loads assets from the given URL's origin.
    ///
    /// - Parameter assetsOrigin: Full URL of the custom CDN origin
    ///   (e.g. `https://my-cdn.example.com`). Trailing slashes are stripped.
    case custom(assetsOrigin: URL)

    // -----------------------------------------------------------------------

    // MARK: - Internal helpers

    // -----------------------------------------------------------------------

    var cdnOrigin: String {
        switch self {
        case .production:
            "https://messaging-assets.ada.support"
        case .preprod:
            "https://messaging-assets.ada-dev2.support"
        case let .local(port):
            "https://localhost:\(port)"
        case let .custom(url):
            url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }

    var sdkUrl: String {
        switch self {
        case .production:
            return "\(cdnOrigin)/sdk.js"
        case let .preprod(branch):
            let resolvedBranch = branch.isEmpty ? "main" : branch
            return "\(cdnOrigin)/\(resolvedBranch)/sdk.js"
        case let .local(port):
            return "https://localhost:\(port)/sdk/index.js"
        case .custom:
            return "\(cdnOrigin)/sdk.js"
        }
    }

    /// URL of the WebView entry-point HTML file on the CDN.
    ///
    /// This page is loaded as the top-level window of the native WKWebView so
    /// that all SDK iframes share the CDN origin. In local dev, `cluster=localhost`
    /// is appended as a URL param (see `webviewCluster`), which causes
    /// AdaMessagingClient to route all API calls to `https://localhost:5040/api`
    /// (LOCALHOST_API_PROXY_BASE in the SDK's config-helpers.ts). The demo
    /// server hosts the `/api/` proxy to the local Ada backend. The assets
    /// server (`https://localhost:4900`) has no `/api/` proxy.
    var webviewHtmlUrl: String {
        switch self {
        case .production:
            return "\(cdnOrigin)/sdk/webview.html"
        case let .preprod(branch):
            let resolvedBranch = branch.isEmpty ? "main" : branch
            return "\(cdnOrigin)/\(resolvedBranch)/sdk/webview.html"
        case let .local(port):
            return "https://localhost:\(port)/sdk/webview.html"
        case .custom:
            return "\(cdnOrigin)/sdk/webview.html"
        }
    }

    /// The Ada cluster to pass explicitly to `AdaMessagingClient`.
    ///
    /// An explicit cluster keeps loopback-hosted local dev on the localhost
    /// rollout path without depending on runtime hostname inference.
    var webviewCluster: String? {
        switch self {
        case .local:
            "localhost"
        case .preprod:
            "ada-dev2.support"
        case .production, .custom:
            nil
        }
    }

    var webviewEdgeCluster: String? {
        switch self {
        case .production:
            "ada.support"
        case .preprod:
            "ada-dev2.support"
        case .local:
            "localhost"
        case .custom:
            nil
        }
    }

    var cspConnectSrc: String {
        switch self {
        case .production:
            "https://*.ada.support https://messaging-assets.ada.support"
        case .preprod:
            "https://*.ada-dev2.support https://messaging-assets.ada-dev2.support"
        case let .local(port):
            "https://localhost:\(port) https: wss:"
        case .custom:
            "\(cdnOrigin) https:"
        }
    }

    /// Whether this environment requires a TLS bypass for self-signed certs.
    /// Only true for `.local` — and only meaningful in DEBUG builds.
    var requiresLocalTlsBypass: Bool {
        if case .local = self { return true }
        return false
    }
}
