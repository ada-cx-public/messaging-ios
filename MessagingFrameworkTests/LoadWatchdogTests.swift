@testable import AdaMessaging
import Foundation
import Testing
import UIKit
import WebKit

@MainActor
final class LoadWatchdogScheduler {
    struct Entry {
        let id: Int
        let dueMs: Double
        let action: @MainActor () -> Void
    }

    var nowMs = 0.0
    var entries: [Entry] = []
    private var nextId = 0

    func schedule(delayMs: Double, action: @escaping @MainActor () -> Void) -> () -> Void {
        nextId += 1
        let id = nextId
        entries.append(Entry(id: id, dueMs: nowMs + delayMs, action: action))
        return { [weak self] in self?.entries.removeAll { $0.id == id } }
    }

    func advance(to timeMs: Double) {
        while let entry = entries.min(by: { $0.dueMs < $1.dueMs }), entry.dueMs <= timeMs {
            nowMs = max(nowMs, entry.dueMs)
            entries.removeAll { $0.id == entry.id }
            entry.action()
        }
        nowMs = timeMs
    }

    func resumeDeadlineFirst(at timeMs: Double) {
        nowMs = timeMs
        let index = entries.firstIndex { $0.dueMs == 30000 }!
        entries.remove(at: index).action()
        advance(to: timeMs)
    }
}

@MainActor
final class WatchdogWebView: AdaRecoverableWebView {
    var stops = 0
    var loads = 0
    var capturedScripts: [String] = []
    var currentURL: URL? = URL(string: "https://messaging-assets.ada.support/sdk/webview.html?handle=watchdog-test")
    override var url: URL? {
        currentURL
    }

    override func reload() -> WKNavigation? {
        loads += 1
        return nil
    }

    override func load(_ request: URLRequest) -> WKNavigation? {
        currentURL = request.url
        loads += 1
        return nil
    }

    override var isLoading: Bool {
        true
    }

    override func stopLoading() {
        stops += 1
    }

    override func evaluateJavaScript(
        _ javaScriptString: String,
        completionHandler _: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil,
    ) {
        capturedScripts.append(javaScriptString)
    }
}

@MainActor
final class LoadWatchdogHost {
    let scheduler = LoadWatchdogScheduler()
    let host: AdaWebHost
    let webView = WatchdogWebView()
    var errors: [AdaWebHost.AdaWebHostError] = []

    init(webSdk: AdaWebSdk = .legacy, headless: Bool = false, environment: AdaEnvironment? = nil) {
        host = AdaWebHost(handle: "watchdog-test", environment: environment, webSdk: webSdk, headless: headless)
        host.teardownWebView()
        host.webView = webView
        host.entryDocumentUrl = webView.url
        host.initialWebViewRequest = URLRequest(url: webView.url!)
        webView.onAttached = { [weak host] in host?.recoverContentProcessIfNeeded() }
        host.loadWatchdog = AdaLoadWatchdog(nowMs: { [scheduler] in scheduler.nowMs }, schedule: scheduler.schedule)
        host.webViewLoadingErrorCallback = { [weak self] error in
            if let error = error as? AdaWebHost.AdaWebHostError { self?.errors.append(error) }
        }
        host.scheduleContentRecoveryReset = scheduler.schedule
        host.startLoadWatchdog(for: webView)
    }
}

@MainActor
struct LoadWatchdogTests {
    @Test func `provisional cancellation after timeout reports only the timeout`() {
        let fixture = LoadWatchdogHost()
        fixture.scheduler.advance(to: 30000)
        fixture.host.webView(fixture.webView, didFailProvisionalNavigation: nil, withError: URLError(.cancelled))
        fixture.scheduler.advance(to: 90000)
        #expect(fixture.errors == [.webViewTimeout])
        #expect(fixture.webView.stops == 1)
    }

    @Test func `provisional cancellation keeps the replacement deadline`() {
        let fixture = LoadWatchdogHost()
        fixture.host.webView(fixture.webView, didFailProvisionalNavigation: nil, withError: URLError(.cancelled))
        fixture.scheduler.advance(to: 30000)
        #expect(fixture.errors == [.webViewTimeout])
    }

    @Test func `no suspension times out at thirty seconds`() {
        let fixture = LoadWatchdogHost()
        let scheduler = fixture.scheduler
        scheduler.advance(to: 29999)
        #expect(fixture.errors.isEmpty)
        scheduler.advance(to: 30000)
        #expect(fixture.errors == [.webViewTimeout])
        #expect(fixture.webView.stops == 1)
        #expect(scheduler.entries.isEmpty)
    }

    @Test func `late deadline rearms for remaining active budget`() {
        let fixture = LoadWatchdogHost()
        let scheduler = fixture.scheduler
        scheduler.advance(to: 10000)
        fixture.host.webView(fixture.webView, didCommit: nil)
        scheduler.resumeDeadlineFirst(at: 35000)
        #expect(fixture.errors.isEmpty)
        #expect(fixture.webView.stops == 0)
        #expect(scheduler.entries.contains { $0.dueMs == 54000 })
        scheduler.advance(to: 53999)
        #expect(fixture.errors.isEmpty)
        scheduler.advance(to: 54000)
        #expect(fixture.errors == [.webViewTimeout])
        #expect(fixture.webView.stops == 1)
        #expect(scheduler.entries.isEmpty)
    }

    @Test func `page finishes during rearm without error`() {
        let fixture = LoadWatchdogHost(webSdk: .messaging, environment: .production)
        let scheduler = fixture.scheduler
        scheduler.advance(to: 10000)
        scheduler.resumeDeadlineFirst(at: 35000)
        fixture.host.webView(fixture.webView, didFinish: nil)
        scheduler.advance(to: 90000)
        #expect(fixture.errors.isEmpty)
        #expect(fixture.webView.stops == 0)
        #expect(scheduler.entries.isEmpty)
    }

    @Test(arguments: [(5999.0, 30000.0), (6000.0, 35000.0)])
    func `suspension threshold extends the timeout only at five seconds`(sampleAt: Double, deadline: Double) {
        let fixture = LoadWatchdogHost()
        fixture.scheduler.nowMs = sampleAt
        fixture.host.loadWatchdog.sample()
        fixture.scheduler.advance(to: deadline - 1)
        #expect(fixture.errors.isEmpty)
        fixture.scheduler.advance(to: deadline)
        #expect(fixture.errors == [.webViewTimeout])
        #expect(fixture.webView.stops == 1)
        #expect(fixture.scheduler.entries.isEmpty)
    }

    @Test func `lifecycle samples alone do not suspend or postpone sampling`() {
        let scheduler = LoadWatchdogScheduler()
        let watchdog = AdaLoadWatchdog(nowMs: { scheduler.nowMs }, schedule: scheduler.schedule)
        var errors = 0
        watchdog.start(budgetMs: 30000, step: "requestStarted") { errors += 1 }
        for timeMs in stride(from: 100.0, through: 30000.0, by: 100) {
            scheduler.advance(to: timeMs)
            watchdog.sample()
        }
        #expect(errors == 1)
        #expect(scheduler.entries.isEmpty)
    }

    @Test func `superseded load ignores old callbacks`() {
        let scheduler = LoadWatchdogScheduler()
        let watchdog = AdaLoadWatchdog(nowMs: { scheduler.nowMs }, schedule: scheduler.schedule)
        var oldErrors = 0
        var newErrors = 0
        watchdog.start(budgetMs: 30000, step: "requestStarted") { oldErrors += 1 }
        let oldCallbacks = scheduler.entries
        scheduler.advance(to: 10000)
        watchdog.start(budgetMs: 30000, step: "requestStarted") { newErrors += 1 }
        for entry in oldCallbacks {
            entry.action()
        }
        scheduler.advance(to: 40000)
        #expect(oldErrors == 0)
        #expect(newErrors == 1)
        #expect(scheduler.entries.isEmpty)
    }

    @Test func `real navigation failure cancels rearmed deadline`() {
        let fixture = LoadWatchdogHost()
        fixture.scheduler.advance(to: 10000)
        fixture.scheduler.resumeDeadlineFirst(at: 35000)
        fixture.host.webView(fixture.webView, didFailProvisionalNavigation: nil, withError: URLError(.cannotFindHost))
        fixture.scheduler.advance(to: 90000)
        #expect(fixture.errors == [.webViewFailedToLoad])
        #expect(fixture.scheduler.entries.isEmpty)
    }

    @Test func `committed navigation cancellation after timeout reports only the timeout`() {
        let fixture = LoadWatchdogHost()
        var events: [[String: Any]] = []
        var subscribed: [[String: Any]] = []
        fixture.host.eventCallbacks = ["*": { events.append($0) }]
        fixture.host.addEventCallback("ada.webview.loadFailed") { subscribed.append($0) }
        fixture.host.webView(fixture.webView, didCommit: nil)
        fixture.scheduler.advance(to: 30000)
        #expect(fixture.errors == [.webViewTimeout])
        #expect(fixture.webView.stops == 1)

        let cancellation = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        fixture.host.webView(fixture.webView, didFail: nil, withError: cancellation)
        fixture.host.webView(fixture.webView, didFailProvisionalNavigation: nil, withError: cancellation)
        fixture.scheduler.advance(to: 90000)
        #expect(fixture.errors == [.webViewTimeout])
        let expected = ["event_name": "ada.webview.loadFailed", "error": "WebView load timed out"]
        #expect(events as? [[String: String]] == [expected])
        #expect(subscribed as? [[String: String]] == [expected])
        #expect(fixture.host.hasError)
        #expect(fixture.webView.stops == 1)
    }

    @Test func `committed navigation cancellation leaves the replacement deadline armed`() {
        let fixture = LoadWatchdogHost()
        var events: [String] = []
        fixture.host.eventCallbacks = ["*": { event in
            if let name = event["event_name"] as? String { events.append(name) }
        }]
        fixture.scheduler.advance(to: 10000)
        fixture.host.webView(fixture.webView, didCommit: nil)

        let cancellation = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        fixture.host.webView(fixture.webView, didFail: nil, withError: cancellation)
        #expect(fixture.errors.isEmpty)
        #expect(events.isEmpty)
        #expect(!fixture.host.hasError)
        fixture.scheduler.advance(to: 29999)
        #expect(fixture.errors.isEmpty)
        fixture.scheduler.advance(to: 30000)
        #expect(fixture.errors == [.webViewTimeout])
        #expect(fixture.webView.stops == 1)
        #expect(events == ["ada.webview.loadFailed"])
    }

    @Test func `committed navigation failure reports once and cancels the deadline`() {
        let fixture = LoadWatchdogHost()
        var events: [String] = []
        fixture.host.eventCallbacks = ["*": { event in
            if let name = event["event_name"] as? String { events.append(name) }
        }]
        fixture.scheduler.advance(to: 10000)
        fixture.host.webView(fixture.webView, didCommit: nil)
        fixture.host.webView(fixture.webView, didFail: nil, withError: URLError(.networkConnectionLost))
        #expect(fixture.host.hasError)
        #expect(fixture.errors == [.webViewFailedToLoad])
        #expect(events == ["ada.webview.loadFailed"])
        #expect(fixture.scheduler.entries.isEmpty)
        fixture.scheduler.advance(to: 90000)
        #expect(fixture.errors == [.webViewFailedToLoad])
    }

    @Test func `committed failure from another webview leaves the host deadline armed`() {
        let fixture = LoadWatchdogHost()
        fixture.host.webView(WKWebView(), didFail: nil, withError: URLError(.networkConnectionLost))
        #expect(fixture.errors.isEmpty)
        fixture.scheduler.advance(to: 30000)
        #expect(fixture.errors == [.webViewTimeout])
        #expect(fixture.scheduler.entries.isEmpty)
    }

    @Test func `teardown cancels sampling and queued deadline`() {
        let fixture = LoadWatchdogHost()
        let callbacks = fixture.scheduler.entries
        fixture.host.teardownWebView()
        fixture.scheduler.nowMs = 35000
        for entry in callbacks {
            entry.action()
        }
        #expect(fixture.errors.isEmpty)
        #expect(fixture.scheduler.entries.isEmpty)
    }

    @Test func `resume notification and late timer count one gap`() {
        let fixture = LoadWatchdogHost()
        let scheduler = fixture.scheduler
        scheduler.advance(to: 10000)
        scheduler.nowMs = 35000
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        scheduler.advance(to: 35000)
        #expect(fixture.errors.isEmpty)
        scheduler.advance(to: 54000)
        #expect(fixture.errors == [.webViewTimeout])
    }

    @Test func `multiple suspensions accumulate without resetting budget`() {
        let fixture = LoadWatchdogHost()
        let scheduler = fixture.scheduler
        scheduler.advance(to: 10000)
        scheduler.resumeDeadlineFirst(at: 35000)
        scheduler.advance(to: 40000)
        scheduler.nowMs = 60000
        scheduler.advance(to: 60000)
        #expect(fixture.errors.isEmpty)
        scheduler.advance(to: 72999)
        #expect(fixture.errors.isEmpty)
        scheduler.advance(to: 73000)
        #expect(fixture.errors == [.webViewTimeout])
    }

    @Test func `suspension does not refund an already spent budget`() {
        let fixture = LoadWatchdogHost()
        fixture.scheduler.advance(to: 29000)
        fixture.scheduler.resumeDeadlineFirst(at: 35000)
        #expect(fixture.errors == [.webViewTimeout])
        #expect(fixture.scheduler.entries.isEmpty)
    }
}

@MainActor
struct ContentProcessRecoveryTests {
    @Test func `termination before cookie setup completes loads the original request once`() throws {
        let fixture = LoadWatchdogHost()
        let request = try URLRequest(url: #require(fixture.webView.url))
        let finishCookieSetup = fixture.host.prepareEntryRequest(request, into: fixture.webView)
        fixture.webView.currentURL = nil
        let window = UIWindow()
        window.addSubview(fixture.webView)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        fixture.host.webViewWebContentProcessDidTerminate(fixture.webView)
        finishCookieSetup()
        #expect(fixture.webView.loads == 1)
        #expect(fixture.webView.url == request.url)
        #expect(fixture.errors.isEmpty)
        fixture.host.teardownWebView()
    }

    @Test func `network recovery does not bypass deferred content recovery`() {
        let fixture = LoadWatchdogHost()
        let window = UIWindow()
        window.addSubview(fixture.webView)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        fixture.host.webViewWebContentProcessDidTerminate(fixture.webView)
        fixture.host.returnToOnline()
        #expect(fixture.host.webView === fixture.webView)
        #expect(fixture.webView.loads == 0)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(fixture.webView.loads == 1)
        #expect(fixture.errors.isEmpty)
        fixture.host.teardownWebView()
    }

    @Test func `terminated process cannot deliver an old bridge reply into the reload`() {
        let fixture = LoadWatchdogHost()
        let window = UIWindow()
        window.addSubview(fixture.webView)
        let bridge = fixture.host.bridgeHandler
        bridge.trustedOrigin = "https://messaging-assets.ada.support"
        bridge.trustedDocumentUrl = fixture.webView.url?.absoluteString
        let oldTicket = bridge.captureDocumentTicket(for: fixture.webView)
        #expect(oldTicket != nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        fixture.host.webViewWebContentProcessDidTerminate(fixture.webView)
        #expect(fixture.webView.loads == 1)
        #expect(bridge.captureDocumentTicket(for: fixture.webView) != oldTicket)
        fixture.host.teardownWebView()
    }

    @Test func `headless termination reloads once while the app is active`() {
        let fixture = LoadWatchdogHost(webSdk: .messaging, headless: true)
        fixture.host.launchHeadlessWebSupport()
        #expect(fixture.webView.superview === fixture.host.headlessContainer)
        #expect(fixture.webView.window == nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        (fixture.host as WKNavigationDelegate).webViewWebContentProcessDidTerminate?(fixture.webView)
        #expect(fixture.webView.loads == 1)
        #expect(fixture.errors.isEmpty)
        fixture.host.teardownWebView()
    }

    @Test func `headless termination reports one failure when recovery is exhausted`() {
        let fixture = LoadWatchdogHost(webSdk: .messaging, headless: true)
        var events: [String] = []
        fixture.host.eventCallbacks = ["*": { event in
            if let name = event["event_name"] as? String { events.append(name) }
        }]
        fixture.host.launchHeadlessWebSupport()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        let delegate = fixture.host as WKNavigationDelegate
        delegate.webViewWebContentProcessDidTerminate?(fixture.webView)
        delegate.webViewWebContentProcessDidTerminate?(fixture.webView)
        delegate.webViewWebContentProcessDidTerminate?(fixture.webView)
        delegate.webViewWebContentProcessDidTerminate?(fixture.webView)
        #expect(fixture.webView.loads == 2)
        #expect(fixture.errors == [.webViewFailedToLoad])
        #expect(events == ["ada.webview.contentProcessTerminated", "ada.webview.loadFailed"])
        #expect(fixture.scheduler.entries.isEmpty)
        fixture.host.teardownWebView()
    }

    @Test(arguments: [nil, "about:blank"] as [String?])
    func `termination with no current URL loads the original request`(_ url: String?) {
        let fixture = LoadWatchdogHost()
        let originalURL = fixture.webView.url
        fixture.webView.currentURL = url.flatMap(URL.init(string:))
        let window = UIWindow()
        window.addSubview(fixture.webView)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        fixture.host.webViewWebContentProcessDidTerminate(fixture.webView)
        #expect(fixture.webView.loads == 1)
        #expect(fixture.webView.url == originalURL)
        #expect(fixture.errors.isEmpty)
        fixture.host.teardownWebView()
    }

    @Test func `foreground content termination reloads once without a failure`() {
        let fixture = LoadWatchdogHost()
        let window = UIWindow()
        window.addSubview(fixture.webView)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        let oldTimers = fixture.scheduler.entries
        (fixture.host as WKNavigationDelegate).webViewWebContentProcessDidTerminate?(fixture.webView)
        #expect(fixture.webView.loads == 1)
        for timer in oldTimers {
            timer.action()
        }
        #expect(fixture.errors.isEmpty)
        fixture.host.teardownWebView()
    }

    @Test func `background termination stops watchdog and recovers on activation`() {
        let fixture = LoadWatchdogHost()
        let window = UIWindow()
        window.addSubview(fixture.webView)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        (fixture.host as WKNavigationDelegate).webViewWebContentProcessDidTerminate?(fixture.webView)
        #expect(fixture.webView.loads == 0)
        #expect(fixture.scheduler.entries.isEmpty)
        fixture.scheduler.advance(to: 90000)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(fixture.webView.loads == 1)
        #expect(fixture.errors.isEmpty)
        fixture.host.teardownWebView()
    }

    @Test func `third termination reports one failure and a stable load restores the budget`() {
        let fixture = LoadWatchdogHost(webSdk: .messaging, environment: .production)
        let window = UIWindow()
        window.addSubview(fixture.webView)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        let delegate = fixture.host as WKNavigationDelegate
        delegate.webViewWebContentProcessDidTerminate?(fixture.webView)
        delegate.webViewWebContentProcessDidTerminate?(fixture.webView)
        #expect(fixture.webView.loads == 2)
        fixture.host.webView(fixture.webView, didFinish: nil)
        fixture.scheduler.advance(to: 60000)
        delegate.webViewWebContentProcessDidTerminate?(fixture.webView)
        delegate.webViewWebContentProcessDidTerminate?(fixture.webView)
        delegate.webViewWebContentProcessDidTerminate?(fixture.webView)
        #expect(fixture.webView.loads == 4)
        #expect(fixture.errors == [.webViewFailedToLoad])
        #expect(fixture.scheduler.entries.isEmpty)
        let error = NSError(domain: WKError.errorDomain, code: WKError.webContentProcessTerminated.rawValue)
        fixture.host.webView(fixture.webView, didFail: nil, withError: error)
        fixture.host.webView(fixture.webView, didFailProvisionalNavigation: nil, withError: error)
        #expect(fixture.errors == [.webViewFailedToLoad])
        fixture.host.teardownWebView()
    }
}
