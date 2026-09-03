//
//  NavigationPolicyTests.swift
//  AdaMessagingTests
//
//  Unit tests for the WKNavigationDelegate policy decision (SUP-247).
//

@testable import AdaMessaging
import Foundation
import Testing
import WebKit

private let appBlockUrl = URL(string: "https://customer.example/app-block/balance")!
private let transcriptUrl = URL(string: "https://customer.example/transcript/123")!
private let telUrl = URL(string: "tel:+15551234567")!
private let smsUrl = URL(string: "sms:+15551234567")!
private let mailtoUrl = URL(string: "mailto:support@customer.example")!
private let intentUrl = URL(string: "intent://scan/#Intent;scheme=zxing;package=com.evil.app;end")!
private let marketUrl = URL(string: "market://details?id=com.evil.app")!
private let fileUrl = URL(string: "file:///etc/passwd")!
private let contentUrl = URL(string: "content://com.android.providers/document/1")!
private let dataHtmlUrl = URL(string: "data:text/html,%3Cbutton%3EClose%3C/button%3E")!
private let fileTranscriptUrl = URL(string: "file:///var/mobile/transcript/123")!

/// The document the wrapper pointed the WebView at for these cases — a production Messaging
/// mount of one bot.
private let entryDocument = "https://messaging-assets.ada.support/sdk/webview.html?handle=ada-example"

private func policy(
    navigationType: WKNavigationType,
    url: URL? = appBlockUrl,
    targetFrameIsMain: Bool?,
    shouldPerformDownload: Bool = false,
    entryDocumentUrl: String? = entryDocument,
) -> AdaNavigationPolicy {
    AdaNavigationPolicy.navigationPolicy(
        navigationType: navigationType,
        url: url,
        targetFrameIsMain: targetFrameIsMain,
        shouldPerformDownload: shouldPerformDownload,
        entryDocumentUrl: entryDocumentUrl,
    )
}

@Suite("Navigation policy")
struct NavigationPolicyTests {
    @Test("a link click inside a subframe loads in place")
    func subframeLinkActivationLoadsInPlace() {
        #expect(policy(navigationType: .linkActivated, targetFrameIsMain: false) == .allow)
    }

    @Test("a link click in the main frame opens externally")
    func mainFrameLinkActivationOpensExternally() {
        #expect(policy(navigationType: .linkActivated, targetFrameIsMain: true) == .cancelAndOpenExternally)
    }

    @Test("a link click with no target frame opens externally")
    func newWindowLinkActivationOpensExternally() {
        #expect(policy(navigationType: .linkActivated, targetFrameIsMain: nil) == .cancelAndOpenExternally)
    }

    @Test("an iframe content load is allowed")
    func subframeOtherNavigationIsAllowed() {
        #expect(policy(navigationType: .other, targetFrameIsMain: false) == .allow)
    }

    @Test("a transcript URL in a subframe is not downloaded")
    func subframeTranscriptUrlIsAllowed() {
        #expect(policy(navigationType: .other, url: transcriptUrl, targetFrameIsMain: false) == .allow)
    }

    @Test("a transcript URL in the main frame is downloaded")
    func mainFrameTranscriptUrlIsDownloaded() {
        #expect(policy(navigationType: .other, url: transcriptUrl, targetFrameIsMain: true) == .cancelAndDownload)
    }

    @Test("a transcript link click in the main frame downloads rather than opening externally")
    func mainFrameTranscriptLinkPrefersDownload() {
        #expect(
            policy(
                navigationType: .linkActivated,
                url: transcriptUrl,
                targetFrameIsMain: true,
            ) == .cancelAndDownload,
        )
    }

    @Test("the mount's own runtime document renders in the main frame")
    func mainFrameRuntimeDocumentIsAllowed() {
        #expect(policy(navigationType: .other, url: URL(string: entryDocument)!, targetFrameIsMain: true) == .allow)
    }

    /// Production loads the versionless entry and the edge 302s it to `/<build>/sdk/webview.html`
    /// with the prefix preserved and the query intact, so the path rule tolerates exactly that one
    /// inserted segment.
    @Test(
        "the edge's build-scoped redirect of the entry document still renders",
        arguments: [
            "https://messaging-assets.ada.support/9f2c1ab/sdk/webview.html?handle=ada-example",
            "https://messaging-assets.ada.support/pr-1234/sdk/webview.html?handle=ada-example",
        ],
    )
    func mainFrameBuildScopedRedirectIsAllowed(url: String) {
        #expect(policy(navigationType: .other, url: URL(string: url)!, targetFrameIsMain: true) == .allow)
    }

    /// The tolerance is one segment of the shape the edge validates before it interpolates it
    /// (`isValidVersionSegment` in `scripts/lambda-edge/origin-request.mjs`), not the entry tail on
    /// its own. Tail-matching alone would hand the injected credentials to any Ada-authored build
    /// under any prefix — every older production build included — which the attacker only has to
    /// select, never to write.
    @Test(
        "a same-origin path that merely ends in the entry tail leaves the WebView",
        arguments: [
            "https://messaging-assets.ada.support/marketing/sdk/webview.html?handle=ada-example",
            "https://messaging-assets.ada.support/static-assets/9f2c1ab/sdk/webview.html?handle=ada-example",
            "https://messaging-assets.ada.support/9f2c1ab/deadbee/sdk/webview.html?handle=ada-example",
            "https://messaging-assets.ada.support/abc123/sdk/webview.html?handle=ada-example",
        ],
    )
    func mainFrameForeignBuildScopedPathIsEjected(url: String) {
        #expect(
            policy(navigationType: .other, url: URL(string: url)!, targetFrameIsMain: true)
                == .cancelAndOpenExternally,
        )
    }

    /// A preprod entry is already build-scoped and gets no redirect, so its own branch prefix is
    /// required: the rule is derived from the entry URL, and a sibling branch is a different build.
    @Test("a sibling preprod branch's entry leaves the WebView")
    func mainFramePreprodSiblingBranchIsEjected() {
        let branchEntry = "https://messaging-assets.ada-dev2.support/feature-x/sdk/webview.html?handle=ada-example"
        let siblingBranch = URL(
            string: "https://messaging-assets.ada-dev2.support/feature-y/sdk/webview.html?handle=ada-example",
        )!
        #expect(
            policy(
                navigationType: .other,
                url: siblingBranch,
                targetFrameIsMain: true,
                entryDocumentUrl: branchEntry,
            ) == .cancelAndOpenExternally,
        )
        #expect(
            policy(
                navigationType: .other,
                url: URL(string: branchEntry)!,
                targetFrameIsMain: true,
                entryDocumentUrl: branchEntry,
            ) == .allow,
        )
    }

    /// Under the shared `static.ada.support/messaging` root the edge preserves the prefix and
    /// inserts the build after it, so the prefix is compared rather than skipped.
    @Test(
        "the shared root's prefix is part of the entry document",
        arguments: [
            ("https://static.ada.support/messaging/9f2c1ab/sdk/webview.html?handle=ada-example", true),
            ("https://static.ada.support/9f2c1ab/sdk/webview.html?handle=ada-example", false),
        ],
    )
    func mainFrameSharedRootPrefixIsRequired(url: String, expectedAllow: Bool) {
        let sharedRootEntry = "https://static.ada.support/messaging/sdk/webview.html?handle=ada-example"
        let decision = policy(
            navigationType: .other,
            url: URL(string: url)!,
            targetFrameIsMain: true,
            entryDocumentUrl: sharedRootEntry,
        )
        #expect(decision == (expectedAllow ? .allow : .cancelAndOpenExternally))
    }

    /// The finding: a script assigning `top.location`, a form submission or a redirect replaces the
    /// main document exactly as a link click does, and the replacement inherits the injected bridge.
    /// Gating only `.linkActivated` left every one of them rendering in place.
    @Test(
        "a script-driven main-frame navigation off the runtime document leaves the WebView",
        arguments: [WKNavigationType.other, .formSubmitted, .formResubmitted, .reload, .backForward],
    )
    func mainFrameForeignDocumentIsEjected(navigationType: WKNavigationType) {
        #expect(policy(navigationType: navigationType, targetFrameIsMain: true) == .cancelAndOpenExternally)
    }

    /// The Ada CDN root serves other bots' runs of the same entry, and the parameters that decide
    /// whose session boots ride the query — so origin is not identity.
    @Test(
        "a same-origin main-frame navigation carrying other start parameters leaves the WebView",
        arguments: [
            "https://messaging-assets.ada.support/sdk/webview.html?handle=attacker",
            "https://messaging-assets.ada.support/sdk/webview.html?handle=ada-example&handle=attacker",
        ],
    )
    func mainFrameSameOriginReconfigurationIsEjected(url: String) {
        let decision = policy(navigationType: .other, url: URL(string: url)!, targetFrameIsMain: true)
        #expect(decision == .cancelAndOpenExternally)
    }

    /// ...and the same root serves a second top-level entry that ignores the params it does not
    /// recognise, so carrying this mount's exact query onto it costs an attacker nothing.
    @Test("a same-origin navigation to another entry carrying this mount's query leaves the WebView")
    func mainFrameSiblingEntryIsEjected() {
        let siblingEntry = URL(string: "https://messaging-assets.ada.support/sdk/chat.html?handle=ada-example")!
        #expect(policy(navigationType: .other, url: siblingEntry, targetFrameIsMain: true) == .cancelAndOpenExternally)
    }

    /// A fragment is no part of the configuration, and the origin comparison folds host case, so
    /// neither ejects the runtime out of its own WebView.
    @Test(
        "a fragment or a differently-cased host on the runtime document still renders",
        arguments: [
            "https://messaging-assets.ada.support/sdk/webview.html?handle=ada-example#/conversation",
            "https://MESSAGING-ASSETS.ada.support/sdk/webview.html?handle=ada-example",
        ],
    )
    func mainFrameFragmentOrHostCasingIsAllowed(url: String) {
        #expect(policy(navigationType: .other, url: URL(string: url)!, targetFrameIsMain: true) == .allow)
    }

    /// Subframes are the SUP-247 carve-out: App Block and `appUrl` content is customer-hosted and
    /// must render where it is, so the main-document rule never applies to them.
    @Test("a foreign document in a subframe still renders in place")
    func subframeForeignDocumentIsAllowed() {
        #expect(policy(navigationType: .other, targetFrameIsMain: false) == .allow)
        #expect(policy(navigationType: .formSubmitted, targetFrameIsMain: false) == .allow)
    }

    /// A `nil` target frame is a new-window request, not a replacement of the document already in
    /// the main frame — `createWebViewWith` hands it to the system, and ejecting it here would also
    /// eject the very first load, whose frame WebKit has not created yet.
    @Test("a new-window navigation is left to the window-open path")
    func newWindowNavigationIsNotTreatedAsAMainDocumentSwap() {
        #expect(policy(navigationType: .other, targetFrameIsMain: nil) == .allow)
    }

    /// No resolvable entry document means nothing was ever loaded, so the main frame holds nothing
    /// worth keeping.
    @Test("an unresolvable entry document ejects every top-level navigation")
    func missingEntryDocumentFailsClosed() {
        #expect(
            policy(
                navigationType: .other,
                url: URL(string: entryDocument)!,
                targetFrameIsMain: true,
                entryDocumentUrl: nil,
            ) == .cancelAndOpenExternally,
        )
    }

    /// The legacy remote page is a different entry on the bot's own host with no build redirect in
    /// front of it, so its path is required to match exactly — and its build-version parameters
    /// ride the query.
    @Test(
        "the legacy remote page binds its path exactly and its build parameters",
        arguments: [
            ("https://ada-example.ada.support/mobile-sdk-webview/", true),
            ("https://ada-example.ada.support/mobile-sdk-webview/?__ada-embed-version=evil", false),
            ("https://ada-example.ada.support/sdk/webview.html", false),
            ("https://ada-example.ada.support/other/", false),
        ],
    )
    func legacyEntryDocumentBinding(url: String, expectedAllow: Bool) {
        let legacyEntry = "https://ada-example.ada.support/mobile-sdk-webview/"
        let decision = policy(
            navigationType: .other,
            url: URL(string: url)!,
            targetFrameIsMain: true,
            entryDocumentUrl: legacyEntry,
        )
        #expect(decision == (expectedAllow ? .allow : .cancelAndOpenExternally))
    }

    @Test("a main-frame link click with no URL is still cancelled")
    func mainFrameLinkActivationWithoutUrlIsCancelled() {
        #expect(policy(navigationType: .linkActivated, url: nil, targetFrameIsMain: true) == .cancelAndOpenExternally)
    }

    @Test(
        "an allowlisted external scheme clicked in a subframe opens externally",
        arguments: [telUrl, smsUrl, mailtoUrl],
    )
    func subframeAllowlistedSchemeOpensExternally(url: URL) {
        #expect(policy(navigationType: .linkActivated, url: url, targetFrameIsMain: false) == .cancelAndOpenExternally)
    }

    @Test("an uppercase allowlisted scheme in a subframe opens externally")
    func subframeAllowlistedSchemeIsCaseInsensitive() {
        #expect(
            policy(
                navigationType: .linkActivated,
                url: URL(string: "MAILTO:support@customer.example")!,
                targetFrameIsMain: false,
            ) == .cancelAndOpenExternally,
        )
    }

    @Test("an intent URL clicked in a subframe stays in the WebView", arguments: [intentUrl, marketUrl])
    func subframeAppLaunchSchemeIsNotHandledExternally(url: URL) {
        #expect(policy(navigationType: .linkActivated, url: url, targetFrameIsMain: false) == .allow)
    }

    @Test("an http link clicked in a subframe stays in the WebView")
    func subframeHttpLinkStaysInPlace() {
        #expect(
            policy(
                navigationType: .linkActivated,
                url: URL(string: "http://customer.example/app-block/balance")!,
                targetFrameIsMain: false,
            ) == .allow,
        )
    }

    @Test("a script-driven subframe navigation to an allowlisted scheme is not handled externally")
    func subframeScriptedAllowlistedSchemeIsNotHandledExternally() {
        #expect(policy(navigationType: .other, url: telUrl, targetFrameIsMain: false) == .allow)
    }

    @Test("an intent URL clicked in the main frame still opens externally")
    func mainFrameAppLaunchSchemeOpensExternally() {
        #expect(
            policy(navigationType: .linkActivated, url: intentUrl, targetFrameIsMain: true) == .cancelAndOpenExternally,
        )
    }

    /// `file:` and `content:` read the device instead of the network, and a subframe reaches
    /// them with one tag and no gesture, so they are refused in every frame.
    @Test(
        "a device-content scheme is blocked in every frame",
        arguments: [fileUrl, contentUrl],
    )
    func deviceContentSchemeIsBlockedInEveryFrame(url: URL) {
        #expect(policy(navigationType: .other, url: url, targetFrameIsMain: true) == .block)
        #expect(policy(navigationType: .other, url: url, targetFrameIsMain: false) == .block)
        #expect(policy(navigationType: .linkActivated, url: url, targetFrameIsMain: true) == .block)
        #expect(policy(navigationType: .linkActivated, url: url, targetFrameIsMain: false) == .block)
    }

    @Test("an uppercase device-content scheme is still blocked")
    func deviceContentSchemeIsCaseInsensitive() {
        #expect(
            policy(
                navigationType: .other,
                url: URL(string: "FILE:///etc/passwd")!,
                targetFrameIsMain: false,
            ) == .block,
        )
    }

    /// A top-level `data:` document would replace the Ada runtime with an opaque-origin page
    /// that still sees the injected bridge.
    @Test("a data URL is blocked as a top-level document")
    func topLevelDataUrlIsBlocked() {
        #expect(policy(navigationType: .other, url: dataHtmlUrl, targetFrameIsMain: true) == .block)
        #expect(policy(navigationType: .other, url: dataHtmlUrl, targetFrameIsMain: nil) == .block)
    }

    /// The web SDK's activation-timeout fallback is a `data:text/html` navigation of the core
    /// SUBFRAME, and its close button is the only escape from a dead full-screen chat.
    @Test("the data URL activation-timeout fallback still renders in a subframe")
    func subframeDataUrlRenders() {
        #expect(policy(navigationType: .other, url: dataHtmlUrl, targetFrameIsMain: false) == .allow)
    }

    /// A blocked scheme wins over every other reading of the URL, including the transcript
    /// download, which matches on a path substring any URL can carry.
    @Test("a blocked scheme naming the transcript path is still blocked")
    func blockWinsOverTranscriptDownload() {
        #expect(policy(navigationType: .other, url: fileTranscriptUrl, targetFrameIsMain: true) == .block)
    }

    /// ...and the external-open arm, which would otherwise hand the URL to the system.
    @Test("a blocked scheme clicked in the main frame is not handed to the system")
    func blockWinsOverExternalOpen() {
        #expect(policy(navigationType: .linkActivated, url: dataHtmlUrl, targetFrameIsMain: true) == .block)
    }
}

/// The download arm, which mirrors Android's `isForMainFrame || hasGesture` gate in
/// `AdaWebViewClient.navigationActionFor` and sits behind the blocked-scheme arm.
@Suite("Navigation policy download arm")
struct NavigationPolicyDownloadTests {
    /// Android's stated reason for the gate: without it embedded content writes to the user's
    /// files with one tag and no interaction. The refusal renders the navigation rather than
    /// blocking it, matching Android's fallthrough to `LOAD_IN_PLACE`.
    @Test(
        "a download flagged in a subframe with no activation is refused",
        arguments: [WKNavigationType.other, .formSubmitted, .reload, .backForward],
    )
    func subframeDownloadWithoutActivationIsRefused(navigationType: WKNavigationType) {
        #expect(
            policy(
                navigationType: navigationType,
                targetFrameIsMain: false,
                shouldPerformDownload: true,
            ) == .allow,
        )
    }

    /// `.linkActivated` is the only user-activation evidence `WKNavigationAction` carries, and the
    /// runtime's own downloads — the transcript blob and the lightbox image — are an
    /// `anchor.click()` inside the app iframe, so the subframe arm has to keep passing it through.
    @Test("a download flagged in a subframe with an activation downloads")
    func subframeDownloadWithActivationDownloads() {
        #expect(
            policy(
                navigationType: .linkActivated,
                targetFrameIsMain: false,
                shouldPerformDownload: true,
            ) == .download,
        )
    }

    /// Legacy parity covers the main frame unconditionally, and a `nil` target frame is a
    /// `download` link opening a new window.
    @Test("a main-frame download needs no activation", arguments: [true, nil] as [Bool?])
    func mainFrameDownloadNeedsNoActivation(targetFrameIsMain: Bool?) {
        #expect(
            policy(
                navigationType: .other,
                targetFrameIsMain: targetFrameIsMain,
                shouldPerformDownload: true,
            ) == .download,
        )
    }

    @Test("an allowlisted external scheme flagged for download still downloads")
    func downloadFlagWinsOverSchemeAllowlist() {
        #expect(
            policy(
                navigationType: .linkActivated,
                url: telUrl,
                targetFrameIsMain: false,
                shouldPerformDownload: true,
            ) == .download,
        )
    }

    /// The blocked-scheme arm stays ahead of the download arm, so no blocked scheme reaches
    /// `WKDownload` in either frame — with or without the activation the subframe arm asks for.
    @Test("a blocked scheme flagged for download is still blocked", arguments: [fileUrl, contentUrl])
    func blockWinsOverDownloadFlag(url: URL) {
        for navigationType in [WKNavigationType.other, .linkActivated] {
            for targetFrameIsMain in [true, false] {
                #expect(
                    policy(
                        navigationType: navigationType,
                        url: url,
                        targetFrameIsMain: targetFrameIsMain,
                        shouldPerformDownload: true,
                    ) == .block,
                )
            }
        }
    }

    /// `data:` is blocked top-level only, so the download flag must not buy it the main frame.
    @Test("a top-level data URL flagged for download is still blocked", arguments: [true, nil] as [Bool?])
    func blockWinsOverDownloadFlagForTopLevelDataUrl(targetFrameIsMain: Bool?) {
        #expect(
            policy(
                navigationType: .linkActivated,
                url: dataHtmlUrl,
                targetFrameIsMain: targetFrameIsMain,
                shouldPerformDownload: true,
            ) == .block,
        )
    }
}

/// The identity check compares a signature of DECODED, canonically re-encoded pairs, keys sorted
/// and repeated values in ARRIVAL order: one configuration is one document however the platform
/// spells it, and a query that merely decodes to the entry's characters is not.
@Suite("Runtime document query identity")
struct RuntimeDocumentQueryIdentityTests {
    private func decision(navigatingTo candidateQuery: String, fromEntry entryQuery: String) -> AdaNavigationPolicy {
        let root = "https://messaging-assets.ada.support/sdk/webview.html"
        return policy(
            navigationType: .other,
            url: URL(string: "\(root)?\(candidateQuery)")!,
            targetFrameIsMain: true,
            entryDocumentUrl: "\(root)?\(entryQuery)",
        )
    }

    @Test(
        "identity follows the query's canonical signature, not its spelling",
        arguments: [
            ("handle=ada-example&greeting=hi%20there%2Fyou", "greeting=hi%20there%2Fyou&handle=ada-example", true),
            ("handle=ada-example&greeting=hi%20there%2Fyou", "handle=ada-exampl%65&greeting=hi+there%2fyou", true),
            ("handle=ada-example&handle=attacker", "handle=attacker&handle=ada-example", false),
            ("greeting=hi%26handle%3Dattacker", "greeting=hi&handle=attacker", false),
        ],
    )
    func mainFrameQuerySignatureDecidesIdentity(entryQuery: String, candidateQuery: String, expectedAllow: Bool) {
        let expected: AdaNavigationPolicy = expectedAllow ? .allow : .cancelAndOpenExternally
        #expect(decision(navigatingTo: entryQuery, fromEntry: entryQuery) == .allow)
        #expect(decision(navigatingTo: candidateQuery, fromEntry: entryQuery) == expected)
    }
}
