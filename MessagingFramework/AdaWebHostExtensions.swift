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
        stopLoadWatchdog()
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

        webView = makeRecoverableWebView(configuration: configuration)
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

        startLoadWatchdog(for: webView)
        loadInitialRequest(into: webView, userContentController: userContentController)
    }

    /// Replaced `WKWebView` instances keep loading and running JS. They can spend the single-use `identityToken`,
    /// causing 401 `identity_token_already_used`. They also emit duplicate SDK events. A premature `sdk.ready` through
    /// the shared `bridgeHandler` removes the new config script and sends queued commands before the new bridge exists.
    /// Tear down the previous WebView before each rebuild.
    func teardownWebView() {
        stopLoadWatchdog()
        resetContentProcessRecovery()
        if let controller = webviewUserContentController {
            // Cuts the orphan document's message path into the shared
            // bridgeHandler (and, on the legacy page, into self), and strips
            // the armed config script so no orphan document can spend the
            // identity token.
            controller.removeAllScriptMessageHandlers()
            controller.removeAllUserScripts()
        }
        webviewConfigUserScript = nil
        // Cleared together with the script it describes: `armedIdentityToken` is the
        // sole input to the consumed-token memo in `adaBridgeDidBecomeReady`, so a
        // token left armed past teardown could latch as consumed on a later document
        // that never received it. The invariant `webviewConfigUserScript == nil
        // implies armedIdentityToken == nil` must hold, as it does in
        // `disarmWebviewConfigScript()`.
        armedIdentityToken = nil
        webviewUserContentController = nil
        entryDocumentUrl = nil
        bridgeHandler.sessionMirrorCommandWebView = nil
        // Curated requests were issued into the document being torn down, so no
        // reply can reach them now — settle them instead of stranding callers to
        // the native timeout.
        bridgeHandler.cancelPendingBridgeRequests()
        // No entry document means no ticket, so nothing can be injected into whatever the
        // torn-down WebView still holds while the replacement is built.
        bridgeHandler.trustedDocumentUrl = nil

        if let replacedWebView = webView {
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
                // Record the token IFF this script actually carries it — matching the
                // token-inclusion condition in makeWebviewConfigScript (non-empty and
                // not already spent). A spent or absent token yields the token-less
                // form, so nothing is armed and the memo must not latch it later.
                let trimmedToken = identityToken.trimmingCharacters(in: .whitespacesAndNewlines)
                armedIdentityToken =
                    (!trimmedToken.isEmpty && trimmedToken != consumedIdentityToken)
                        ? trimmedToken
                        : nil
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
                let load = prepareEntryRequest(buildWebviewRequest(url: url, environment: env), into: webView)
                setPreprodDemoCookieIfNeeded(environment: env, in: webView, completion: load)
            }
            return
        }

        guard let remoteURL = entryDocumentUrl else { return }
        let webRequest = URLRequest(
            url: remoteURL,
            cachePolicy: .useProtocolCachePolicy,
            timeoutInterval: webViewTimeout,
        )
        loadEntryRequest(webRequest, into: webView)
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
    func makeWebviewConfigScript(retainedOnly: Bool = false) -> WKUserScript? {
        guard webSdk == .messaging, let environment else { return nil }

        var trimmedIdentityToken = identityToken.trimmingCharacters(in: .whitespacesAndNewlines)
        // A retained-only re-arm (post-`sdk.ready`) never carries the one-shot identity
        // token, only the per-document config (sensitiveMetaFields/appUrl/mirror flag).
        if retainedOnly {
            trimmedIdentityToken = ""
        }
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
        // appUrl and the mirror flag are plain (non-credential) config that must
        // re-deliver on every same-origin document, so they ride the origin-only
        // guard. The credential (sensitiveMetaFields) is layered in separately below,
        // bound to THIS mount's document.
        var baseRetained: [String: Any] = ["nativeSessionMirrorSupported": true]
        let trimmedAppUrl = appUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAppUrl.isEmpty {
            baseRetained["appUrl"] = trimmedAppUrl
        }

        guard !trimmedIdentityToken.isEmpty || !baseRetained.isEmpty,
              let trustedOrigin = Self.pageOrigin(ofUrl: environment.webviewHtmlUrl),
              let baseJson = jsonObjectString(baseRetained)
        else { return nil }

        let originJson = jsonStr(trustedOrigin)

        // EXP-1223 (grJTO / grJTI): the sensitive metafields carry a per-session
        // credential (e.g. Simplii's otc_token). It rides EVERY document-start
        // injection — the initial one AND the retained re-arm — so a reload / in-place
        // recovery delivers it at document-start, before the runtime creates the first
        // chatter (otherwise a reloaded document's greeting reproduces the pre-PR
        // empty-sensitiveMetaFields gap; delivering it only post-`sdk.ready` is too
        // late for a private-mode reload that mints a fresh chatter during boot). It
        // stays CURRENT because `setSensitiveMetaFields`/`reset` rebuild the armed
        // script (see `refreshRetainedConfigScriptIfArmed`); the backing field mirrors
        // the web session (merge on set, clear on reset). It is bound to THIS mount's
        // document — the loaded path ends with the webview.html tail AND the URL's
        // `handle` equals ours — so a same-origin nav to `webview.html?handle=<other-bot>`
        // cannot receive it. JSON-encoded STRING: parsed outside the runtime's
        // string-only injected-config allowlist.
        // Strip the SDK-owned device keys: the Messaging init sensitive path does not
        // strip them (shared/utils sdk-owned-meta-fields covers only
        // initialURL/introShown/test_user), so a device_token carried in
        // sensitiveMetaFields would inject a device_os-less credential and double-register
        // (SUP-42). iOS delivers the Messaging device token via the post-sdk.ready setter,
        // which derives device_os, so the injected credential carries no device binding at
        // all. Mirrors RN's stripDeviceKeys and the Android strip.
        let injectableSensitiveMetafields = sensitiveMetafields.filter {
            $0.key != "device_token" && $0.key != "device_os"
        }
        // The credential-document guard, shared by BOTH the one-shot identity token and
        // the sensitive metafields: origin alone is not identity, so either is delivered
        // only when the loaded document is THIS mount's bot document — the pathname ends
        // with the entry tail AND the URL's `handle` equals ours. A same-origin top-level
        // nav to `webview.html?handle=<other-bot>` therefore receives neither.
        // endsWith the entry tail, not the full path: the versionless and shared-root
        // entries are 302-redirected with a build segment inserted before the tail
        // (/<build>/sdk/webview.html, /messaging/<build>/sdk/webview.html), so exact
        // equality would withhold from every production load. (Mirrors Android's
        // AdaDocumentIdentity.isBuildScopedEntryPath.) Lowercase the pathname before the
        // tail test so the predicate matches the shared/RN/Android guards
        // (webview-privilege.ts, host-page.ts, AdaMessagingView.kt), which all
        // `toLowerCase()`; a case-variant served path must not make one platform deliver
        // while another withholds.
        let credentialDocumentGuard = "String(window.location.pathname || \"\").toLowerCase()"
            + ".endsWith(\(jsonStr(Self.webviewEntryPathTail))) && "
            + "new URLSearchParams(window.location.search).get(\"handle\") === "
            + "\(jsonStr(handle))"
        var credentialBlock = ""
        if !injectableSensitiveMetafields.isEmpty,
           let sensitiveJson = jsonObjectString(injectableSensitiveMetafields)
        {
            credentialBlock = "if (\(credentialDocumentGuard)) "
                + "{ __adaCfg.sensitiveMetaFields = \(jsonStr(sensitiveJson)); } "
        }

        if trimmedIdentityToken.isEmpty {
            // IIFE so `__adaCfg` is function-scoped, never a leftover `window.__adaCfg`
            // global: the runtime deletes `window.__ADA_WEBVIEW_CONFIG__` after reading
            // it so the credential is not re-readable, and a top-level `var` would keep
            // a copy alive on the global.
            return WKUserScript(
                source: "if (window.location.origin === \(originJson)) { "
                    + "window.__ADA_WEBVIEW_CONFIG__ = (function () { "
                    + "var __adaCfg = \(baseJson); "
                    + credentialBlock
                    + "return __adaCfg; })(); }",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
            )
        }

        let injectionId = Self.identityTokenInjectionId(trimmedIdentityToken)
        let markerKeyJson = jsonStr(Self.identityTokenConsumedStorageKey)
        let injectionIdJson = jsonStr(injectionId)
        // Gate the one-shot identity token behind the SAME credential-document guard as
        // sensitiveMetaFields: origin alone is not identity, so a same-origin nav to
        // another bot's document must not receive our token. Off the credential document
        // the IIFE returns the base config with no token, injectionId, or
        // consumed-marker read.
        let source = "if (window.location.origin === \(originJson)) { "
            + "window.__ADA_WEBVIEW_CONFIG__ = (function () { "
            + "var __adaCfg = \(baseJson); "
            + credentialBlock
            + "if (\(credentialDocumentGuard)) { "
            + "try { if (window.sessionStorage.getItem(\(markerKeyJson)) === \(injectionIdJson)) "
            + "{ return __adaCfg; } } catch (e) {} "
            + "__adaCfg.identityToken = \(jsonStr(trimmedIdentityToken)); "
            + "__adaCfg.injectionId = \(injectionIdJson); "
            + "} "
            + "return __adaCfg; "
            + "})(); }"
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
        )
    }

    /// Rebuilds the document-start scripts once the runtime reports ready: the
    /// mount has consumed (or the in-script guard withheld) the one-shot identity
    /// token, and no later document in this webview may receive that TOKEN again.
    /// The retained payload (`sensitiveMetaFields` / `appUrl` / mirror flag) is
    /// re-armed below so it keeps riding later documents at document-start; only the
    /// one-shot identity token is permanently withheld. `WKUserContentController` has
    /// no single-script removal, so the list is rebuilt without exactly the armed
    /// script. Also called by ``refreshRetainedConfigScriptIfArmed()`` after a
    /// post-ready credential change, so the re-arm always reflects the current
    /// backing field rather than the value armed at the last `sdk.ready`.
    func disarmWebviewConfigScript() {
        guard let armedScript = webviewConfigUserScript,
              let controller = webviewUserContentController
        else { return }
        webviewConfigUserScript = nil
        // The token-bearing script (if any) is being removed and never re-armed, so
        // the document no longer carries the identity token.
        armedIdentityToken = nil
        let remainingScripts = controller.userScripts.filter { $0 !== armedScript }
        controller.removeAllUserScripts()
        remainingScripts.forEach(controller.addUserScript)
        // EXP-1223: re-arm the retained config so a later document in this WebView
        // (a reload or in-place recovery) receives sensitiveMetaFields + appUrl +
        // nativeSessionMirrorSupported at document-start — before the runtime creates
        // the first chatter, so document #2's greeting does not reproduce the pre-PR
        // empty-sensitiveMetaFields gap. The credential is built from the CURRENT
        // backing field and kept current by refreshRetainedConfigScriptIfArmed on
        // every setter/reset; the one-shot identity token is never re-armed
        // (retainedOnly: true). The post-ready setSensitiveMetaFields send remains the
        // N-1 fallback.
        if let retainedScript = makeWebviewConfigScript(retainedOnly: true) {
            controller.addUserScript(retainedScript)
            webviewConfigUserScript = retainedScript
        }
    }

    /// Rebuilds the armed retained config script from the CURRENT backing fields after
    /// a post-ready credential change (`setSensitiveMetaFields`/`reset`), so a later
    /// document's document-start injection carries the current credential — not the
    /// value armed at the last `sdk.ready`. No-op before ready (the full script,
    /// including its one-shot identity token, is still armed and must not be rebuilt
    /// until `disarmWebviewConfigScript` runs at ready) and when no script is armed.
    func refreshRetainedConfigScriptIfArmed() {
        guard webHostLoaded, armedIdentityToken == nil, webviewConfigUserScript != nil
        else { return }
        disarmWebviewConfigScript()
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
