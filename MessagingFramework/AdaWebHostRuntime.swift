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
            webHostLoaded = true
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
            let deviceTokenJson = jsonStr(deviceToken)

            evalJS("""
                (function() {
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
                        parentElement: "parent-element",
                        onAdaEmbedLoaded: () => {
                            adaEmbed.setDeviceToken(\(deviceTokenJson));
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
                })();
            """)
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

    func evalJS(_ toRun: String) {
        guard webHostLoaded else {
            pendingCommands.append { [weak self] in
                self?.evalJS(toRun)
            }
            return
        }
        guard let webView else { return }

        webView.evaluateJavaScript(toRun) { _, error in
            if let err = error {
                debugPrint(err)
            }
        }
    }

    func returnToOnline() {
        guard !isInOfflineMode else { return }

        if let offlineVC = offlineViewController {
            offlineVC.view.removeFromSuperview()
            offlineViewController = nil
        }

        // This should reset the webview if client is offline on launch
        if !webHostLoaded {
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
        webHostLoaded = true
        if let callbacks = eventCallbacks {
            let event: [String: Any] = ["event_name": "sdk.ready", "web_sdk": webSdk.rawValue]
            callbacks["sdk.ready"]?(event)
            callbacks["*"]?(event)
        }
        // Send device token once SDK is ready (pending commands are flushed by webHostLoaded didSet).
        if !deviceToken.isEmpty, let webView {
            bridgeHandler.setDeviceToken(deviceToken, to: webView)
        }
    }

    /// Called for every SDK event (new bridge path).
    public func adaBridge(_: AdaBridgeHandler, didReceiveEvent key: String, data: Any?) {
        guard let callbacks = eventCallbacks else { return }
        var event: [String: Any] = ["event_name": key]
        if let data { event["data"] = data }
        callbacks[key]?(event)
        callbacks["*"]?(event)
    }

    /// Called on fatal bridge error.
    public func adaBridge(_: AdaBridgeHandler, didEncounterError error: String) {
        debugPrint("[AdaWebHost] Bridge error: \(error)")
        // Surface bridge errors as synthetic events so EventLogView can display them
        // (helps diagnose SDK load failures during E2E testing).
        guard let callbacks = eventCallbacks else { return }
        let event: [String: Any] = ["event_name": "ada.bridge.error", "error": error]
        callbacks["*"]?(event)
    }
}
