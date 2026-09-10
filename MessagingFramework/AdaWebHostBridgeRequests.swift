//
//  AdaWebHostBridgeRequests.swift
//  AdaMessaging
//
//  The curated request/response bridge surface (EXP-1225): a fixed allowlist of
//  reads and writes/triggers the host can drive, each answered with exactly one
//  `AdaBridgeRequestResult`. The method set and its curation mirror
//  `BRIDGE_REQUEST_METHODS` in `packages/sdk/src/mobile-webview-runtime.ts`, so
//  iOS, Android, React Native and the web runtime expose the same capabilities.
//

import Foundation
import WebKit

/// Theme the host can push to the runtime through ``AdaWebHost/setTheme(_:completion:)``.
public enum AdaChatTheme: String, Sendable {
    case light
    case dark
    case auto
}

public extension AdaWebHost {
    // -----------------------------------------------------------------------
    // MARK: - Reads (public models only)

    // -----------------------------------------------------------------------

    /// Reads the runtime's public info model (`adaEmbed.getInfo`).
    func getInfo(completion: @escaping (AdaBridgeRequestResult) -> Void) {
        performBridgeRequest(method: "getInfo", completion: completion)
    }

    /// Whether the chat window is currently open (`adaEmbed.isOpen`).
    func isOpen(completion: @escaping (AdaBridgeRequestResult) -> Void) {
        performBridgeRequest(method: "isOpen", completion: completion)
    }

    /// Reads the non-sensitive meta-fields (`adaEmbed.getMetaFields`). Never
    /// returns `sensitiveMetaFields` — the web-side facade excludes them.
    func getMetaFields(completion: @escaping (AdaBridgeRequestResult) -> Void) {
        performBridgeRequest(method: "getMetaFields", completion: completion)
    }

    /// Reads the public conversation info model (`adaEmbed.getConversation`).
    func getConversation(completion: @escaping (AdaBridgeRequestResult) -> Void) {
        performBridgeRequest(method: "getConversation", completion: completion)
    }

    /// Reads the public message models (`adaEmbed.getMessages`).
    func getMessages(completion: @escaping (AdaBridgeRequestResult) -> Void) {
        performBridgeRequest(method: "getMessages", completion: completion)
    }

    // -----------------------------------------------------------------------
    // MARK: - Writes / triggers

    // -----------------------------------------------------------------------

    /// Requests the chat window open (`adaEmbed.open`). The Messaging webview is
    /// always mounted, so the runtime registers no `open` invoker and resolves
    /// `unsupported` rather than a no-op success.
    func open(completion: ((AdaBridgeRequestResult) -> Void)? = nil) {
        performBridgeRequest(method: "open", completion: completion ?? { _ in })
    }

    /// Requests the chat window closed (`adaEmbed.close`). The Messaging webview is
    /// always mounted, so the runtime registers no `close` invoker and resolves
    /// `unsupported` rather than a no-op success.
    func close(completion: ((AdaBridgeRequestResult) -> Void)? = nil) {
        performBridgeRequest(method: "close", completion: completion ?? { _ in })
    }

    /// Requests a toggle of the chat window (`adaEmbed.toggle`). The Messaging webview
    /// is always mounted, so the runtime registers no `toggle` invoker and resolves
    /// `unsupported` rather than a no-op success.
    func toggle(completion: ((AdaBridgeRequestResult) -> Void)? = nil) {
        performBridgeRequest(method: "toggle", completion: completion ?? { _ in })
    }

    /// Triggers a proactive message by key (`adaEmbed.triggerProactive`).
    func triggerProactive(
        messageKey: String,
        params: [String: String]? = nil,
        completion: ((AdaBridgeRequestResult) -> Void)? = nil,
    ) {
        var requestParams: [String: Any] = ["messageKey": messageKey]
        if let params {
            requestParams["params"] = params
        }
        performBridgeRequest(
            method: "triggerProactive",
            params: requestParams,
            completion: completion ?? { _ in },
        )
    }

    /// Triggers a specific answer by id (`adaEmbed.triggerAnswer`).
    func triggerAnswer(answerId: String, completion: ((AdaBridgeRequestResult) -> Void)? = nil) {
        performBridgeRequest(
            method: "triggerAnswer",
            params: ["answerId": answerId],
            completion: completion ?? { _ in },
        )
    }

    /// Triggers the greeting (`adaEmbed.triggerGreeting`). Pass a `handle` to
    /// greet as a different bot; omit it for the current one.
    func triggerGreeting(handle: String? = nil, completion: ((AdaBridgeRequestResult) -> Void)? = nil) {
        let params: [String: Any]? = handle.map { ["handle": $0] }
        performBridgeRequest(
            method: "triggerGreeting",
            params: params,
            completion: completion ?? { _ in },
        )
    }

    /// Dismisses the active proactive campaign (`adaEmbed.closeCampaign`).
    func closeCampaign(completion: ((AdaBridgeRequestResult) -> Void)? = nil) {
        performBridgeRequest(method: "closeCampaign", completion: completion ?? { _ in })
    }

    /// Sets the chat theme (`adaEmbed.setTheme`). Web-owned and meaningful on
    /// mobile, so it stays on the allowlist even though native owns presentation.
    func setTheme(_ theme: AdaChatTheme, completion: ((AdaBridgeRequestResult) -> Void)? = nil) {
        performBridgeRequest(
            method: "setTheme",
            params: ["theme": theme.rawValue],
            completion: completion ?? { _ in },
        )
    }

    // -----------------------------------------------------------------------
    // MARK: - Dispatch

    // -----------------------------------------------------------------------

    /// Queues a curated request until the runtime is ready, then issues it. The
    /// legacy remote host page runs embed-2 with no correlated response channel,
    /// so it answers `unsupported` rather than injecting a request nothing can
    /// reply to — an explicit signal, not silent drift.
    private func performBridgeRequest(
        method: String,
        params: [String: Any]? = nil,
        completion: @escaping (AdaBridgeRequestResult) -> Void,
    ) {
        guard usesBridgeRuntime else {
            completion(.unsupported)
            return
        }
        // Bound the PRE-ready queue (and its per-request main-queue backstops) at
        // registration: dispatchBridgeCommandWhenReady queues each request until sdk.ready, so
        // a host firing reads faster than the runtime answers would grow pendingCommands (and
        // the ~40s timers) without bound — sendBridgeRequest's maxPendingBridgeRequests only
        // applies AFTER dispatch, which never happens pre-ready. Reject the (cap+1)th now,
        // matching RN's registration-time gate and Android.
        if queuedBridgeRequestCount >= AdaBridgeHandler.maxPendingBridgeRequests {
            completion(.failure("Too many bridge requests are awaiting a response"))
            return
        }
        queuedBridgeRequestCount += 1
        // Decrement exactly once when the request LEAVES the queued phase — either it
        // dispatches (the post-dispatch map then bounds it) or it settles while still queued.
        var leftQueue = false
        let leaveQueue: () -> Void = { [weak self] in
            if leftQueue { return }
            leftQueue = true
            self?.queuedBridgeRequestCount -= 1
        }
        // Settle exactly once, always, with two backstops that hand off at dispatch.
        // Both run on the main queue, so `didSettle`/`didDispatch` race nothing.
        var didSettle = false
        var didDispatch = false
        let settleOnce: (AdaBridgeRequestResult) -> Void = { result in
            if didSettle { return }
            didSettle = true
            completion(result)
        }
        // QUEUED-phase backstop: dispatchBridgeCommandWhenReady may never run its closure
        // (the runtime never becomes ready, or the queue is cleared on teardown), so
        // without this the caller would hang. `didDispatch` disarms it once the request
        // dispatches — otherwise, armed from the PUBLIC call, it would fire before the
        // in-flight timeout whenever the queue wait exceeded the 5s grace and report
        // "timed out before ready" for a request that did dispatch, dropping the real reply.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AdaBridgeHandler.bridgeRequestTimeout + 5,
        ) {
            if didDispatch { return }
            // Settle the completion, but do NOT free the pre-ready slot here: the queued
            // closure still sits in pendingCommands until the runtime drains it, so freeing
            // the slot now would let a host re-fill it every timeout cycle and grow the queue
            // without bound. The slot is released only when the closure actually leaves the
            // queue and runs — the dispatch closure below, whether at ready or when a rebuilt
            // runtime drains the pendingCommands that survive teardown.
            settleOnce(.failure("Bridge request timed out before the runtime was ready"))
        }
        dispatchBridgeCommandWhenReady { [bridgeHandler] webView in
            // This runs when the queued command drains at sdk.ready (or inline if already
            // ready), so the request has now LEFT the queue — free its pre-ready slot here,
            // BEFORE the didSettle short-circuit, so a request the queued backstop already
            // settled still releases its slot when it drains.
            leaveQueue()
            // If the queued-phase backstop already settled this request (readiness took
            // too long), do NOT execute it — a timed-out trigger must not still fire once
            // the runtime finally becomes ready.
            if didSettle { return }
            didDispatch = true
            // DISPATCH-phase backstop, armed from HERE so the queue wait is excluded from
            // its window. This is also the only settlement independent of the handler's
            // lifetime: sendBridgeRequest's own in-flight timer captures the handler
            // WEAKLY and no-ops if the host + WebView are torn down before the reply, which
            // would otherwise leave the caller unsettled forever now that the queued-phase
            // backstop is disarmed.
            DispatchQueue.main.asyncAfter(
                deadline: .now() + AdaBridgeHandler.bridgeRequestTimeout + 5,
            ) {
                settleOnce(.failure("Bridge request timed out"))
            }
            bridgeHandler.sendBridgeRequest(
                method: method,
                params: params,
                to: webView,
                completion: settleOnce,
            )
        }
    }
}
