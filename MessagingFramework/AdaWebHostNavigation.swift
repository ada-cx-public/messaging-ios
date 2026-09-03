import Foundation
import SafariServices
import UIKit
import WebKit

// MARK: - Runtime document identity

extension AdaWebHost {
    /// Path tail of the Messaging runtime's entry document. Pinned to
    /// `WEBVIEW_ENTRY_PATH_TAIL` in `shared/utils/src/webview-privilege.ts`, which the shared
    /// web-side privilege gate keys on.
    nonisolated static let webviewEntryPathTail = "/sdk/webview.html"

    /// Canonical re-encoding of one raw query key or value: decode what the platform sent, then
    /// re-encode it. The allowed set emits neither `&`, `=` nor `,`, which is what makes a
    /// signature built from these pieces unambiguous — a delimiter inside a VALUE stays escaped
    /// and can never be read as structure. A malformed escape is not decodable, so it is encoded
    /// as the literal text it is and lands in its own equivalence class rather than silently
    /// matching a well-formed value.
    nonisolated static func canonicalQueryComponent(_ raw: String) -> String {
        // JavaScript's encodeURIComponent unreserved set, so the signature a native wrapper
        // computes and the one React Native computes agree character for character.
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()",
        )
        guard let decoded = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
            return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
        }
        return decoded.addingPercentEncoding(withAllowedCharacters: allowed) ?? decoded
    }

    /// A URL's query reduced to a signature that is equal for exactly those URLs the web runtime
    /// would start with the same configuration, and different for every other. Fragment stripped
    /// and keys sorted, so a platform that reorders the pairs or rewrites `+`/`%20` still compares
    /// equal while a single changed value does not.
    ///
    /// Every piece is canonically RE-ENCODED rather than left decoded. A signature of decoded
    /// pairs joined by raw `&`/`=` is ambiguous: a mount whose own config legitimately contains a
    /// delimiter — a greeting of `&handle=attacker`, which `buildWebviewUrl` emits percent-encoded
    /// — produces the same decoded text as a navigation carrying a real extra `handle` pair, so an
    /// attacker could match the signature while the runtime read a bot they chose.
    ///
    /// Repeated keys keep their values in ARRIVAL order under one entry, so `a=1&a=2` and `a=2&a=1`
    /// are different signatures: the runtime reads the first value, so collapsing or re-ordering
    /// duplicates would erase exactly the distinction that decides which value it uses.
    nonisolated static func normalizedQuerySignature(ofUrl rawUrl: String) -> String {
        let withoutFragment = rawUrl.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard let queryStart = withoutFragment.firstIndex(of: "?") else { return "" }

        var valuesByKey: [String: [String]] = [:]
        let query = withoutFragment[withoutFragment.index(after: queryStart)...]
        for pair in query.split(separator: "&") {
            let key: String
            let value: String
            if let separator = pair.firstIndex(of: "=") {
                key = canonicalQueryComponent(String(pair[..<separator]))
                value = canonicalQueryComponent(String(pair[pair.index(after: separator)...]))
            } else {
                key = canonicalQueryComponent(String(pair))
                value = ""
            }
            valuesByKey[key, default: []].append(value)
        }

        return valuesByKey.keys.sorted()
            .map { "\($0)=\((valuesByKey[$0] ?? []).joined(separator: ","))" }
            .joined(separator: "&")
    }

    /// A URL's path, lowercased, with query and fragment removed. `nil` when the string carries no
    /// `scheme://` authority at all, which fails closed at the callers below.
    nonisolated static func documentPath(ofUrl rawUrl: String) -> String? {
        let withoutFragment = String(rawUrl.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let withoutQuery = withoutFragment.firstIndex(of: "?")
            .map { String(withoutFragment[..<$0]) } ?? withoutFragment
        guard let schemeEnd = withoutQuery.range(of: "://") else { return nil }
        let authorityAndPath = withoutQuery[schemeEnd.upperBound...]
        guard let pathStart = authorityAndPath.firstIndex(of: "/") else { return "/" }
        return String(authorityAndPath[pathStart...]).lowercased()
    }

    /// Whether a URL addresses the same ENTRY DOCUMENT this mount pointed the WebView at. Origin
    /// and query decide which CONFIGURATION a document would boot with; this decides which document
    /// boots it. Without it the same Ada CDN root serves a second top-level entry — `sdk/chat.html`,
    /// which ignores query params it does not recognise — so a subframe could set `top.location` to
    /// that entry carrying the mount's own query verbatim and be taken for the runtime.
    ///
    /// Exactly one extra segment is tolerated, and only where the edge inserts one. A versionless
    /// entry (production `/sdk/webview.html`, and under a shared root `/messaging/sdk/webview.html`)
    /// is 302-redirected to the current build with the prefix preserved and the version inserted
    /// immediately before the entry tail — `/<build>/sdk/webview.html` — so plain path equality would
    /// eject every production load. Matching on the entry TAIL alone would tolerate far more than
    /// that: any published build of the entry under any prefix, which on preprod is
    /// `/<any branch>/sdk/webview.html` and on production includes every older build whose fixed
    /// holes are public history. The attacker never has to write content, only to select which
    /// Ada-authored build receives the injected credentials.
    ///
    /// So the prefix is compared, not skipped, and the rule is derived from the ENTRY URL rather
    /// than hardcoded to the tail: a preprod source (`/<branch>/sdk/webview.html`) is already
    /// build-scoped and gets no redirect, so its own branch prefix is required and a sibling branch
    /// cannot match, and the legacy remote host page — `/mobile-sdk-webview/` on the bot's own host,
    /// with no redirect in front of it — is held to exact path equality.
    ///
    /// The residual is a production entry substituted by an OLDER production build: both are
    /// `/<valid build>/sdk/webview.html`, and native cannot tell which build the manifest currently
    /// resolves to. Closing it needs the current build identifier, which only the edge holds.
    nonisolated static func isSameEntryDocument(candidateUrl: String, entryDocumentUrl: String) -> Bool {
        guard let entryPath = documentPath(ofUrl: entryDocumentUrl),
              let candidatePath = documentPath(ofUrl: candidateUrl)
        else { return false }
        return candidatePath == entryPath
            || isBuildScopedEntryPath(candidatePath, entryPath: entryPath)
    }

    /// The one redirect shape tolerated: see ``isSameEntryDocument(candidateUrl:entryDocumentUrl:)``.
    private nonisolated static func isBuildScopedEntryPath(_ candidatePath: String, entryPath: String) -> Bool {
        guard entryPath.hasSuffix(webviewEntryPathTail), candidatePath.hasSuffix(webviewEntryPathTail) else {
            return false
        }
        let prefix = entryPath.dropLast(webviewEntryPathTail.count)
        guard candidatePath.hasPrefix("\(prefix)/") else { return false }
        return isBuildVersionSegment(
            candidatePath.dropFirst(prefix.count + 1).dropLast(webviewEntryPathTail.count),
        )
    }

    /// The shape a build identifier has to have for the edge to interpolate it into a redirect
    /// target — `VERSION_SEGMENT_PATTERN` / `isValidVersionSegment` in
    /// `scripts/lambda-edge/origin-request.mjs`, the same shape `scripts/sdk.js` enforces on a
    /// pinned version. The manifest value is validated against it before the `Location` is built, so
    /// a segment of any other shape in that position was never produced by the redirect this
    /// tolerance exists for.
    ///
    /// The segment is carved out of ``documentPath(ofUrl:)``, which lowercases, so the ASCII
    /// hex-digit test here IS the `[0-9a-f]` the Android and React Native patterns spell — no
    /// uppercase can reach it, and excluding uppercase separately would only look like a
    /// divergence from them.
    private nonisolated static func isBuildVersionSegment(_ segment: Substring) -> Bool {
        if segment.hasPrefix("pr-") {
            let number = segment.dropFirst(3)
            return !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
        }
        return (7 ... 40).contains(segment.count)
            && segment.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// "This URL is the runtime document THIS mount pointed the WebView at" — the identity test
    /// every injection and every top-level navigation is judged against.
    ///
    /// Origin alone is not identity. The bot `handle`, the cluster, metaFields and every other start
    /// parameter ride the QUERY (see `buildWebviewUrl`), so a subframe — App Block or `appUrl`
    /// content, which SUP-247 deliberately renders in place — can set `top.location` to another URL
    /// on the same Ada CDN origin and be taken for the runtime, receiving the host's injected
    /// `setSensitiveMetaFields` / `setDeviceToken` and the mirror seed under a handle it chose.
    ///
    /// Query alone is not identity either: the same CDN root serves `sdk/chat.html`, which ignores
    /// the params it does not recognise, so carrying this mount's exact query onto it costs an
    /// attacker nothing. Origin, entry and query signature are all required.
    nonisolated static func isRuntimeDocumentUrl(_ candidateUrl: String, entryDocumentUrl: String) -> Bool {
        guard let entryOrigin = pageOrigin(ofUrl: entryDocumentUrl),
              pageOrigin(ofUrl: candidateUrl) == entryOrigin,
              isSameEntryDocument(candidateUrl: candidateUrl, entryDocumentUrl: entryDocumentUrl)
        else { return false }
        return normalizedQuerySignature(ofUrl: candidateUrl)
            == normalizedQuerySignature(ofUrl: entryDocumentUrl)
    }
}

// MARK: - Navigation policy

/// The decision `webView(_:decidePolicyFor:decisionHandler:)` reaches for a navigation.
///
/// Kept separate from `WKNavigationAction` so the policy is a pure function of a few
/// values: `WKNavigationAction` and `WKFrameInfo` cannot be constructed or meaningfully
/// subclassed, so a policy expressed only inside the delegate cannot be unit tested.
enum AdaNavigationPolicy: Equatable {
    /// Let the WebView load the navigation in place.
    case allow
    /// Cancel outright — neither loaded nor handed to another app.
    case block
    /// Cancel and hand the URL to the system browser / Safari view controller.
    case cancelAndOpenExternally
    /// Cancel and download the URL as the chat transcript instead of navigating.
    case cancelAndDownload
    /// Let WebKit convert the navigation into a `WKDownload`.
    case download

    /// Schemes a link click hands to the system from any frame, main or not.
    ///
    /// WKWebView cannot load these itself, so gating them on the main frame makes them dead
    /// links in App Block content. Each one hands off to a first-party system app that shows
    /// the target before acting. The set stays closed rather than widening to "any non-http
    /// scheme": `intent:` and other app-launch schemes would let untrusted subframe content
    /// drive arbitrary installed-app deep links.
    static let externalSchemesAllowedFromAnyFrame: Set<String> = ["tel", "sms", "mailto"]

    /// Schemes that read the device instead of the network. A subframe reaches them with one
    /// tag and no gesture, so they are refused in every frame.
    static let localContentSchemes: Set<String> = ["file", "content"]

    /// `data:` carries its own inline content rather than reading the device, so it is refused
    /// only as a top-level document — there it would replace the Ada runtime with an
    /// opaque-origin document that still sees the injected bridge. In a subframe it is the web
    /// SDK's own activation-timeout fallback (`data:text/html`), whose close button is the only
    /// escape from a dead full-screen chat, so it renders.
    static let inlineContentScheme = "data"

    /// All iOS has where Android reads `WebResourceRequest.hasGesture()`: `WKNavigationAction`
    /// exposes no user-activation flag, so the navigation type is the only public evidence of how a
    /// navigation was raised — and it proves less. `.linkActivated` is an ANCHOR ACTIVATION, not a
    /// finger: WebKit raises it for `HTMLAnchorElement.click()` exactly as for a tap, so a subframe
    /// determined to download can still synthesize one. It refuses every shape with NO activation —
    /// an injected `<a download>` never activated, a frame pointed at the resource, a script
    /// assigning `location` — and cannot be narrowed: the runtime's own downloads (transcript blob,
    /// lightbox image) are that same synthetic click, in the app SUBFRAME of `sdk/webview.html`.
    static func isUserActivated(_ navigationType: WKNavigationType) -> Bool {
        navigationType == .linkActivated
    }

    /// - Parameter targetFrameIsMain: `nil` when the action has no target frame, which
    ///   WebKit uses for a request to open a new window. The external-navigation arms and the
    ///   download arm treat that as top-level, so a `window.open` still leaves the WebView and a
    ///   `download` link opening a new window still downloads.
    ///
    /// Subframe navigations are never sent to the browser (SUP-247), except for a link click
    /// on `externalSchemesAllowedFromAnyFrame`: customer-hosted App Block content is mounted
    /// as an iframe, and a link click inside it reports `.linkActivated` exactly like a
    /// top-level one, so an ungated arm ejects the content out of the app. The `/transcript/`
    /// arm is gated for the same reason — a customer path containing that substring is theirs
    /// to navigate, not Ada's transcript.
    ///
    /// The block arm is ordered ahead of every other reading of the URL, download included, so
    /// no blocked or inline scheme can reach `WKDownload` or the transcript download in any
    /// frame — a `file:`/`content:`/top-level `data:` URL naming `/transcript/`, or one WebKit
    /// flags for download, is still refused.
    ///
    /// The download arm then carries Android's gate (`isForMainFrame || hasGesture` in
    /// `AdaWebViewClient.navigationActionFor`): legacy parity covers a main-frame download only, so
    /// a subframe downloads solely behind a user activation — otherwise embedded content writes to
    /// the user's files with one tag and no interaction. ``isUserActivated(_:)`` says what iOS can
    /// prove there; a refusal is not a block but Android's fallthrough to `LOAD_IN_PLACE`.
    ///
    /// - Parameter entryDocumentUrl: the document this mount pointed the WebView at. A top-level
    ///   navigation to anything else leaves the WebView, whatever drove it — a script assigning
    ///   `top.location`, a form submission and a redirect all replace the main document in place
    ///   just as a link click would, and the replacement inherits the injected bridge, the
    ///   document-start config script and the host's commands. Gating only `.linkActivated` left
    ///   every other way of getting there rendering in place, which is neither Android's posture
    ///   nor React Native's. `nil` (no resolvable entry document, so nothing was ever loaded)
    ///   fails closed.
    ///
    ///   That arm keys on `targetFrameIsMain == true` rather than on `isTopLevel`, which the other
    ///   arms use. A `nil` target frame is WebKit asking to open a NEW window — it cannot replace
    ///   the document already in the main frame, and `createWebViewWith` hands it to the system
    ///   anyway — so treating it as a foreign main document would buy nothing and would eject a
    ///   frame WebKit had not yet created.
    static func navigationPolicy(
        navigationType: WKNavigationType,
        url: URL?,
        targetFrameIsMain: Bool?,
        shouldPerformDownload: Bool,
        entryDocumentUrl: String?,
    ) -> AdaNavigationPolicy {
        let isTopLevel = targetFrameIsMain ?? true
        let scheme = url?.scheme?.lowercased() ?? ""

        if isBlockedScheme(scheme, isTopLevel: isTopLevel) {
            return .block
        }
        if shouldPerformDownload, isTopLevel || isUserActivated(navigationType) {
            return .download
        }
        if isTopLevel, let url, url.absoluteString.range(of: "/transcript/") != nil {
            return .cancelAndDownload
        }
        if isTopLevel, navigationType == .linkActivated {
            return .cancelAndOpenExternally
        }
        if targetFrameIsMain == true, !isRuntimeDocument(url: url, entryDocumentUrl: entryDocumentUrl) {
            return .cancelAndOpenExternally
        }
        if navigationType == .linkActivated, externalSchemesAllowedFromAnyFrame.contains(scheme) {
            return .cancelAndOpenExternally
        }
        return .allow
    }

    /// Whether a main-frame navigation target is the mount's own runtime document, and so may
    /// render in place. Subframe targets never reach this — SUP-247 keeps them rendering where
    /// they are.
    private static func isRuntimeDocument(url: URL?, entryDocumentUrl: String?) -> Bool {
        guard let url, let entryDocumentUrl else { return false }
        return AdaWebHost.isRuntimeDocumentUrl(url.absoluteString, entryDocumentUrl: entryDocumentUrl)
    }

    static func isBlockedScheme(_ scheme: String, isTopLevel: Bool) -> Bool {
        localContentSchemes.contains(scheme) || (isTopLevel && scheme == inlineContentScheme)
    }
}

// MARK: - WKNavigationDelegate & WKUIDelegate

extension AdaWebHost: WKNavigationDelegate, WKUIDelegate {
    public func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        let url = webView.url?.absoluteString ?? ""
        let event: [String: Any] = ["event_name": "ada.webview.loaded", "url": url]
        dispatchEventToSubscribers(event, rawData: rawSdkEventData(event))
        eventCallbacks?["*"]?(event)
    }

    public func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        // Whena  reset method is built - we will need to set this back to false
        hasError = true
        webViewLoadingErrorCallback?(AdaWebHostError.webViewFailedToLoad)
        let event: [String: Any] = ["event_name": "ada.webview.loadFailed", "error": error.localizedDescription]
        dispatchEventToSubscribers(event, rawData: rawSdkEventData(event))
        eventCallbacks?["*"]?(event)
    }

    /// Shared function to handle opening of urls
    public func openUrl(webView: WKWebView, url: URL) {
        let httpSchemes = ["http", "https"]
        let urlScheme = url.scheme
        // Handle opening universal links within the host App
        // This requires the appScheme argument to work
        if urlScheme == appScheme {
            guard let presentingVC = findViewController(from: webView) else { return }
            presentingVC.dismiss(animated: true) {
                let shared = UIApplication.shared
                if shared.canOpenURL(url) {
                    shared.open(url, options: [:], completionHandler: nil)
                }
            }
            // Only open links in in-app WebView if URL uses HTTP(S) scheme, and the openWebLinksInSafari option is
            // false
            // This is where SUP-43 is likely crashing
        } else if openWebLinksInSafari == false, httpSchemes.contains(urlScheme ?? "") {
            let sfVC = SFSafariViewController(url: url)
            guard let presentingVC = findViewController(from: webView) else { return }
            presentingVC.present(sfVC, animated: true, completion: nil)
        } else {
            let shared = UIApplication.shared
            if shared.canOpenURL(url) {
                shared.open(url, options: [:], completionHandler: nil)
            }
        }
    }

    /// Used for weblinks and signon (handling window.open js call)
    public func webView(
        _ webView: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures,
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            openUrl(webView: webView, url: url)
        }
        return nil
    }

    /// Used for processing all other navigation
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void,
    ) {
        var shouldPerformDownload = false
        if #available(iOS 14.5, *) {
            shouldPerformDownload = navigationAction.shouldPerformDownload
        }
        let url = navigationAction.request.url

        switch AdaNavigationPolicy.navigationPolicy(
            navigationType: navigationAction.navigationType,
            url: url,
            targetFrameIsMain: navigationAction.targetFrame?.isMainFrame,
            shouldPerformDownload: shouldPerformDownload,
            entryDocumentUrl: entryDocumentUrl?.absoluteString,
        ) {
        case .download:
            if #available(iOS 14.5, *) {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        case .cancelAndDownload:
            if let url {
                downloadUrl(url: url, fileName: "chat_transcript.txt")
            }
            decisionHandler(.cancel)
        case .cancelAndOpenExternally:
            if let url {
                openUrl(webView: webView, url: url)
            }
            decisionHandler(.cancel)
        case .block:
            decisionHandler(.cancel)
        case .allow:
            decisionHandler(.allow)
        }
    }

    /// Bypasses TLS certificate validation for local dev servers.
    ///
    /// Allows WKWebView to load `webview.html` and all sub-resources from
    /// `localhost` (SDK assets) and to make API fetch calls to `localhost`
    /// (local Ada backend proxy). Legacy `messaging-assets.net` /
    /// `messaging-demo.net` aliases remain allowed for compatibility with older
    /// local setups.
    ///
    /// The dev servers now serve one committed certificate signed by a committed
    /// local-dev CA (`messaging/scripts/certs/`), which
    /// `scripts/trust-dev-cert-ios.sh` installs into the simulator — so a
    /// correctly set-up simulator no longer needs this bypass for navigations.
    /// It is kept because it also covers machines that have not run that script,
    /// and because JS-initiated `fetch()`/XHR go through the system trust store
    /// rather than this delegate. DEBUG-only; see the `#if DEBUG` guard below.
    private static let localDevHosts: Set<String> = [
        "localhost",
        "127.0.0.1",
        "messaging-assets.net",
        "messaging-demo.net",
    ]

    public func webView(
        _: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
    ) {
        #if DEBUG
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               Self.localDevHosts.contains(challenge.protectionSpace.host),
               let trust = challenge.protectionSpace.serverTrust,
               case .local = (environment ?? .production)
            {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
        #endif
        completionHandler(.performDefaultHandling, nil)
    }

    /// Download the file from the given url and store it locally in the app's temp folder and present the activity
    /// viewer.
    private func downloadUrl(url downloadUrl: URL, fileName: String) {
        let localFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        URLSession.shared.dataTask(with: downloadUrl) { data, response, err in
            guard let data, err == nil else {
                debugPrint("Error downloading from url=\(downloadUrl.absoluteString): \(err.debugDescription)")
                return
            }
            if let httpResponse = response as? HTTPURLResponse {
                debugPrint("HTTP Status=\(httpResponse.statusCode)")
            }
            // write the downloaded data to a temporary folder
            do {
                try data.write(to: localFileURL, options: .atomic) // atomic option overwrites it if needed
                DispatchQueue.main.async { [weak self] in
                    guard let self, let webView else { return }
                    // present activity viewer
                    let items = [localFileURL]
                    let ac = UIActivityViewController(activityItems: items, applicationActivities: nil)
                    findViewController(from: webView)?.present(ac, animated: true)
                }
            } catch {
                debugPrint(error)
            }
        }.resume()
    }
}

// MARK: - WKDownloadDelegate

@available(iOS 14.5, *)
extension AdaWebHost: WKDownloadDelegate {
    public func download(
        _: WKDownload,
        decideDestinationUsing _: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void,
    ) {
        let localFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedFilename)

        completionHandler(localFileURL)

        DispatchQueue.main.async { [weak self] in
            guard let self, let webView else { return }
            // present activity viewer
            let items = [localFileURL]
            let ac = UIActivityViewController(activityItems: items, applicationActivities: nil)
            findViewController(from: webView)?.present(ac, animated: true)
        }
    }

    public func webView(_: WKWebView, navigationAction _: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }
}
