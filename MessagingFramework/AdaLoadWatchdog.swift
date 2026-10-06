import Darwin
import Foundation
import UIKit
import WebKit

@MainActor
final class AdaLoadWatchdog {
    static let sampleIntervalMs = 1000.0
    static let suspensionThresholdMs = 5000.0

    struct Suspension {
        let latenessMs: Double
        let step: String
    }

    typealias Schedule = (Double, @escaping @MainActor () -> Void) -> (() -> Void)

    private let nowMs: () -> Double
    private let schedule: Schedule
    private var cancelSample: (() -> Void)?
    private var cancelDeadline: (() -> Void)?
    private var onTimeout: (() -> Void)?
    private var generation = 0
    private var startedAtMs = 0.0
    private var nextSampleAtMs = 0.0
    private var suspendedMs = 0.0
    private var budgetMs = 0.0
    private var step = ""
    private(set) var lastSuspension: Suspension?

    init(
        nowMs: @escaping () -> Double = {
            // This monotonic clock includes device sleep, so a resumed sample can detect the full gap.
            Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000
        },
        schedule: @escaping Schedule = { delayMs, action in
            let work = DispatchWorkItem { MainActor.assumeIsolated { action() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delayMs / 1000, execute: work)
            return { work.cancel() }
        },
    ) {
        self.nowMs = nowMs
        self.schedule = schedule
    }

    func start(budgetMs: Double, step: String, onTimeout: @escaping () -> Void) {
        stop()
        self.budgetMs = max(0, budgetMs)
        self.step = step
        self.onTimeout = onTimeout
        startedAtMs = nowMs()
        nextSampleAtMs = startedAtMs + Self.sampleIntervalMs
        suspendedMs = 0
        lastSuspension = nil
        scheduleSample()
        scheduleDeadline(afterMs: self.budgetMs)
    }

    func stop() {
        generation += 1
        cancelSample?()
        cancelDeadline?()
        cancelSample = nil
        cancelDeadline = nil
        onTimeout = nil
    }

    func reached(step: String) {
        sample()
        self.step = step
    }

    func sample() {
        guard onTimeout != nil else { return }
        let now = nowMs()
        guard now >= nextSampleAtMs else { return }
        let latenessMs = now - nextSampleAtMs
        if latenessMs >= Self.suspensionThresholdMs {
            suspendedMs += latenessMs
            lastSuspension = Suspension(latenessMs: latenessMs, step: step)
        }
        nextSampleAtMs = now + Self.sampleIntervalMs
        cancelSample?()
        scheduleSample()
    }

    private func scheduleSample() {
        let ticket = generation
        cancelSample = schedule(max(0, nextSampleAtMs - nowMs())) { [weak self] in
            guard let self, generation == ticket, onTimeout != nil else { return }
            sample()
        }
    }

    private func scheduleDeadline(afterMs delayMs: Double) {
        let ticket = generation
        cancelDeadline = schedule(delayMs) { [weak self] in
            guard let self, generation == ticket, let onTimeout else { return }
            sample()
            let remainingMs = budgetMs - (nowMs() - startedAtMs - suspendedMs)
            if remainingMs > 0 {
                scheduleDeadline(afterMs: remainingMs)
            } else {
                stop()
                onTimeout()
            }
        }
    }
}

extension AdaWebHost {
    func startLoadWatchdog(for webView: WKWebView) {
        stopLoadWatchdog()
        loadWatchdog.start(budgetMs: webViewTimeout * 1000, step: "requestStarted") { [weak self, weak webView] in
            guard let self, let webView, self.webView === webView else { return }
            stopLoadWatchdog()
            contentProcessRecoveryFailed = contentProcessRecoveryFailed || contentProcessRecoveryInFlight
            contentProcessRecoveryInFlight = false
            if !hasError, webView.isLoading {
                hasError = true
                webView.stopLoading()
                webViewLoadingErrorCallback?(AdaWebHostError.webViewTimeout)
                let event: [String: Any] = ["event_name": "ada.webview.loadFailed", "error": "WebView load timed out"]
                dispatchEventToSubscribers(event, rawData: rawSdkEventData(event))
                eventCallbacks?["*"]?(event)
            }
        }
        observeApplicationLifecycle()
    }

    func stopLoadWatchdog() {
        loadWatchdog.stop()
    }
}
