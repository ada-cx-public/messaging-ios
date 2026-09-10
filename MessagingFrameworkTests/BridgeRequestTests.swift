//
//  BridgeRequestTests.swift
//  AdaMessagingTests
//
//  Unit tests for the curated request/response bridge (EXP-1225): native issues
//  an `ada.request`, the runtime answers with exactly one `sdk.response`, and the
//  reply is correlated by `requestId` and bound to the requesting document.
//

@testable import AdaMessaging
import Foundation
import Testing
import WebKit

// ---------------------------------------------------------------------------

// MARK: - Helpers

// ---------------------------------------------------------------------------

/// Decodes the JSON command native injected through the `__ADA_BRIDGE_DISPATCH__`
/// template, undoing the template-literal escaping so the command dict is
/// inspectable.
@MainActor
private func dispatchedCommand(from script: String) throws -> [String: Any] {
    let openMarker = "window.__ADA_BRIDGE_DISPATCH__(`"
    let closeMarker = "`)}true;"
    let start = try #require(script.range(of: openMarker))
    let end = try #require(script.range(of: closeMarker, range: start.upperBound ..< script.endIndex))
    let escaped = String(script[start.upperBound ..< end.lowerBound])
    let json = escaped
        .replacingOccurrences(of: "\\${", with: "${")
        .replacingOccurrences(of: "\\`", with: "`")
        .replacingOccurrences(of: "\\\\", with: "\\")
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    return try #require(object as? [String: Any])
}

@MainActor
private func requestId(from webView: ScriptCapturingWebView) throws -> String {
    let script = try #require(webView.capturedScripts.first { $0.contains("ada.request") })
    let command = try dispatchedCommand(from: script)
    return try #require(command["requestId"] as? String)
}

// ---------------------------------------------------------------------------

// MARK: - AdaBridgeHandlerRequestTests

// ---------------------------------------------------------------------------

@MainActor
struct AdaBridgeHandlerRequestTests {
    @MainActor
    private final class Fixture {
        let handler: AdaBridgeHandler
        let webView: ScriptCapturingWebView
        var fireTimeout: (() -> Void)?

        init() {
            handler = AdaBridgeHandler(
                userDefaults: UserDefaults(suiteName: "com.ada.bridge.request.\(UUID().uuidString)")!,
            )
            handler.trustedOrigin = "https://messaging-assets.ada.support"
            handler.trustedDocumentUrl = "https://messaging-assets.ada.support/sdk/webview.html"
            webView = ScriptCapturingWebView()
        }

        /// Captures the timeout fire block instead of scheduling a real timer, so
        /// the timeout path is driven synchronously.
        func captureTimeout() {
            handler.bridgeRequestTimeoutRunner = { [weak self] _, work in
                self?.fireTimeout = work
            }
        }
    }

    @Test
    func `sendBridgeRequest injects an ada.request carrying the method and a string requestId`() throws {
        let fixture = Fixture()

        fixture.handler.sendBridgeRequest(method: "getInfo", params: nil, to: fixture.webView) { _ in }

        let command = try dispatchedCommand(from: #require(fixture.webView.capturedScripts.first))
        #expect(command["type"] as? String == "ada.request")
        #expect(command["method"] as? String == "getInfo")
        #expect((command["requestId"] as? String)?.isEmpty == false)
    }

    @Test
    func `params ride the request`() throws {
        let fixture = Fixture()

        fixture.handler.sendBridgeRequest(
            method: "triggerAnswer",
            params: ["answerId": "answer-42"],
            to: fixture.webView,
        ) { _ in }

        let command = try dispatchedCommand(from: #require(fixture.webView.capturedScripts.first))
        let params = try #require(command["params"] as? [String: Any])
        #expect(params["answerId"] as? String == "answer-42")
    }

    @Test
    func `a matching response settles the completion with the result`() throws {
        let fixture = Fixture()
        var results: [AdaBridgeRequestResult] = []
        fixture.handler.sendBridgeRequest(method: "getInfo", params: nil, to: fixture.webView) { results.append($0) }
        let id = try requestId(from: fixture.webView)

        fixture.handler.handleBridgeMessage([
            "type": "sdk.response",
            "requestId": id,
            "generation": 1,
            "result": ["isChatOpen": true],
        ])

        #expect(results.count == 1)
        guard case let .success(value) = try #require(results.first) else {
            Issue.record("expected success")
            return
        }
        #expect((value as? [String: Any])?["isChatOpen"] as? Bool == true)
    }

    @Test
    func `an unsupported reply settles unsupported`() throws {
        let fixture = Fixture()
        var results: [AdaBridgeRequestResult] = []
        fixture.handler
            .sendBridgeRequest(method: "getMessages", params: nil, to: fixture.webView) { results.append($0) }
        let id = try requestId(from: fixture.webView)

        fixture.handler.handleBridgeMessage(["type": "sdk.response", "requestId": id, "unsupported": true])

        guard case .unsupported = try #require(results.first) else {
            Issue.record("expected unsupported")
            return
        }
    }

    @Test
    func `an error reply settles failure`() throws {
        let fixture = Fixture()
        var results: [AdaBridgeRequestResult] = []
        fixture.handler.sendBridgeRequest(method: "triggerAnswer", params: ["answerId": "x"], to: fixture.webView) {
            results.append($0)
        }
        let id = try requestId(from: fixture.webView)

        fixture.handler.handleBridgeMessage([
            "type": "sdk.response",
            "requestId": id,
            "error": "boom",
        ])

        guard case let .failure(message) = try #require(results.first) else {
            Issue.record("expected failure")
            return
        }
        #expect(message == "boom")
    }

    @Test
    func `a null result settles success with nil`() throws {
        let fixture = Fixture()
        var results: [AdaBridgeRequestResult] = []
        fixture.handler.sendBridgeRequest(method: "open", params: nil, to: fixture.webView) { results.append($0) }
        let id = try requestId(from: fixture.webView)

        fixture.handler.handleBridgeMessage(["type": "sdk.response", "requestId": id, "result": NSNull()])

        guard case let .success(value) = try #require(results.first) else {
            Issue.record("expected success")
            return
        }
        #expect(value == nil)
    }

    /// A reply whose `requestId` matches nothing outstanding must not invent a
    /// callback or crash — the request registry is the only thing that can settle
    /// a caller.
    @Test
    func `a reply with an unknown request id is dropped`() {
        let fixture = Fixture()
        var results: [AdaBridgeRequestResult] = []
        fixture.handler.sendBridgeRequest(method: "getInfo", params: nil, to: fixture.webView) { results.append($0) }

        fixture.handler.handleBridgeMessage(["type": "sdk.response", "requestId": "not-a-real-id", "result": 1])

        #expect(results.isEmpty)
    }

    /// The reply is bound to the document the request was accepted into. A reply
    /// arriving after a same-origin document replaced the frame redeems a
    /// different ticket, so it is not delivered as this request's answer.
    @Test
    func `a reply after the document changed settles failure`() throws {
        let fixture = Fixture()
        var results: [AdaBridgeRequestResult] = []
        fixture.handler.sendBridgeRequest(method: "getInfo", params: nil, to: fixture.webView) { results.append($0) }
        let id = try requestId(from: fixture.webView)

        fixture.webView.documentUrl = URL(string: "https://messaging-assets.ada.support/sdk/webview.html?handle=other")
        fixture.handler.handleBridgeMessage(["type": "sdk.response", "requestId": id, "result": ["a": 1]])

        guard case .failure = try #require(results.first) else {
            Issue.record("expected failure for a departed document")
            return
        }
    }

    @Test
    func `sendBridgeRequest with no live runtime document settles failure at once`() throws {
        let fixture = Fixture()
        fixture.webView.documentUrl = URL(string: "https://attacker.example/sdk/webview.html")
        var results: [AdaBridgeRequestResult] = []

        fixture.handler.sendBridgeRequest(method: "getInfo", params: nil, to: fixture.webView) { results.append($0) }

        #expect(fixture.webView.capturedScripts.isEmpty)
        guard case .failure = try #require(results.first) else {
            Issue.record("expected failure with no live document")
            return
        }
    }

    @Test
    func `the native timeout settles failure and a late reply is then dropped`() throws {
        let fixture = Fixture()
        fixture.captureTimeout()
        var results: [AdaBridgeRequestResult] = []
        fixture.handler.sendBridgeRequest(method: "getInfo", params: nil, to: fixture.webView) { results.append($0) }
        let id = try requestId(from: fixture.webView)

        // Bind before calling: `try #require(...)()` (invoking the unwrapped value
        // inline) crashes swift-frontend's type checker (Xcode 26.6).
        let fireTimeout = try #require(fixture.fireTimeout)
        fireTimeout()
        fixture.handler.handleBridgeMessage(["type": "sdk.response", "requestId": id, "result": 1])

        #expect(results.count == 1)
        guard case .failure = try #require(results.first) else {
            Issue.record("expected failure from the timeout")
            return
        }
    }

    @Test
    func `cancelPendingBridgeRequests settles every outstanding request as failure`() throws {
        let fixture = Fixture()
        var firstResults: [AdaBridgeRequestResult] = []
        var secondResults: [AdaBridgeRequestResult] = []
        fixture.handler
            .sendBridgeRequest(method: "getInfo", params: nil, to: fixture.webView) { firstResults.append($0) }
        fixture.handler
            .sendBridgeRequest(method: "isOpen", params: nil, to: fixture.webView) { secondResults.append($0) }

        fixture.handler.cancelPendingBridgeRequests()

        guard case .failure = try #require(firstResults.first) else {
            Issue.record("expected failure")
            return
        }
        guard case .failure = try #require(secondResults.first) else {
            Issue.record("expected failure")
            return
        }
    }

    /// The runtime posts exactly one `sdk.response`, but a duplicate must not
    /// settle a caller twice.
    @Test
    func `a duplicate reply is ignored`() throws {
        let fixture = Fixture()
        var results: [AdaBridgeRequestResult] = []
        fixture.handler.sendBridgeRequest(method: "getInfo", params: nil, to: fixture.webView) { results.append($0) }
        let id = try requestId(from: fixture.webView)

        fixture.handler.handleBridgeMessage(["type": "sdk.response", "requestId": id, "result": 1])
        fixture.handler.handleBridgeMessage(["type": "sdk.response", "requestId": id, "result": 2])

        #expect(results.count == 1)
    }
}

// ---------------------------------------------------------------------------

// MARK: - AdaWebHostBridgeRequestTests

// ---------------------------------------------------------------------------

@MainActor
struct AdaWebHostBridgeRequestTests {
    private static func messagingHost() -> (AdaWebHost, ScriptCapturingWebView) {
        let host = AdaWebHost(handle: "ada-example", environment: .production, webSdk: .messaging)
        let webView = ScriptCapturingWebView.mounted(on: host)
        return (host, webView)
    }

    @Test
    func `getInfo queues until ready then dispatches an ada.request`() throws {
        let (host, webView) = Self.messagingHost()
        host.webHostLoaded = false

        host.getInfo { _ in }
        #expect(webView.capturedScripts.isEmpty)

        host.webHostLoaded = true

        let command =
            try dispatchedCommand(from: #require(webView.capturedScripts.first { $0.contains("ada.request") }))
        #expect(command["method"] as? String == "getInfo")
    }

    @Test
    func `open dispatches an ada.request with the open method`() throws {
        let (host, webView) = Self.messagingHost()
        host.webHostLoaded = true

        host.open()

        let command =
            try dispatchedCommand(from: #require(webView.capturedScripts.first { $0.contains("ada.request") }))
        #expect(command["method"] as? String == "open")
    }

    @Test
    func `setTheme sends the theme param`() throws {
        let (host, webView) = Self.messagingHost()
        host.webHostLoaded = true

        host.setTheme(.dark)

        let command =
            try dispatchedCommand(from: #require(webView.capturedScripts.first { $0.contains("ada.request") }))
        #expect(command["method"] as? String == "setTheme")
        #expect((command["params"] as? [String: Any])?["theme"] as? String == "dark")
    }

    @Test
    func `triggerProactive sends the message key and params`() throws {
        let (host, webView) = Self.messagingHost()
        host.webHostLoaded = true

        host.triggerProactive(messageKey: "promo", params: ["campaign": "spring"])

        let command =
            try dispatchedCommand(from: #require(webView.capturedScripts.first { $0.contains("ada.request") }))
        let params = try #require(command["params"] as? [String: Any])
        #expect(params["messageKey"] as? String == "promo")
        #expect((params["params"] as? [String: Any])?["campaign"] as? String == "spring")
    }

    /// The full host round-trip: a queued read reaches the runtime after ready and
    /// its reply settles the caller's completion.
    @Test
    func `a host read settles once the runtime replies`() throws {
        let (host, webView) = Self.messagingHost()
        host.webHostLoaded = true
        var results: [AdaBridgeRequestResult] = []

        host.getInfo { results.append($0) }
        let id = try requestId(from: webView)
        host.bridgeHandler.handleBridgeMessage([
            "type": "sdk.response",
            "requestId": id,
            "result": ["botName": "Ada"],
        ])

        guard case let .success(value) = try #require(results.first) else {
            Issue.record("expected success")
            return
        }
        #expect((value as? [String: Any])?["botName"] as? String == "Ada")
    }

    /// The legacy remote host page runs embed-2 with no correlated response
    /// channel, so a curated request there answers `unsupported` rather than
    /// injecting a request nothing can reply to.
    @Test
    func `the legacy remote runtime answers curated requests unsupported`() throws {
        let host = AdaWebHost(handle: "ada-example", environment: .production, webSdk: .legacy)
        var results: [AdaBridgeRequestResult] = []

        host.getInfo { results.append($0) }

        guard case .unsupported = try #require(results.first) else {
            Issue.record("expected unsupported on the legacy remote runtime")
            return
        }
    }

    /// The navigation-delegate half of the cross-SDK "settle outstanding requests
    /// when the document is replaced" contract: committing a new main-frame document
    /// fails the request issued into the previous one, so the host callback resolves
    /// immediately instead of stranding for the full 35s timeout. Deleting the
    /// `didCommit` override leaves this failing.
    @Test
    func `committing a new document settles an outstanding request as failure`() throws {
        let (host, webView) = Self.messagingHost()
        host.webHostLoaded = true
        var results: [AdaBridgeRequestResult] = []

        host.getInfo { results.append($0) }
        _ = try requestId(from: webView)
        #expect(results.isEmpty)

        host.webView(webView, didCommit: nil)

        guard case .failure = try #require(results.first) else {
            Issue.record("expected failure once the document was replaced")
            return
        }
    }
}
