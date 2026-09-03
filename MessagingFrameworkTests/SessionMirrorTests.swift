//
//  SessionMirrorTests.swift
//  AdaMessagingTests
//
//  Unit tests for the Keychain-backed native session mirror (EXP-1082).
//
//  One suite per mirror surface (store, routing, pull responder, legacy script)
//  belongs together, so the file runs long.
// swiftlint:disable file_length

@testable import AdaMessaging
import Foundation
import JavaScriptCore
import Testing
import UIKit
import WebKit

// ---------------------------------------------------------------------------

// MARK: - Test doubles and helpers

// ---------------------------------------------------------------------------

/// In-memory Keychain fake. `log` records the mutation order so tests can pin
/// the delete-before-ack durability contract. `failDeletes` simulates a
/// Keychain that reports delete failure while the item survives; `failWrites`
/// simulates a `SecItemAdd`/`SecItemUpdate` failure that leaves the prior blob
/// intact; `failReads` simulates `errSecInteractionNotAllowed` — the item is
/// there, the Keychain refuses to hand it over. `accountsSurvivingDeleteAll`
/// simulates the sharper case: a service-wide delete that REPORTS success while
/// an account is still stored.
private final class FakeSessionMirrorKeychain: AdaSessionMirrorKeychain {
    var items: [String: Data] = [:]
    var log: [String] = []
    var failDeletes = false
    var failWrites = false
    var failReads = false
    var accountsSurvivingDeleteAll: Set<String> = []

    @discardableResult
    func setData(_ data: Data, forAccount account: String) -> Bool {
        log.append("set:\(account)")
        guard !failWrites else { return false }
        items[account] = data
        return true
    }

    func readData(forAccount account: String) -> AdaSessionMirrorReadResult<Data> {
        log.append("read:\(account)")
        guard !failReads else { return .failed }
        guard let data = items[account] else { return .absent }
        return .found(data)
    }

    /// Mirrors `SecItemCopyMatching` with `kSecMatchLimitAll`: no matching item is
    /// `errSecItemNotFound`, so an empty service enumerates as `absent`, never `found([])`.
    func readAllAccounts() -> AdaSessionMirrorReadResult<[String]> {
        log.append("readAll")
        guard !failReads else { return .failed }
        guard !items.isEmpty else { return .absent }
        return .found(items.keys.sorted())
    }

    @discardableResult
    func deleteData(forAccount account: String) -> Bool {
        log.append("delete:\(account)")
        guard !failDeletes else { return false }
        items.removeValue(forKey: account)
        return true
    }

    @discardableResult
    func deleteAll() -> Bool {
        log.append("deleteAll")
        guard !failDeletes else { return false }
        items = items.filter { accountsSurvivingDeleteAll.contains($0.key) }
        return true
    }
}

@MainActor
private final class AckSpyBridgeHandler: AdaBridgeHandler {
    var onAck: ((String) -> Void)?
    var onSeed: ((String, [String: Any]?) -> Void)?

    override func acknowledgeSessionMirrorClear(requestId: String, ticket: AdaDocumentTicket?) {
        onAck?(requestId)
    }

    /// Captures the pull response instead of dispatching it into a WebView the
    /// test does not have. Ticket redemption is covered separately by the tests
    /// that drive the real `deliverSessionMirrorSeed`.
    override func deliverSessionMirrorSeed(requestId: String, seed: [String: Any]?, ticket _: AdaDocumentTicket?) {
        onSeed?(requestId, seed)
    }
}

/// Records the SDK events the bridge reports to its host delegate.
private final class EventSpyDelegate: NSObject, AdaBridgeDelegate {
    var events: [(key: String, data: Any?)] = []

    func adaBridge(_: AdaBridgeHandler, didReceiveEvent key: String, data: Any?) {
        events.append((key: key, data: data))
    }

    func diagnosticReasons() -> [String] {
        events
            .filter { $0.key == "ada.sessionMirror.diagnostic" }
            .compactMap { ($0.data as? [String: String])?["reason"] }
    }
}

/// Test convenience over the three-way read: the blob when present, `nil` for both
/// "no blob stored" and "the Keychain refused the read". Tests that care about the
/// difference read `readBlobJson` directly.
private extension AdaSessionMirrorStore {
    func storedBlobJson(forScopeKey scopeKey: String) -> String? {
        if case let .found(json) = readBlobJson(forScopeKey: scopeKey) { return json }
        return nil
    }
}

private func makeIsolatedDefaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "com.ada.session-mirror.test.\(UUID().uuidString)"))
}

private func jsonString(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object)
    return try #require(String(data: data, encoding: .utf8))
}

private func scalarJsonString(_ value: String) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
    return try #require(String(data: data, encoding: .utf8))
}

// ---------------------------------------------------------------------------

// MARK: - AdaSessionMirrorStoreTests

// ---------------------------------------------------------------------------

private struct StoreFixture {
    let store: AdaSessionMirrorStore
    let keychain: FakeSessionMirrorKeychain
    let defaults: UserDefaults
}

struct AdaSessionMirrorStoreTests {
    private func makeStore() throws -> StoreFixture {
        let defaults = try makeIsolatedDefaults()
        let keychain = FakeSessionMirrorKeychain()
        return StoreFixture(
            store: AdaSessionMirrorStore(userDefaults: defaults, keychain: keychain),
            keychain: keychain,
            defaults: defaults,
        )
    }

    @Test
    func `round-trips a blob through the scope key`() throws {
        let store = try makeStore().store

        store.store(blobJson: "{\"generation\":3}", scopeKey: "scope-a")

        #expect(store.storedBlobJson(forScopeKey: "scope-a") == "{\"generation\":3}")
        #expect(store.storedBlobJson(forScopeKey: "scope-b") == nil)
    }

    /// Keychain items survive uninstall; the UserDefaults sentinel does not. An
    /// absent sentinel means reinstall — everything must be wiped before any
    /// injection so a reinstall never resurrects the previous install's session.
    @Test
    func `wipes surviving keychain blobs on first run after install`() throws {
        let fixture = try makeStore()
        fixture.keychain.items["scope-from-previous-install"] = Data("{}".utf8)

        fixture.store.prepareForLaunch()

        #expect(fixture.keychain.items.isEmpty)
        #expect(fixture.store.storedBlobJson(forScopeKey: "scope-from-previous-install") == nil)
        #expect(fixture.defaults.bool(forKey: AdaSessionMirrorStore.installedSentinelKey))
    }

    @Test
    func `keeps blobs on later launches once the sentinel is written`() throws {
        let fixture = try makeStore()
        fixture.store.prepareForLaunch()
        fixture.store.store(blobJson: "{}", scopeKey: "scope-a")

        fixture.store.prepareForLaunch()

        #expect(fixture.keychain.items["scope-a"] != nil)
        #expect(fixture.store.storedBlobJson(forScopeKey: "scope-a") == "{}")
    }

    @Test
    func `clear removes one scope's blob but leaves other scopes`() throws {
        let fixture = try makeStore()
        let store = fixture.store
        store.store(blobJson: "{\"a\":1}", scopeKey: "scope-a")
        store.store(blobJson: "{\"b\":2}", scopeKey: "scope-b")

        store.clear(scopeKey: "scope-a")

        #expect(store.storedBlobJson(forScopeKey: "scope-a") == nil)
        #expect(store.storedBlobJson(forScopeKey: "scope-b") == "{\"b\":2}")
        #expect(fixture.keychain.items.count == 1)
    }

    @Test
    func `clearAll wipes every blob but keeps the install sentinel`() throws {
        let fixture = try makeStore()
        fixture.store.prepareForLaunch()
        fixture.store.store(blobJson: "{}", scopeKey: "scope-a")
        fixture.store.store(blobJson: "{}", scopeKey: "scope-b")

        #expect(fixture.store.clearAll())

        #expect(fixture.keychain.items.isEmpty)
        #expect(fixture.store.storedBlobJson(forScopeKey: "scope-a") == nil)
        #expect(fixture.defaults.bool(forKey: AdaSessionMirrorStore.installedSentinelKey))
    }

    /// A failed delete must report `false` and leave the blob in place, so a
    /// later retry can succeed and the web side keeps its tombstone stamp.
    @Test
    func `a failed clear returns false and keeps the blob for retry`() throws {
        let fixture = try makeStore()
        fixture.store.store(blobJson: "{}", scopeKey: "scope-a")
        fixture.keychain.failDeletes = true

        #expect(!fixture.store.clear(scopeKey: "scope-a"))
        #expect(fixture.store.storedBlobJson(forScopeKey: "scope-a") == "{}")

        fixture.keychain.failDeletes = false
        #expect(fixture.store.clear(scopeKey: "scope-a"))
        #expect(fixture.store.storedBlobJson(forScopeKey: "scope-a") == nil)
    }

    @Test
    func `a failed clearAll returns false and keeps the blobs`() throws {
        let fixture = try makeStore()
        fixture.store.store(blobJson: "{}", scopeKey: "scope-a")
        fixture.keychain.failDeletes = true

        #expect(!fixture.store.clearAll())
        #expect(fixture.store.storedBlobJson(forScopeKey: "scope-a") == "{}")

        fixture.keychain.failDeletes = false
        #expect(fixture.store.clearAll())
        #expect(fixture.store.storedBlobJson(forScopeKey: "scope-a") == nil)
    }

    /// The read-back half of the wipe contract, matched to ``clear(scopeKey:)``: a
    /// `true` is only ever reported when the store is verified empty. Here the
    /// delete itself reports success, so a `clearAll` that returned the delete's
    /// status alone would call this a confirmed wipe.
    @Test
    func `clearAll confirms the wipe only after every scope reads back absent`() throws {
        let fixture = try makeStore()
        fixture.store.store(blobJson: "{\"a\":1}", scopeKey: "scope-a")
        fixture.store.store(blobJson: "{\"b\":2}", scopeKey: "scope-b")

        #expect(fixture.store.clearAll())

        #expect(fixture.store.storedBlobJson(forScopeKey: "scope-a") == nil)
        #expect(fixture.store.storedBlobJson(forScopeKey: "scope-b") == nil)
        let deleteIndex = try #require(fixture.keychain.log.firstIndex(of: "deleteAll"))
        let verifyIndex = try #require(fixture.keychain.log.lastIndex(of: "readAll"))
        #expect(deleteIndex < verifyIndex)
    }

    /// A Keychain that refuses reads has not proved absence — it has performed no
    /// read at all. Both consumers treat `true` as proof no credential survives, so
    /// an unverifiable wipe reports `false` even though the delete itself succeeded.
    @Test
    func `a clearAll whose read-back could not be performed is not a confirmed wipe`() throws {
        let fixture = try makeStore()
        fixture.store.store(blobJson: "{}", scopeKey: "scope-a")
        fixture.keychain.failReads = true

        #expect(!fixture.store.clearAll())

        #expect(fixture.keychain.log.contains("deleteAll"))
    }

    /// The case no index-based check ever covered: the service-wide delete reports
    /// success while a scope is still stored. The enumeration is what catches it,
    /// so it must cover scopes native keeps no record of.
    @Test
    func `a clearAll that leaves a scope behind reports failure`() throws {
        let fixture = try makeStore()
        fixture.store.store(blobJson: "{\"a\":1}", scopeKey: "scope-a")
        fixture.store.store(blobJson: "{\"b\":2}", scopeKey: "scope-b")
        fixture.keychain.accountsSurvivingDeleteAll = ["scope-b"]

        #expect(!fixture.store.clearAll())

        #expect(fixture.store.storedBlobJson(forScopeKey: "scope-b") == "{\"b\":2}")
    }

    /// The reinstall sentinel reads the same wipe result: a delete that reported
    /// success while the previous install's blob survived must not stamp it, or the
    /// next pull hands that install's credentials back.
    @Test
    func `a reinstall wipe that leaves a blob behind leaves the sentinel unset`() throws {
        let fixture = try makeStore()
        fixture.keychain.items["scope-from-previous-install"] = Data("{}".utf8)
        fixture.keychain.accountsSurvivingDeleteAll = ["scope-from-previous-install"]

        fixture.store.prepareForLaunch()

        #expect(!fixture.defaults.bool(forKey: AdaSessionMirrorStore.installedSentinelKey))
        #expect(!fixture.store.confirmInstallWipe())

        fixture.keychain.accountsSurvivingDeleteAll = []
        #expect(fixture.store.confirmInstallWipe())
        #expect(fixture.keychain.items.isEmpty)
    }

    /// A failed Keychain write must leave the prior blob intact and report
    /// `false`, so the web side does not treat the generation as durable.
    @Test
    func `a failed keychain write keeps the prior blob`() throws {
        let fixture = try makeStore()
        let store = fixture.store
        store.store(blobJson: "{\"generation\":3}", scopeKey: "scope-a")

        fixture.keychain.failWrites = true
        #expect(!store.store(blobJson: "{\"generation\":4}", scopeKey: "scope-a"))

        #expect(store.storedBlobJson(forScopeKey: "scope-a") == "{\"generation\":3}")
    }

    /// A reinstall wipe that fails must not stamp the sentinel: the next
    /// launch retries the wipe instead of injecting the previous install's
    /// surviving blobs forever.
    @Test
    func `a failed reinstall wipe leaves the sentinel unset so the next launch retries`() throws {
        let fixture = try makeStore()
        fixture.keychain.items["scope-from-previous-install"] = Data("{}".utf8)
        fixture.keychain.failDeletes = true

        fixture.store.prepareForLaunch()

        #expect(!fixture.defaults.bool(forKey: AdaSessionMirrorStore.installedSentinelKey))

        fixture.keychain.failDeletes = false
        fixture.store.prepareForLaunch()

        #expect(fixture.keychain.items.isEmpty)
        #expect(fixture.defaults.bool(forKey: AdaSessionMirrorStore.installedSentinelKey))
    }
}

// ---------------------------------------------------------------------------

// MARK: - SessionMirrorBridgeRoutingTests

// ---------------------------------------------------------------------------

@MainActor
private struct RoutingFixture {
    let handler: AckSpyBridgeHandler
    let store: AdaSessionMirrorStore
    let keychain: FakeSessionMirrorKeychain
    let defaults: UserDefaults
}

@MainActor
struct SessionMirrorBridgeRoutingTests {
    private func makeHandler() throws -> RoutingFixture {
        let defaults = try makeIsolatedDefaults()
        let keychain = FakeSessionMirrorKeychain()
        let store = AdaSessionMirrorStore(userDefaults: defaults, keychain: keychain)
        let handler = AckSpyBridgeHandler(userDefaults: defaults, sessionMirrorStore: store)
        handler.sessionMirrorLegacyScopePrefix = "ada-session-mirror:legacy:ada-example:"
        handler.sessionMirrorRuntime = .messaging(scopePrefix: "ada-session-mirror:ada-example:")
        // Run the keychain mutation and its main-thread completion inline so the
        // delete-before-invalidate-before-ack ordering is observable synchronously.
        handler.sessionMirrorKeychainRunner = { work in work() }
        handler.sessionMirrorMainRunner = { work in work() }
        return RoutingFixture(handler: handler, store: store, keychain: keychain, defaults: defaults)
    }

    private func mirrorWrite(
        scopeKey: String = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support",
        generation: Int = 7,
        entries: [String: String] = ["messagingAuthState": "{\"jwt\":\"opaque\"}"],
    ) -> [String: Any] {
        [
            "type": "sdk.session.mirror",
            "version": 1,
            "scopeKey": scopeKey,
            "generation": generation,
            "writtenAt": 1_756_700_000_000,
            "entries": entries,
        ]
    }

    @Test
    func `persists a v1 mirror payload verbatim minus type`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let store = fixture.store
        let scopeKey = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"

        handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeKey))

        let blobJson = try #require(store.storedBlobJson(forScopeKey: scopeKey))
        let blob = try #require(
            try JSONSerialization.jsonObject(with: Data(blobJson.utf8)) as? [String: Any],
        )
        #expect(blob["type"] == nil)
        #expect(blob["version"] as? Int == 1)
        #expect(blob["scopeKey"] as? String == scopeKey)
        #expect(blob["generation"] as? Int == 7)
        #expect(blob["writtenAt"] as? Int == 1_756_700_000_000)
        let entries = try #require(blob["entries"] as? [String: String])
        #expect(entries["messagingAuthState"] == "{\"jwt\":\"opaque\"}")
    }

    /// Messaging `entries` are never filtered natively — the web-side
    /// allowlist is the single filter, and the blob is opaque here. (Legacy
    /// blobs are the exception: their 5-key allowlist is enforced natively.)
    @Test
    func `stores messaging entries opaquely without inspecting their keys`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let store = fixture.store

        handler.handleBridgeMessage(
            mirrorWrite(entries: ["some-future-key": "value", "chatter": "abc123"]),
        )

        let blobJson = try #require(store.storedBlobJson(forScopeKey: "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"))
        let blob = try #require(
            try JSONSerialization.jsonObject(with: Data(blobJson.utf8)) as? [String: Any],
        )
        let entries = try #require(blob["entries"] as? [String: String])
        #expect(entries["some-future-key"] == "value")
        #expect(entries["chatter"] == "abc123")
    }

    /// The pinned runtime — not the page-supplied `scopeKey` — decides how a
    /// write is classified: a Messaging page relabeling its blob into the
    /// legacy namespace (or another handle's) must not get it stored at all.
    @Test
    func `the messaging runtime drops writes outside its own scope grammar`() throws {
        let fixture = try makeHandler()

        fixture.handler.handleBridgeMessage(
            mirrorWrite(
                scopeKey: "ada-session-mirror:legacy:ada-example:https://ada-example.ada.support",
                entries: ["chatter": "relabeled"],
            ),
        )
        fixture.handler.handleBridgeMessage(
            mirrorWrite(scopeKey: "ada-session-mirror:other-bot:origin:https://other.ada.support"),
        )

        #expect(fixture.keychain.items.isEmpty)
    }

    /// A bot literally named "legacy" produces Messaging scope keys starting
    /// `ada-session-mirror:legacy:` — the handle-delimited legacy prefix keeps
    /// those classified as Messaging, so they store normally.
    @Test
    func `a bot named legacy still writes messaging blobs under its own runtime`() throws {
        let fixture = try makeHandler()
        fixture.handler.sessionMirrorLegacyScopePrefix = "ada-session-mirror:legacy:legacy:"
        fixture.handler.sessionMirrorRuntime = .messaging(scopePrefix: "ada-session-mirror:legacy:")
        let scopeKey = "ada-session-mirror:legacy:origin:https://legacy.ada.support"

        fixture.handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeKey))

        #expect(fixture.store.storedBlobJson(forScopeKey: scopeKey) != nil)
    }

    @Test
    func `the legacy runtime accepts only the exact natively-computed scope key`() throws {
        let fixture = try makeHandler()
        let legacyScope = "ada-session-mirror:legacy:ada-example:https://ada-example.ada.support"
        fixture.handler.sessionMirrorRuntime = .legacy(scopeKey: legacyScope)

        fixture.handler.handleBridgeMessage(
            mirrorWrite(
                scopeKey: "ada-session-mirror:legacy:ada-example:https://other.ada.support",
                entries: ["chatter": "abc123"],
            ),
        )
        fixture.handler.handleBridgeMessage(
            mirrorWrite(scopeKey: "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"),
        )

        #expect(fixture.keychain.items.isEmpty)
    }

    /// A relabeled Messaging blob (JWT + refresh token) must be rejected at
    /// store time, not left for the legacy page to filter after injection.
    @Test
    func `the legacy runtime drops a write carrying keys outside the legacy allowlist`() throws {
        let fixture = try makeHandler()
        let legacyScope = "ada-session-mirror:legacy:ada-example:https://ada-example.ada.support"
        fixture.handler.sessionMirrorRuntime = .legacy(scopeKey: legacyScope)

        fixture.handler.handleBridgeMessage(
            mirrorWrite(
                scopeKey: legacyScope,
                entries: ["chatter": "abc123", "messagingAuthState": "{\"jwt\":\"opaque\"}"],
            ),
        )

        #expect(fixture.keychain.items.isEmpty)
    }

    /// The legacy stamp entry travels inside `entries` and is allowlisted.
    @Test
    func `the legacy runtime accepts the scope's generation stamp entry`() throws {
        let fixture = try makeHandler()
        let legacyScope = "ada-session-mirror:legacy:ada-example:https://ada-example.ada.support"
        fixture.handler.sessionMirrorRuntime = .legacy(scopeKey: legacyScope)

        fixture.handler.handleBridgeMessage(
            mirrorWrite(
                scopeKey: legacyScope,
                entries: ["chatter": "abc123", "\(legacyScope):generation": "4"],
            ),
        )

        #expect(fixture.store.storedBlobJson(forScopeKey: legacyScope) != nil)
    }

    /// No pinned runtime (e.g. the localhost-Legacy bridge runtime) fails
    /// closed for writes and clears alike.
    @Test
    func `mirror writes and clears are dropped when no runtime is pinned`() throws {
        let fixture = try makeHandler()
        let scopeKey = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"
        fixture.handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeKey))
        fixture.handler.sessionMirrorRuntime = nil
        var acks: [String] = []
        fixture.handler.onAck = { acks.append($0) }

        fixture.handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeKey, generation: 8))
        fixture.handler.handleBridgeMessage([
            "type": "sdk.session.mirrorClear",
            "version": 1,
            "scopeKey": scopeKey,
            "requestId": "req-44",
        ])

        let blobJson = try #require(fixture.store.storedBlobJson(forScopeKey: scopeKey))
        let blob = try #require(
            try JSONSerialization.jsonObject(with: Data(blobJson.utf8)) as? [String: Any],
        )
        #expect(blob["generation"] as? Int == 7)
        #expect(acks.isEmpty)
    }

    @Test
    func `ignores a mirror payload with an unrecognized version`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let keychain = fixture.keychain
        var payload = mirrorWrite()
        payload["version"] = 2

        handler.handleBridgeMessage(payload)

        #expect(keychain.items.isEmpty)
    }

    @Test
    func `ignores a mirror payload without a scope key`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let keychain = fixture.keychain
        var payload = mirrorWrite()
        payload.removeValue(forKey: "scopeKey")

        handler.handleBridgeMessage(payload)

        #expect(keychain.items.isEmpty)
    }

    /// The web-side MES-1376 barrier treats the ack as proof the blob cannot
    /// resurrect the cleared session, so the delete must land first.
    @Test
    func `clear deletes the blob durably before dispatching the ack`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let store = fixture.store
        let keychain = fixture.keychain
        let scopeKey = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"
        handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeKey))
        handler.onAck = { keychain.log.append("ack:\($0)") }

        handler.handleBridgeMessage([
            "type": "sdk.session.mirrorClear",
            "version": 1,
            "scopeKey": scopeKey,
            "requestId": "req-42",
        ])

        #expect(store.storedBlobJson(forScopeKey: scopeKey) == nil)
        let deleteIndex = try #require(keychain.log.firstIndex(of: "delete:\(scopeKey)"))
        let ackIndex = try #require(keychain.log.firstIndex(of: "ack:req-42"))
        #expect(deleteIndex < ackIndex)
    }

    /// The ack is the web side's proof the blob is gone. A failed Keychain
    /// delete must therefore never ack: the web side's wait times out, keeps
    /// its generation stamp, and the surviving blob stays tombstoned instead
    /// of resurrecting the cleared session at the next boot.
    @Test
    func `a failed keychain delete sends no ack and keeps the blob`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let scopeKey = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"
        handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeKey))
        fixture.keychain.failDeletes = true
        var acks: [String] = []
        handler.onAck = { acks.append($0) }

        handler.handleBridgeMessage([
            "type": "sdk.session.mirrorClear",
            "version": 1,
            "scopeKey": scopeKey,
            "requestId": "req-45",
        ])

        #expect(acks.isEmpty)
        #expect(fixture.store.storedBlobJson(forScopeKey: scopeKey) != nil)
    }

    @Test
    func `clear without a request id still clears but sends no ack`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let store = fixture.store
        let scopeKey = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"
        handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeKey))
        var acks: [String] = []
        handler.onAck = { acks.append($0) }

        handler.handleBridgeMessage(["type": "sdk.session.mirrorClear", "version": 1, "scopeKey": scopeKey])

        #expect(store.storedBlobJson(forScopeKey: scopeKey) == nil)
        #expect(acks.isEmpty)
    }

    /// The branding cache and the session mirror are separate channels: the
    /// branding cache's TTL-expiry wipe (`clearPersistedState`) must never
    /// destroy the mirror, or backgrounding the app 10 minutes would defeat
    /// the whole force-quit persistence feature.
    @Test
    func `branding-cache clearPersistedState leaves the session mirror intact`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let store = fixture.store
        handler.handleBridgeMessage(mirrorWrite())

        handler.clearPersistedState()

        #expect(store.storedBlobJson(forScopeKey: "ada-session-mirror:ada-example:origin:https://ada-example.ada.support") != nil)
    }

    /// The sign-out wipe behind ``AdaWebHostCommands/clearPersistedState()``:
    /// every scope goes, not just the one the current page happens to hold.
    @Test
    func `the sign-out wipe removes every scope's mirror`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let store = fixture.store
        let scopeA = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"
        let scopeB = "ada-session-mirror:ada-example:origin:https://other.ada.support"
        handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeA))
        handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeB))

        handler.clearAllSessionMirrors()

        #expect(store.storedBlobJson(forScopeKey: scopeA) == nil)
        #expect(store.storedBlobJson(forScopeKey: scopeB) == nil)
    }

    /// The half that distinguishes ``AdaWebHostCommands/clearPersistedStateDurably()``
    /// from the `Void` variant: the same all-scope wipe, plus a `true` that means
    /// the caller may treat the sign-out as complete.
    @Test
    func `the durable sign-out wipe removes every scope's mirror and reports true`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let store = fixture.store
        let scopeA = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"
        let scopeB = "ada-session-mirror:ada-example:origin:https://other.ada.support"
        handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeA))
        handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeB))

        #expect(handler.clearAllSessionMirrorsDurably())

        #expect(store.storedBlobJson(forScopeKey: scopeA) == nil)
        #expect(store.storedBlobJson(forScopeKey: scopeB) == nil)
    }

    /// A Keychain that refuses the wipe must report `false`, not a silently
    /// successful sign-out: the credentials survive, so the caller has to retry
    /// rather than tell the user they are signed out.
    @Test
    func `a failed sign-out wipe reports false and keeps the blob for retry`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let scopeKey = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"
        handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeKey))
        fixture.keychain.failDeletes = true

        #expect(!handler.clearAllSessionMirrorsDurably())

        #expect(fixture.store.storedBlobJson(forScopeKey: scopeKey) != nil)
    }

    /// A keychain daemon that never answers must not strand the caller either. The wait is
    /// bounded at both ends — ``AdaBridgeHandler/sessionMirrorClearDurablyStartGrace`` to reach
    /// the head of the mirror queue, ``AdaBridgeHandler/sessionMirrorClearDurablyTimeout``
    /// overall — and an unsettled wipe reports `false` under the same retry contract as a
    /// refused one. This runner never runs the wipe at all, so the grace is the end that
    /// answers it.
    @Test
    func `a sign-out wipe that never settles reports false at the bound`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let scopeKey = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"
        handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeKey))
        // Accepts the wipe and never runs it, so the semaphore is never signalled.
        handler.sessionMirrorKeychainRunner = { _ in }

        #expect(!handler.clearAllSessionMirrorsDurably())

        #expect(fixture.store.storedBlobJson(forScopeKey: scopeKey) != nil)
    }

}

// ---------------------------------------------------------------------------

// MARK: - SessionMirrorDiagnosticTests

// ---------------------------------------------------------------------------

/// The mirror's silent failure paths: a write the Keychain refuses, a clear whose only signal is
/// a withheld ack, the wipe behind the `Void` sign-out hook, which has no return value to report
/// through, and a legacy mount that failed closed on an unresolved persistence mode and so sends
/// no mirror message at all. Each leaves the session in a state the host would otherwise never
/// learn about, so each reports one reason enum on the shared `ada.sessionMirror.diagnostic`
/// event.
@MainActor
struct SessionMirrorDiagnosticTests {
    private static let scopeKey = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"

    private func makeHandler() throws -> RoutingFixture {
        let defaults = try makeIsolatedDefaults()
        let keychain = FakeSessionMirrorKeychain()
        let store = AdaSessionMirrorStore(userDefaults: defaults, keychain: keychain)
        let handler = AckSpyBridgeHandler(userDefaults: defaults, sessionMirrorStore: store)
        handler.sessionMirrorLegacyScopePrefix = "ada-session-mirror:legacy:ada-example:"
        handler.sessionMirrorRuntime = .messaging(scopePrefix: "ada-session-mirror:ada-example:")
        handler.sessionMirrorKeychainRunner = { work in work() }
        handler.sessionMirrorMainRunner = { work in work() }
        return RoutingFixture(handler: handler, store: store, keychain: keychain, defaults: defaults)
    }

    private func mirrorWrite(generation: Int = 7) -> [String: Any] {
        [
            "type": "sdk.session.mirror",
            "version": 1,
            "scopeKey": Self.scopeKey,
            "generation": generation,
            "writtenAt": 1_756_700_000_000,
            "entries": ["messagingAuthState": "{\"jwt\":\"opaque\"}"],
        ]
    }

    /// The `Void` sign-out hook returns nothing, so a Keychain that refuses the wipe leaves the
    /// signed-out user's blob for the next launch's seed pull to answer with.
    @Test
    func `a failed void sign-out wipe reports the delete failure to the host`() throws {
        let fixture = try makeHandler()
        let delegate = EventSpyDelegate()
        fixture.handler.delegate = delegate
        fixture.handler.handleBridgeMessage(mirrorWrite())
        fixture.keychain.failDeletes = true

        fixture.handler.clearAllSessionMirrors()

        #expect(delegate.diagnosticReasons() == ["adapter-removeItem-failed"])
        #expect(fixture.store.storedBlobJson(forScopeKey: Self.scopeKey) != nil)
    }

    /// The durable variant returns `false` to its caller AND reports, so a host that signs out
    /// on one path and monitors on the other sees the same failure.
    @Test
    func `a failed durable sign-out wipe reports the delete failure to the host`() throws {
        let fixture = try makeHandler()
        let delegate = EventSpyDelegate()
        fixture.handler.delegate = delegate
        fixture.handler.handleBridgeMessage(mirrorWrite())
        fixture.keychain.failDeletes = true

        #expect(!fixture.handler.clearAllSessionMirrorsDurably())

        #expect(delegate.diagnosticReasons() == ["adapter-removeItem-failed"])
    }

    @Test
    func `a confirmed sign-out wipe reports nothing to the host`() throws {
        let fixture = try makeHandler()
        let delegate = EventSpyDelegate()
        fixture.handler.delegate = delegate
        fixture.handler.handleBridgeMessage(mirrorWrite())

        fixture.handler.clearAllSessionMirrors()

        #expect(fixture.store.storedBlobJson(forScopeKey: Self.scopeKey) == nil)
        #expect(delegate.events.isEmpty)
    }

    /// The web side stamps its generation before native commits, so a refused write pins the
    /// page ahead of a blob native never took.
    @Test
    func `a refused mirror write reports the write failure to the host`() throws {
        let fixture = try makeHandler()
        let delegate = EventSpyDelegate()
        fixture.handler.delegate = delegate
        fixture.keychain.failWrites = true

        fixture.handler.handleBridgeMessage(mirrorWrite())

        #expect(delegate.diagnosticReasons() == ["adapter-setItem-failed"])
        let payload = try #require(delegate.events.first?.data as? [String: String])
        // A mirror payload is the whole credential blob, so only the reason may ride this channel.
        #expect(Set(payload.keys) == ["reason"])
    }

    @Test
    func `repeated mirror write failures report once`() throws {
        let fixture = try makeHandler()
        let delegate = EventSpyDelegate()
        fixture.handler.delegate = delegate
        fixture.keychain.failWrites = true

        fixture.handler.handleBridgeMessage(mirrorWrite(generation: 7))
        fixture.handler.handleBridgeMessage(mirrorWrite(generation: 8))

        #expect(delegate.diagnosticReasons() == ["adapter-setItem-failed"])
    }

    /// The host's documented response to `adapter-removeItem-failed` is to retry the sign-out.
    /// A silent retry is indistinguishable from one that worked, so this reason never dedupes.
    @Test
    func `every failed sign-out wipe reports, so a retry is never silent`() throws {
        let fixture = try makeHandler()
        let delegate = EventSpyDelegate()
        fixture.handler.delegate = delegate
        fixture.handler.handleBridgeMessage(mirrorWrite())
        fixture.keychain.failDeletes = true

        fixture.handler.clearAllSessionMirrors()
        fixture.handler.clearAllSessionMirrors()

        #expect(
            delegate.diagnosticReasons() == [
                "adapter-removeItem-failed",
                "adapter-removeItem-failed",
            ]
        )
    }

    @Test
    func `a committed mirror write reports nothing to the host`() throws {
        let fixture = try makeHandler()
        let delegate = EventSpyDelegate()
        fixture.handler.delegate = delegate

        fixture.handler.handleBridgeMessage(mirrorWrite())

        #expect(fixture.store.storedBlobJson(forScopeKey: Self.scopeKey) != nil)
        #expect(delegate.events.isEmpty)
    }

    /// A scope key the pinned runtime may not touch is dropped on all three routes, and a drop is
    /// silent: the page keeps mirroring into a store that never takes the blob, and the host has
    /// no way to tell that from a working mirror.
    @Test(
        "a message naming a scope the pinned runtime may not touch reports the scope mismatch",
        arguments: [
            "sdk.session.mirror",
            "sdk.session.mirrorClear",
            "sdk.session.mirrorRequest",
        ],
    )
    func foreignScopeKeyReportsScopeMismatch(messageType: String) throws {
        let fixture = try makeHandler()
        let delegate = EventSpyDelegate()
        fixture.handler.delegate = delegate

        fixture.handler.handleBridgeMessage([
            "type": messageType,
            "version": 1,
            "scopeKey": "ada-session-mirror:attacker:origin:https://attacker.example",
            "requestId": "req-foreign",
            "generation": 7,
            "entries": ["messagingAuthState": "{\"jwt\":\"opaque\"}"],
        ])

        #expect(delegate.diagnosticReasons() == ["scope-mismatch"])
        #expect(fixture.store.storedBlobJson(forScopeKey: "ada-session-mirror:attacker:origin:https://attacker.example") == nil)
    }

    /// Version is judged before scope, matching this file's own write path and both sibling
    /// wrappers. A seed request on a protocol this build does not know is answered empty and
    /// classified no further: its `scopeKey` means whatever that version says it means, so
    /// reporting a scope rejection over it would put an unearned `scope-mismatch` into a reason
    /// vocabulary read across all three platforms. The request is still answered, because
    /// silence would strand the web side on its fail-open timeout.
    @Test
    func `an unrecognised-version seed request is answered empty without a scope rejection`() throws {
        let fixture = try makeHandler()
        let delegate = EventSpyDelegate()
        fixture.handler.delegate = delegate
        var answered: [(String, [String: Any]?)] = []
        fixture.handler.onSeed = { answered.append(($0, $1)) }

        fixture.handler.handleBridgeMessage([
            "type": "sdk.session.mirrorRequest",
            "version": 2,
            "scopeKey": "ada-session-mirror:attacker:origin:https://attacker.example",
            "requestId": "req-future-version",
        ])

        #expect(delegate.diagnosticReasons() == [])
        // Both halves the name promises. Silence would strand the web side on its
        // fail-open timeout, so the rejection is still an answer — an empty one.
        #expect(answered.count == 1)
        #expect(answered.first?.0 == "req-future-version")
        #expect(answered.first?.1 == nil)
    }

    /// A legacy blob carrying a Messaging credential is refused by the entry allowlist. Refusing it
    /// is the security property; reporting it is how the host learns the legacy page is posting
    /// something native will never store.
    @Test
    func `a legacy mirror write outside the entry allowlist reports it to the host`() throws {
        let fixture = try makeHandler()
        let delegate = EventSpyDelegate()
        fixture.handler.delegate = delegate
        let legacyScope = "ada-session-mirror:legacy:ada-example:https://ada-example.ada.support"
        fixture.handler.sessionMirrorRuntime = .legacy(scopeKey: legacyScope)

        fixture.handler.handleBridgeMessage([
            "type": "sdk.session.mirror",
            "version": 1,
            "scopeKey": legacyScope,
            "generation": 7,
            "writtenAt": 1_756_700_000_000,
            "entries": ["chatter": "abc123", "messagingAuthState": "{\"jwt\":\"opaque\"}"],
        ])

        #expect(delegate.diagnosticReasons() == ["entries-not-allowlisted"])
        #expect(fixture.store.storedBlobJson(forScopeKey: legacyScope) == nil)
    }

    /// The allowlist is re-checked when the blob is read back, so a blob that reached the store by
    /// some other route is still refused — and that refusal is answered as an ordinary empty seed,
    /// which looks exactly like having no session at all.
    @Test
    func `a legacy seed read outside the entry allowlist reports it to the host`() throws {
        let fixture = try makeHandler()
        let delegate = EventSpyDelegate()
        let legacyScope = "ada-session-mirror:legacy:ada-example:https://ada-example.ada.support"
        fixture.handler.sessionMirrorRuntime = .legacy(scopeKey: legacyScope)
        fixture.store.prepareForLaunch()
        fixture.store.store(
            blobJson: try jsonString([
                "version": 1,
                "scopeKey": legacyScope,
                "generation": 2,
                "entries": ["chatter": "x", "messagingAuthState": "{\"jwt\":\"opaque\"}"],
            ]),
            scopeKey: legacyScope,
        )
        fixture.handler.delegate = delegate

        fixture.handler.handleBridgeMessage([
            "type": "sdk.session.mirrorRequest",
            "version": 1,
            "scopeKey": legacyScope,
            "requestId": "req-poisoned",
        ])

        #expect(delegate.diagnosticReasons() == ["entries-not-allowlisted"])
    }

    /// The pull contract answers a refused Keychain read with SILENCE — an empty seed would open
    /// the web side's write path and overwrite the intact blob. That silence is exactly what makes
    /// the failure invisible: the web side just times out. The host hears it here instead.
    @Test
    func `a keychain read the seed pull answers with silence reports the read failure to the host`() throws {
        let fixture = try makeHandler()
        let delegate = EventSpyDelegate()
        fixture.store.prepareForLaunch()
        fixture.handler.handleBridgeMessage(mirrorWrite())
        fixture.handler.delegate = delegate
        var answered: [(String, [String: Any]?)] = []
        fixture.handler.onSeed = { answered.append(($0, $1)) }
        fixture.keychain.failReads = true

        fixture.handler.handleBridgeMessage([
            "type": "sdk.session.mirrorRequest",
            "version": 1,
            "scopeKey": Self.scopeKey,
            "requestId": "req-refused",
        ])

        #expect(answered.isEmpty)
        #expect(delegate.diagnosticReasons() == ["adapter-getItem-failed"])
    }

    private func mirrorClear(requestId: String = "req-clear") -> [String: Any] {
        [
            "type": "sdk.session.mirrorClear",
            "version": 1,
            "scopeKey": Self.scopeKey,
            "requestId": requestId,
        ]
    }

    /// A failed web-ordered clear withholds the ack, which is what preserves the page's
    /// generation stamp — but the page only sees a timeout, and the HOST sees nothing at all. So
    /// the surviving blob is reported here, as Android and React Native both do.
    @Test
    func `a failed web-ordered clear reports the delete failure and sends no ack`() throws {
        let fixture = try makeHandler()
        let delegate = EventSpyDelegate()
        fixture.handler.handleBridgeMessage(mirrorWrite())
        fixture.handler.delegate = delegate
        var acks: [String] = []
        fixture.handler.onAck = { acks.append($0) }
        fixture.keychain.failDeletes = true

        fixture.handler.handleBridgeMessage(mirrorClear())

        #expect(delegate.diagnosticReasons() == ["adapter-removeItem-failed"])
        #expect(acks.isEmpty)
        #expect(fixture.store.storedBlobJson(forScopeKey: Self.scopeKey) != nil)
    }

    @Test
    func `a confirmed web-ordered clear acks and reports nothing`() throws {
        let fixture = try makeHandler()
        let delegate = EventSpyDelegate()
        fixture.handler.handleBridgeMessage(mirrorWrite())
        fixture.handler.delegate = delegate
        var acks: [String] = []
        fixture.handler.onAck = { acks.append($0) }

        fixture.handler.handleBridgeMessage(mirrorClear())

        #expect(acks == ["req-clear"])
        #expect(delegate.events.isEmpty)
        #expect(fixture.store.storedBlobJson(forScopeKey: Self.scopeKey) == nil)
    }

    /// The web side retries a clear whose ack never arrived. A retry that reports nothing is
    /// indistinguishable from one that worked, so this reason never dedupes — the same reason
    /// `deduplicatesPerDocument` excludes it for the sign-out wipe.
    @Test
    func `every failed web-ordered clear reports, so a retry is never silent`() throws {
        let fixture = try makeHandler()
        let delegate = EventSpyDelegate()
        fixture.handler.handleBridgeMessage(mirrorWrite())
        fixture.handler.delegate = delegate
        fixture.keychain.failDeletes = true

        fixture.handler.handleBridgeMessage(mirrorClear(requestId: "req-clear-1"))
        fixture.handler.handleBridgeMessage(mirrorClear(requestId: "req-clear-2"))

        #expect(
            delegate.diagnosticReasons() == [
                "adapter-removeItem-failed",
                "adapter-removeItem-failed",
            ]
        )
    }

    /// The legacy pre-start script fails closed when it cannot resolve the bot's persistence
    /// mode, which reaches native as no mirror message at all. This one message is how that mount
    /// says so, and it is the reason Android and React Native already report.
    @Test
    func `the legacy fail-closed message reports an unresolved rollout to the host`() throws {
        let fixture = try makeHandler()
        let delegate = EventSpyDelegate()
        fixture.handler.delegate = delegate

        fixture.handler.handleBridgeMessage([
            "type": "sdk.session.mirrorDiagnostic",
            "version": 1,
            "scopeKey": Self.scopeKey,
        ])

        #expect(delegate.diagnosticReasons() == ["legacy-rollout-unresolved"])
        let payload = try #require(delegate.events.first?.data as? [String: String])
        #expect(Set(payload.keys) == ["reason"])
    }

    /// Nothing is read off this message and nothing durable follows from it, so native fixes the
    /// reason rather than gating on fields a sender controls — which is also what stops a sender
    /// widening the closed reason set.
    @Test
    func `the legacy fail-closed message reports whatever version and scope it names`() throws {
        let fixture = try makeHandler()
        let delegate = EventSpyDelegate()
        fixture.handler.delegate = delegate

        fixture.handler.handleBridgeMessage([
            "type": "sdk.session.mirrorDiagnostic",
            "version": 99,
            "scopeKey": "ada-session-mirror:attacker:origin:https://attacker.example",
            "reason": "adapter-getItem-failed",
        ])

        #expect(delegate.diagnosticReasons() == ["legacy-rollout-unresolved"])
    }

    /// A page posting it on every message would flood the host's log, so this reason dedupes for
    /// the bound document — unlike a clear failure, which the caller is expected to retry.
    @Test
    func `repeated legacy fail-closed messages report once`() throws {
        let fixture = try makeHandler()
        let delegate = EventSpyDelegate()
        fixture.handler.delegate = delegate

        fixture.handler.handleBridgeMessage(["type": "sdk.session.mirrorDiagnostic", "version": 1])
        fixture.handler.handleBridgeMessage(["type": "sdk.session.mirrorDiagnostic", "version": 1])

        #expect(delegate.diagnosticReasons() == ["legacy-rollout-unresolved"])
    }

    /// The diagnostic route must never reach the clear handler it sits beside — a `default:` arm
    /// that swallowed it would turn a telemetry message into a delete.
    @Test
    func `the legacy fail-closed message never clears a blob`() throws {
        let fixture = try makeHandler()
        fixture.handler.handleBridgeMessage(mirrorWrite())

        fixture.handler.handleBridgeMessage([
            "type": "sdk.session.mirrorDiagnostic",
            "version": 1,
            "scopeKey": Self.scopeKey,
        ])

        #expect(fixture.store.storedBlobJson(forScopeKey: Self.scopeKey) != nil)
    }
}

// ---------------------------------------------------------------------------

// MARK: - SessionMirrorHostWiringTests

// ---------------------------------------------------------------------------

@MainActor
struct SessionMirrorHostWiringTests {
    @Test
    func `legacy scope key follows the pinned contract shape`() {
        let host = AdaWebHost(handle: "ada-example")

        let scopeKey = host.legacySessionMirrorScopeKey(pageOrigin: "https://ada-example.ada.support")

        #expect(scopeKey == "ada-session-mirror:legacy:ada-example:https://ada-example.ada.support")
    }

    @Test
    func `legacy scope prefix is handle-scoped and matches the scope key shape`() {
        let host = AdaWebHost(handle: "ada-example")

        #expect(host.legacySessionMirrorScopePrefix() == "ada-session-mirror:legacy:ada-example:")
        #expect(
            host.legacySessionMirrorScopeKey(pageOrigin: "https://ada-example.ada.support")
                .hasPrefix(host.legacySessionMirrorScopePrefix()),
        )
    }

    @Test
    func `legacy host installs the legacy mirror watcher at document start`() {
        let host = AdaWebHost(handle: "ada-example")

        let scripts = host.webviewUserContentController?.userScripts ?? []
        let watcher = scripts.first {
            $0.source.contains("ada-session-mirror:legacy:ada-example:")
        }

        #expect(watcher != nil)
        #expect(watcher?.injectionTime == .atDocumentStart)
    }

    @Test
    func `messaging host does not install the legacy watcher`() {
        let host = AdaWebHost(handle: "ada-example", environment: .production, webSdk: .messaging)

        let scripts = host.webviewUserContentController?.userScripts ?? []

        #expect(!scripts.contains { $0.source.contains("ada-session-mirror:legacy") })
    }

    @Test
    func `messaging host pins the messaging mirror runtime`() throws {
        let host = AdaWebHost(handle: "ada-example", environment: .production, webSdk: .messaging)

        guard case let .messaging(scopePrefix)? = host.bridgeHandler.sessionMirrorRuntime else {
            Issue.record("expected a pinned messaging runtime")
            return
        }
        #expect(scopePrefix == "ada-session-mirror:ada-example:")
    }

    @Test
    func `legacy host pins the exact natively-computed legacy scope key`() throws {
        let host = AdaWebHost(handle: "ada-example")

        guard case let .legacy(scopeKey)? = host.bridgeHandler.sessionMirrorRuntime else {
            Issue.record("expected a pinned legacy runtime")
            return
        }
        #expect(scopeKey.hasPrefix("ada-session-mirror:legacy:ada-example:https://"))
    }

    /// The localhost-Legacy bridge runtime drives no mirror: nothing is
    /// pinned, so every mirror write, clear and seed pull fails closed.
    @Test
    func `localhost legacy host pins no mirror runtime`() {
        let host = AdaWebHost(handle: "ada-example", environment: .local(port: 4900))

        #expect(host.bridgeHandler.sessionMirrorRuntime == nil)
    }
}

// ---------------------------------------------------------------------------

// MARK: - LegacySessionMirrorScriptTests

// ---------------------------------------------------------------------------

/// Executes the injected legacy pull-bootstrap + adopt-and-watch script in
/// JavaScriptCore against a fake page, pinning the native seed pull, the
/// adaEmbed.start hold/release gate, adoption, watching, clears, and the
/// persistence-mode gating — one suite for one script, so it runs long.
@MainActor
// swiftlint:disable:next type_body_length
enum LegacySessionMirrorScriptTests {
    private static let origin = "https://ada-example.ada.support"
    private static let scopeKey = "ada-session-mirror:legacy:ada-example:https://ada-example.ada.support"
    private static let stampKey = "\(scopeKey):generation"

    private static func makeContext(
        localStorage: [String: String] = [:],
        seed: [String: Any]? = nil,
        documentOrigin: String = origin,
        clientBlob: [String: Any]? = ["persistence": "normal"],
        fetchNeverSettles: Bool = false,
        pageSearch: String = "",
        pageHash: String = "",
        throwOnSetItemKey: String? = nil,
        callStart: Bool = true,
        deliverSeed: Bool = true,
        hostname: String = "ada-example.ada.support",
    ) throws -> JSContext {
        let context = try #require(JSContext())
        let storeJson = try jsonString(localStorage)
        let originJson = try scalarJsonString(documentOrigin)
        let searchJson = try scalarJsonString(pageSearch)
        let hashJson = try scalarJsonString(pageHash)
        let hostnameJson = try scalarJsonString(hostname)
        let throwKeyJson = try throwOnSetItemKey.map { try scalarJsonString($0) } ?? "null"
        let fetchBody = try fetchBodyScript(clientBlob: clientBlob, fetchNeverSettles: fetchNeverSettles)
        context.evaluateScript(harnessBootstrapScript(
            storeJson: storeJson,
            originJson: originJson,
            searchJson: searchJson,
            hashJson: hashJson,
            fetchBody: fetchBody,
            throwKeyJson: throwKeyJson,
            hostnameJson: hostnameJson,
        ))
        let source = try #require(
            AdaBridgeHandler.legacySessionMirrorScriptSource(scopeKey: scopeKey, pageOrigin: origin),
        )
        context.evaluateScript(source)
        if callStart {
            // Simulate embed-2 defining adaEmbed after the document-start script,
            // then the wrapper's direct adaEmbed.start(config) call.
            context.evaluateScript("""
            window.adaEmbed = { start: function () { startCalls++; } };
            window.adaEmbed.start({ handle: "ada-example" });
            """)
        }
        if deliverSeed {
            try deliverSeedReply(seed, in: context)
        }
        return context
    }

    /// Simulates native answering the pull by dispatching `sdk.sessionMirror.seed`
    /// into the injected receiver, keyed to the request the script posted.
    private static func deliverSeedReply(_ seed: [String: Any]?, in context: JSContext) throws {
        let seedJson = try seed.map { try jsonString($0) } ?? "null"
        context.evaluateScript("""
        (function () {
            var req = null;
            for (var i = 0; i < posts.length; i++) {
                if (posts[i].type === "sdk.session.mirrorRequest") { req = posts[i]; }
            }
            if (!req || !window.__ADA_BRIDGE_DISPATCH__) { return; }
            var reply = { type: "sdk.sessionMirror.seed", requestId: req.requestId, seed: \(seedJson) };
            window.__ADA_BRIDGE_DISPATCH__(JSON.stringify(reply));
        })();
        """)
    }

    private static func fetchBodyScript(clientBlob: [String: Any]?, fetchNeverSettles: Bool) throws -> String {
        if fetchNeverSettles {
            // Captures `reject` so a test can land the real rejection AFTER the bound already
            // fired — the ordering an abort actually produces on device.
            return "return new Promise(function (_, reject) { rejectFetch = reject; });"
        }
        guard let clientBlob else {
            return "return Promise.reject(new Error(\"network\"));"
        }
        let clientJson = try jsonString(clientBlob)
        return "return Promise.resolve({ json: function () { return Promise.resolve(\(clientJson)); } });"
    }

    private static func harnessBootstrapScript(
        storeJson: String,
        originJson: String,
        searchJson: String,
        hashJson: String,
        fetchBody: String,
        throwKeyJson: String = "null",
        hostnameJson: String = "\"ada-example.ada.support\"",
    ) -> String {
        """
        var store = \(storeJson);
        var posts = [];
        var intervals = [];
        var listeners = {};
        var fetches = [];
        var timeouts = [];
        var aborts = [];
        var startCalls = 0;
        var rejectFetch = null;
        function setInterval(fn, ms) { intervals.push({ fn: fn, ms: ms }); return intervals.length; }
        function setTimeout(fn, ms) { timeouts.push({ fn: fn, ms: ms, cleared: false }); return timeouts.length; }
        function clearTimeout(id) {
            if (typeof id === "number" && id >= 1 && id <= timeouts.length) { timeouts[id - 1].cleared = true; }
        }
        function AbortController() {
            var signal = { aborted: false };
            this.signal = signal;
            this.abort = function () { signal.aborted = true; aborts.push(true); };
        }
        var window = {
            location: {
                origin: \(originJson),
                hostname: \(hostnameJson),
                search: \(searchJson),
                hash: \(hashJson)
            },
            localStorage: {
                getItem: function (key) {
                    return Object.prototype.hasOwnProperty.call(store, key) ? store[key] : null;
                },
                setItem: function (key, value) {
                    if (key === \(throwKeyJson)) { throw new Error("quota exceeded"); }
                    store[key] = String(value);
                },
                removeItem: function (key) { delete store[key]; }
            },
            webkit: { messageHandlers: { adaBridge: {
                postMessage: function (message) { posts.push(message); }
            } } },
            addEventListener: function (name, fn) { listeners[name] = fn; },
            fetch: function (url) {
                fetches.push(url);
                \(fetchBody)
            }
        };
        """
    }

    private static func storage(in context: JSContext) throws -> [String: String] {
        let json = context.evaluateScript("JSON.stringify(store)")?.toString() ?? "{}"
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(parsed as? [String: String])
    }

    private static func posts(in context: JSContext) throws -> [[String: Any]] {
        let json = context.evaluateScript("JSON.stringify(posts)")?.toString() ?? "[]"
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(parsed as? [[String: Any]])
    }

    /// Posts excluding the outbound seed pull request, so watch/clear
    /// assertions are not polluted by the always-present `mirrorRequest`.
    private static func mirrorPosts(in context: JSContext) throws -> [[String: Any]] {
        try posts(in: context).filter { $0["type"] as? String != "sdk.session.mirrorRequest" }
    }

    /// Those posts as types in order, so a settle path can be pinned to exactly the messages it
    /// produced rather than only to producing none.
    private static func mirrorPostTypes(in context: JSContext) throws -> [String] {
        try mirrorPosts(in: context).compactMap { $0["type"] as? String }
    }

    private static func fetches(in context: JSContext) throws -> [String] {
        let json = context.evaluateScript("JSON.stringify(fetches)")?.toString() ?? "[]"
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(parsed as? [String])
    }

    private static func startCalls(in context: JSContext) -> Int {
        Int(context.evaluateScript("startCalls")?.toInt32() ?? -1)
    }

    private static func poll(in context: JSContext) {
        context.evaluateScript("intervals[0].fn();")
    }

    /// Fires the pending pre-start timeout unless a settled fetch cleared it.
    private static func fireFetchTimeout(in context: JSContext) {
        context.evaluateScript("if (timeouts[0] && !timeouts[0].cleared) { timeouts[0].fn(); }")
    }

    private static func timeoutCleared(in context: JSContext) -> Bool {
        context.evaluateScript("!!(timeouts[0] && timeouts[0].cleared)")?.toBool() == true
    }

    private static func aborted(in context: JSContext) -> Bool {
        context.evaluateScript("aborts.length > 0")?.toBool() == true
    }

    private static func hasSeedRequest(in context: JSContext) throws -> Bool {
        try posts(in: context).contains { $0["type"] as? String == "sdk.session.mirrorRequest" }
    }

    private static func seedBlob(generation: Int, entries: [String: String]) -> [String: Any] {
        [
            "version": 1,
            "scopeKey": scopeKey,
            "generation": generation,
            "writtenAt": 1_756_700_000_000,
            "entries": entries,
        ]
    }

    // -----------------------------------------------------------------------

    // MARK: Adoption

    // -----------------------------------------------------------------------

    @Test
    static func `adopts the pulled seed when local storage was wiped`() throws {
        let context = try makeContext(
            localStorage: [:],
            seed: seedBlob(generation: 5, entries: ["chatter": "c-1", "created": "123", "sessionToken": "s-1"]),
        )

        let store = try storage(in: context)
        #expect(store["chatter"] == "c-1")
        #expect(store["created"] == "123")
        #expect(store["sessionToken"] == "s-1")
        #expect(store[stampKey] == "5")
    }

    @Test
    static func `adopts wholesale removing local keys absent from the seed`() throws {
        let context = try makeContext(
            localStorage: [
                "chatter": "stale",
                "zdMessagingExternalUserId": "stale-zd",
                stampKey: "3",
            ],
            seed: seedBlob(generation: 5, entries: ["chatter": "fresh"]),
        )

        let store = try storage(in: context)
        #expect(store["chatter"] == "fresh")
        #expect(store["zdMessagingExternalUserId"] == nil)
        #expect(store[stampKey] == "5")
    }

    @Test
    static func `a mid-adoption write failure rolls back every legacy key and the stamp`() throws {
        let context = try makeContext(
            localStorage: [:],
            seed: seedBlob(
                generation: 5,
                entries: ["chatter": "fresh", "created": "222", "sessionToken": "s-fresh"],
            ),
            throwOnSetItemKey: "sessionToken",
        )

        let store = try storage(in: context)
        #expect(store["chatter"] == nil)
        #expect(store["created"] == nil)
        #expect(store["sessionToken"] == nil)
        #expect(store[stampKey] == nil)
    }

    @Test
    static func `keeps local storage wholesale when its stamp is not older`() throws {
        let context = try makeContext(
            localStorage: ["chatter": "local", "sessionToken": "local-token", stampKey: "8"],
            seed: seedBlob(generation: 5, entries: ["chatter": "native"]),
        )

        let store = try storage(in: context)
        #expect(store["chatter"] == "local")
        #expect(store["sessionToken"] == "local-token")
    }

    /// A native blob older than the local stamp means an earlier mirror never
    /// committed — the stamp is written before native acks — so the live local
    /// session must be re-posted instead of being stranded a generation ahead
    /// of native forever.
    @Test
    static func `re-mirrors the live local session when the native blob is older than the stamp`() throws {
        let context = try makeContext(
            localStorage: ["chatter": "local", "sessionToken": "local-token", stampKey: "8"],
            seed: seedBlob(generation: 5, entries: ["chatter": "native"]),
        )

        let mirrorPosts = try mirrorPosts(in: context)
        #expect(mirrorPosts.count == 1)
        let post = try #require(mirrorPosts.first)
        #expect(post["type"] as? String == "sdk.session.mirror")
        #expect(post["generation"] as? Int == 9)
        let entries = try #require(post["entries"] as? [String: String])
        #expect(entries["chatter"] == "local")
        #expect(entries["sessionToken"] == "local-token")
        #expect(entries[stampKey] == "9")
        #expect(try storage(in: context)[stampKey] == "9")
    }

    /// The same self-heal for the harsher case: the stamp survived but native
    /// holds no blob at all (killed before the write, an oversize drop, or a
    /// clear on a still-live page).
    @Test
    static func `re-mirrors the live local session when native answers empty at a stamped generation`() throws {
        let context = try makeContext(localStorage: ["chatter": "local", stampKey: "4"], seed: nil)

        let mirrorPosts = try mirrorPosts(in: context)
        #expect(mirrorPosts.count == 1)
        let post = try #require(mirrorPosts.first)
        #expect(post["type"] as? String == "sdk.session.mirror")
        #expect(post["generation"] as? Int == 5)
        let entries = try #require(post["entries"] as? [String: String])
        #expect(entries["chatter"] == "local")
        #expect(try storage(in: context)[stampKey] == "5")
    }

    @Test
    static func `does not re-mirror when the native blob already matches the local stamp`() throws {
        let context = try makeContext(
            localStorage: ["chatter": "local", stampKey: "5"],
            seed: seedBlob(generation: 5, entries: ["chatter": "local"]),
        )

        #expect(try mirrorPosts(in: context).isEmpty)
        #expect(try storage(in: context)["chatter"] == "local")
        #expect(try storage(in: context)[stampKey] == "5")
    }

    /// Amendment F — first launch after SDK upgrade: a live local session with
    /// no stamp wins and seeds the mirror, so the upgrade never logs anyone out.
    @Test
    static func `upgrade migration keeps the live local session and seeds the mirror`() throws {
        let context = try makeContext(
            localStorage: ["chatter": "live-session", "created": "111"],
            seed: seedBlob(generation: 5, entries: ["chatter": "native-old"]),
        )

        let store = try storage(in: context)
        #expect(store["chatter"] == "live-session")
        #expect(store[stampKey] == "6")

        let mirrorPosts = try mirrorPosts(in: context)
        #expect(mirrorPosts.count == 1)
        let post = try #require(mirrorPosts.first)
        #expect(post["type"] as? String == "sdk.session.mirror")
        #expect(post["generation"] as? Int == 6)
        let entries = try #require(post["entries"] as? [String: String])
        #expect(entries["chatter"] == "live-session")
        #expect(entries[stampKey] == "6")
    }

    @Test
    static func `seeds the mirror at generation 1 when native answers empty`() throws {
        let context = try makeContext(localStorage: ["chatter": "live-session"], seed: nil)

        let mirrorPosts = try mirrorPosts(in: context)
        #expect(mirrorPosts.count == 1)
        let post = try #require(mirrorPosts.first)
        #expect(post["type"] as? String == "sdk.session.mirror")
        #expect(post["scopeKey"] as? String == scopeKey)
        #expect(post["generation"] as? Int == 1)
        #expect(try storage(in: context)[stampKey] == "1")
    }

    // -----------------------------------------------------------------------

    // MARK: Fail-open validation

    // -----------------------------------------------------------------------

    @Test
    static func `rejects a pulled seed whose scope key does not match`() throws {
        var blob = seedBlob(generation: 9, entries: ["chatter": "foreign"])
        blob["scopeKey"] = "ada-session-mirror:legacy:other-bot:https://other.ada.support"
        let context = try makeContext(localStorage: [:], seed: blob)

        #expect(try storage(in: context)["chatter"] == nil)
        #expect(try mirrorPosts(in: context).isEmpty)
    }

    @Test
    static func `rejects a pulled seed carrying a key outside the legacy allowlist`() throws {
        var blob = seedBlob(generation: 9, entries: ["chatter": "x"])
        blob["entries"] = ["chatter": "x", "identityToken": "must-never-adopt"]
        let context = try makeContext(localStorage: [:], seed: blob)

        let store = try storage(in: context)
        #expect(store["chatter"] == nil)
        #expect(store["identityToken"] == nil)
    }

    @Test
    static func `rejects a pulled seed with a non-integer generation`() throws {
        var blob = seedBlob(generation: 1, entries: ["chatter": "x"])
        blob["generation"] = 1.5
        let context = try makeContext(localStorage: [:], seed: blob)

        #expect(try storage(in: context)["chatter"] == nil)
    }

    @Test
    static func `is inert on a foreign origin`() throws {
        let context = try makeContext(
            localStorage: ["chatter": "live"],
            seed: seedBlob(generation: 9, entries: ["chatter": "native"]),
            documentOrigin: "https://evil.example.com",
        )

        #expect(try storage(in: context)["chatter"] == "live")
        #expect(try posts(in: context).isEmpty)
        #expect(context.evaluateScript("intervals.length")?.toInt32() == 0)
        // With no interception on a foreign origin, the wrapper's start runs.
        #expect(startCalls(in: context) == 1)
    }

    // -----------------------------------------------------------------------

    // MARK: Watching

    // -----------------------------------------------------------------------

    @Test
    static func `polls every two seconds and listens for page lifecycle events`() throws {
        let context = try makeContext(localStorage: [:])

        #expect(context.evaluateScript("intervals[0].ms")?.toInt32() == 2000)
        #expect(context.evaluateScript("typeof listeners.visibilitychange")?.toString() == "function")
        #expect(context.evaluateScript("typeof listeners.pagehide")?.toString() == "function")
    }

    @Test
    static func `posts a mirror write with a bumped generation when a key changes`() throws {
        let context = try makeContext(
            localStorage: ["chatter": "a", stampKey: "4"],
            seed: seedBlob(generation: 4, entries: ["chatter": "a"]),
        )

        poll(in: context)
        #expect(try mirrorPosts(in: context).isEmpty)

        context.evaluateScript("store.chatter = \"b\"; store.unrelatedKey = \"never-mirrored\";")
        poll(in: context)

        let mirrorPosts = try mirrorPosts(in: context)
        #expect(mirrorPosts.count == 1)
        let post = try #require(mirrorPosts.first)
        #expect(post["type"] as? String == "sdk.session.mirror")
        #expect(post["version"] as? Int == 1)
        #expect(post["generation"] as? Int == 5)
        let entries = try #require(post["entries"] as? [String: String])
        #expect(entries["chatter"] == "b")
        #expect(entries["unrelatedKey"] == nil)
        #expect(try storage(in: context)[stampKey] == "5")
    }

    /// The stamp SURVIVES a clear-on-empty (RN parity): it is the tombstone
    /// that stops an unconfirmed or unacked native delete from resurrecting
    /// the cleared session at the next boot.
    @Test
    static func `posts a mirror clear keeping the stamp when every legacy key transitions to absent`() throws {
        let context = try makeContext(
            localStorage: ["chatter": "a", "created": "1", "sessionToken": "t", stampKey: "4"],
            seed: seedBlob(generation: 4, entries: ["chatter": "a", "created": "1", "sessionToken": "t"]),
        )

        context.evaluateScript(
            "delete store.chatter; delete store.created; delete store.sessionToken;",
        )
        poll(in: context)

        let clearPosts = try mirrorPosts(in: context)
        #expect(clearPosts.count == 1)
        let post = try #require(clearPosts.first)
        #expect(post["type"] as? String == "sdk.session.mirrorClear")
        #expect(post["scopeKey"] as? String == scopeKey)
        #expect(((post["requestId"] as? String) ?? "").isEmpty == false)
        #expect(try storage(in: context)[stampKey] == "4")
    }

    // -----------------------------------------------------------------------

    // MARK: Persistence-mode gating (decision 3)

    // -----------------------------------------------------------------------

    @Test
    static func `resolves the mode from the rollout client blob derived from the hostname`() throws {
        let context = try makeContext(localStorage: ["chatter": "live"])

        #expect(try fetches(in: context) == ["https://rollout.ada.support/ada-example/client.json"])
        #expect(context.evaluateScript("intervals.length")?.toInt32() == 1)
    }

    @Test
    static func `session mode seeds nothing and clears a stale normal-era mirror`() throws {
        let context = try makeContext(
            localStorage: ["chatter": "stale-normal-era", "sessionToken": "stale-token"],
            clientBlob: ["persistence": "session"],
        )

        let allPosts = try mirrorPosts(in: context)
        #expect(allPosts.count == 1)
        #expect(allPosts.first?["type"] as? String == "sdk.session.mirrorClear")
        let store = try storage(in: context)
        #expect(store["chatter"] == nil)
        #expect(store["sessionToken"] == nil)
        #expect(context.evaluateScript("intervals.length")?.toInt32() == 0)
    }

    @Test
    static func `private mode removes adopted keys and clears the mirror`() throws {
        let context = try makeContext(
            localStorage: [:],
            seed: seedBlob(generation: 5, entries: ["chatter": "native", "sessionToken": "t"]),
            clientBlob: ["persistence": "private"],
        )

        let store = try storage(in: context)
        #expect(store["chatter"] == nil)
        #expect(store["sessionToken"] == nil)
        #expect(store[stampKey] == nil)
        let allPosts = try mirrorPosts(in: context)
        #expect(allPosts.count == 1)
        #expect(allPosts.first?["type"] as? String == "sdk.session.mirrorClear")
        #expect(context.evaluateScript("intervals.length")?.toInt32() == 0)
    }

    @Test
    static func `an unresolvable mode makes no native write and no clear`() throws {
        let context = try makeContext(localStorage: ["chatter": "live"], clientBlob: nil)

        // The one message a fail-closed mount sends is the diagnostic — never a write or a clear.
        #expect(try mirrorPostTypes(in: context) == ["sdk.session.mirrorDiagnostic"])
        #expect(context.evaluateScript("intervals.length")?.toInt32() == 0)
        #expect(try storage(in: context)["chatter"] == "live")
    }

    @Test
    static func `a client blob without a persistence string makes no native write and no clear`() throws {
        let context = try makeContext(localStorage: ["chatter": "live"], clientBlob: ["cache_version": "v2"])

        #expect(try mirrorPosts(in: context).isEmpty)
        #expect(context.evaluateScript("intervals.length")?.toInt32() == 0)
    }

    @Test
    static func `a hung rollout fetch fails closed on timeout with no native write and no clear`() throws {
        let context = try makeContext(localStorage: ["chatter": "live"], fetchNeverSettles: true)

        #expect(try fetches(in: context) == ["https://rollout.ada.support/ada-example/client.json"])
        #expect(try mirrorPosts(in: context).isEmpty)
        #expect(context.evaluateScript("intervals.length")?.toInt32() == 0)

        fireFetchTimeout(in: context)

        #expect(aborted(in: context))
        #expect(try mirrorPostTypes(in: context) == ["sdk.session.mirrorDiagnostic"])
        #expect(context.evaluateScript("intervals.length")?.toInt32() == 0)
        #expect(try storage(in: context)["chatter"] == "live")
    }

    @Test
    static func `a resolved normal mode clears the fetch timeout and a late timeout is inert`() throws {
        let context = try makeContext(localStorage: ["chatter": "live"])

        #expect(timeoutCleared(in: context))
        #expect(context.evaluateScript("intervals.length")?.toInt32() == 1)

        fireFetchTimeout(in: context)

        #expect(aborted(in: context) == false)
        #expect(context.evaluateScript("intervals.length")?.toInt32() == 1)
    }

    @Test
    static func `the private hash override skips adoption and clears before any fetch`() throws {
        let context = try makeContext(
            localStorage: [:],
            seed: seedBlob(generation: 5, entries: ["chatter": "native"]),
            pageHash: "#private",
        )

        #expect(try storage(in: context)["chatter"] == nil)
        let allPosts = try mirrorPosts(in: context)
        #expect(allPosts.count == 1)
        #expect(allPosts.first?["type"] as? String == "sdk.session.mirrorClear")
        #expect(try fetches(in: context).isEmpty)
        #expect(try hasSeedRequest(in: context) == false)
        #expect(context.evaluateScript("intervals.length")?.toInt32() == 0)
    }

    @Test
    static func `the private query override skips adoption and clears before any fetch`() throws {
        let context = try makeContext(
            localStorage: ["chatter": "stale"],
            pageSearch: "?private=true",
        )

        #expect(try storage(in: context)["chatter"] == nil)
        let allPosts = try mirrorPosts(in: context)
        #expect(allPosts.first?["type"] as? String == "sdk.session.mirrorClear")
        #expect(try fetches(in: context).isEmpty)
    }

    // -----------------------------------------------------------------------

    // MARK: Pull request + adaEmbed.start gate (EXP-1107)

    // -----------------------------------------------------------------------

    @Test
    static func `pulls the seed from native with a versioned mirror request`() throws {
        let context = try makeContext(localStorage: ["chatter": "live"], callStart: false, deliverSeed: false)

        let request = try #require(
            try posts(in: context).first { $0["type"] as? String == "sdk.session.mirrorRequest" },
        )
        #expect(request["version"] as? Int == 1)
        #expect(request["scopeKey"] as? String == scopeKey)
        #expect(((request["requestId"] as? String) ?? "").isEmpty == false)
    }

    /// The gate: adaEmbed.start is held until BOTH the mode and the pulled seed
    /// settle, then released — so a confirmed-normal seed lands in page storage
    /// before legacy chat reads it.
    @Test
    static func `holds adaEmbed start until the seed settles then releases it`() throws {
        let context = try makeContext(
            localStorage: [:],
            seed: seedBlob(generation: 5, entries: ["chatter": "native"]),
            deliverSeed: false,
        )

        // Mode resolved normal during setup, but the seed has not arrived: held.
        #expect(startCalls(in: context) == 0)
        #expect(try storage(in: context)["chatter"] == nil)

        try deliverSeedReply(seedBlob(generation: 5, entries: ["chatter": "native"]), in: context)

        #expect(startCalls(in: context) == 1)
        #expect(try storage(in: context)["chatter"] == "native")
        #expect(try storage(in: context)[stampKey] == "5")

        // Adoption ran BEFORE apply() dropped the seed, and a second reply after
        // that drop cannot re-adopt over the settled generation.
        try deliverSeedReply(seedBlob(generation: 9, entries: ["chatter": "late"]), in: context)

        #expect(startCalls(in: context) == 1)
        #expect(try storage(in: context)["chatter"] == "native")
        #expect(try storage(in: context)[stampKey] == "5")
    }

    @Test
    static func `releases adaEmbed start without adoption on the bounded timeout`() throws {
        let context = try makeContext(
            localStorage: ["chatter": "live"],
            fetchNeverSettles: true,
            deliverSeed: false,
        )

        #expect(startCalls(in: context) == 0)

        fireFetchTimeout(in: context)

        #expect(startCalls(in: context) == 1)
        #expect(try mirrorPostTypes(in: context) == ["sdk.session.mirrorDiagnostic"])
        #expect(try storage(in: context)["chatter"] == "live")
    }

    @Test
    static func `releases adaEmbed start on a non-normal mode without waiting for the seed`() throws {
        let context = try makeContext(
            localStorage: ["chatter": "stale"],
            clientBlob: ["persistence": "session"],
            deliverSeed: false,
        )

        // No seed delivered, yet start is released because a non-normal mode
        // decides without the seed.
        #expect(startCalls(in: context) == 1)
        let allPosts = try mirrorPosts(in: context)
        #expect(allPosts.first?["type"] as? String == "sdk.session.mirrorClear")
    }

    /// The resurrection guard at the script layer: native answers empty (a
    /// clear beat the read), so normal mode adopts nothing and still releases.
    @Test
    static func `an empty native answer under normal mode adopts nothing and releases start`() throws {
        let context = try makeContext(localStorage: [:], seed: nil, deliverSeed: false)

        #expect(startCalls(in: context) == 0)

        try deliverSeedReply(nil, in: context)

        #expect(startCalls(in: context) == 1)
        #expect(try storage(in: context)["chatter"] == nil)
    }

    /// The interleaving the bounded-timer comment names: the mode resolves
    /// normal while the seed pull is still outstanding, so the SINGLE shared
    /// pre-start timer keeps bounding the seed wait (it is not cleared until
    /// both settle). When that one bound fires, start releases exactly once
    /// with no adoption, and a seed answered after the bound is inert — no
    /// double-wait, no second release, no late adoption.
    @Test
    static func `normal mode with an outstanding seed releases start once on the shared timeout`() throws {
        let context = try makeContext(
            localStorage: [:],
            seed: seedBlob(generation: 9, entries: ["chatter": "native"]),
            deliverSeed: false,
        )

        // Mode settled normal during setup; the seed has not arrived, so the
        // one pre-start timer is still armed and start stays held.
        #expect(startCalls(in: context) == 0)
        #expect(timeoutCleared(in: context) == false)

        fireFetchTimeout(in: context)

        // The single bound releases start without adopting the un-arrived seed.
        #expect(startCalls(in: context) == 1)
        #expect(try storage(in: context)["chatter"] == nil)

        // A seed answered after the bound cannot re-release start or adopt late.
        try deliverSeedReply(seedBlob(generation: 9, entries: ["chatter": "native"]), in: context)

        #expect(startCalls(in: context) == 1)
        #expect(try storage(in: context)["chatter"] == nil)
    }

    /// A pull the bound settles unanswered is not an empty answer: native may
    /// still hold a blob at a generation this page cannot see. Adoption fails
    /// open, but the watcher's write path closes, so the live page session is
    /// never posted at generation 1 over the blob the next boot would adopt.
    @Test
    static func `a timed-out seed pull closes the write path so no generation-1 post reaches native`() throws {
        let context = try makeContext(
            localStorage: ["chatter": "live"],
            seed: seedBlob(generation: 9, entries: ["chatter": "native"]),
            deliverSeed: false,
        )

        fireFetchTimeout(in: context)

        #expect(try mirrorPosts(in: context).isEmpty)
        #expect(try storage(in: context)[stampKey] == nil)

        // The watcher is armed, but a later page write still posts nothing.
        context.evaluateScript("store[\"sessionToken\"] = \"s\";")
        poll(in: context)

        #expect(try mirrorPosts(in: context).isEmpty)
        #expect(try storage(in: context)[stampKey] == nil)
    }

    /// A wipe the page can see IS an answer about the session, so a stale native
    /// blob must not outlive it — the closed write path never closes clears.
    @Test
    static func `a timed-out seed pull still posts the clear when every legacy key goes absent`() throws {
        let context = try makeContext(
            localStorage: ["chatter": "live", "sessionToken": "s"],
            seed: seedBlob(generation: 9, entries: ["chatter": "native"]),
            deliverSeed: false,
        )

        fireFetchTimeout(in: context)

        #expect(try mirrorPosts(in: context).isEmpty)

        context.evaluateScript("delete store[\"chatter\"]; delete store[\"sessionToken\"];")
        poll(in: context)

        let posts = try mirrorPosts(in: context)
        #expect(posts.count == 1)
        #expect(posts.first?["type"] as? String == "sdk.session.mirrorClear")
        #expect(posts.first?["scopeKey"] as? String == scopeKey)
    }

    // -----------------------------------------------------------------------

    // MARK: Terminal `applied` guard — a settlement that ran before the reply

    // -----------------------------------------------------------------------

    @Test
    static func `a late seed reply after a non-normal settle adopts nothing`() throws {
        let context = try makeContext(
            localStorage: ["chatter": "stale", "sessionToken": "stale-token"],
            clientBlob: ["persistence": "session"],
            deliverSeed: false,
        )

        // Non-normal mode decided without the seed: forward-clear, start released.
        #expect(startCalls(in: context) == 1)
        #expect(try mirrorPosts(in: context).count == 1)
        #expect(try mirrorPosts(in: context).first?["type"] as? String == "sdk.session.mirrorClear")

        try deliverSeedReply(
            seedBlob(generation: 9, entries: ["chatter": "native", "sessionToken": "native-token"]),
            in: context,
        )

        let store = try storage(in: context)
        #expect(store["chatter"] == nil)
        #expect(store["sessionToken"] == nil)
        #expect(store[stampKey] == nil)
        #expect(try mirrorPosts(in: context).count == 1)
        #expect(context.evaluateScript("intervals.length")?.toInt32() == 0)
        #expect(startCalls(in: context) == 1)
    }

    @Test
    static func `a late seed reply after an unresolved settle stays inert`() throws {
        let context = try makeContext(
            localStorage: ["chatter": "live"],
            clientBlob: nil,
            deliverSeed: false,
        )

        // Fail-closed: the rejected mode fetch settled the mode unresolved, so
        // apply() neither wrote nor cleared, reported once, and released start.
        #expect(startCalls(in: context) == 1)
        #expect(try mirrorPostTypes(in: context) == ["sdk.session.mirrorDiagnostic"])
        #expect(try storage(in: context)["chatter"] == "live")

        try deliverSeedReply(seedBlob(generation: 9, entries: ["chatter": "native"]), in: context)

        let store = try storage(in: context)
        #expect(store["chatter"] == "live")
        #expect(store[stampKey] == nil)
        #expect(try mirrorPostTypes(in: context) == ["sdk.session.mirrorDiagnostic"])
        #expect(context.evaluateScript("intervals.length")?.toInt32() == 0)
        #expect(startCalls(in: context) == 1)
    }

    @Test
    static func `a late seed reply after the bounded timeout adopts nothing`() throws {
        let context = try makeContext(
            localStorage: [:],
            fetchNeverSettles: true,
            deliverSeed: false,
        )

        #expect(startCalls(in: context) == 0)

        fireFetchTimeout(in: context)

        #expect(aborted(in: context))
        #expect(startCalls(in: context) == 1)

        try deliverSeedReply(
            seedBlob(generation: 9, entries: ["chatter": "native", "sessionToken": "native-token"]),
            in: context,
        )

        let store = try storage(in: context)
        #expect(store["chatter"] == nil)
        #expect(store["sessionToken"] == nil)
        #expect(store[stampKey] == nil)
        #expect(try mirrorPostTypes(in: context) == ["sdk.session.mirrorDiagnostic"])
        #expect(context.evaluateScript("intervals.length")?.toInt32() == 0)
        #expect(startCalls(in: context) == 1)
    }

    // -----------------------------------------------------------------------

    // MARK: Fail-closed rollout reporting

    // -----------------------------------------------------------------------

    /// A mount that failed closed on an unknown mode restores nothing, and its silence is
    /// indistinguishable from a mount that simply had no session to restore. Android and React
    /// Native both post this, so iOS reporting it is what makes one host handler read every
    /// wrapper.
    @Test
    static func `a rejected rollout fetch posts the diagnostic with no value in it`() throws {
        let context = try makeContext(localStorage: ["chatter": "live"], clientBlob: nil)

        let posted = try mirrorPosts(in: context)
        #expect(posted.count == 1)
        let diagnostic = try #require(posted.first)
        #expect(diagnostic["type"] as? String == "sdk.session.mirrorDiagnostic")
        #expect(diagnostic["version"] as? Int == 1)
        // The envelope Android and React Native send, and no more: no entries, no generation,
        // no seed. Native discards all three fields and fixes the reason itself, so the reason
        // that reaches the host is enum-only.
        #expect(Set(diagnostic.keys) == ["type", "version", "scopeKey"])
    }

    @Test
    static func `a hung rollout fetch posts the diagnostic once its bound fires, not before`() throws {
        let context = try makeContext(localStorage: ["chatter": "live"], fetchNeverSettles: true)

        #expect(try mirrorPostTypes(in: context).isEmpty)

        fireFetchTimeout(in: context)

        #expect(try mirrorPostTypes(in: context) == ["sdk.session.mirrorDiagnostic"])
    }

    /// The timeout and the fetch rejection can both fire. Whichever settles the mode first owns
    /// the outcome, so the later one must not report a second time.
    @Test
    static func `a fetch rejection after the bound already fired does not report twice`() throws {
        let context = try makeContext(localStorage: ["chatter": "live"], fetchNeverSettles: true)

        fireFetchTimeout(in: context)
        // The real rejection lands afterwards, the way an abort provokes it on device.
        context.evaluateScript("rejectFetch(new Error(\"aborted\"));")

        #expect(try mirrorPostTypes(in: context) == ["sdk.session.mirrorDiagnostic"])
    }

    /// A page the mode was never resolvable from is a page the mirror does not apply to, not a
    /// degraded one — reporting it would point a host at a condition it cannot act on.
    @Test
    static func `a page with no resolvable rollout host fails closed without reporting`() throws {
        let context = try makeContext(localStorage: ["chatter": "live"], hostname: "localhost")

        #expect(try fetches(in: context).isEmpty)
        #expect(try mirrorPostTypes(in: context).isEmpty)
        #expect(context.evaluateScript("intervals.length")?.toInt32() == 0)
        #expect(try storage(in: context)["chatter"] == "live")
    }

    /// A resolved-but-unusable client blob is an ANSWER about the mode, not a failure to get one,
    /// so it fails closed silently — Android draws the same line.
    @Test
    static func `a client blob without a persistence string fails closed without reporting`() throws {
        let context = try makeContext(localStorage: ["chatter": "live"], clientBlob: ["cache_version": "v2"])

        #expect(try mirrorPostTypes(in: context).isEmpty)
    }

    @Test
    static func `a resolved mode never posts the diagnostic`() throws {
        let normal = try makeContext(localStorage: ["chatter": "live"])
        let nonNormal = try makeContext(
            localStorage: ["chatter": "live"],
            clientBlob: ["persistence": "session"],
        )

        #expect(try mirrorPostTypes(in: normal).contains("sdk.session.mirrorDiagnostic") == false)
        #expect(try mirrorPostTypes(in: nonNormal) == ["sdk.session.mirrorClear"])
    }
}

// ---------------------------------------------------------------------------

// MARK: - SessionMirrorPullResponderTests

// ---------------------------------------------------------------------------

@MainActor
struct SessionMirrorPullResponderTests {
    private func makeHandler() throws -> RoutingFixture {
        let defaults = try makeIsolatedDefaults()
        let keychain = FakeSessionMirrorKeychain()
        let store = AdaSessionMirrorStore(userDefaults: defaults, keychain: keychain)
        let handler = AckSpyBridgeHandler(userDefaults: defaults, sessionMirrorStore: store)
        handler.sessionMirrorLegacyScopePrefix = "ada-session-mirror:legacy:ada-example:"
        handler.sessionMirrorRuntime = .messaging(scopePrefix: "ada-session-mirror:ada-example:")
        handler.sessionMirrorKeychainRunner = { work in work() }
        handler.sessionMirrorMainRunner = { work in work() }
        // Every real pull runs after the launch wipe; an unconfirmed one answers
        // empty, which the reinstall tests below drive deliberately.
        store.prepareForLaunch()
        return RoutingFixture(handler: handler, store: store, keychain: keychain, defaults: defaults)
    }

    private func mirrorWrite(
        scopeKey: String = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support",
        generation: Int = 7,
        entries: [String: String] = ["messagingAuthState": "{\"jwt\":\"opaque\"}"],
    ) -> [String: Any] {
        [
            "type": "sdk.session.mirror",
            "version": 1,
            "scopeKey": scopeKey,
            "generation": generation,
            "writtenAt": 1_756_700_000_000,
            "entries": entries,
        ]
    }

    private func mirrorRequest(scopeKey: String, requestId: String = "req-1") -> [String: Any] {
        ["type": "sdk.session.mirrorRequest", "version": 1, "scopeKey": scopeKey, "requestId": requestId]
    }

    /// The core pull: native reads its store live for the requested scope and
    /// answers `sdk.sessionMirror.seed` with the stored blob.
    @Test
    func `the pull responder answers the stored blob for the requested scope`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let scopeKey = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"
        handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeKey, generation: 7))
        var answered: [(String, [String: Any]?)] = []
        handler.onSeed = { answered.append(($0, $1)) }

        handler.handleBridgeMessage(mirrorRequest(scopeKey: scopeKey, requestId: "req-seed"))

        #expect(answered.count == 1)
        let (requestId, seed) = try #require(answered.first)
        #expect(requestId == "req-seed")
        let blob = try #require(seed)
        #expect(blob["generation"] as? Int == 7)
        #expect(blob["scopeKey"] as? String == scopeKey)
    }

    /// The resurrection guarantee: a clear ordered before the read makes the
    /// live read answer EMPTY. There is no frozen document-start blob to
    /// re-inject, so a cleared session cannot come back.
    @Test
    func `the pull responder answers empty after a clear ordered before the read`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let scopeKey = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"
        handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeKey))
        var answered: [(String, [String: Any]?)] = []
        handler.onSeed = { answered.append(($0, $1)) }

        // Clear is enqueued (and, with the inline runner, runs) before the read.
        handler.handleBridgeMessage([
            "type": "sdk.session.mirrorClear",
            "version": 1,
            "scopeKey": scopeKey,
            "requestId": "clear-1",
        ])
        handler.handleBridgeMessage(mirrorRequest(scopeKey: scopeKey, requestId: "req-after-clear"))

        #expect(answered.count == 1)
        let (requestId, seed) = try #require(answered.first)
        #expect(requestId == "req-after-clear")
        #expect(seed == nil)
    }

    /// A request for a scope the store never held answers empty rather than a
    /// foreign blob.
    @Test
    func `the pull responder answers empty when no blob is stored`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        var answered: [(String, [String: Any]?)] = []
        handler.onSeed = { answered.append(($0, $1)) }

        handler.handleBridgeMessage(
            mirrorRequest(scopeKey: "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"),
        )

        #expect(answered.count == 1)
        #expect(answered.first?.1 == nil)
    }

    /// Messaging vs legacy scope isolation: the Messaging-pinned runtime never
    /// answers the legacy blob. It replies EMPTY rather than staying silent, so
    /// the web side resolves at once instead of waiting out its fail-open
    /// timeout — the blob still does not cross.
    @Test
    func `the messaging responder answers empty for a legacy scope`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let legacyScope = "ada-session-mirror:legacy:ada-example:https://ada-example.ada.support"
        // Store a legacy blob directly so the only reason for the empty answer
        // is classification, not absence.
        fixture.store.store(blobJson: "{\"scopeKey\":\"\(legacyScope)\"}", scopeKey: legacyScope)
        var answered: [(String, [String: Any]?)] = []
        handler.onSeed = { answered.append(($0, $1)) }

        handler.handleBridgeMessage(mirrorRequest(scopeKey: legacyScope, requestId: "req-legacy-scope"))

        #expect(answered.count == 1)
        #expect(answered.first?.0 == "req-legacy-scope")
        #expect(answered.first?.1 == nil)
    }

    /// The legacy-pinned runtime answers its own exact scope with the blob and a
    /// messaging-scoped request with an empty seed — the two never cross.
    @Test
    func `the legacy responder answers its own scope and empties the messaging scope`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let legacyScope = "ada-session-mirror:legacy:ada-example:https://ada-example.ada.support"
        handler.sessionMirrorRuntime = .legacy(scopeKey: legacyScope)
        handler.handleBridgeMessage(
            mirrorWrite(scopeKey: legacyScope, entries: ["chatter": "abc123"]),
        )
        var answered: [(String, [String: Any]?)] = []
        handler.onSeed = { answered.append(($0, $1)) }

        handler.handleBridgeMessage(
            mirrorRequest(
                scopeKey: "ada-session-mirror:ada-example:origin:https://ada-example.ada.support",
                requestId: "req-messaging",
            ),
        )
        #expect(answered.count == 1)
        #expect(answered.first?.0 == "req-messaging")
        #expect(answered.first?.1 == nil)

        handler.handleBridgeMessage(mirrorRequest(scopeKey: legacyScope, requestId: "req-legacy"))
        #expect(answered.count == 2)
        let (_, seed) = try #require(answered.last)
        #expect((try #require(seed))["scopeKey"] as? String == legacyScope)
    }

    /// A legacy blob relabeled to carry a Messaging credential (JWT) must not be
    /// answered even if it somehow sits under the legacy scope — the allowlist
    /// is re-checked at read time.
    @Test
    func `the legacy responder answers empty for a blob outside the legacy allowlist`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let legacyScope = "ada-session-mirror:legacy:ada-example:https://ada-example.ada.support"
        handler.sessionMirrorRuntime = .legacy(scopeKey: legacyScope)
        let poisoned = try jsonString([
            "version": 1,
            "scopeKey": legacyScope,
            "generation": 2,
            "entries": ["chatter": "x", "messagingAuthState": "{\"jwt\":\"opaque\"}"],
        ])
        fixture.store.store(blobJson: poisoned, scopeKey: legacyScope)
        var answered: [(String, [String: Any]?)] = []
        handler.onSeed = { answered.append(($0, $1)) }

        handler.handleBridgeMessage(mirrorRequest(scopeKey: legacyScope))

        #expect(answered.count == 1)
        #expect(answered.first?.1 == nil)
    }

    /// An unsupported protocol version is still refused a blob, but it is
    /// refused OUT LOUD: a `version: 2` request gets an empty seed under its own
    /// requestId, never this native's v1 blob and never silence.
    @Test
    func `the pull responder answers empty for an unsupported protocol version`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let scopeKey = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"
        handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeKey, generation: 7))
        var answered: [(String, [String: Any]?)] = []
        handler.onSeed = { answered.append(($0, $1)) }

        handler.handleBridgeMessage([
            "type": "sdk.session.mirrorRequest", "version": 2, "scopeKey": scopeKey, "requestId": "req-v2",
        ])

        #expect(answered.count == 1)
        #expect(answered.first?.0 == "req-v2")
        #expect(answered.first?.1 == nil)
    }

    /// The version gate is on the READ too, not only on the write that produced
    /// the blob: once a v2 writer ships it shares the Keychain with binaries that
    /// only speak v1, and a v1 binary must never hand that v2 payload back
    /// labelled as a v1 seed.
    @Test
    func `the pull responder answers empty for a stored blob of an unsupported version`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let scopeKey = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"
        let futureBlob = try jsonString([
            "version": 2,
            "scopeKey": scopeKey,
            "generation": 3,
            "entries": ["messagingAuthState": "{\"jwt\":\"opaque\"}"],
        ])
        fixture.store.store(blobJson: futureBlob, scopeKey: scopeKey)
        var answered: [(String, [String: Any]?)] = []
        handler.onSeed = { answered.append(($0, $1)) }

        handler.handleBridgeMessage(mirrorRequest(scopeKey: scopeKey, requestId: "req-blob-v2"))

        #expect(answered.count == 1)
        #expect(answered.first?.0 == "req-blob-v2")
        #expect(answered.first?.1 == nil)
    }

    /// A missing or blank `requestId` is the one case that stays dropped: there
    /// is no pending web-side request to resolve, so there is nothing to answer.
    @Test
    func `the pull responder drops a request with no usable request id`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let scopeKey = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"
        handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeKey))
        var answered = false
        handler.onSeed = { _, _ in answered = true }

        handler.handleBridgeMessage([
            "type": "sdk.session.mirrorRequest", "version": 1, "scopeKey": scopeKey, "requestId": "",
        ])
        handler.handleBridgeMessage([
            "type": "sdk.session.mirrorRequest", "version": 1, "scopeKey": scopeKey,
        ])

        #expect(!answered)
    }

    /// An empty `scopeKey` cannot classify, so it is answered empty rather than
    /// dropped — the same refuse-out-loud contract as a foreign scope.
    @Test
    func `the pull responder answers empty for a blank scope key`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        handler.handleBridgeMessage(mirrorWrite())
        var answered: [(String, [String: Any]?)] = []
        handler.onSeed = { answered.append(($0, $1)) }

        handler.handleBridgeMessage(mirrorRequest(scopeKey: "", requestId: "req-blank-scope"))

        #expect(answered.count == 1)
        #expect(answered.first?.0 == "req-blank-scope")
        #expect(answered.first?.1 == nil)
    }

    /// The reinstall guarantee. Keychain blobs survive uninstall and the web
    /// runtime recomputes the same scope key for the same handle/endpoint, so an
    /// unconfirmed launch wipe must answer every pull empty — otherwise the
    /// previous install's JWT and refresh token reach the very next boot.
    @Test
    func `the pull responder answers empty while the reinstall wipe is unconfirmed`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let scopeKey = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"
        handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeKey))
        // Reinstall: UserDefaults (the sentinel) is gone, the Keychain blob is
        // not, and the launch wipe fails — the Keychain is locked before first
        // unlock.
        fixture.defaults.removeObject(forKey: AdaSessionMirrorStore.installedSentinelKey)
        fixture.keychain.failDeletes = true
        fixture.store.prepareForLaunch()
        var answered: [(String, [String: Any]?)] = []
        handler.onSeed = { answered.append(($0, $1)) }

        handler.handleBridgeMessage(mirrorRequest(scopeKey: scopeKey, requestId: "req-reinstall"))

        #expect(answered.count == 1)
        #expect(answered.first?.0 == "req-reinstall")
        #expect(answered.first?.1 == nil)
        #expect(fixture.keychain.items[scopeKey] != nil)
    }

    /// The gate is not a one-way brick: the responder retries the wipe, so once
    /// the Keychain unlocks the previous install's blob is destroyed and this
    /// install's own session is answerable again.
    @Test
    func `the pull responder resumes once the retried reinstall wipe confirms`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let scopeKey = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"
        handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeKey, generation: 7))
        fixture.defaults.removeObject(forKey: AdaSessionMirrorStore.installedSentinelKey)
        fixture.keychain.failDeletes = true
        fixture.store.prepareForLaunch()
        fixture.keychain.failDeletes = false
        var answered: [(String, [String: Any]?)] = []
        handler.onSeed = { answered.append(($0, $1)) }

        handler.handleBridgeMessage(mirrorRequest(scopeKey: scopeKey, requestId: "req-retry"))

        #expect(answered.first?.1 == nil)
        #expect(fixture.keychain.items.isEmpty)

        handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeKey, generation: 2))
        handler.handleBridgeMessage(mirrorRequest(scopeKey: scopeKey, requestId: "req-fresh"))

        #expect(answered.count == 2)
        let blob = try #require(answered.last?.1)
        #expect(blob["generation"] as? Int == 2)
    }

    /// No pinned runtime (localhost-Legacy bridge runtime) still refuses the
    /// blob for the pull — and says so, so the boot pull is not left hanging.
    @Test
    func `the pull responder answers empty when no runtime is pinned`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        let scopeKey = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"
        handler.handleBridgeMessage(mirrorWrite(scopeKey: scopeKey))
        handler.sessionMirrorRuntime = nil
        var answered: [(String, [String: Any]?)] = []
        handler.onSeed = { answered.append(($0, $1)) }

        handler.handleBridgeMessage(mirrorRequest(scopeKey: scopeKey, requestId: "req-unpinned"))

        #expect(answered.count == 1)
        #expect(answered.first?.0 == "req-unpinned")
        #expect(answered.first?.1 == nil)
    }
}

// ---------------------------------------------------------------------------

// MARK: - SessionMirrorDocumentTicketTests

// ---------------------------------------------------------------------------

/// Holds work handed to the keychain runner instead of running it, so a test can move the
/// main document in the window between a request being accepted and its reply being written.
/// That window is the defect: the Keychain read is off-thread, and the reply carries the whole
/// mirror blob — the messaging JWT, its refresh token, the chatter token, the Zendesk keys.
private final class DeferredKeychainRunner {
    var pending: [() -> Void] = []

    func drain() {
        let work = pending
        pending = []
        for item in work { item() }
    }
}

private struct TicketFixture {
    let handler: AdaBridgeHandler
    let webView: ScriptCapturingWebView
    let store: AdaSessionMirrorStore
    let keychain: FakeSessionMirrorKeychain
}

@MainActor
struct SessionMirrorDocumentTicketTests {
    private static let trustedOrigin = "https://messaging-assets.ada.support"
    private static let runtimeDocument = "https://messaging-assets.ada.support/sdk/webview.html?handle=ada-example"
    private static let scopeKey = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"
    private static let credential = "jwt.and.refresh-token"

    private func makeFixture(deferring runner: DeferredKeychainRunner? = nil) throws -> TicketFixture {
        let defaults = try makeIsolatedDefaults()
        let keychain = FakeSessionMirrorKeychain()
        let store = AdaSessionMirrorStore(userDefaults: defaults, keychain: keychain)
        let handler = AdaBridgeHandler(userDefaults: defaults, sessionMirrorStore: store)
        let webView = ScriptCapturingWebView(documentUrl: URL(string: Self.runtimeDocument))
        handler.trustedOrigin = Self.trustedOrigin
        handler.trustedDocumentUrl = Self.runtimeDocument
        handler.sessionMirrorCommandWebView = webView
        handler.sessionMirrorLegacyScopePrefix = "ada-session-mirror:legacy:ada-example:"
        handler.sessionMirrorRuntime = .messaging(scopePrefix: "ada-session-mirror:ada-example:")
        if let runner {
            handler.sessionMirrorKeychainRunner = { work in runner.pending.append(work) }
        } else {
            handler.sessionMirrorKeychainRunner = { work in work() }
        }
        handler.sessionMirrorMainRunner = { work in work() }
        store.prepareForLaunch()
        store.store(blobJson: Self.storedBlob, scopeKey: Self.scopeKey)
        return TicketFixture(handler: handler, webView: webView, store: store, keychain: keychain)
    }

    private static var storedBlob: String {
        """
        {"version":1,"scopeKey":"\(scopeKey)","generation":7,\
        "entries":{"messagingAuthState":"\(credential)"}}
        """
    }

    private func pullRequest(requestId: String = "req-seed") -> [String: Any] {
        [
            "type": "sdk.session.mirrorRequest",
            "version": 1,
            "scopeKey": Self.scopeKey,
            "requestId": requestId,
        ]
    }

    @Test
    func `the seed reply reaches the document that asked for it`() throws {
        let runner = DeferredKeychainRunner()
        let fixture = try makeFixture(deferring: runner)

        fixture.handler.handleBridgeMessage(pullRequest())
        runner.drain()

        let script = try #require(fixture.webView.capturedScripts.first)
        #expect(script.contains("sdk.sessionMirror.seed"))
        #expect(script.contains(Self.credential))
    }

    /// The headline case: the read is handed to a serial queue and the reply lands later, by
    /// which time an in-place main-frame navigation can have replaced the runtime with a page
    /// that still sees `window.__ADA_BRIDGE_DISPATCH__`. The ticket captured when the request
    /// was accepted no longer matches, so the credentials are not written.
    @Test
    func `the seed reply is dropped when a foreign document replaced the runtime in flight`() throws {
        let runner = DeferredKeychainRunner()
        let fixture = try makeFixture(deferring: runner)

        fixture.handler.handleBridgeMessage(pullRequest())
        fixture.webView.documentUrl = URL(string: "https://evil.example/collect.html")
        runner.drain()

        #expect(fixture.webView.capturedScripts.isEmpty)
    }

    /// Document identity, not origin: the Ada CDN origin serves other documents, and the start
    /// parameters this run was launched with ride the query. An origin-only check would pass
    /// both of these navigations.
    @Test(
        "the seed reply is dropped when the main frame moved to another document on the same origin",
        arguments: [
            "https://messaging-assets.ada.support/sdk/chat.html",
            "https://messaging-assets.ada.support/sdk/webview.html?handle=other-bot",
        ],
    )
    func seedReplyIsDroppedOnSameOriginDocumentChange(url: String) throws {
        let runner = DeferredKeychainRunner()
        let fixture = try makeFixture(deferring: runner)

        fixture.handler.handleBridgeMessage(pullRequest())
        fixture.webView.documentUrl = URL(string: url)
        runner.drain()

        #expect(fixture.webView.capturedScripts.isEmpty)
    }

    /// A recovery rebuild (`hardResetWebView`) mounts a new WebView on the same URL. The
    /// previous WebView's request must not be answered into it.
    @Test
    func `the seed reply is dropped when the WebView was rebuilt in flight`() throws {
        let runner = DeferredKeychainRunner()
        let fixture = try makeFixture(deferring: runner)

        fixture.handler.handleBridgeMessage(pullRequest())
        let rebuilt = ScriptCapturingWebView(documentUrl: URL(string: Self.runtimeDocument))
        fixture.handler.sessionMirrorCommandWebView = rebuilt
        runner.drain()

        #expect(rebuilt.capturedScripts.isEmpty)
        #expect(fixture.webView.capturedScripts.isEmpty)
    }

    /// The clear ack is deferred across the same off-thread window as the seed. Dropping it
    /// times the web side out, which tombstones the blob — the safe direction.
    @Test
    func `the clear ack is dropped when a foreign document replaced the runtime in flight`() throws {
        let runner = DeferredKeychainRunner()
        let fixture = try makeFixture(deferring: runner)

        fixture.handler.handleBridgeMessage([
            "type": "sdk.session.mirrorClear",
            "version": 1,
            "scopeKey": Self.scopeKey,
            "requestId": "req-clear",
        ])
        fixture.webView.documentUrl = URL(string: "https://evil.example/collect.html")
        runner.drain()

        #expect(fixture.webView.capturedScripts.isEmpty)
        // The delete still happened — only the acknowledgement is withheld.
        #expect(fixture.store.storedBlobJson(forScopeKey: Self.scopeKey) == nil)
    }

    /// Withholding the reply is correct and it is also the whole visible outcome: the page waits
    /// out its pull budget and adopts nothing, which is indistinguishable from having no session.
    /// A mount whose main frame keeps moving under it therefore mirrors nothing, forever, in
    /// silence — so the refusal itself is reported.
    @Test(
        "a mirror reply refused by the document guard reports the document mismatch",
        arguments: [
            ["type": "sdk.session.mirrorRequest", "version": 1, "requestId": "req-seed"],
            ["type": "sdk.session.mirrorClear", "version": 1, "requestId": "req-clear"],
        ],
    )
    func refusedMirrorReplyReportsDocumentMismatch(message: [String: Any]) throws {
        let runner = DeferredKeychainRunner()
        let fixture = try makeFixture(deferring: runner)
        let delegate = EventSpyDelegate()
        fixture.handler.delegate = delegate

        fixture.handler.handleBridgeMessage(message.merging(["scopeKey": Self.scopeKey]) { current, _ in current })
        fixture.webView.documentUrl = URL(string: "https://evil.example/collect.html")
        runner.drain()

        #expect(fixture.webView.capturedScripts.isEmpty)
        #expect(delegate.diagnosticReasons() == ["origin-mismatch"])
    }

    /// The reply the guard DID honour must stay silent, or the reason means nothing.
    @Test
    func `a seed reply the document guard honours reports nothing`() throws {
        let runner = DeferredKeychainRunner()
        let fixture = try makeFixture(deferring: runner)
        let delegate = EventSpyDelegate()
        fixture.handler.delegate = delegate

        fixture.handler.handleBridgeMessage(pullRequest())
        runner.drain()

        #expect(fixture.webView.capturedScripts.count == 1)
        #expect(delegate.events.isEmpty)
    }

    /// Host commands are ticketed at the moment they are issued, so one issued while a foreign
    /// document holds the main frame is not written into it either.
    @Test
    func `a host command is not injected into a document that replaced the runtime`() throws {
        let fixture = try makeFixture()

        fixture.handler.setLanguage("fr", to: fixture.webView)
        #expect(fixture.webView.capturedScripts.count == 1)

        fixture.webView.documentUrl = URL(string: "https://evil.example/collect.html")
        fixture.handler.setSensitiveMetaFields(["ssn": "000-00-0000"], to: fixture.webView)

        #expect(fixture.webView.capturedScripts.count == 1)
    }

    /// No pinned origin mints no ticket, so the injection path fails closed rather than
    /// writing into whatever document happens to be loaded.
    @Test
    func `no ticket is minted without a pinned trusted origin`() throws {
        let fixture = try makeFixture()
        fixture.handler.trustedOrigin = nil

        #expect(fixture.handler.captureDocumentTicket(for: fixture.webView) == nil)

        fixture.handler.setLanguage("fr", to: fixture.webView)
        #expect(fixture.webView.capturedScripts.isEmpty)
    }

    /// The same fail-closed rule for the entry document: knowing the origin is not knowing which
    /// document was loaded, and every ticket is minted against that.
    @Test
    func `no ticket is minted without a pinned entry document`() throws {
        let fixture = try makeFixture()
        fixture.handler.trustedDocumentUrl = nil

        #expect(fixture.handler.captureDocumentTicket(for: fixture.webView) == nil)

        fixture.handler.setLanguage("fr", to: fixture.webView)
        #expect(fixture.webView.capturedScripts.isEmpty)
    }

    /// The headline hole: redemption compares the full URL, so it only catches a document that
    /// arrives AFTER a ticket was minted. An attacker needs no outstanding ticket — once the
    /// replacement holds the main frame, every subsequent host command MINTS ITS OWN fresh ticket
    /// against it. Origin alone passed all of these: the CDN root serves other bots' runs of the
    /// same entry, a second top-level entry that ignores unrecognised params, and any other page.
    @Test(
        "no ticket is minted for a same-origin document that is not the mount's own entry",
        arguments: [
            "https://messaging-assets.ada.support/sdk/webview.html?handle=attacker",
            "https://messaging-assets.ada.support/sdk/webview.html?handle=ada-example&handle=attacker",
            "https://messaging-assets.ada.support/sdk/chat.html?handle=ada-example",
            "https://messaging-assets.ada.support/sdk/webview.html",
            "https://messaging-assets.ada.support/marketing/sdk/webview.html?handle=ada-example",
        ],
    )
    func noTicketIsMintedForAForeignSameOriginDocument(url: String) throws {
        let fixture = try makeFixture()
        fixture.webView.documentUrl = URL(string: url)

        #expect(fixture.handler.captureDocumentTicket(for: fixture.webView) == nil)

        fixture.handler.setSensitiveMetaFields(["ssn": "000-00-0000"], to: fixture.webView)
        fixture.handler.setDeviceToken("apns-token", to: fixture.webView)
        #expect(fixture.webView.capturedScripts.isEmpty)
    }

    /// ...including the pull reply, which carries the whole mirror blob — the JWT, the refresh
    /// token and the chatter token. The request is posted BY the replacement, so its ticket is
    /// minted while the replacement already holds the frame and no in-flight swap is involved.
    @Test
    func `the seed reply is refused when the replacement document asked for it`() throws {
        let fixture = try makeFixture()
        fixture.webView.documentUrl = URL(string: "https://messaging-assets.ada.support/sdk/webview.html?handle=evil")

        fixture.handler.handleBridgeMessage(pullRequest())

        #expect(fixture.webView.capturedScripts.isEmpty)
    }

    /// The build-scoped prefix the edge 302 adds is tolerated, and a fragment route is not a
    /// different configuration — neither may cost the runtime its own tickets.
    @Test(
        "a ticket is still minted for the entry document the edge redirected to",
        arguments: [
            "https://messaging-assets.ada.support/9f2c1ab/sdk/webview.html?handle=ada-example",
            "https://messaging-assets.ada.support/sdk/webview.html?handle=ada-example#/conversation",
        ],
    )
    func aTicketIsMintedForTheRedirectedEntryDocument(url: String) throws {
        let fixture = try makeFixture()
        fixture.webView.documentUrl = URL(string: url)

        #expect(fixture.handler.captureDocumentTicket(for: fixture.webView) != nil)

        fixture.handler.setLanguage("fr", to: fixture.webView)
        #expect(fixture.webView.capturedScripts.count == 1)
    }
}

// ---------------------------------------------------------------------------

// MARK: - SessionMirrorReadFailureTests

// ---------------------------------------------------------------------------

/// A Keychain read can fail without the item being gone — `errSecInteractionNotAllowed` is
/// exactly what an `AfterFirstUnlockThisDeviceOnly` item returns for a process running before
/// the first unlock after reboot. Collapsing that to "absent" tells the web runtime native
/// holds nothing, which opens its write path and lets a generation-1 write overwrite the
/// intact blob.
@MainActor
struct SessionMirrorReadFailureTests {
    private static let scopeKey = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"

    private func makeHandler() throws -> RoutingFixture {
        let defaults = try makeIsolatedDefaults()
        let keychain = FakeSessionMirrorKeychain()
        let store = AdaSessionMirrorStore(userDefaults: defaults, keychain: keychain)
        let handler = AckSpyBridgeHandler(userDefaults: defaults, sessionMirrorStore: store)
        handler.sessionMirrorLegacyScopePrefix = "ada-session-mirror:legacy:ada-example:"
        handler.sessionMirrorRuntime = .messaging(scopePrefix: "ada-session-mirror:ada-example:")
        handler.sessionMirrorKeychainRunner = { work in work() }
        handler.sessionMirrorMainRunner = { work in work() }
        store.prepareForLaunch()
        return RoutingFixture(handler: handler, store: store, keychain: keychain, defaults: defaults)
    }

    private func mirrorRequest(requestId: String) -> [String: Any] {
        [
            "type": "sdk.session.mirrorRequest",
            "version": 1,
            "scopeKey": Self.scopeKey,
            "requestId": requestId,
        ]
    }

    @Test
    func `a refused read reports failed while a missing item reports absent`() throws {
        let defaults = try makeIsolatedDefaults()
        let keychain = FakeSessionMirrorKeychain()
        let store = AdaSessionMirrorStore(userDefaults: defaults, keychain: keychain)
        store.store(blobJson: "{\"generation\":3}", scopeKey: "scope-a")

        #expect(store.readBlobJson(forScopeKey: "scope-b") == .absent)

        keychain.failReads = true
        #expect(store.readBlobJson(forScopeKey: "scope-a") == .failed)
        #expect(store.readBlobJson(forScopeKey: "scope-b") == .failed)
    }

    /// The clear ack means "the blob can no longer resurrect this session". A read-back that
    /// could not be performed does not establish that, so it must not confirm the delete.
    @Test
    func `a clear is not confirmed when the read-back could not be performed`() throws {
        let defaults = try makeIsolatedDefaults()
        let keychain = FakeSessionMirrorKeychain()
        let store = AdaSessionMirrorStore(userDefaults: defaults, keychain: keychain)
        store.store(blobJson: "{}", scopeKey: Self.scopeKey)
        keychain.failReads = true

        #expect(store.clear(scopeKey: Self.scopeKey) == false)
    }

    /// The fix: silence, not an empty seed. Core already models the unanswered pull as its
    /// `seed-timeout` outcome — adoption fails open, writes stay suppressed — which is the
    /// only outcome that does not risk destroying the blob.
    @Test
    func `the pull responder sends no reply when the keychain read fails`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        fixture.store.store(blobJson: "{\"version\":1,\"scopeKey\":\"\(Self.scopeKey)\"}", scopeKey: Self.scopeKey)
        fixture.keychain.failReads = true
        var answered: [(String, [String: Any]?)] = []
        handler.onSeed = { answered.append(($0, $1)) }

        handler.handleBridgeMessage(mirrorRequest(requestId: "req-unreadable"))

        #expect(answered.isEmpty)
    }

    /// The discriminating half: a store that genuinely holds nothing is still answered with an
    /// explicit empty seed, so a first-run boot resolves at once instead of burning the web
    /// side's 4500 ms pull budget. Silence is reserved for the read that did not happen.
    @Test
    func `the pull responder still answers an empty seed when nothing is stored`() throws {
        let fixture = try makeHandler()
        let handler = fixture.handler
        var answered: [(String, [String: Any]?)] = []
        handler.onSeed = { answered.append(($0, $1)) }

        handler.handleBridgeMessage(mirrorRequest(requestId: "req-empty"))

        #expect(answered.count == 1)
        #expect(answered.first?.0 == "req-empty")
        #expect(answered.first?.1 == nil)
    }
}

// ---------------------------------------------------------------------------

// MARK: - SessionMirrorCrossHandlerOrderingTests

// ---------------------------------------------------------------------------

/// Keychain fake whose write BLOCKS inside the store until the test opens the gate, so a
/// mirror write one handler already accepted is still uncommitted while another handler
/// runs the app-scoped sign-out wipe. The gate is waited on OUTSIDE the lock: holding the
/// lock across it would serialize the two handlers by itself and hide the defect.
private final class GatedSessionMirrorKeychain: AdaSessionMirrorKeychain, @unchecked Sendable {
    let writeGate = DispatchSemaphore(value: 0)
    let writeCommitted = DispatchSemaphore(value: 0)
    let wipeCommitted = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    @discardableResult
    func setData(_ data: Data, forAccount account: String) -> Bool {
        // Bounded so a failing assertion cannot wedge the process-wide mirror queue and
        // take every later test down with it.
        _ = writeGate.wait(timeout: .now() + 5)
        lock.lock()
        items[account] = data
        lock.unlock()
        writeCommitted.signal()
        return true
    }

    func readData(forAccount account: String) -> AdaSessionMirrorReadResult<Data> {
        lock.lock()
        defer { lock.unlock() }
        guard let data = items[account] else { return .absent }
        return .found(data)
    }

    func readAllAccounts() -> AdaSessionMirrorReadResult<[String]> {
        lock.lock()
        defer { lock.unlock() }
        guard !items.isEmpty else { return .absent }
        return .found(items.keys.sorted())
    }

    @discardableResult
    func deleteData(forAccount account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        items.removeValue(forKey: account)
        return true
    }

    @discardableResult
    func deleteAll() -> Bool {
        lock.lock()
        items = [:]
        lock.unlock()
        wipeCommitted.signal()
        return true
    }
}

/// Waits for `semaphore` on a background thread, so a test holding a window open never
/// blocks the main actor the other `@MainActor` suites are queued on.
private func awaitSignal(_ semaphore: DispatchSemaphore, timeout: TimeInterval) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success)
        }
    }
}

/// A handler is per mount; the Keychain it writes to is app-wide, and unmounting a handler
/// does not cancel work it already enqueued. So two mounts share one store, and only
/// process-wide serialization makes a clear run after every write already enqueued.
///
/// Unlike every other suite here, these drive the REAL keychain runner — the inline
/// substitute collapses both handlers onto the calling thread, which is exactly the
/// interleaving under test.
@MainActor
struct SessionMirrorCrossHandlerOrderingTests {
    private static let scopeKey = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"

    private struct Fixture {
        let signOutHandler: AdaBridgeHandler
        let mirroringHandler: AdaBridgeHandler
        let store: AdaSessionMirrorStore
        let keychain: GatedSessionMirrorKeychain
    }

    private func makeFixture() throws -> Fixture {
        let keychain = GatedSessionMirrorKeychain()
        let store = AdaSessionMirrorStore(userDefaults: try makeIsolatedDefaults(), keychain: keychain)
        let handlers = try (0 ..< 2).map { _ -> AdaBridgeHandler in
            let handler = AdaBridgeHandler(userDefaults: try makeIsolatedDefaults(), sessionMirrorStore: store)
            handler.sessionMirrorLegacyScopePrefix = "ada-session-mirror:legacy:ada-example:"
            handler.sessionMirrorRuntime = .messaging(scopePrefix: "ada-session-mirror:ada-example:")
            return handler
        }
        return Fixture(
            signOutHandler: handlers[0],
            mirroringHandler: handlers[1],
            store: store,
            keychain: keychain,
        )
    }

    private func mirrorWrite() -> [String: Any] {
        [
            "type": "sdk.session.mirror",
            "version": 1,
            "scopeKey": Self.scopeKey,
            "generation": 7,
            "writtenAt": 1_756_700_000_000,
            "entries": ["messagingAuthState": "{\"jwt\":\"opaque\"}"],
        ]
    }

    /// The app-scoped sign-out wipe against a write another mount already accepted. Ordered
    /// per handler, the wipe runs beside that write, verifies the store empty and reports
    /// the sign-out complete; the write then commits the signed-out session's blob behind
    /// it, and the next launch's seed pull hands it straight back.
    @Test
    func `a sign-out wipe cannot outrun another handler's pending mirror write`() async throws {
        let fixture = try makeFixture()
        fixture.mirroringHandler.handleBridgeMessage(mirrorWrite())

        fixture.signOutHandler.clearAllSessionMirrors()
        // Ordered per handler the wipe settles inside this window, beside the write the
        // gate still holds; ordered process-wide it cannot start until the gate opens.
        let wipedBesidePendingWrite = await awaitSignal(fixture.keychain.wipeCommitted, timeout: 2)
        fixture.keychain.writeGate.signal()

        #expect(await awaitSignal(fixture.keychain.writeCommitted, timeout: 5))
        if !wipedBesidePendingWrite {
            #expect(await awaitSignal(fixture.keychain.wipeCommitted, timeout: 5))
        }
        #expect(fixture.store.readBlobJson(forScopeKey: Self.scopeKey) == .absent)
    }

    /// The other side of that ordering. `AdaWebHost` is `@MainActor`, so an actor-correct
    /// `clearPersistedStateDurably()` runs ON the main actor — there is no off-main call for a
    /// host to make. Ordered behind another mount's stalled write, a wait for the whole
    /// durable bound is therefore a multi-second main-thread freeze, and the wipe could not
    /// have been confirmed in that window anyway. The caller is answered at the start grace
    /// instead, and the wipe it left queued still lands after the write.
    @Test
    func `a durable sign-out is answered without waiting out another handler's stalled write`() async throws {
        let fixture = try makeFixture()
        fixture.mirroringHandler.handleBridgeMessage(mirrorWrite())

        let start = DispatchTime.now()
        let confirmed = fixture.signOutHandler.clearAllSessionMirrorsDurably()
        let blockedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

        #expect(!confirmed)
        #expect(blockedSeconds < AdaBridgeHandler.sessionMirrorClearDurablyTimeout / 2)

        fixture.keychain.writeGate.signal()
        #expect(await awaitSignal(fixture.keychain.writeCommitted, timeout: 5))
        #expect(await awaitSignal(fixture.keychain.wipeCommitted, timeout: 5))
        #expect(fixture.store.readBlobJson(forScopeKey: Self.scopeKey) == .absent)
    }
}

// ---------------------------------------------------------------------------

// MARK: - SessionMirrorDurableClearThreadingTests

// ---------------------------------------------------------------------------

/// Keychain fake whose service-wide delete stalls AFTER the wipe has begun. That is the shape the
/// start grace cannot bound — the wipe already reached the head of the mirror queue, so the grace
/// is satisfied and the remaining wait is the wipe itself.
private final class StallingWipeKeychain: AdaSessionMirrorKeychain, @unchecked Sendable {
    private let wipeDelay: TimeInterval
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    init(wipeDelay: TimeInterval) {
        self.wipeDelay = wipeDelay
    }

    @discardableResult
    func setData(_ data: Data, forAccount account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        items[account] = data
        return true
    }

    func readData(forAccount account: String) -> AdaSessionMirrorReadResult<Data> {
        lock.lock()
        defer { lock.unlock() }
        guard let data = items[account] else { return .absent }
        return .found(data)
    }

    func readAllAccounts() -> AdaSessionMirrorReadResult<[String]> {
        lock.lock()
        defer { lock.unlock() }
        guard !items.isEmpty else { return .absent }
        return .found(items.keys.sorted())
    }

    @discardableResult
    func deleteData(forAccount account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        items.removeValue(forKey: account)
        return true
    }

    @discardableResult
    func deleteAll() -> Bool {
        // Outside the lock: the stall is the point, and holding the lock across it would block the
        // test's own reads instead.
        Thread.sleep(forTimeInterval: wipeDelay)
        lock.lock()
        defer { lock.unlock() }
        items = [:]
        return true
    }
}

/// Thread-safe box for the durable result the completion variant reports off the calling frame,
/// plus the thread it arrived on — the completion is documented to land on the main actor.
private final class DurabilityReport: @unchecked Sendable {
    let settled = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stored: Bool?
    private var arrivedOnMainThread = false

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var deliveredOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return arrivedOnMainThread
    }

    func report(_ durable: Bool) {
        lock.lock()
        stored = durable
        arrivedOnMainThread = Thread.isMainThread
        lock.unlock()
        settled.signal()
    }
}

/// What the durable sign-out costs its caller. `AdaWebHost` is `@MainActor`, so the only
/// actor-correct caller of either variant is the main actor — there is no off-main call an iOS host
/// can make, which is what makes the cost load-bearing rather than a documentation footnote.
///
/// These drive a REAL serial queue: the inline substitute the other suites use collapses the wipe
/// onto the calling thread, which erases exactly the distinction under test. It is a private queue
/// rather than the process-wide one, so a wipe another suite is deliberately stalling there cannot
/// decide the timings measured here.
@MainActor
struct SessionMirrorDurableClearThreadingTests {
    private static let scopeKey = "ada-session-mirror:ada-example:origin:https://ada-example.ada.support"

    /// Comfortably longer than ``AdaBridgeHandler/sessionMirrorClearDurablyStartGrace`` and far
    /// shorter than ``AdaBridgeHandler/sessionMirrorClearDurablyTimeout``, so a wipe that stalls
    /// still settles and the two variants differ only in who waits for it.
    private static let wipeDelay: TimeInterval = 0.6

    private struct Fixture {
        let handler: AdaBridgeHandler
        let store: AdaSessionMirrorStore
    }

    private func makeFixture(keychain: AdaSessionMirrorKeychain? = nil) throws -> Fixture {
        let defaults = try makeIsolatedDefaults()
        let store = AdaSessionMirrorStore(
            userDefaults: defaults,
            keychain: keychain ?? StallingWipeKeychain(wipeDelay: Self.wipeDelay),
        )
        let handler = AdaBridgeHandler(userDefaults: defaults, sessionMirrorStore: store)
        handler.sessionMirrorLegacyScopePrefix = "ada-session-mirror:legacy:ada-example:"
        handler.sessionMirrorRuntime = .messaging(scopePrefix: "ada-session-mirror:ada-example:")
        let queue = DispatchQueue(label: "test.session-mirror.\(UUID().uuidString)")
        handler.sessionMirrorKeychainRunner = { work in queue.async(execute: work) }
        return Fixture(handler: handler, store: store)
    }

    private func mirrorWrite() -> [String: Any] {
        [
            "type": "sdk.session.mirror",
            "version": 1,
            "scopeKey": Self.scopeKey,
            "generation": 7,
            "writtenAt": 1_756_700_000_000,
            "entries": ["messagingAuthState": "{\"jwt\":\"opaque\"}"],
        ]
    }

    private func secondsSpent(_ work: () -> Void) -> Double {
        let start = DispatchTime.now()
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// The blocking variant's real cost, and the reason the non-blocking one exists. The start
    /// grace bounds only the wait for the queue's head; once the wipe itself begins, the caller
    /// pays for it up to the full timeout. On the main actor that is a frozen UI.
    @Test
    func `the blocking durable sign-out holds its caller past the start grace once the wipe begins`() throws {
        let fixture = try makeFixture()
        fixture.handler.handleBridgeMessage(mirrorWrite())
        var confirmed = false

        let blockedSeconds = secondsSpent { confirmed = fixture.handler.clearAllSessionMirrorsDurably() }

        #expect(confirmed)
        #expect(blockedSeconds > AdaBridgeHandler.sessionMirrorClearDurablyStartGrace)
        #expect(fixture.store.readBlobJson(forScopeKey: Self.scopeKey) == .absent)
    }

    /// The same wipe and the same answer, with the caller left running. This is what a sign-out on
    /// the main actor should call.
    @Test
    func `the completion durable sign-out returns before the wipe and reports it when it lands`() async throws {
        let fixture = try makeFixture()
        fixture.handler.handleBridgeMessage(mirrorWrite())
        let report = DurabilityReport()

        let blockedSeconds = secondsSpent {
            fixture.handler.clearAllSessionMirrorsDurably { durable in report.report(durable) }
        }

        #expect(blockedSeconds < AdaBridgeHandler.sessionMirrorClearDurablyStartGrace)
        #expect(report.value == nil)

        #expect(await awaitSignal(report.settled, timeout: 10))
        #expect(report.value == true)
        #expect(report.deliveredOnMainThread)
        #expect(fixture.store.readBlobJson(forScopeKey: Self.scopeKey) == .absent)
    }

    /// The `false`-means-retry contract is the same on both variants, so a host that moves off the
    /// blocking one keeps the failure signal it was relying on.
    @Test
    func `the completion durable sign-out reports false when the wipe cannot be confirmed`() throws {
        let keychain = FakeSessionMirrorKeychain()
        let fixture = try makeFixture(keychain: keychain)
        // Inline here: this test is about the reported value, and the ordering the other two pin
        // would only make it slower to read.
        fixture.handler.sessionMirrorKeychainRunner = { work in work() }
        fixture.handler.sessionMirrorMainRunner = { work in work() }
        fixture.handler.handleBridgeMessage(mirrorWrite())
        keychain.failDeletes = true
        let report = DurabilityReport()

        fixture.handler.clearAllSessionMirrorsDurably { durable in report.report(durable) }

        #expect(report.value == false)
        #expect(fixture.store.storedBlobJson(forScopeKey: Self.scopeKey) != nil)
    }
}
