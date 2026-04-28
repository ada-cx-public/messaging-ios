//
//  AdaWebHostExtensions.swift
//  AdaMessaging
//

import Foundation
import WebKit

// MARK: - Private WebView setup

extension AdaWebHost {
    private static let preprodMessagingReferer = "https://messaging-demo.ada-dev2.support/"

    private static let frameworkSemver: String? = {
        let bundle = Bundle(for: AdaWebHost.self)
        guard let rawVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }

        let trimmedVersion = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVersion.isEmpty else {
            return nil
        }

        let semverPattern = #"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$"#
        return trimmedVersion.range(of: semverPattern, options: .regularExpression) != nil
            ? trimmedVersion
            : nil
    }()

    func hostTelemetryPayload() -> [String: String] {
        var payload = [
            "surface": "mobile",
            "hostPlatform": "ios",
            "mobilePackage": "messaging-ios",
            "webSdkOrigin": webSdk.rawValue,
        ]

        if let frameworkSemver = Self.frameworkSemver {
            payload["mobileVersion"] = frameworkSemver
        }

        return payload
    }

    func hostTelemetryJSONString() -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: hostTelemetryPayload()),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    func setupWebView() {
        let wkPreferences = WKPreferences()
        wkPreferences.javaScriptCanOpenWindowsAutomatically = true
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences = wkPreferences

        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController
        registerMessageHandlers(on: userContentController)

        webView = WKWebView(frame: .zero, configuration: configuration)
        guard let webView else { return }
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = self
        webView.uiDelegate = self

        #if DEBUG
            // Lets Safari's Web Inspector attach to the WebView on debug SDK builds.
            // Requires `DEBUG` in `SWIFT_ACTIVE_COMPILATION_CONDITIONS` for the
            // framework's Debug config (set in AdaMessaging.xcodeproj). Release
            // builds never get this.
            if #available(iOS 16.4, *) {
                webView.isInspectable = true
            }
        #endif

        loadInitialRequest(into: webView, userContentController: userContentController)

        let timeout = webViewTimeout
        Task { @MainActor [weak self, webView] in
            do {
                try await Self.sleepForWebViewTimeout(timeout)
            } catch {
                return
            }

            guard let self else { return }
            if !hasError, webView.isLoading {
                webView.stopLoading()
                webViewLoadingErrorCallback?(AdaWebHostError.webViewTimeout)
            }
        }
    }

    private static func sleepForWebViewTimeout(_ timeout: TimeInterval) async throws {
        if #available(iOS 16.0, *) {
            try await Task.sleep(for: .seconds(timeout))
        } else {
            try await Task.sleep(nanoseconds: secondsToNanoseconds(timeout))
        }
    }

    private static func secondsToNanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64((max(0, seconds) * 1_000_000_000).rounded())
    }

    private func registerMessageHandlers(on userContentController: WKUserContentController) {
        if usesBridgeRuntime {
            userContentController.add(bridgeHandler, name: "adaBridge")

            if let initialStateScript = bridgeHandler.makeInitialStateScript() {
                userContentController.addUserScript(initialStateScript)
            }
        }

        if usesLegacyRemoteHostPage {
            userContentController.add(self, name: "embedReady")
            userContentController.add(self, name: "eventCallbackHandler")
            userContentController.add(self, name: "zdChatterAuthCallbackHandler")
            userContentController.add(self, name: "chatFrameTimeoutCallbackHandler")
        }
    }

    private func loadInitialRequest(into webView: WKWebView, userContentController: WKUserContentController) {
        if usesBridgeRuntime, let env = environment {
            userContentController.addUserScript(errorInterceptorScript())

            if let url = buildWebviewUrl(environment: env) {
                setPreprodDemoCookieIfNeeded(environment: env, in: webView) {
                    webView.load(self.buildWebviewRequest(url: url, environment: env))
                }
            }
            return
        }

        guard let remoteURL = legacyMobileSdkWebviewUrl() else { return }
        let webRequest = URLRequest(
            url: remoteURL,
            cachePolicy: .useProtocolCachePolicy,
            timeoutInterval: webViewTimeout,
        )
        webView.load(webRequest)
    }

    private func setPreprodDemoCookieIfNeeded(
        environment: AdaEnvironment,
        in webView: WKWebView,
        completion: @escaping @MainActor @Sendable () -> Void,
    ) {
        let trimmedToken = preprodDemoToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard webSdk == .messaging,
              case .preprod = environment,
              !trimmedToken.isEmpty
        else {
            completion()
            return
        }

        let cookieProperties: [HTTPCookiePropertyKey: Any] = [
            .domain: "messaging-assets.ada-dev2.support",
            .path: "/",
            .name: "ada_demo_token",
            .value: trimmedToken,
            .secure: "TRUE",
        ]
        guard let cookie = HTTPCookie(properties: cookieProperties) else {
            completion()
            return
        }

        webView.configuration.websiteDataStore.httpCookieStore.setCookie(
            cookie,
        ) {
            Task { @MainActor in
                completion()
            }
        }
    }

    private func errorInterceptorScript() -> WKUserScript {
        let source = """
        (function() {
            function reportBridgeError(message) {
                try {
                    var handler =
                        window.webkit &&
                        window.webkit.messageHandlers &&
                        window.webkit.messageHandlers.adaBridge;
                    if (handler) {
                        handler.postMessage({
                            type: "sdk.error",
                            error: message
                        });
                    }
                } catch (_) {}
            }

            var originalOnError = window.onerror;
            window.onerror = function(message, source, line) {
                reportBridgeError(
                    (source || "") + (line ? ":" + line : "") + " " + (message || "")
                );
                if (originalOnError) {
                    originalOnError.apply(this, arguments);
                }
                return false;
            };

            window.addEventListener("unhandledrejection", function(event) {
                reportBridgeError(
                    "Unhandled rejection: " +
                    String(event && event.reason ? event.reason : "unknown")
                );
            });
        })();
        """

        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
        )
    }

    func buildWebviewRequest(url: URL, environment: AdaEnvironment) -> URLRequest {
        var request = URLRequest(url: url)
        if webSdk == .messaging, case .preprod = environment {
            request.setValue(Self.preprodMessagingReferer, forHTTPHeaderField: "Referer")
            let trimmedToken = preprodDemoToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedToken.isEmpty {
                request.setValue("ada_demo_token=\(trimmedToken)", forHTTPHeaderField: "Cookie")
            }
        }
        return request
    }

    /// Builds the `sdk/webview.html` URL for the given environment, encoding
    /// the SDK config (handle, cluster, ada_web_sdk, ada_host_telemetry, language, greeting, metaFields) as
    /// URL query parameters.
    func buildWebviewUrl(environment: AdaEnvironment) -> URL? {
        guard var components = URLComponents(string: environment.webviewHtmlUrl) else { return nil }

        var queryItems = [
            URLQueryItem(name: "handle", value: handle),
            URLQueryItem(name: "ada_handle", value: handle),
        ]

        // Use caller-supplied cluster if present, otherwise fall back to the
        // environment's implied cluster (e.g. "localhost" for .local).
        let trimmedCluster = cluster.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveCluster = trimmedCluster.isEmpty ? environment.webviewCluster : trimmedCluster
        let edgeCluster = effectiveCluster ?? environment.webviewEdgeCluster
        if let effectiveCluster {
            queryItems.append(URLQueryItem(name: "cluster", value: effectiveCluster))
        }
        if let edgeCluster {
            queryItems.append(URLQueryItem(name: "ada_cluster", value: edgeCluster))
        }
        queryItems.append(URLQueryItem(name: "ada_web_sdk", value: webSdk.rawValue))
        if !language.isEmpty {
            queryItems.append(URLQueryItem(name: "language", value: language))
        }
        if !greeting.isEmpty {
            queryItems.append(URLQueryItem(name: "greeting", value: greeting))
        }
        if !metafields.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: metafields),
           let json = String(data: data, encoding: .utf8)
        {
            queryItems.append(URLQueryItem(name: "metaFields", value: json))
        }
        if let hostTelemetry = hostTelemetryJSONString() {
            queryItems.append(URLQueryItem(name: "ada_host_telemetry", value: hostTelemetry))
        }

        components.queryItems = queryItems
        return components.url
    }

    private func legacyMobileSdkWebviewUrl() -> URL? {
        let cluster = effectiveLegacyCluster
        let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)

        let host: String
        if cluster.isEmpty {
            if trimmedDomain.isEmpty {
                host = "\(handle).ada.support"
            } else if trimmedDomain.hasSuffix(".support") {
                host = "\(handle).\(trimmedDomain)"
            } else {
                host = "\(handle).\(trimmedDomain).support"
            }
        } else if cluster.hasSuffix(".support") {
            host = "\(handle).\(cluster)"
        } else {
            let hostDomain = trimmedDomain.isEmpty ? "ada" : trimmedDomain
            if hostDomain.hasSuffix(".support") {
                host = "\(handle).\(cluster).\(hostDomain)"
            } else {
                host = "\(handle).\(cluster).\(hostDomain).support"
            }
        }

        guard var components = URLComponents(string: "https://\(host)/mobile-sdk-webview/") else { return nil }

        let trimmedEmbedVersion = embedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        var queryItems: [URLQueryItem] = []
        if !trimmedEmbedVersion.isEmpty {
            // Read by embed-loader → pins embed-2 to the given SHA.
            queryItems.append(URLQueryItem(name: "__ada-embed-version", value: trimmedEmbedVersion))
        }
        if !trimmedVersion.isEmpty {
            // Read by embed-2's chat-versioning → pins the chat bundle to the given SHA.
            queryItems.append(URLQueryItem(name: "__ada-chat-version", value: trimmedVersion))
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        return components.url
    }

    func legacyEmbedStartConfig() -> (cluster: String, domain: String) {
        let trimmedCluster = cluster.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)

        if case .preprod = environment {
            let preprodDomainSource = trimmedDomain.isEmpty ? trimmedCluster : trimmedDomain
            let normalizedPreprodDomain = normalizeLegacyEmbedDomain(preprodDomainSource)
            let preprodDomain = normalizedPreprodDomain.isEmpty ? "ada-dev2" : normalizedPreprodDomain
            return (cluster: "", domain: preprodDomain)
        }

        if trimmedDomain.isEmpty, trimmedCluster.hasSuffix(".support") {
            return (cluster: "", domain: normalizeLegacyEmbedDomain(trimmedCluster))
        }

        return (
            cluster: trimmedCluster,
            domain: normalizeLegacyEmbedDomain(trimmedDomain),
        )
    }

    private func normalizeLegacyEmbedDomain(_ value: String) -> String {
        if value.hasSuffix(".support") {
            return String(value.dropLast(".support".count))
        }
        return value
    }
}
