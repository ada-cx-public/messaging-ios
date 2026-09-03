//
//  AdaSessionMirrorStore.swift
//  AdaMessaging
//
//  Keychain-backed native session mirror (EXP-1082, pull transport EXP-1107).
//
//  The web runtime dual-writes its allowlisted session state to WebView
//  localStorage and mirrors it here through `sdk.session.mirror` bridge
//  messages, one atomic blob per scope key. At boot the web side PULLS the
//  blob back: it emits `sdk.session.mirrorRequest` and native answers
//  `sdk.sessionMirror.seed` by reading this store LIVE for the requested
//  scope, so a session — including live handoff context — survives a
//  force-quit that wipes WebView storage. Because native reads live, a clear
//  ordered before the read makes the answer empty: there is no frozen
//  document-start blob to re-inject, so a cleared session cannot resurrect.
//
//  Native holds the blob but never judges it: no TTL, no freshness or
//  generation comparison, and `entries` is persisted verbatim without being
//  parsed, filtered, or logged. Session validity is decided entirely by the
//  web runtime after adoption. This channel is separate from the branding
//  cache (`sdk.state.cache` / `__ADA_INITIAL_STATE__`), which keeps its
//  10-minute TTL and is untouched by mirror clears.
//
//  Security posture:
//   • Keychain items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
//     so mirror data never migrates via iCloud Keychain or a device restore.
//   • Keychain items survive app uninstall, so a UserDefaults first-run
//     sentinel detects reinstall and wipes every mirror entry at launch. Until
//     that wipe is confirmed the pull responder answers every seed empty, so an
//     uninstall/reinstall can never resurrect a session.
//   • One-shot identity tokens and sensitiveMetaFields never reach this
//     store: the web-side `SESSION_MIRROR_KEY_ALLOWLIST` is the single
//     filter, and it excludes them by construction.
//
//  The store, bridge routing, the pull responder, and the legacy-page script
//  template pin one cross-package contract, so they stay in one file.
// swiftlint:disable file_length

import Foundation
import Security
import WebKit

/// Carries the durable-wipe outcome from the serial keychain queue back to a
/// blocked caller. The completion `DispatchSemaphore` that gates the read
/// establishes the happens-before edge across the two threads.
private final class SessionMirrorClearResult {
    var durable = false
}

// ---------------------------------------------------------------------------

// MARK: - AdaSessionMirrorKeychain

// ---------------------------------------------------------------------------

/// Outcome of a mirror read. `failed` is deliberately distinct from `absent`, and every
/// caller must keep them apart: `SecItemCopyMatching` returns `errSecInteractionNotAllowed`
/// for an `AfterFirstUnlockThisDeviceOnly` item read before the first unlock after reboot,
/// and answering that as "absent" tells the web runtime native holds nothing — it then opens
/// its write path and a generation-1 write overwrites the intact blob.
enum AdaSessionMirrorReadResult<Value> {
    case found(Value)
    case absent
    case failed
}

extension AdaSessionMirrorReadResult: Equatable where Value: Equatable {}

/// Closed set of session-mirror degradation reasons reported to the host as the
/// ``AdaBridgeHandler/sessionMirrorDiagnosticEventKey`` SDK event. Reason enums only: a mirror
/// payload is the whole credential blob, so no scope key, entry key, origin or stored value may
/// ride this channel.
///
/// Every mirror failure here is otherwise silent — a refused write is dropped, a failed read is
/// answered with deliberate silence, a rejected scope simply returns, a failed clear earns no ack,
/// the wipe behind the `Void` sign-out hook has no return value to report through, and a legacy
/// mount that failed closed on an unresolved persistence mode sends nothing at all — so without
/// this a mirror dead in production is invisible to the host.
///
/// The raw values are React Native's `SessionMirrorDiagnosticReason` vocabulary verbatim, which
/// Android reports too, so one host handler reads every wrapper. Add a value here only after the
/// same value exists on the other wrappers.
///
/// Four of RN's reasons are deliberately absent, because iOS cannot ever reach them: `nonce-mismatch`
/// and `guard-origin-unavailable` describe RN's in-page frame-authenticity guard, which exists
/// because its bridge cannot identify the posting frame — WebKit hands iOS that identity directly as
/// `WKScriptMessage.frameInfo`; and `adapter-quarantined` / `adapter-unavailable` describe a
/// host-supplied storage adapter that may be missing or repeatedly throwing, where iOS's store is
/// the system Keychain, always present and never host-supplied.
enum AdaSessionMirrorDiagnosticReason: String {
    /// A store read did not happen, so what the scope holds is unknown.
    case storeReadFailed = "adapter-getItem-failed"

    /// A store write did not commit, so the mirrored session is not durable.
    case storeWriteFailed = "adapter-setItem-failed"

    /// A store delete did not commit or did not verify absent, so a blob may survive.
    case storeDeleteFailed = "adapter-removeItem-failed"

    /// The requested scope is not one the pinned runtime may read, write or clear.
    case scopeMismatch = "scope-mismatch"

    /// A legacy-scope blob carries an entry key outside the legacy allowlist.
    case entriesNotAllowlisted = "entries-not-allowlisted"

    /// The document a mirror reply was due into is no longer the one that asked.
    case documentMismatch = "origin-mismatch"

    /// The legacy pre-start script could not resolve the bot's persistence mode — the rollout
    /// `client.json` fetch errored or hit its bounded timeout — so it failed closed: nothing
    /// adopted, nothing cleared, nothing written. That outcome reaches native as no mirror
    /// message at all, so without this report a legacy mount that refused to restore a session
    /// looks exactly like one that had no session to restore.
    case legacyRolloutUnresolved = "legacy-rollout-unresolved"

    /// Whether repeats of this reason are suppressed for the bound document. True for the
    /// runtime-driven reasons, which recur on every message while a store is degraded or a page
    /// keeps naming a scope it may not touch, and would otherwise flood the host's event log.
    ///
    /// ``storeDeleteFailed`` is excluded: it reports one discrete clear — a host-initiated
    /// sign-out, or a web-ordered `sdk.session.mirrorClear` — whose documented contract is that
    /// the caller retries. A retry that reports nothing is indistinguishable from one that
    /// worked, so the host would stop retrying with the signed-out blob still in the store.
    /// Matches Android's `deduplicatesPerDocument`.
    var deduplicatesPerDocument: Bool {
        self != .storeDeleteFailed
    }
}

/// Minimal Keychain seam so unit tests can substitute an in-memory fake —
/// `SecItem*` needs a real Keychain, which a test bundle may not have.
protocol AdaSessionMirrorKeychain {
    /// Writes `data` for `account`, replacing any existing item in place.
    /// Returns whether the write is confirmed committed — a `false` return
    /// means the prior blob (if any) is untouched and no new blob was stored.
    @discardableResult func setData(_ data: Data, forAccount account: String) -> Bool
    /// Reads `account`, distinguishing a missing item from a read the Keychain refused.
    func readData(forAccount account: String) -> AdaSessionMirrorReadResult<Data>
    /// Every account the service currently holds, so a service-wide wipe can be verified
    /// against the scopes that actually exist rather than a list native maintains. `absent`
    /// means the service holds nothing; `failed` means the enumeration did not happen and
    /// proves nothing about what is stored.
    func readAllAccounts() -> AdaSessionMirrorReadResult<[String]>
    /// Deletes return whether the item is confirmed absent — `errSecItemNotFound`
    /// counts as success because the goal is absence, not that a row existed.
    @discardableResult func deleteData(forAccount account: String) -> Bool
    @discardableResult func deleteAll() -> Bool
}

/// Real Keychain implementation. `SecItemDelete` is synchronous and its status
/// is surfaced, which is what makes the mirror-clear ack durable-ordered: a
/// `true` return means the deletion is committed, and only that outcome may be
/// acked back to the web runtime.
struct AdaSessionMirrorSecItemKeychain: AdaSessionMirrorKeychain {
    private func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AdaSessionMirrorStore.keychainService,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    /// Atomic, status-checked replace: `SecItemUpdate` rewrites the value in
    /// place, so a failed or killed write can never leave the account with no
    /// blob (the delete-then-add ordering it replaces could). Falls back to
    /// `SecItemAdd` only when nothing exists yet. The OSStatus is load-bearing:
    /// the write path returns durability so the bridge can withhold the
    /// durably-mirrored signal on a write that was not committed.
    @discardableResult
    func setData(_ data: Data, forAccount account: String) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            attributes as CFDictionary,
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var addAttributes = baseQuery(account: account)
        addAttributes[kSecValueData as String] = data
        addAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addAttributes as CFDictionary, nil) == errSecSuccess
    }

    /// The `OSStatus` is load-bearing here, not just on the write path: only `errSecItemNotFound`
    /// proves the account holds nothing. Every other non-success status — `errSecInteractionNotAllowed`
    /// before the first unlock after reboot, a daemon failure — is a read that did not happen, and
    /// the caller must not read it as an empty store.
    func readData(forAccount account: String) -> AdaSessionMirrorReadResult<Data> {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess, let data = result as? Data else { return .failed }
        return .found(data)
    }

    /// `kSecMatchLimitAll` with no account, so it enumerates every scope stored under the
    /// service — including legacy scopes and any scope written by an earlier version. An
    /// item whose account attribute is missing is counted as unnameable rather than
    /// dropped: silently shortening the list would let a surviving blob read as an empty
    /// store.
    func readAllAccounts() -> AdaSessionMirrorReadResult<[String]> {
        var query = baseQuery(account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return .failed }
        let accounts = items.compactMap { $0[kSecAttrAccount as String] as? String }
        guard accounts.count == items.count else { return .failed }
        return .found(accounts)
    }

    @discardableResult
    func deleteData(forAccount account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    @discardableResult
    func deleteAll() -> Bool {
        let status = SecItemDelete(baseQuery(account: nil) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// ---------------------------------------------------------------------------

// MARK: - AdaSessionMirrorStore

// ---------------------------------------------------------------------------

/// Persists session-mirror blobs keyed by their verbatim web-owned `scopeKey`
/// (Keychain account). The web runtime pulls a blob back by naming its own
/// scope key, so native needs no other way to resolve one.
final class AdaSessionMirrorStore {
    static let keychainService = "cx.ada.messaging.session-mirror"
    static let installedSentinelKey = "cx.ada.messaging.session-mirror.installed"

    private let userDefaults: UserDefaults
    private let keychain: AdaSessionMirrorKeychain

    init(
        userDefaults: UserDefaults = .standard,
        keychain: AdaSessionMirrorKeychain = AdaSessionMirrorSecItemKeychain(),
    ) {
        self.userDefaults = userDefaults
        self.keychain = keychain
    }

    /// Keychain items survive app uninstall; UserDefaults do not. An absent
    /// sentinel therefore means fresh install or reinstall — wipe every mirror
    /// blob at launch, so a reinstall never resurrects the previous install's
    /// session.
    func prepareForLaunch() {
        guard !userDefaults.bool(forKey: Self.installedSentinelKey) else { return }
        // The sentinel is stamped only on a wipe ``clearAll()`` verified by read-back:
        // an unverified one leaves it unset, so the next launch retries and
        // ``confirmInstallWipe()`` keeps every seed answer empty until it confirms.
        guard clearAll() else { return }
        userDefaults.set(true, forKey: Self.installedSentinelKey)
    }

    /// Whether this install's reinstall wipe is confirmed, retrying the wipe
    /// when it is not — `deleteAll()` fails before first unlock, and by the time
    /// a page pulls its seed the device is usually unlocked. A `false` return
    /// means the previous install's blob may still be present, so a caller that
    /// would hand a blob back to the page must answer nothing instead.
    func confirmInstallWipe() -> Bool {
        prepareForLaunch()
        return userDefaults.bool(forKey: Self.installedSentinelKey)
    }

    /// Returns whether the blob is durably stored. The `false` return lets the
    /// bridge withhold any signal that would let the web side treat the
    /// generation as durably mirrored.
    @discardableResult
    func store(blobJson: String, scopeKey: String) -> Bool {
        guard let data = blobJson.data(using: .utf8) else { return false }
        return keychain.setData(data, forAccount: scopeKey)
    }

    /// Reads one scope's blob, keeping "the Keychain refused the read" distinct from "no blob
    /// is stored". Bytes that are not valid UTF-8 report `absent`: a blob is present but
    /// unusable, and the store holding garbage is a state the web runtime may safely overwrite,
    /// unlike a read that never happened.
    func readBlobJson(forScopeKey scopeKey: String) -> AdaSessionMirrorReadResult<String> {
        switch keychain.readData(forAccount: scopeKey) {
        case let .found(data):
            guard let json = String(data: data, encoding: .utf8) else { return .absent }
            return .found(json)
        case .absent:
            return .absent
        case .failed:
            return .failed
        }
    }

    /// Deletes one scope's blob. A `true` return is durable and verified
    /// (`SecItemDelete` is synchronous and the blob reads back as absent), so
    /// the caller may ack the clear. Returns `false` when the delete failed —
    /// or when the read-back could not confirm absence, which is not the same
    /// answer as absence; the caller must not ack either way.
    @discardableResult
    func clear(scopeKey: String) -> Bool {
        guard keychain.deleteData(forAccount: scopeKey) else { return false }
        if case .absent = keychain.readData(forAccount: scopeKey) { return true }
        return false
    }

    /// Deletes every mirror blob (all scopes). The first-run sentinel stays — it
    /// records "this install has run", not mirror content.
    ///
    /// A `true` return is durable and verified, on the same terms as
    /// ``clear(scopeKey:)``: every scope the service held before the wipe reads
    /// back ABSENT, and a fresh enumeration finds nothing left. Enumeration is
    /// how the set of scopes is established — native keeps no index, so a scope
    /// written by an earlier version or under the legacy grammar is covered too.
    ///
    /// Returns `false` on the delete failing AND on every read that did not
    /// happen. A refused read (`errSecInteractionNotAllowed` before the first
    /// unlock after reboot) leaves the store's contents unknown, which is not
    /// absence: both consumers — the sign-out retry contract and the reinstall
    /// sentinel — treat `true` as proof that no credential survives, so an
    /// unverifiable wipe must report `false` and be retried.
    @discardableResult
    func clearAll() -> Bool {
        let scopesBeforeWipe = keychain.readAllAccounts()
        guard keychain.deleteAll(), isConfirmedEmpty(keychain.readAllAccounts()) else { return false }
        switch scopesBeforeWipe {
        case let .found(scopes):
            return scopes.allSatisfy { scope in
                if case .absent = keychain.readData(forAccount: scope) { return true }
                return false
            }
        case .absent:
            return true
        case .failed:
            return false
        }
    }

    /// Whether a service-wide enumeration proves the store holds nothing: it answered
    /// `absent`, or answered with an empty listing. `failed` is a read that did not
    /// happen, so it proves nothing.
    private func isConfirmedEmpty(_ result: AdaSessionMirrorReadResult<[String]>) -> Bool {
        switch result {
        case .absent: true
        case let .found(scopes): scopes.isEmpty
        case .failed: false
        }
    }
}

// ---------------------------------------------------------------------------

// MARK: - AdaSessionMirrorRuntime

// ---------------------------------------------------------------------------

/// The runtime the wrapper is hosting in this webview — the authority for
/// classifying `sdk.session.mirror(Clear)` messages. The message's own
/// `scopeKey` is page-supplied and never trusted for classification: without
/// this pin a compromised page could relabel its blob into the other runtime's
/// namespace and have it stored — and later injected — there.
enum AdaSessionMirrorRuntime {
    /// Messaging webview (`sdk/webview.html`): scope keys must extend the
    /// handle's `ada-session-mirror:<handle>:` prefix and must not be
    /// legacy-scoped.
    case messaging(scopePrefix: String)
    /// Remote Legacy host page: only the exact natively-computed
    /// `ada-session-mirror:legacy:<handle>:<origin>` scope key is accepted.
    case legacy(scopeKey: String)

    /// Bound on the legacy pre-start step: the rollout `client.json` fetch that
    /// resolves the persistence mode AND the native seed pull run inside this
    /// window. On timeout the injected bootstrap releases `adaEmbed.start` with
    /// no adoption (a missed restore, never a leak), so a slow network can
    /// never hang the widget.
    nonisolated static let legacyRolloutFetchTimeoutMs = 5000
}

// ---------------------------------------------------------------------------

// MARK: - AdaBridgeHandler session-mirror routing and injection

// ---------------------------------------------------------------------------

extension AdaBridgeHandler {
    func routeSessionMirrorMessage(type: String, body: [String: Any]) {
        switch type {
        case "sdk.session.mirror":
            handleSessionMirrorWrite(body)
        case "sdk.session.mirrorRequest":
            handleSessionMirrorRequest(body)
        case "sdk.session.mirrorDiagnostic":
            // Ungated on `version` and `scopeKey`, unlike its siblings: nothing is read off this
            // message and nothing durable follows from it, so the reason native reports is fixed
            // here and a sender can never widen the closed set (Android/RN parity).
            emitSessionMirrorDiagnostic(.legacyRolloutUnresolved)
        case "sdk.session.mirrorClear":
            handleSessionMirrorClear(body)
        default:
            // Naming the destructive arm rather than falling into it. The clear is
            // deliberately ungated on `version`, so reaching it by default meant any
            // future `sdk.session.mirror*` type added to the caller's filter, without a
            // matching case here, would silently delete the scope's blob — a coupling
            // held in a different file. Android and React Native both switch on the
            // clear type explicitly; this is iOS matching them.
            break
        }
    }

    /// Persists a `sdk.session.mirror` payload verbatim (minus `type`). Only
    /// protocol version 1 is recognized; anything else is ignored, not stored.
    /// The scope key must match the wrapper-pinned runtime's natively-computed
    /// grammar — the page-supplied `scopeKey` is never trusted to classify the
    /// blob. Messaging `entries` stay opaque (the web-side allowlist is the
    /// single filter); a legacy blob is additionally validated against the
    /// legacy key allowlist before it is stored.
    func handleSessionMirrorWrite(_ body: [String: Any]) {
        guard let version = body["version"] as? Int, version == 1 else { return }
        guard let scopeKey = body["scopeKey"] as? String, !scopeKey.isEmpty,
              isExpectedSessionMirrorScopeKey(scopeKey)
        else {
            emitSessionMirrorDiagnostic(.scopeMismatch)
            return
        }
        var payload = body
        payload.removeValue(forKey: "type")
        if case .legacy? = sessionMirrorRuntime {
            guard Self.isValidLegacySessionMirrorPayload(payload, scopeKey: scopeKey) else {
                emitSessionMirrorDiagnostic(.entriesNotAllowlisted)
                return
            }
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }
        // Classification above reads the pinned-runtime state on the delivery
        // (main) thread; only the blocking Keychain write is handed to the
        // serial queue, which keeps it ordered ahead of a later clear.
        sessionMirrorKeychainRunner { [self] in
            // The web side stamps its generation before this commits, so a dropped write
            // pins the page ahead of native with nothing else to say so.
            guard !sessionMirrorStore.store(blobJson: json, scopeKey: scopeKey) else { return }
            sessionMirrorMainRunner { [self] in
                emitSessionMirrorDiagnostic(.storeWriteFailed)
            }
        }
    }

    /// Reports a mirror failure to the host through the same delegate event surface every SDK
    /// event travels. Main thread only — the delegate is `@MainActor`, while the failures it
    /// reports are detected on the serial keychain queue.
    ///
    /// Only ``AdaSessionMirrorDiagnosticReason/storeWriteFailed`` is deduplicated, and only
    /// within one bound document. Writes are driven by the runtime, so a degraded Keychain
    /// repeats that failure on every message and would flood the host's event log.
    /// ``AdaSessionMirrorDiagnosticReason/storeDeleteFailed`` is not: a wipe is one discrete
    /// host-initiated sign-out whose documented contract is that the host retries, and a retry
    /// that reports nothing is indistinguishable from a retry that worked.
    func emitSessionMirrorDiagnostic(_ reason: AdaSessionMirrorDiagnosticReason) {
        if reason.deduplicatesPerDocument,
           !reportedSessionMirrorDiagnostics.insert(reason).inserted {
            return
        }
        delegate?.adaBridge(
            self,
            didReceiveEvent: Self.sessionMirrorDiagnosticEventKey,
            data: ["reason": reason.rawValue],
        )
    }

    /// Whether a bridge message's page-supplied scope key matches the runtime
    /// the wrapper pinned for this webview. No pinned runtime (e.g. the
    /// localhost-Legacy bridge runtime, which drives no mirror) fails closed.
    func isExpectedSessionMirrorScopeKey(_ scopeKey: String) -> Bool {
        switch sessionMirrorRuntime {
        case let .messaging(scopePrefix)?:
            scopeKey.hasPrefix(scopePrefix) && !isLegacySessionMirrorScopeKey(scopeKey)
        case let .legacy(expectedScopeKey)?:
            scopeKey == expectedScopeKey
        case nil:
            false
        }
    }

    /// Handle-delimited (`ada-session-mirror:legacy:<handle>:`), so it stays
    /// exact even for a bot literally named "legacy". Deliberately no
    /// shape-level fallback: with no prefix wired nothing classifies as legacy,
    /// and the injection paths fail closed on the missing prefix instead.
    func isLegacySessionMirrorScopeKey(_ scopeKey: String) -> Bool {
        guard let sessionMirrorLegacyScopePrefix else { return false }
        return scopeKey.hasPrefix(sessionMirrorLegacyScopePrefix)
    }

    /// Handles `sdk.session.mirrorClear`: deletes the blob durably, THEN acks —
    /// the web-side MES-1376 destructive-operation barrier holds the clear
    /// incomplete until the ack arrives. Only a confirmed delete is acked: on
    /// a failed delete no ack is sent, the web side's wait times out, and its
    /// surviving generation stamp tombstones the blob — so neither a kill nor
    /// a Keychain failure mid-clear can resurrect a deleted session. That
    /// withheld ack is silent to the HOST, though, so the failed delete is
    /// also reported on the diagnostic channel. Not gated on `version` (a
    /// clear from any future protocol must still destroy a v1 blob), but the
    /// scope key must match the pinned runtime like any write.
    /// Under the pull transport there is no frozen document-start blob to
    /// re-inject, so no delivered marker needs invalidating: the boot read
    /// simply finds the deleted blob absent and answers empty.
    func handleSessionMirrorClear(_ body: [String: Any]) {
        guard let scopeKey = body["scopeKey"] as? String, !scopeKey.isEmpty,
              isExpectedSessionMirrorScopeKey(scopeKey)
        else {
            emitSessionMirrorDiagnostic(.scopeMismatch)
            return
        }
        let requestId = (body["requestId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let ticket = sessionMirrorCommandWebView.flatMap { captureDocumentTicket(for: $0) }
        // The blocking delete and its read-back run on the serial keychain queue,
        // off the main delivery thread. The ack marshals back to the main thread
        // from the same completion, after the delete confirms — so the ack can
        // never precede a durable delete, and a failed delete earns no ack.
        sessionMirrorKeychainRunner { [self] in
            let cleared = sessionMirrorStore.clear(scopeKey: scopeKey)
            sessionMirrorMainRunner { [self] in
                // Withholding the ack is what keeps the web side's generation stamp, but it
                // reports nothing: the page just times out, and the host never learns a blob
                // survived a clear the page believed it ordered (Android/RN parity).
                guard cleared else {
                    emitSessionMirrorDiagnostic(.storeDeleteFailed)
                    return
                }
                guard let requestId else { return }
                acknowledgeSessionMirrorClear(requestId: requestId, ticket: ticket)
            }
        }
    }

    /// Enqueues a fire-and-forget wipe of every scope's mirror blob on the
    /// serial keychain queue and returns at once, so the `Void` sign-out path
    /// never blocks the main thread. The caller gets no return value, so a wipe
    /// that did not commit is reported on the diagnostic event channel instead;
    /// call ``clearAllSessionMirrorsDurably()`` when the result is needed inline.
    func clearAllSessionMirrors() {
        sessionMirrorKeychainRunner { [self] in
            _ = wipeSessionMirrorsReportingFailure()
        }
    }

    /// Wipes every scope and reports a wipe that did not commit or did not verify absent — the
    /// previous user's blob survives into the next launch's seed pull, and on the `Void` sign-out
    /// path this event is the host's only chance to hear that and retry. Runs on the serial
    /// keychain queue; the report marshals back to the main thread.
    private func wipeSessionMirrorsReportingFailure() -> Bool {
        let wiped = sessionMirrorStore.clearAll()
        if !wiped {
            sessionMirrorMainRunner { [self] in
                emitSessionMirrorDiagnostic(.storeDeleteFailed)
            }
        }
        return wiped
    }

    /// Wipes every scope's mirror blob on the serial keychain queue and reports the durable
    /// result to `completion` on the main thread WITHOUT blocking the caller.
    ///
    /// The non-blocking counterpart to ``clearAllSessionMirrorsDurably()``, and the one a
    /// main-actor sign-out should use: same wipe, same `false`-means-retry contract, but the
    /// caller keeps running while the Keychain works. No deadline, because there is no blocked
    /// caller to strand — a wipe queued behind another mount's stalled write reports whenever it
    /// lands rather than being abandoned unanswered.
    func clearAllSessionMirrorsDurably(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        sessionMirrorKeychainRunner { [self] in
            let durable = wipeSessionMirrorsReportingFailure()
            sessionMirrorMainRunner { completion(durable) }
        }
    }

    /// Wipes every scope's mirror blob on the serial keychain queue and BLOCKS the caller — on
    /// the main actor, since that is the only place an actor-correct caller can call it from —
    /// until the queue reports whether the wipe is durably gone.
    ///
    /// The block is bounded by ``AdaBridgeHandler/sessionMirrorClearDurablyTimeout`` and nothing
    /// shorter: the grace below bounds only the wait for the queue's head, and the wipe itself may
    /// then spend the whole remainder. Prefer ``clearAllSessionMirrorsDurably(completion:)``, which
    /// reports the same result with no block at all.
    ///
    /// The bound is split because the queue is process-wide. Reaching the head of it gets only
    /// ``AdaBridgeHandler/sessionMirrorClearDurablyStartGrace``; the wipe itself then gets the
    /// rest. Waiting for the queue and waiting for the wipe are different things: a write another
    /// mount already accepted is work this wipe is deliberately ordered behind, and paying the
    /// whole bound for someone else's stalled write buys nothing, since the wipe could not have
    /// been confirmed in that window anyway. Bailing at the grace costs only the answer — the wipe
    /// stays enqueued, still runs after every write any instance accepted, and still verifies
    /// absence — so `false` here means "not confirmed yet, retry", never "not wiped".
    func clearAllSessionMirrorsDurably() -> Bool {
        let deadline = DispatchTime.now() + Self.sessionMirrorClearDurablyTimeout
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = SessionMirrorClearResult()
        sessionMirrorKeychainRunner { [self] in
            started.signal()
            result.durable = wipeSessionMirrorsReportingFailure()
            finished.signal()
        }
        guard started.wait(timeout: .now() + Self.sessionMirrorClearDurablyStartGrace) == .success,
              finished.wait(timeout: deadline) == .success
        else { return false }
        return result.durable
    }

    /// Answers a `sdk.session.mirrorRequest` (pull transport, EXP-1107): reads
    /// the store LIVE for the requested scope on the serial keychain queue and
    /// replies `sdk.sessionMirror.seed` `{ requestId, seed }`, where `seed` is
    /// the mirror blob or `null` when absent. Because the read is enqueued FIFO
    /// behind any write/clear already delivered, a clear ordered before the
    /// request forces an empty answer — a cleared session is structurally
    /// unresurrectable (no frozen document-start blob exists any more). The
    /// page-supplied `scopeKey` is classified against the pinned runtime like
    /// any write, and a legacy scope's blob is additionally revalidated against
    /// the legacy key allowlist so a relabeled Messaging blob never crosses.
    ///
    /// A request that fails those gates is answered with an EMPTY seed rather
    /// than dropped (Android/RN parity). Validation is unchanged — an invalid
    /// request still never receives a blob — but silence would strand the web
    /// side on its 4500 ms fail-open timeout for an answer that can only ever be
    /// "no seed"; an explicit empty reply resolves it at once. Only a request
    /// carrying no usable `requestId` is dropped: with no id there is no pending
    /// request to resolve, so there is nothing to answer.
    ///
    /// A Keychain read that FAILED is the one case answered with silence rather than an empty
    /// seed. An empty seed says "native holds nothing", which opens the web side's write path
    /// and lets a generation-1 write overwrite the intact blob — destroying exactly the session
    /// the mirror exists to restore. Core already models the unknown answer as its
    /// `seed-timeout` outcome: adoption fails open, writes stay suppressed. Sending nothing is
    /// how native says that, at the cost of the web side's 4500 ms pull budget.
    ///
    /// The reply is bound to the document that asked. The Keychain read is handed to a serial
    /// queue and the reply lands later, by which time an in-place main-frame navigation may
    /// have replaced the document — and the payload is the whole mirror blob, so an unpinned
    /// reply hands a JWT, a refresh token and the chatter token to whatever page is there.
    func handleSessionMirrorRequest(_ body: [String: Any]) {
        guard let requestId = (body["requestId"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
        else { return }
        let ticket = sessionMirrorCommandWebView.flatMap { captureDocumentTicket(for: $0) }
        // Version first, matching this file's own write path and both sibling wrappers. A
        // request whose protocol this build does not recognise is answered empty and not
        // classified further: its `scopeKey` means whatever that version says it means, so
        // rejecting it as a foreign scope would put an unearned `scope-mismatch` into a
        // reason vocabulary EXP-1084 reads across all three platforms.
        guard let version = body["version"] as? Int, version == 1 else {
            // Already on the delivery (main) thread, like the classification below and
            // every other `evaluateJavaScript` dispatch from here.
            deliverSessionMirrorSeed(requestId: requestId, seed: nil, ticket: ticket)
            return
        }
        let scopeKey = (body["scopeKey"] as? String) ?? ""
        guard !scopeKey.isEmpty, isExpectedSessionMirrorScopeKey(scopeKey) else {
            // A scope the pinned runtime may not read, on a protocol it does understand.
            emitSessionMirrorDiagnostic(.scopeMismatch)
            deliverSessionMirrorSeed(requestId: requestId, seed: nil, ticket: ticket)
            return
        }
        let isLegacyScope: Bool = if case .legacy? = sessionMirrorRuntime { true } else { false }
        // Classification above reads the pinned-runtime state on the delivery
        // (main) thread; only the blocking Keychain read is handed to the serial
        // queue, which keeps it ordered behind a write/clear already enqueued.
        sessionMirrorKeychainRunner { [self] in
            let outcome = liveSessionMirrorSeed(scopeKey: scopeKey, isLegacyScope: isLegacyScope)
            if case .failed = outcome {
                // The silence the pull contract requires is exactly what makes this invisible:
                // the web side just times out. The host hears it here instead.
                sessionMirrorMainRunner { [self] in
                    emitSessionMirrorDiagnostic(.storeReadFailed)
                }
                return
            }
            let seed: [String: Any]? = if case let .found(blob) = outcome { blob } else { nil }
            sessionMirrorMainRunner { [self] in
                deliverSessionMirrorSeed(requestId: requestId, seed: seed, ticket: ticket)
            }
        }
    }

    /// Reads the blob live for `scopeKey`. Reports `found` with the parsed blob, `absent` when
    /// there is nothing to hand back — no blob, corrupt, an unsupported protocol version,
    /// mismatched, or (for a legacy scope) carrying keys outside the legacy allowlist — and
    /// `failed` only when the Keychain refused the read, which the caller must answer with
    /// silence rather than an empty seed. Runs on the serial keychain queue.
    ///
    /// The stored blob's own `version` is re-checked here, not just on the write
    /// that produced it: once a version-2 writer ships, a binary that only speaks
    /// v1 shares the Keychain with it, and an unchecked read would hand that v2
    /// payload to the web runtime labelled as a v1 seed.
    ///
    /// An unconfirmed reinstall wipe also answers `nil`. Keychain blobs survive
    /// uninstall and the web runtime recomputes the same scope key for the same
    /// handle/endpoint, so the previous install's credentials would otherwise be
    /// reachable by the very next pull whenever the launch wipe failed.
    private func liveSessionMirrorSeed(
        scopeKey: String,
        isLegacyScope: Bool,
    ) -> AdaSessionMirrorReadResult<[String: Any]> {
        guard sessionMirrorStore.confirmInstallWipe() else { return .absent }
        let read = sessionMirrorStore.readBlobJson(forScopeKey: scopeKey)
        if case .failed = read { return .failed }
        guard case let .found(blobJson) = read,
              let blob = Self.jsonObjectDocument(blobJson),
              blob["version"] as? Int == 1,
              blob["scopeKey"] as? String == scopeKey
        else { return .absent }
        if isLegacyScope, !Self.isValidLegacySessionMirrorPayload(blob, scopeKey: scopeKey) {
            sessionMirrorMainRunner { [self] in
                emitSessionMirrorDiagnostic(.entriesNotAllowlisted)
            }
            return .absent
        }
        return .found(blob)
    }

    /// Returns the document-start `WKUserScript` that drives the mirror on the
    /// remote Legacy host page (`/mobile-sdk-webview/`), where the 5 legacy
    /// session keys live in the page's own localStorage and legacy chat code is
    /// unchanged. Under the pull transport it does one bounded pre-start step
    /// before releasing `adaEmbed.start`: it PULLS the seed from native
    /// (`sdk.session.mirrorRequest` → `sdk.sessionMirror.seed`, answered live)
    /// AND resolves the bot's persistence mode from the same rollout client blob
    /// legacy chat fetches. Only mode "normal" writes the pulled seed to page
    /// storage and watches; any other known mode forward-clears the legacy keys
    /// with one mirror clear; an unresolved mode (fetch failure/timeout) fails
    /// CLOSED — no write, no clear. There is no frozen document-start blob, so a
    /// clear ordered before the pull yields an empty answer and the cleared
    /// session cannot resurrect.
    func makeLegacySessionMirrorScript(scopeKey: String) -> WKUserScript? {
        guard let trustedOrigin,
              let source = Self.legacySessionMirrorScriptSource(scopeKey: scopeKey, pageOrigin: trustedOrigin)
        else { return nil }
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
        )
    }

    /// Returns a JSON string literal (with quotes and escaping) safe to embed
    /// in an injected script — never raw interpolation.
    nonisolated static func jsonStringLiteral(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    /// The stored blob is untrusted on-disk bytes, so require it to round-trip
    /// as a JSON object before the pull responder hands it back: a corrupt or
    /// hand-edited blob is rejected here and the seed pull simply answers empty,
    /// rather than a malformed value reaching the typed `sdk.sessionMirror.seed`
    /// reply that `dispatchCommand` serializes into the page.
    nonisolated static func jsonObjectDocument(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The 5 legacy session keys the legacy watcher template mirrors — must
    /// match `KEYS` in `legacySessionMirrorScriptTemplate` below. Together
    /// with the scope's generation stamp these are the only entries a legacy
    /// blob may carry.
    nonisolated static let legacySessionMirrorEntryKeys: Set<String> = [
        "chatter",
        "created",
        "sessionToken",
        "zdMessagingExternalUserId",
        "zdMessagingChatterCreated",
    ]

    /// Native allowlist check for a legacy blob's `entries`, applied both
    /// before the blob is stored and before it is injected — a relabeled
    /// Messaging blob (JWT + refresh token) must be rejected here, not by the
    /// page after the blob already sits on `window`.
    nonisolated static func isValidLegacySessionMirrorPayload(
        _ payload: [String: Any],
        scopeKey: String,
    ) -> Bool {
        guard let entries = payload["entries"] as? [String: Any] else { return false }
        let stampKey = "\(scopeKey):generation"
        return entries.allSatisfy { key, value in
            (key == stampKey || legacySessionMirrorEntryKeys.contains(key)) && value is String
        }
    }

    /// Builds the legacy pull bootstrap + adopt-and-watch script. All
    /// parameters are embedded as JSON literals; the 5-key allowlist and the
    /// message shapes are fixed in the template. Adoption is wholesale: a
    /// mid-loop write failure rolls back every legacy key and the stamp rather
    /// than leaving a stitched partial generation, and generation authority
    /// stays with the page's stamp key.
    /// The watcher's clear-on-empty keeps the generation stamp (RN parity):
    /// the stamp is the tombstone that stops an unconfirmed native delete from
    /// resurrecting the cleared session at the next boot. Only the
    /// non-normal-mode clear removes it, along with the keys themselves.
    /// The script holds `adaEmbed.start` (by intercepting the assignment of
    /// `window.adaEmbed` and wrapping its `start`) until one bounded pre-start
    /// step settles: it PULLS the seed from native and resolves the persistence
    /// mode from a bounded (5s) rollout `client.json` fetch. Only mode "normal"
    /// writes the pulled seed to page storage and watches; any other known mode
    /// forward-clears the legacy keys and stamp; an unresolved mode (fetch
    /// error, non-JSON, or timeout) fails CLOSED — no write, no clear — so
    /// credentials are never durably mirrored under a possibly session/private
    /// bot. That fail-closed mount posts one `sdk.session.mirrorDiagnostic`,
    /// which the wrapper reports as ``AdaSessionMirrorDiagnosticReason/legacyRolloutUnresolved``;
    /// a page the mode was never resolvable from (no dotted host, no `fetch`)
    /// stays inert without it, being a page the mirror does not apply to rather
    /// than a degraded one. On timeout it releases start with no adoption
    /// (never a hang), and
    /// because native answers the seed live there is no frozen blob to survive
    /// a clear ordered before the pull. A pull the timeout settles unanswered is
    /// likewise not an empty answer: adoption fails open, but the watcher's
    /// mirror writes stay closed so a generation-1 post cannot overwrite the
    /// blob native still holds. Explicit clears keep reaching native there.
    nonisolated static func legacySessionMirrorScriptSource(
        scopeKey: String,
        pageOrigin: String,
    ) -> String? {
        guard let scopeKeyJson = jsonStringLiteral(scopeKey),
              let originJson = jsonStringLiteral(pageOrigin)
        else { return nil }
        return legacySessionMirrorScriptTemplate
            .replacingOccurrences(of: "__ADA_MIRROR_ORIGIN_JSON__", with: originJson)
            .replacingOccurrences(of: "__ADA_MIRROR_SCOPE_KEY_JSON__", with: scopeKeyJson)
    }

    private nonisolated static let legacySessionMirrorScriptTemplate = """
    (function () {
        if (window.location.origin !== __ADA_MIRROR_ORIGIN_JSON__) { return; }
        var SCOPE_KEY = __ADA_MIRROR_SCOPE_KEY_JSON__;
        var STAMP_KEY = SCOPE_KEY + ":generation";
        var KEYS = [
            "chatter",
            "created",
            "sessionToken",
            "zdMessagingExternalUserId",
            "zdMessagingChatterCreated"
        ];
        var MAX_SERIALIZED_ENTRIES = 131072;
        var ROLLOUT_FETCH_TIMEOUT_MS = \(AdaSessionMirrorRuntime.legacyRolloutFetchTimeoutMs);

        // ---- adaEmbed.start hold/release -----------------------------------
        // The wrapper evaluates window.adaEmbed.start(config) directly once the
        // remote page is ready. Hold that call until the bounded pre-start step
        // (native seed pull + mode resolution) settles, so a confirmed-normal
        // seed lands in page localStorage before legacy chat reads it. embed-2
        // assigns window.adaEmbed AFTER this document-start script runs, so
        // intercept the assignment and wrap .start — never a change to the page.
        var startReleased = false;
        var heldStart = null;
        function releaseStart() {
            if (startReleased) { return; }
            startReleased = true;
            if (heldStart !== null) {
                var held = heldStart;
                heldStart = null;
                try { held.fn.apply(held.embed, held.args); } catch (_) {}
            }
        }
        function wrapEmbedStart(embed) {
            if (!embed || typeof embed !== "object" || embed.__adaSessionMirrorStartWrapped__) { return; }
            var original = embed.start;
            if (typeof original !== "function") { return; }
            embed.__adaSessionMirrorStartWrapped__ = true;
            embed.start = function () {
                if (startReleased) { return original.apply(embed, arguments); }
                heldStart = { embed: embed, fn: original, args: arguments };
            };
        }
        try {
            var currentEmbed = window.adaEmbed;
            Object.defineProperty(window, "adaEmbed", {
                configurable: true,
                get: function () { return currentEmbed; },
                set: function (value) { currentEmbed = value; wrapEmbedStart(value); }
            });
            if (currentEmbed) { wrapEmbedStart(currentEmbed); }
        } catch (_) {
            // If interception fails, never hold start hostage.
            startReleased = true;
        }

        function post(message) {
            try {
                var handler =
                    window.webkit &&
                    window.webkit.messageHandlers &&
                    window.webkit.messageHandlers.adaBridge;
                if (handler) { handler.postMessage(message); }
            } catch (_) {}
        }

        function read(key) {
            try { return window.localStorage.getItem(key); } catch (_) { return null; }
        }
        function writeKey(key, value) {
            try { window.localStorage.setItem(key, value); } catch (_) {}
        }
        function removeKey(key) {
            try { window.localStorage.removeItem(key); } catch (_) {}
        }

        function stampGeneration() {
            var raw = read(STAMP_KEY);
            var parsed = raw === null ? NaN : parseInt(raw, 10);
            return isFinite(parsed) && parsed >= 1 ? parsed : 0;
        }

        function snapshot() {
            var entries = {};
            var present = 0;
            for (var i = 0; i < KEYS.length; i++) {
                var value = read(KEYS[i]);
                if (typeof value === "string") {
                    entries[KEYS[i]] = value;
                    present++;
                }
            }
            return { entries: entries, present: present };
        }

        function fingerprint(entries) {
            return JSON.stringify(KEYS.map(function (key) {
                return Object.prototype.hasOwnProperty.call(entries, key) ? entries[key] : null;
            }));
        }

        // Closes the mirror write path for this document. A pull that never answered
        // is NOT the same as native answering empty: native may still hold a blob at
        // a generation this page cannot see, and a post at localStamp + 1 is
        // generation 1 after a WebView wipe — it would overwrite the very blob the
        // next boot would adopt. Writes stay closed; an explicit clear still reaches
        // native, because a wipe the page can see is an answer about the session and
        // a stale native blob must not outlive it.
        var writesSuppressed = false;

        function postMirror(generation, entries) {
            if (writesSuppressed) { return; }
            entries[STAMP_KEY] = String(generation);
            try {
                if (JSON.stringify(entries).length > MAX_SERIALIZED_ENTRIES) { return; }
            } catch (_) { return; }
            writeKey(STAMP_KEY, String(generation));
            post({
                type: "sdk.session.mirror",
                version: 1,
                scopeKey: SCOPE_KEY,
                generation: generation,
                writtenAt: Date.now(),
                entries: entries
            });
        }

        function postClear() {
            post({
                type: "sdk.session.mirrorClear",
                version: 1,
                scopeKey: SCOPE_KEY,
                requestId: String(Date.now()) + "-" + Math.random().toString(16).slice(2)
            });
        }

        function isValidBlob(blob) {
            if (blob === null || typeof blob !== "object") { return false; }
            if (blob.version !== 1 || blob.scopeKey !== SCOPE_KEY) { return false; }
            if (typeof blob.generation !== "number" || !isFinite(blob.generation) ||
                blob.generation < 1 || Math.floor(blob.generation) !== blob.generation) {
                return false;
            }
            if (blob.entries === null || typeof blob.entries !== "object") { return false; }
            for (var key in blob.entries) {
                if (!Object.prototype.hasOwnProperty.call(blob.entries, key)) { continue; }
                if (key !== STAMP_KEY && KEYS.indexOf(key) === -1) { return false; }
                if (typeof blob.entries[key] !== "string") { return false; }
            }
            return true;
        }

        function adopt(blob) {
            var adopted = false;
            try {
                for (var i = 0; i < KEYS.length; i++) {
                    var key = KEYS[i];
                    if (Object.prototype.hasOwnProperty.call(blob.entries, key)) {
                        window.localStorage.setItem(key, blob.entries[key]);
                    } else {
                        window.localStorage.removeItem(key);
                    }
                }
                window.localStorage.setItem(STAMP_KEY, String(blob.generation));
                adopted = true;
            } catch (_) {}
            if (!adopted) {
                for (var j = 0; j < KEYS.length; j++) { removeKey(KEYS[j]); }
                removeKey(STAMP_KEY);
            }
        }

        function pagePrivateOverride() {
            try {
                if (String(window.location.hash || "").replace("#", "") === "private") { return true; }
                return /[?&]private=(true|1)([&#]|$)/.test(String(window.location.search || ""));
            } catch (_) { return false; }
        }

        function clearMirrorForNonNormalMode() {
            try {
                for (var i = 0; i < KEYS.length; i++) { removeKey(KEYS[i]); }
            } catch (_) {}
            removeKey(STAMP_KEY);
            postClear();
        }

        // Wholesale adopt-or-ignore decision for the pulled seed against the
        // current page storage. Returns the pending generation to seed the
        // mirror at when a live local session must win over the native blob.
        // A live session whose stamp the pulled seed does not match re-mirrors
        // (Android/RN parity): postMirror writes the stamp BEFORE native commits,
        // so a kill, an oversize drop or a failed Keychain write between the two
        // pins the page ahead of native permanently unless this boot re-posts.
        function adoptSeedIfNeeded(seed) {
            var pendingSeedGeneration = null;
            var shouldAdoptSeed = false;
            try {
                var stamp = stampGeneration();
                var hasLocalSession = read("chatter") !== null;
                if (seed !== null && seed !== undefined && isValidBlob(seed)) {
                    if (stamp >= 1) {
                        if (seed.generation > stamp) {
                            shouldAdoptSeed = true;
                        } else if (seed.generation < stamp && hasLocalSession) {
                            pendingSeedGeneration = stamp + 1;
                        }
                    } else if (hasLocalSession) {
                        pendingSeedGeneration = seed.generation + 1;
                    } else {
                        shouldAdoptSeed = true;
                    }
                } else if (hasLocalSession) {
                    pendingSeedGeneration = stamp + 1;
                }
            } catch (_) {}
            if (shouldAdoptSeed) { adopt(seed); }
            return pendingSeedGeneration;
        }

        function startMirroring(pendingSeedGeneration) {
            try {
                if (pendingSeedGeneration !== null && read("chatter") !== null) {
                    postMirror(Math.max(pendingSeedGeneration, stampGeneration() + 1), snapshot().entries);
                }
            } catch (_) {}

            var lastFingerprint;
            var lastPresent;
            try {
                var initial = snapshot();
                lastFingerprint = fingerprint(initial.entries);
                lastPresent = initial.present;
            } catch (_) {
                lastFingerprint = fingerprint({});
                lastPresent = 0;
            }

            function poll() {
                try {
                    var current = snapshot();
                    var currentFingerprint = fingerprint(current.entries);
                    if (currentFingerprint === lastFingerprint) { return; }
                    var previousPresent = lastPresent;
                    lastFingerprint = currentFingerprint;
                    lastPresent = current.present;
                    if (current.present === 0 && previousPresent > 0) {
                        postClear();
                        return;
                    }
                    postMirror(stampGeneration() + 1, current.entries);
                } catch (_) {}
            }

            try { setInterval(poll, 2000); } catch (_) {}
            try {
                window.addEventListener("visibilitychange", poll);
                window.addEventListener("pagehide", poll);
            } catch (_) {}
        }

        // ---- bounded pre-start state machine (mode + native seed pull) -----
        var applied = false;
        var modeState = { settled: false, mode: null };
        var seedState = { settled: false, seed: null };
        // Whether a null mode came from a rollout fetch that ERRORED or timed out, rather
        // than from a page the mode was never resolvable for (no dotted host, no fetch).
        // Both fail closed identically, but only the first is a degradation the host can
        // act on: the second is a page this feature does not apply to.
        var rolloutUnresolved = false;
        var timeoutId = null;
        function clearFetchTimeout() {
            if (timeoutId !== null) { try { clearTimeout(timeoutId); } catch (_) {} }
            timeoutId = null;
        }
        function apply() {
            if (applied) { return; }
            applied = true;
            clearFetchTimeout();
            var mode = modeState.settled ? modeState.mode : null;
            if (mode === "normal") {
                var seed = seedState.settled ? seedState.seed : null;
                startMirroring(adoptSeedIfNeeded(seed));
            } else if (typeof mode === "string") {
                clearMirrorForNonNormalMode();
            } else if (rolloutUnresolved) {
                // Fail-closed on an UNKNOWN mode: no write, no clear, and one report —
                // a mount that refused to restore a session is otherwise
                // indistinguishable from one that had nothing to restore.
                post({
                    type: "sdk.session.mirrorDiagnostic",
                    version: 1,
                    scopeKey: SCOPE_KEY
                });
            }
            // A null mode with no failed fetch behind it (inert page): fail closed the same
            // way — no write, no clear — but nothing to report.
            // Drop the pulled blob once the decision is applied so a credential
            // seed is not retained in this closure for the document lifetime
            // (Android/RN parity). The `settled` guard already makes any late
            // reply a no-op, so the receiver can stay for the shared bridge.
            seedState.seed = null;
            releaseStart();
        }
        function maybeApply() {
            // Only normal mode needs the seed; other modes decide without it.
            if (modeState.settled && modeState.mode === "normal" && seedState.settled) { apply(); }
        }
        function onModeSettled(mode) {
            if (modeState.settled) { return; }
            modeState.settled = true;
            modeState.mode = (typeof mode === "string") ? mode : null;
            if (modeState.mode === "normal") { maybeApply(); } else { apply(); }
        }
        // Settles the mode UNKNOWN from a rollout fetch that errored or timed out. Guarded on
        // `settled` before the flag is raised, so a fetch rejection landing after the timeout
        // already settled cannot report twice, and cannot relabel a mode that did resolve.
        function onModeUnresolved() {
            if (modeState.settled) { return; }
            rolloutUnresolved = true;
            onModeSettled(null);
        }
        function onSeedSettled(seed) {
            // `applied` is terminal. A non-normal, unresolved, or timeout
            // settlement can apply BEFORE the reply lands; without this guard a
            // late reply would re-populate the credential blob that apply()
            // just dropped, and apply() cannot run again to clear it.
            if (applied || seedState.settled) { return; }
            seedState.settled = true;
            seedState.seed = seed;
            maybeApply();
        }

        // Native answers the seed pull through the same dispatch channel the
        // clear-ack uses. The legacy page defines no bridge adapter, so this
        // injected receiver owns __ADA_BRIDGE_DISPATCH__ for the seed reply.
        var seedRequestId = String(Date.now()) + "-" + Math.random().toString(16).slice(2);
        window.__ADA_BRIDGE_DISPATCH__ = function (json) {
            try {
                var command = typeof json === "string" ? JSON.parse(json) : json;
                if (command && command.type === "sdk.sessionMirror.seed" &&
                    command.requestId === seedRequestId) {
                    onSeedSettled(command.seed === undefined ? null : command.seed);
                }
            } catch (_) {}
        };

        if (pagePrivateOverride()) {
            // Page override forces non-normal: clear, no seed needed, release.
            onModeSettled("private");
            return;
        }

        // Pull the seed from native (answered live → empty after a clear).
        post({
            type: "sdk.session.mirrorRequest",
            version: 1,
            scopeKey: SCOPE_KEY,
            requestId: seedRequestId
        });

        try {
            var hostParts = String(window.location.hostname || "").split(".");
            if (hostParts.length < 2 || typeof window.fetch !== "function") {
                // The mode cannot be resolved from this host: fail closed and
                // release start so legacy chat still boots.
                onModeSettled(null);
                return;
            }
            var clientUrl = "https://rollout." + hostParts.slice(1).join(".") +
                "/" + hostParts[0] + "/client.json";

            var controller = null;
            try {
                controller = typeof AbortController === "function" ? new AbortController() : null;
            } catch (_) {}
            // Bound the whole pre-start step: on timeout, settle the mode
            // unresolved if still pending and force apply so start is never held
            // past the bound (start-without-adoption, never a hang). Adoption
            // fails OPEN here; the write path does not. An unanswered pull leaves
            // native's generation unknown, so writes close for the document while
            // an explicit clear still reaches native.
            timeoutId = setTimeout(function () {
                if (controller) { try { controller.abort(); } catch (_) {} }
                if (!modeState.settled) {
                    modeState.settled = true;
                    modeState.mode = null;
                    rolloutUnresolved = true;
                }
                if (!seedState.settled) { writesSuppressed = true; }
                apply();
            }, ROLLOUT_FETCH_TIMEOUT_MS);

            window.fetch(clientUrl, controller ? { signal: controller.signal } : undefined)
                .then(function (response) { return response.json(); })
                .then(function (client) {
                    var mode = client === null || typeof client !== "object" ? null : client.persistence;
                    onModeSettled(mode);
                })
                .catch(function () { onModeUnresolved(); });
        } catch (_) {
            // An unexpected failure setting up the mode fetch must still release
            // start, without writing the seed under an unknown mode.
            onModeSettled(null);
        }
    })();
    """
}
