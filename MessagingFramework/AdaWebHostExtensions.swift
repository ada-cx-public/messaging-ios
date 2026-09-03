//
//  AdaWebHostExtensions.swift
//  AdaMessaging
//

import Foundation
import WebKit

// MARK: - Private WebView setup

extension AdaWebHost {
    private static let preprodMessagingReferer = "https://messaging-demo.ada-dev2.support/"

    func hostTelemetryPayload() -> [String: String] {
        var payload = [
            "surface": "mobile",
            "hostPlatform": "ios",
            "mobilePackage": "messaging-ios",
            "webSdkOrigin": webSdk.rawValue,
        ]

        if let packageVersion = AdaMessagingVersion.current {
            payload["mobileVersion"] = packageVersion
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
        webviewUserContentController = userContentController
        entryDocumentUrl = resolveEntryDocumentUrl()
        registerMessageHandlers(on: userContentController)

        webView = WKWebView(frame: .zero, configuration: configuration)
        guard let webView else { return }
        bridgeHandler.sessionMirrorCommandWebView = webView
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

    /// Neutralizes the current WebView before a rebuild. `setupWebView()` only
    /// overwrites `webView`/`webviewUserContentController`, and a replaced
    /// `WKWebView` is NOT inert: detached, it keeps loading and executing JS
    /// (the load-timeout Task retains it for the full `webViewTimeout`), so its
    /// document would spend the single-use `identityToken` (401
    /// `identity_token_already_used` for the document the customer actually
    /// uses), fire a premature `sdk.ready` through the shared `bridgeHandler` —
    /// disarming the NEW WebView's still-unconsumed config script and flushing
    /// queued commands before the new bridge exists — and keep emitting
    /// duplicate SDK events to customer callbacks. Every rebuild must tear the
    /// predecessor down first.
    func teardownWebView() {
        if let controller = webviewUserContentController {
            // Cuts the orphan document's message path into the shared
            // bridgeHandler (and, on the legacy page, into self), and strips
            // the armed config script so no orphan document can spend the
            // identity token.
            controller.removeAllScriptMessageHandlers()
            controller.removeAllUserScripts()
        }
        webviewConfigUserScript = nil
        webviewUserContentController = nil
        entryDocumentUrl = nil
        bridgeHandler.sessionMirrorCommandWebView = nil
        // No entry document means no ticket, so nothing can be injected into whatever the
        // torn-down WebView still holds while the replacement is built.
        bridgeHandler.trustedDocumentUrl = nil

        if let replacedWebView = webView {
            // Also keeps the load-timeout Task's late `isLoading` check from
            // reporting a false timeout for a WebView that no longer matters.
            replacedWebView.stopLoading()
            replacedWebView.navigationDelegate = nil
            replacedWebView.uiDelegate = nil
            replacedWebView.removeFromSuperview()
        }
        webView = nil

        // Whatever readiness the replaced runtime reported died with it —
        // queue commands until the rebuilt runtime reports its own sdk.ready.
        webHostLoaded = false
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

    /// The document this mount points the WebView at, resolved once so the value pinned as the
    /// injection authority is the same string the WebView is asked to load.
    private func resolveEntryDocumentUrl() -> URL? {
        if usesBridgeRuntime {
            return environment.flatMap { buildWebviewUrl(environment: $0) }
        }
        return legacyMobileSdkWebviewUrl()
    }

    private func registerMessageHandlers(on userContentController: WKUserContentController) {
        bridgeHandler.sessionMirrorLegacyScopePrefix = legacySessionMirrorScopePrefix()
        // Fails closed: mirror writes and clears are dropped until a runtime
        // is pinned below. The localhost-Legacy bridge runtime never pins one
        // — its page drives no mirror.
        bridgeHandler.sessionMirrorRuntime = nil
        // Fails closed the same way: no pinned entry document means no ticket, so no injection.
        bridgeHandler.trustedDocumentUrl = nil
        // Reinstall wipe must run before any mirror injection script is built.
        bridgeHandler.sessionMirrorStore.prepareForLaunch()

        if usesBridgeRuntime {
            // Same trusted origin the config script is scoped to: the host page
            // the WebView loads. Fails closed — with no resolvable origin the
            // handler drops every message.
            bridgeHandler.trustedOrigin = environment.flatMap { Self.pageOrigin(ofUrl: $0.webviewHtmlUrl) }
            // The origin is the whole CDN root, which also serves other bots' runs and other
            // entries; the start parameters that decide WHOSE session this is ride the query.
            bridgeHandler.trustedDocumentUrl = entryDocumentUrl?.absoluteString
            userContentController.add(bridgeHandler, name: "adaBridge")

            if let initialStateScript = bridgeHandler.makeInitialStateScript() {
                userContentController.addUserScript(initialStateScript)
            }

            // Messaging only: a localhost-Legacy run of the same config must
            // neither accept mirror writes nor answer the seed pull with the
            // Messaging blob (JWT + refresh token).
            if webSdk == .messaging {
                bridgeHandler.sessionMirrorRuntime = .messaging(
                    scopePrefix: messagingSessionMirrorScopePrefix(),
                )
            }

            if let webviewConfigScript = makeWebviewConfigScript() {
                userContentController.addUserScript(webviewConfigScript)
                webviewConfigUserScript = webviewConfigScript
            }
        }

        if usesLegacyRemoteHostPage {
            userContentController.add(self, name: "embedReady")
            userContentController.add(self, name: "eventCallbackHandler")
            userContentController.add(self, name: "zdChatterAuthCallbackHandler")
            userContentController.add(self, name: "chatFrameTimeoutCallbackHandler")
            registerLegacySessionMirror(on: userContentController)
        }
    }

    /// The remote Legacy page persists the 5 legacy session keys in its own
    /// bot-domain localStorage, so the mirror there is driven entirely by one
    /// injected script with zero legacy-chat code changes: it pulls the seed
    /// from native at boot, adopts/watches it, and posts its
    /// `sdk.session.mirror(Clear)` / `sdk.session.mirrorRequest` messages
    /// through the same origin-gated bridge handler. No frozen document-start
    /// blob is injected — the pull answers live, so a clear cannot resurrect.
    private func registerLegacySessionMirror(on userContentController: WKUserContentController) {
        guard let pageUrl = entryDocumentUrl,
              let pageOrigin = Self.pageOrigin(ofUrl: pageUrl.absoluteString)
        else { return }

        bridgeHandler.trustedOrigin = pageOrigin
        bridgeHandler.trustedDocumentUrl = pageUrl.absoluteString
        userContentController.add(bridgeHandler, name: "adaBridge")

        let scopeKey = legacySessionMirrorScopeKey(pageOrigin: pageOrigin)
        bridgeHandler.sessionMirrorRuntime = .legacy(scopeKey: scopeKey)
        if let legacyScript = bridgeHandler.makeLegacySessionMirrorScript(scopeKey: scopeKey) {
            userContentController.addUserScript(legacyScript)
        }
    }

    /// Scope key for a Legacy host page's mirror blob — pinned to the
    /// cross-package contract's `ada-session-mirror:legacy:<handle>:<origin>`
    /// shape (the Messaging runtime computes its own scope key web-side).
    func legacySessionMirrorScopeKey(pageOrigin: String) -> String {
        legacySessionMirrorScopePrefix() + pageOrigin
    }

    /// Prefix of every Legacy scope key this instance's handle can produce.
    /// Handed to the bridge handler so Legacy blobs never enter the instance
    /// index and are never injected on the Messaging path.
    func legacySessionMirrorScopePrefix() -> String {
        "ada-session-mirror:legacy:\(handle):"
    }

    /// Prefix of every Messaging-run scope key this instance's handle can
    /// produce — `buildSessionMirrorScopeKey` web-side yields
    /// `ada-session-mirror:<handle>:<scope>`. Pins which writes the Messaging
    /// runtime may store.
    func messagingSessionMirrorScopePrefix() -> String {
        "ada-session-mirror:\(handle):"
    }

    private func loadInitialRequest(into webView: WKWebView, userContentController: WKUserContentController) {
        if usesBridgeRuntime, let env = environment {
            userContentController.addUserScript(errorInterceptorScript())

            if let url = entryDocumentUrl {
                setPreprodDemoCookieIfNeeded(environment: env, in: webView) {
                    webView.load(self.buildWebviewRequest(url: url, environment: env))
                }
            }
            return
        }

        guard let remoteURL = entryDocumentUrl else { return }
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

    private static let errorInterceptorScriptSource = """
        (function() {
            function postToBridge(message) {
                try {
                    var handler =
                        window.webkit &&
                        window.webkit.messageHandlers &&
                        window.webkit.messageHandlers.adaBridge;
                    if (handler) {
                        handler.postMessage(message);
                    }
                } catch (_) {}
            }

            function reportBridgeError(message) {
                postToBridge({
                    type: "sdk.error",
                    error: message
                });
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

            // Resource load failures do not bubble, so only a capture-phase
            // listener sees them. Runtime script errors reach window.onerror
            // above instead (their target is the window, filtered out here).
            // De-duplicated per URL: retry loops for one broken asset must not
            // flood the bridge.
            var reportedSubresourceUrls = {};
            window.addEventListener("error", function(event) {
                var target = event && event.target;
                if (!target || target === window || !target.tagName) {
                    return;
                }
                var url = target.currentSrc || target.src || target.href || "";
                if (typeof url !== "string" || url === "" ||
                    reportedSubresourceUrls[url] === true) {
                    return;
                }
                reportedSubresourceUrls[url] = true;
                postToBridge({
                    type: "sdk.subresourceLoadFailed",
                    url: url,
                    element: String(target.tagName).toLowerCase()
                });
            }, true);
        })();
    """

    func errorInterceptorScript() -> WKUserScript {
        WKUserScript(
            source: Self.errorInterceptorScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
        )
    }

    /// sessionStorage key the webview runtime writes (with the consumed token's
    /// `injectionId`) after it reads an injected `identityToken`. Pinned to
    /// `IDENTITY_TOKEN_CONSUMED_STORAGE_KEY` in
    /// `packages/sdk/src/mobile-webview-runtime.ts` — the two literals must match.
    static let identityTokenConsumedStorageKey = "__ada_identity_token_consumed__"

    /// Non-sensitive per-token id paired with an injected `identityToken`
    /// (FNV-1a 32-bit over UTF-16 code units, hex). The runtime stores it in
    /// sessionStorage on consumption; the emitted guard compares against it so a
    /// spent token is withheld from later documents while a NEW token (new id) is
    /// still delivered. Only distinguishes tokens from each other — not a security
    /// primitive, reveals nothing about the token.
    static func identityTokenInjectionId(_ identityToken: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for codeUnit in identityToken.utf16 {
            hash ^= UInt32(codeUnit)
            hash = hash &* 16_777_619
        }
        return String(hash, radix: 16)
    }

    private func jsonObjectString(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    /// Returns a `WKUserScript` that sets the one-shot `window.__ADA_WEBVIEW_CONFIG__`
    /// global before the document starts loading. The webview runtime reads it once
    /// inside `mountAdaWebViewRuntime`, merges it into the start config, and deletes
    /// it. Sensitive values (`identityToken`) travel through this global — never the
    /// URL — so they stay out of request logs. The payload is JSON-serialized, never
    /// string-interpolated, so values cannot break out of the script.
    ///
    /// A `WKUserScript` has no origin scoping: it re-executes on EVERY main-frame
    /// document for the webview's lifetime, and non-link-activated top-level
    /// navigations (redirects, meta refresh, script-driven location changes) are
    /// allowed by the navigation delegate. The `location.origin` guard makes the
    /// script a no-op on any document that is not the Ada webview host page, so the
    /// identity token is never handed to a third-party origin (mirrors Android's
    /// `trustedBridgeOriginRules` scoping). When no trusted origin can be resolved,
    /// no script is built — the token is never injected unguarded.
    ///
    /// The identity token is additionally one-shot PER TOKEN, not per document: the
    /// runtime records the token's `injectionId` in sessionStorage when it consumes
    /// it, and the emitted guard withholds the (spent, single-use) token from every
    /// later document in the same webview session — replaying it would force the
    /// runtime through the failed-exchange storage wipe. `appUrl` is plain config
    /// and keeps riding every document so a reload re-mounts the custom app. The
    /// registration is removed outright in `disarmWebviewConfigScript()` once the
    /// runtime reports ready. When sessionStorage is unavailable the script
    /// degrades to delivering the token rather than breaking identity entirely.
    ///
    /// Returns `nil` on the Legacy runtime or when there is nothing to send.
    func makeWebviewConfigScript() -> WKUserScript? {
        guard webSdk == .messaging, let environment else { return nil }

        var trimmedIdentityToken = identityToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedIdentityToken.isEmpty, trimmedIdentityToken == consumedIdentityToken {
            // A rebuilt WebView has fresh sessionStorage, so the in-script
            // consumed-marker guard cannot withhold the spent token — only this
            // native memo can (mirrors Android's TokenAlreadyConsumed decision).
            debugPrint(
                "[AdaWebHost] identityToken was already consumed by the runtime and is "
                    + "not re-injected. Mint a new token to re-authenticate.",
            )
            trimmedIdentityToken = ""
        }
        // Native-capability handshake (EXP-1082): only a native version that
        // implements the sdk.session.mirror(Clear) handlers and emits
        // ada.sessionMirrorClearAck advertises support, so the CDN web runtime —
        // instant and unversioned — arms the mirror + durable-clear barrier only
        // inside this version or newer. Older wrappers omit the field, the SDK
        // reads it absent, and the mirror degrades cleanly to pre-EXP-1082
        // behavior. A real JSON boolean, not a string: the SDK gate compares
        // `=== true`. Kept in `retainedConfig` so it rides every document (and
        // folds into `fullConfig` below), exactly like `appUrl`.
        var retainedConfig: [String: Any] = ["nativeSessionMirrorSupported": true]
        let trimmedAppUrl = appUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAppUrl.isEmpty {
            retainedConfig["appUrl"] = trimmedAppUrl
        }

        guard !trimmedIdentityToken.isEmpty || !retainedConfig.isEmpty,
              let trustedOrigin = Self.pageOrigin(ofUrl: environment.webviewHtmlUrl),
              let retainedJson = jsonObjectString(retainedConfig)
        else { return nil }

        let originJson = jsonStr(trustedOrigin)

        if trimmedIdentityToken.isEmpty {
            return WKUserScript(
                source: "if (window.location.origin === \(originJson)) { "
                    + "window.__ADA_WEBVIEW_CONFIG__ = \(retainedJson); }",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
            )
        }

        let injectionId = Self.identityTokenInjectionId(trimmedIdentityToken)
        var fullConfig = retainedConfig
        fullConfig["identityToken"] = trimmedIdentityToken
        fullConfig["injectionId"] = injectionId
        guard let fullJson = jsonObjectString(fullConfig) else { return nil }

        let markerKeyJson = jsonStr(Self.identityTokenConsumedStorageKey)
        let injectionIdJson = jsonStr(injectionId)
        let source = "if (window.location.origin === \(originJson)) { "
            + "window.__ADA_WEBVIEW_CONFIG__ = (function () { "
            + "try { if (window.sessionStorage.getItem(\(markerKeyJson)) === \(injectionIdJson)) "
            + "{ return \(retainedJson); } } catch (e) {} "
            + "return \(fullJson); "
            + "})(); }"
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
        )
    }

    /// Removes the armed `window.__ADA_WEBVIEW_CONFIG__` document-start script once
    /// the runtime reports ready: the mount has consumed (or the in-script guard
    /// withheld) the one-shot token, and no later document in this webview may
    /// receive it again. `WKUserContentController` has no single-script removal,
    /// so the list is rebuilt without exactly the armed script.
    func disarmWebviewConfigScript() {
        guard let armedScript = webviewConfigUserScript,
              let controller = webviewUserContentController
        else { return }
        webviewConfigUserScript = nil
        let remainingScripts = controller.userScripts.filter { $0 !== armedScript }
        controller.removeAllUserScripts()
        remainingScripts.forEach(controller.addUserScript)
    }

    /// Derives the value `window.location.origin` reports for a document loaded from
    /// `urlString`: lowercased scheme and host, with the port only when it is not the
    /// scheme's default — a default port in the URL would otherwise never match.
    /// Only http(s) URLs carry a guardable origin; anything else returns `nil` so the
    /// caller fails closed (mirrors React Native's `scriptGuardOrigin`).
    nonisolated static func pageOrigin(ofUrl urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(),
              !host.isEmpty
        else { return nil }

        let defaultPorts: [String: Int] = ["https": 443, "http": 80]
        if let port = url.port, port != defaultPorts[scheme] {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
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
        // Only the Messaging runtime reads it, and only an opted-in host sends it — the
        // param's absence is what keeps the gate closed for existing integrations.
        if enableProgrammaticControl, webSdk == .messaging {
            queryItems.append(URLQueryItem(name: "enableProgrammaticControl", value: "true"))
        }
        if headless, webSdk == .messaging {
            queryItems.append(URLQueryItem(name: "headless", value: "true"))
        }
        queryItems.append(
            contentsOf: [expectsIdentityTokenQueryItem(), messagingStylesQueryItem()].compactMap(\.self),
        )
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

    /// Boolean only — the token itself never rides the URL. Lets the runtime
    /// report (instead of silently starting anonymous) when the armed
    /// identityToken injection never delivered. A consumed token is no longer
    /// armed, so flagging it would make the runtime report a false loss.
    private func expectsIdentityTokenQueryItem() -> URLQueryItem? {
        let trimmedIdentityToken = identityToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard webSdk == .messaging,
              !trimmedIdentityToken.isEmpty,
              trimmedIdentityToken != consumedIdentityToken
        else { return nil }
        return URLQueryItem(name: "expectsIdentityToken", value: "true")
    }

    /// Messaging styles are a JSON object of string tokens riding the shared
    /// `styles` query param; the legacy CSS-string shape has no meaning to the
    /// Messaging runtime and is dropped rather than sent malformed.
    private func messagingStylesQueryItem() -> URLQueryItem? {
        guard webSdk == .messaging else { return nil }
        let trimmedStyles = styles.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStyles.isEmpty else { return nil }
        guard let stylesJson = Self.messagingStylesJson(trimmedStyles) else {
            debugPrint(
                "[AdaWebHost] styles must be a JSON object of string values on the "
                    + "Messaging runtime — ignoring.",
            )
            return nil
        }
        return URLQueryItem(name: "styles", value: stylesJson)
    }

    /// Validates and canonicalizes the Messaging `styles` value: it must parse
    /// as a JSON object whose values are all strings (the runtime's
    /// `Record<string, string>` contract). Returns the re-serialized JSON, or
    /// `nil` for any other shape — including the Legacy runtime's CSS-string
    /// form, which the Messaging runtime cannot interpret.
    static func messagingStylesJson(_ styles: String) -> String? {
        guard let data = styles.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              !object.isEmpty,
              let normalized = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: normalized, encoding: .utf8)
        else { return nil }
        return json
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
