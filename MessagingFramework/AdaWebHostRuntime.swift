import Foundation
import UIKit
import WebKit

// MARK: - WKScriptMessageHandler

extension AdaWebHost: WKScriptMessageHandler {
    /// When the webview loads up, it'll pass back a message to here.
    /// Fire our initialize methods when that happens.
    public func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        let messageName = message.name
        if messageName == "embedReady" {
            guard bridgeHandler.isTrustedSource(of: message) else { return }
            markWebHostReady()
        } else if let webViewLoadingErrorCallback,
                  messageName == "chatFrameTimeoutCallbackHandler"
        {
            webViewLoadingErrorCallback(AdaWebHostError.webViewTimeout)
        } else if let zdChatterAuthCallback, messageName == "zdChatterAuthCallbackHandler" {
            zdChatterAuthCallback { token in
                guard let data = try? JSONSerialization.data(withJSONObject: token, options: .fragmentsAllowed),
                      let tokenJson = String(data: data, encoding: .utf8) else { return }
                self.evalJS("if(window.zdTokenCallback){window.zdTokenCallback(\(tokenJson));}")
            }
        } else if messageName == "eventCallbackHandler",
                  let event = message.body as? [String: Any]
        {
            dispatchEventToSubscribers(event, rawData: rawSdkEventData(event))

            if let eventName = event["event_name"] as? String,
               let specificCallback = eventCallbacks?[eventName]
            {
                specificCallback(event)
            }

            if let wildcardCallback = eventCallbacks?["*"] {
                wildcardCallback(event)
            }
        }
    }
}

// MARK: - Multi-subscriber event callbacks

public extension AdaWebHost {
    /// Registers `callback` for events named `eventName`; `"*"` (the default)
    /// receives every event. Unlike ``eventCallbacks`` — one closure per key,
    /// replaced wholesale — any number of callbacks can subscribe to the same
    /// event. Mirrors Android's `addEventCallback`.
    @discardableResult
    func addEventCallback(
        _ eventName: String = "*",
        callback: @escaping (_ event: [String: Any]) -> Void,
    ) -> AdaEventSubscription {
        let subscription = AdaEventSubscription()
        eventCallbackSubscriptions[eventName, default: []]
            .append((token: ObjectIdentifier(subscription), callback: callback))
        return subscription
    }

    /// Removes exactly the callback that ``addEventCallback(_:callback:)``
    /// returned `subscription` for. Unknown tokens are a no-op. Mirrors
    /// Android's `removeEventCallback`.
    func removeEventCallback(_ subscription: AdaEventSubscription) {
        let token = ObjectIdentifier(subscription)
        for (eventName, entries) in eventCallbackSubscriptions {
            let remaining = entries.filter { $0.token != token }
            if remaining.count != entries.count {
                eventCallbackSubscriptions[eventName] = remaining.isEmpty ? nil : remaining
            }
        }
    }

    /// Removes every callback registered through ``addEventCallback(_:callback:)``
    /// for `eventName` (`"*"` by default). Mirrors Android's `removeEventCallbacks`.
    func removeEventCallbacks(_ eventName: String = "*") {
        eventCallbackSubscriptions[eventName] = nil
    }

    /// Registers a raw sink that receives every SDK event as its key plus its
    /// JSON-encoded data, without knowing keys in advance. Mirrors Android's
    /// `addSdkEventCallback`.
    @discardableResult
    func addSdkEventCallback(
        _ callback: @escaping (_ key: String, _ data: String?) -> Void,
    ) -> AdaEventSubscription {
        let subscription = AdaEventSubscription()
        sdkEventCallbackSubscriptions.append((token: ObjectIdentifier(subscription), callback: callback))
        return subscription
    }

    /// Removes exactly the raw sink that ``addSdkEventCallback(_:)`` returned
    /// `subscription` for. Mirrors Android's `removeSdkEventCallback`.
    func removeSdkEventCallback(_ subscription: AdaEventSubscription) {
        let token = ObjectIdentifier(subscription)
        sdkEventCallbackSubscriptions.removeAll { $0.token == token }
    }
}

extension AdaWebHost {
    /// Fans one event out to the multi-subscriber registries: raw sinks first,
    /// then the callbacks keyed by the event's name, then the `"*"` catch-all
    /// (Android's dispatch order). The single-closure ``eventCallbacks``
    /// dictionary is NOT dispatched here — each emission site keeps its exact
    /// historical delivery for that surface.
    func dispatchEventToSubscribers(_ event: [String: Any], rawData: String?) {
        let name = event["event_name"] as? String ?? ""
        for entry in sdkEventCallbackSubscriptions {
            entry.callback(name, rawData)
        }
        for entry in eventCallbackSubscriptions[name] ?? [] {
            entry.callback(event)
        }
        if name != "*" {
            for entry in eventCallbackSubscriptions["*"] ?? [] {
                entry.callback(event)
            }
        }
    }

    /// JSON-encodes an event payload for the raw ``addSdkEventCallback(_:)``
    /// sinks. Strings pass through unquoted, matching Android's `optString`
    /// treatment of the bridge's `data` field.
    func rawSdkEventData(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value)
            || value is NSNumber || value is NSNull,
            let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
            let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }
}

// MARK: - JavaScript evaluation

extension AdaWebHost {
    func initializeWebView() {
        do {
            let metaFieldsData = try JSONSerialization.data(withJSONObject: metafields, options: [])
            let metaFieldsJson = String(data: metaFieldsData, encoding: .utf8) ?? "{}"

            let sensitiveMetaFieldsData = try JSONSerialization.data(withJSONObject: sensitiveMetafields, options: [])
            let sensitiveMetaFieldsJson = String(data: sensitiveMetaFieldsData, encoding: .utf8) ?? "{}"
            let hostTelemetryJson = hostTelemetryJSONString() ?? "{}"

            // JSON-encode all developer-supplied string config values so that
            // characters like `"`, `\`, and newlines can't break the JS context.
            let handleJson = jsonStr(handle)
            let embedStartConfig = legacyEmbedStartConfig()
            let clusterJson = jsonStr(embedStartConfig.cluster)
            let domainJson = jsonStr(embedStartConfig.domain)
            let languageJson = jsonStr(language)
            let stylesJson = jsonStr(styles)
            let greetingJson = jsonStr(greeting)
            // A whitespace-only token must never seed a bogus device_token/device_os binding
            // on the first chatter: a blank string is falsy so embed-2 skips it, but a
            // whitespace-only token is truthy and would fold through. Mirror Android's
            // isNotBlank gate and RN's isNonBlankToken — emit the init-time deviceToken start
            // option and the post-ready setter call only for a non-blank token. (EXP-1223)
            let deviceTokenJson = jsonStr(deviceToken)
            let hasDeviceToken =
                !deviceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let deviceTokenStartOption = hasDeviceToken ? "deviceToken: \(deviceTokenJson)," : ""
            let deviceTokenSetterCall =
                hasDeviceToken ? "adaEmbed.setDeviceToken(\(deviceTokenJson));" : ""

            let startBody = """
                window.adaEmbed.start({
                    handle: \(handleJson),
                    cluster: \(clusterJson),
                    domain: \(domainJson),
                    language: \(languageJson),
                    styles: \(stylesJson),
                    greeting: \(greetingJson),
                    metaFields: \(metaFieldsJson),
                    hostTelemetry: \(hostTelemetryJson),
                    sensitiveMetaFields: \(sensitiveMetaFieldsJson),
                    \(deviceTokenStartOption)
                    parentElement: "parent-element",
                    onAdaEmbedLoaded: () => {
                        // Init-time deviceToken (above) pre-populates the device_token/
                        // device_os chatter variables on the FIRST chatter via embed-2's
                        // StartOptions.deviceToken (EXP-1223). Actual push registration
                        // still happens here: this setter's post-ready data_storage write
                        // is what binds the device, and it is also the N-1 fallback for an
                        // embed-2 build too old to read the start option.
                        \(deviceTokenSetterCall)
                        adaEmbed.subscribeEvent("ada:chat_frame_timeout", (data, context) => {
                            window.webkit.messageHandlers
                                .chatFrameTimeoutCallbackHandler
                                .postMessage("chatFrameTimeout");
                        });
                    },
                    zdChatterAuthCallback: function(callback) {
                        window.zdTokenCallback = callback;
                        window.webkit.messageHandlers.zdChatterAuthCallbackHandler.postMessage("getToken");
                    },
                    eventCallbacks: {
                        "*": (event) => window.webkit.messageHandlers.eventCallbackHandler.postMessage(event)
                    }
                });
            """
            // Under the pull transport the injected legacy bootstrap script
            // itself holds and releases `adaEmbed.start` around its bounded
            // pre-start step, so start is evaluated directly here (no native
            // resolved-mode barrier wrapper).
            evalJS(startBody)
        } catch {
            debugPrint("Serialization error: \(error.localizedDescription)")
        }
    }

    /// Returns a JSON-encoded string literal (with surrounding quotes and proper escaping)
    /// for safe embedding in an evaluated JavaScript string.
    func jsonStr(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return json
    }

    /// The legacy host page's `adaEmbed.*` command sink. Commands issued before the page
    /// reports ready are queued and replayed, so the document they land in is decided at
    /// replay time, not at call time — and `webHostLoaded` alone does not notice a top-level
    /// navigation that replaced the page in place. `setSensitiveMetaFields` travels this path,
    /// so the check is on the live main document, not just on the WebView being alive.
    ///
    /// Gated on the same document ticket every bridge injection is gated on, not on the origin:
    /// the legacy page's own origin also serves whatever else the bot's host does, and the
    /// build-version parameters the page reads ride its query, so an origin comparison passes a
    /// same-origin replacement carrying parameters an attacker chose. Fails closed — a mount that
    /// pins no entry document loaded no page either, so there is nothing to command.
    func evalJS(_ toRun: String) {
        guard webHostLoaded else {
            pendingCommands.append { [weak self] in
                self?.evalJS(toRun)
            }
            return
        }
        guard let webView, bridgeHandler.captureDocumentTicket(for: webView) != nil else { return }

        webView.evaluateJavaScript(toRun) { _, error in
            if let err = error {
                debugPrint(err)
            }
        }
    }

    private func markWebHostReady() {
        hasDisplayedPage = true
        contentProcessRecoveryInFlight = false
        contentProcessRecoveryFailed = false
        hasError = false
        stopLoadWatchdog()
        if let webView { scheduleStableContentRecoveryReset(for: webView) }
        webHostLoaded = true
    }

    func returnToOnline() {
        guard !isInOfflineMode else { return }
        if let offlineVC = offlineViewController {
            offlineVC.view.removeFromSuperview()
            offlineViewController = nil
        }

        if contentProcessRecoveryPending {
            recoverContentProcessIfNeeded()
            return
        }

        if contentProcessRecoveryInFlight || contentProcessRecoveryFailed || (!webHostLoaded && hasDisplayedPage) {
            cancelContentRecoveryReset?()
            cancelContentRecoveryReset = nil
            contentProcessRecoveries = 0
            contentProcessRecoveryFailed = false
            hasError = false
            contentProcessRecoveryPending = true
            recoverContentProcessIfNeeded()
            return
        }

        if !webHostLoaded, !hasDisplayedPage {
            setupWebView()
        }
    }
}

// MARK: - Keyboard handling

extension AdaWebHost {
    @objc func keyboardWillHide(notification _: NSNotification) {
        if #available(iOS 12.0, *) {
            guard let webView else { return }

            // fix: for_where — replaced `if` inside `for` with `where` clause
            for view in webView.subviews where view.isKind(of: NSClassFromString("WKScrollView") ?? UIScrollView.self) {
                guard let scroller = view as? UIScrollView else { return }
                scroller.contentOffset = CGPoint(x: 0, y: 0)
            }
        }
    }
}

// MARK: - Utilities

extension AdaWebHost {
    func findViewController(from view: UIView) -> UIViewController? {
        if let nextResponder = view.next as? UIViewController {
            nextResponder
        } else if let nextResponder = view.next as? UIView {
            findViewController(from: nextResponder)
        } else {
            nil
        }
    }
}

// MARK: - AdaBridgeDelegate

extension AdaWebHost: AdaBridgeDelegate {
    /// Called when the Ada SDK signals it is ready to accept commands (new bridge path).
    public func adaBridgeDidBecomeReady(_: AdaBridgeHandler) {
        // The mount consumed the one-shot identityToken (or the in-script guard
        // withheld it); memo the spent token so a WebView rebuild never re-arms
        // it, then remove the document-start registration so no later document
        // can replay the spent credential. Key the memo on the token actually armed
        // into this document (`armedIdentityToken`), not on `webviewConfigUserScript`:
        // the retained-only re-arm leaves that non-nil without a token, so reading it
        // here would memo a fresh, never-injected token as consumed and strand an
        // identified session as anonymous after an in-place reload.
        if let armed = armedIdentityToken, !armed.isEmpty {
            consumedIdentityToken = armed
        }
        disarmWebviewConfigScript()
        markWebHostReady()
        let event: [String: Any] = ["event_name": "sdk.ready", "web_sdk": webSdk.rawValue]
        dispatchEventToSubscribers(event, rawData: rawSdkEventData(event))
        if let callbacks = eventCallbacks {
            callbacks["sdk.ready"]?(event)
            callbacks["*"]?(event)
        }
        // Send device token once SDK is ready (pending commands are flushed by webHostLoaded didSet).
        if !deviceToken.isEmpty, let webView {
            bridgeHandler.setDeviceToken(deviceToken, to: webView)
        }
        // Init-time sensitive meta-fields must travel through the bridge — only the legacy
        // `adaEmbed.start(...)` payload carried them before, so the Messaging runtime
        // silently dropped them. Never sent via the URL. Mirrors Android's
        // `enqueueInitialBridgeState`.
        if !sensitiveMetafields.isEmpty, let webView {
            bridgeHandler.setSensitiveMetaFields(sensitiveMetafields, to: webView)
        }
    }

    public func adaBridgeDidRequestZendeskChatterAuth(_ handler: AdaBridgeHandler) {
        adaBridgeDidRequestZendeskChatterAuth(handler, requestId: nil)
    }

    public func adaBridgeDidRequestZendeskChatterAuth(_ handler: AdaBridgeHandler, requestId: String?) {
        guard let webView else { return }
        zdChatterAuthRequestSeq &+= 1
        let requestSeq = zdChatterAuthRequestSeq
        guard let zdChatterAuthCallback else {
            // Resolve immediately rather than burning the SDK's 10s auth timeout on a host
            // that has no token to give — the same guard the React Native handler applies.
            handler.sendZendeskChatterAuthResponse(token: nil, requestId: requestId, to: webView)
            return
        }
        var hasResponded = false
        zdChatterAuthCallback { token in
            Task { @MainActor [weak self] in
                // Each request takes exactly one answer, so a host that calls back twice
                // must not inject a second. `hasResponded` covers that within one cycle;
                // the sequence check covers a host that answers an OLDER refresh cycle
                // late, which would otherwise inject a stale token as the answer to the
                // request currently outstanding.
                guard !hasResponded, let self, let webView = self.webView else { return }
                guard requestSeq == zdChatterAuthRequestSeq else { return }
                hasResponded = true
                handler.sendZendeskChatterAuthResponse(token: token, requestId: requestId, to: webView)
            }
        }
    }

    /// Called for every SDK event (new bridge path).
    public func adaBridge(_: AdaBridgeHandler, didReceiveEvent key: String, data: Any?) {
        var event: [String: Any] = ["event_name": key]
        if let data { event["data"] = data }
        dispatchEventToSubscribers(event, rawData: rawSdkEventData(data))
        guard let callbacks = eventCallbacks else { return }
        callbacks[key]?(event)
        callbacks["*"]?(event)
    }

    /// Called on fatal bridge error.
    public func adaBridge(_: AdaBridgeHandler, didEncounterError error: String) {
        debugPrint("[AdaWebHost] Bridge error: \(error)")
        // Surface bridge errors as synthetic events so EventLogView can display them
        // (helps diagnose SDK load failures during E2E testing).
        let event: [String: Any] = ["event_name": "ada.bridge.error", "error": error]
        dispatchEventToSubscribers(event, rawData: rawSdkEventData(event))
        // Historical surface: the single-closure dictionary hears bridge errors
        // on "*" only.
        eventCallbacks?["*"]?(event)
    }

    /// Called when the runtime page reports a failed subresource load.
    public func adaBridge(_: AdaBridgeHandler, didFailSubresourceLoad details: [String: Any]) {
        var event: [String: Any] = [
            "event_name": "ada.webview.subresourceLoadFailed",
            "url": details["url"] as? String ?? "",
            "error": "WKWebView failed to load an Ada runtime subresource",
        ]
        if let element = details["element"] as? String {
            event["element"] = element
        }
        dispatchEventToSubscribers(event, rawData: rawSdkEventData(event))
        // Same wildcard-only dictionary delivery as ada.webview.loadFailed.
        eventCallbacks?["*"]?(event)
    }
}
