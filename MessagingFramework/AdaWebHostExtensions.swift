//
//  AdaWebHostExtensions.swift
//  AdaMessaging
//

import Foundation
import WebKit

// MARK: - Private WebView setup

extension AdaWebHost {
    func hostTelemetryPayload() -> [String: String] {
        [
            "surface": "mobile",
            "hostPlatform": "ios",
            "mobilePackage": "messaging-ios",
            "webSdkOrigin": webSdk.rawValue,
        ]
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
        loadInitialRequest(into: webView, userContentController: userContentController)

        let timeout = webViewTimeout
        Task { @MainActor [weak self, webView] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self else { return }
            if !hasError, webView.isLoading {
                webView.stopLoading()
                webViewLoadingErrorCallback?(AdaWebHostError.webViewTimeout)
            }
        }
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
                webView.load(URLRequest(url: url))
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
            forMainFrameOnly: false,
        )
    }

    /// Builds the `sdk/webview.html` URL for the given environment, encoding
    /// the SDK config (handle, cluster, ada_web_sdk, ada_host_telemetry, language, greeting, metaFields) as
    /// URL query parameters.
    func buildWebviewUrl(environment: AdaEnvironment) -> URL? {
        guard var components = URLComponents(string: environment.webviewHtmlUrl) else { return nil }

        var queryItems = [URLQueryItem(name: "handle", value: handle)]

        // Use caller-supplied cluster if present, otherwise fall back to the
        // environment's implied cluster (e.g. "localhost" for .local).
        let trimmedCluster = cluster.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveCluster = trimmedCluster.isEmpty ? environment.webviewCluster : trimmedCluster
        if let effectiveCluster {
            queryItems.append(URLQueryItem(name: "cluster", value: effectiveCluster))
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

        return URL(string: "https://\(host)/mobile-sdk-webview/")
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
