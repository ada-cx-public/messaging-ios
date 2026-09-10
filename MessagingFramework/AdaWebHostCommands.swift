import Foundation
import WebKit

// MARK: - Commands

public extension AdaWebHost {
    internal func dispatchBridgeCommandWhenReady(_ action: @escaping (WKWebView) -> Void) {
        if webHostLoaded, let webView {
            action(webView)
            return
        }

        guard !webHostLoaded else { return }

        pendingCommands.append { [weak self] in
            guard let webView = self?.webView else { return }
            action(webView)
        }
    }

    func setDeviceToken(deviceToken: String) {
        // A whitespace-only token must never win or clear an existing registration
        // (mirrors RN's isNonBlankToken and Android's isNotBlank). Delivery is gated on
        // a non-empty token, so a blank call before the runtime is ready would otherwise
        // overwrite the retained token and permanently discard the init-time push token. (EXP-1223)
        guard !deviceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        self.deviceToken = deviceToken
        if usesBridgeRuntime {
            // Before the bridge runtime is ready, keep only the latest token in
            // host state and let `adaBridgeDidBecomeReady` deliver it once.
            guard webHostLoaded, let webView else { return }
            bridgeHandler.setDeviceToken(deviceToken, to: webView)
            return
        }
        evalJS("setDeviceToken(\(jsonStr(deviceToken)));")
    }

    /// Push a dictionary of fields to the server
    @available(
        *,
        deprecated,
        message: "Deprecated. Use setMetaFields(builder:) instead.",
        renamed: "setMetaFields(builder:)"
    )
    func setMetaFields(_ fields: [String: Any]) {
        if usesBridgeRuntime {
            dispatchBridgeCommandWhenReady { [bridgeHandler] webView in
                bridgeHandler.setMetaFields(fields, to: webView)
            }
            return
        }
        guard let json = try? JSONSerialization.data(withJSONObject: fields, options: []),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        evalJS("adaEmbed.setMetaFields(\(jsonString));")
    }

    /// Push a dictionary of fields to the server
    @available(
        *,
        deprecated,
        message: "Deprecated. Use setSensitiveMetaFields(builder:) instead.",
        renamed: "setSensitiveMetaFields(builder:)"
    )
    func setSensitiveMetaFields(_ fields: [String: Any]) {
        // MERGE into the backing field, matching the web runtime's
        // SET_SENSITIVE_META_FIELDS handler (`{ ...existing, ...payload }`), so the
        // post-ready re-send on a later document (adaBridgeDidBecomeReady) reflects
        // the session's full credential set — a partial update must not drop keys a
        // prior call set (EXP-1223).
        self.sensitiveMetafields.merge(fields) { _, new in new }
        // Rebuild the armed document-start re-arm so a later document carries this
        // updated credential, not the value armed at the last sdk.ready (EXP-1223 grJTI).
        refreshRetainedConfigScriptIfArmed()
        if usesBridgeRuntime {
            dispatchBridgeCommandWhenReady { [bridgeHandler] webView in
                bridgeHandler.setSensitiveMetaFields(fields, to: webView)
            }
            return
        }
        guard let json = try? JSONSerialization.data(withJSONObject: fields, options: []),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        evalJS("adaEmbed.setSensitiveMetaFields(\(jsonString));")
    }

    /// Override method using builder class
    func setMetaFields(builder: MetaFields.Builder) {
        let metaFields = builder.build().metaFields
        if usesBridgeRuntime {
            dispatchBridgeCommandWhenReady { [bridgeHandler] webView in
                bridgeHandler.setMetaFields(metaFields, to: webView)
            }
            return
        }
        guard let json = try? JSONSerialization.data(withJSONObject: metaFields, options: []),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        evalJS("adaEmbed.setMetaFields(\(jsonString));")
    }

    func setSensitiveMetaFields(builder: MetaFields.Builder) {
        let metaFields = builder.build().metaFields
        // Merge into the backing field (see the string overload).
        self.sensitiveMetafields.merge(metaFields) { _, new in new }
        refreshRetainedConfigScriptIfArmed()
        if usesBridgeRuntime {
            dispatchBridgeCommandWhenReady { [bridgeHandler] webView in
                bridgeHandler.setSensitiveMetaFields(metaFields, to: webView)
            }
            return
        }
        guard let json = try? JSONSerialization.data(withJSONObject: metaFields, options: []),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        evalJS("adaEmbed.setSensitiveMetaFields(\(jsonString));")
    }

    /// Re-initialize chat and optionally reset history, language, meta data, etc
    /// When this method is deprecated, the 4 override reset methods should be replaced
    @available(
        *,
        deprecated,
        message: "Deprecated. Use reset(metaFields:sensitiveMetaFields:) instead.",
        renamed: "reset(metaFields:sensitiveMetaFields:)"
    )
    func reset(
        language: String? = nil,
        greeting: String? = nil,
        metaFields: [String: Any]? = nil,
        sensitiveMetaFields: [String: Any]? = nil,
        resetChatHistory: Bool? = true,
    ) {
        // A reset REPLACES the session's sensitive fields with the reset's value —
        // matching the web RESET handler (`newState.sensitiveMetaFields = payload`),
        // where an omitted value clears them. So the backing field the post-ready
        // re-send reads must track that: the reset's fields, or empty when none are
        // passed. Otherwise a later document resurrects a credential the reset
        // cleared (EXP-1223).
        self.sensitiveMetafields = sensitiveMetaFields ?? [:]
        refreshRetainedConfigScriptIfArmed()
        if usesBridgeRuntime {
            dispatchBridgeCommandWhenReady { [bridgeHandler] webView in
                bridgeHandler.reset(
                    language: language,
                    greeting: greeting,
                    metaFields: metaFields.map { AdaWebHost.withReservedMetaFields($0) },
                    sensitiveMetaFields: sensitiveMetaFields,
                    resetChatHistory: resetChatHistory,
                    to: webView,
                )
            }
            return
        }
        let data: [String: Any?] = [
            "language": language,
            "greeting": greeting,
            "metaFields": AdaWebHost.withReservedMetaFields(metaFields),
            "sensitiveMetaFields": sensitiveMetaFields,
            "resetChatHistory": resetChatHistory,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: data, options: .fragmentsAllowed),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        evalJS("adaEmbed.reset(\(jsonString));")
    }

    func reset(
        language: String? = nil,
        greeting: String? = nil,
        metaFields: MetaFields.Builder,
        resetChatHistory: Bool? = true,
    ) {
        // This reset carries no sensitive fields, so the web clears them — the
        // backing field the post-ready re-send reads must clear too (EXP-1223).
        self.sensitiveMetafields = [:]
        refreshRetainedConfigScriptIfArmed()
        if usesBridgeRuntime {
            dispatchBridgeCommandWhenReady { [bridgeHandler] webView in
                bridgeHandler.reset(
                    language: language,
                    greeting: greeting,
                    metaFields: AdaWebHost.withReservedMetaFields(metaFields.build().metaFields),
                    sensitiveMetaFields: nil,
                    resetChatHistory: resetChatHistory,
                    to: webView,
                )
            }
            return
        }
        let data: [String: Any?] = [
            "language": language,
            "greeting": greeting,
            "metaFields": AdaWebHost.withReservedMetaFields(metaFields.build().metaFields),
            "sensitiveMetaFields": nil,
            "resetChatHistory": resetChatHistory,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: data, options: .fragmentsAllowed),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        evalJS("adaEmbed.reset(\(jsonString));")
    }

    func reset(
        language: String? = nil,
        greeting: String? = nil,
        sensitiveMetaFields: MetaFields.Builder,
        resetChatHistory: Bool? = true,
    ) {
        let resolvedSensitiveMetaFields = sensitiveMetaFields.build().metaFields
        // The retained-injection backing field tracks the reset's sensitive fields
        // so a later document re-arms with them (EXP-1223).
        self.sensitiveMetafields = resolvedSensitiveMetaFields
        refreshRetainedConfigScriptIfArmed()
        if usesBridgeRuntime {
            dispatchBridgeCommandWhenReady { [bridgeHandler] webView in
                bridgeHandler.reset(
                    language: language,
                    greeting: greeting,
                    metaFields: nil,
                    sensitiveMetaFields: resolvedSensitiveMetaFields,
                    resetChatHistory: resetChatHistory,
                    to: webView,
                )
            }
            return
        }
        let data: [String: Any?] = [
            "language": language,
            "greeting": greeting,
            "metaFields": AdaWebHost.withReservedMetaFields(nil),
            "sensitiveMetaFields": resolvedSensitiveMetaFields,
            "resetChatHistory": resetChatHistory,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: data, options: .fragmentsAllowed),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        evalJS("adaEmbed.reset(\(jsonString));")
    }

    func reset(
        language: String? = nil,
        greeting: String? = nil,
        metaFields: MetaFields.Builder,
        sensitiveMetaFields: MetaFields.Builder,
        resetChatHistory: Bool? = true,
    ) {
        let resolvedSensitiveMetaFields = sensitiveMetaFields.build().metaFields
        // The retained-injection backing field tracks the reset's sensitive fields
        // so a later document re-arms with them (EXP-1223).
        self.sensitiveMetafields = resolvedSensitiveMetaFields
        refreshRetainedConfigScriptIfArmed()
        if usesBridgeRuntime {
            dispatchBridgeCommandWhenReady { [bridgeHandler] webView in
                bridgeHandler.reset(
                    language: language,
                    greeting: greeting,
                    metaFields: AdaWebHost.withReservedMetaFields(metaFields.build().metaFields),
                    sensitiveMetaFields: resolvedSensitiveMetaFields,
                    resetChatHistory: resetChatHistory,
                    to: webView,
                )
            }
            return
        }
        let data: [String: Any?] = [
            "language": language,
            "greeting": greeting,
            "metaFields": AdaWebHost.withReservedMetaFields(metaFields.build().metaFields),
            "sensitiveMetaFields": resolvedSensitiveMetaFields,
            "resetChatHistory": resetChatHistory,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: data, options: .fragmentsAllowed),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        evalJS("adaEmbed.reset(\(jsonString));")
    }

    func reset(language: String? = nil, greeting: String? = nil, resetChatHistory: Bool? = true) {
        // No sensitive fields, so the web clears them — clear the backing field the
        // post-ready re-send reads (EXP-1223).
        self.sensitiveMetafields = [:]
        refreshRetainedConfigScriptIfArmed()
        if usesBridgeRuntime {
            dispatchBridgeCommandWhenReady { [bridgeHandler] webView in
                bridgeHandler.reset(
                    language: language,
                    greeting: greeting,
                    resetChatHistory: resetChatHistory,
                    to: webView,
                )
            }
            return
        }
        let data: [String: Any?] = [
            "language": language,
            "greeting": greeting,
            "metaFields": AdaWebHost.withReservedMetaFields(nil),
            "sensitiveMetaFields": nil,
            "resetChatHistory": resetChatHistory,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: data, options: .fragmentsAllowed),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        evalJS("adaEmbed.reset(\(jsonString));")
    }

    /// Re-initialize chat and optionally reset history, language, meta data, etc
    func deleteHistory() {
        if usesBridgeRuntime {
            dispatchBridgeCommandWhenReady { [bridgeHandler] webView in
                bridgeHandler.deleteHistory(to: webView)
            }
            return
        }
        evalJS("adaEmbed.deleteHistory();")
    }

    /// Programmatically send a user message into the conversation.
    ///
    /// Messaging runtime only, and core rejects it with `ProgrammaticControlNotEnabled`
    /// unless the host was created with `enableProgrammaticControl: true`. Queued until
    /// the runtime is ready. The legacy remote host page has no send command, so the
    /// call is dropped there.
    func sendMessage(_ body: String) {
        guard usesBridgeRuntime else {
            debugPrint("[AdaWebHost] sendMessage is not supported on the legacy remote host page")
            return
        }
        dispatchBridgeCommandWhenReady { [bridgeHandler] webView in
            bridgeHandler.sendMessage(body, to: webView)
        }
    }

    /// Removes every natively persisted cache: the allowlisted startup/branding
    /// state in `UserDefaults` AND the Keychain session mirror for all scopes —
    /// call on user sign-out or whenever recoverable chat state should be
    /// discarded. The next WebView session starts without rehydrated state.
    /// Does not touch the web runtime's own storage; use ``deleteHistory()``
    /// or `reset` for the conversation itself.
    ///
    /// Returns `Void`, preserving the original binary contract — a consumer that
    /// links against a prebuilt XCFramework built with
    /// `BUILD_LIBRARY_FOR_DISTRIBUTION=YES` keeps resolving the same mangled
    /// symbol across a framework swap. Call ``clearPersistedStateDurably()`` when
    /// you need to know whether the mirror wipe is confirmed durable.
    ///
    /// Non-blocking and main-thread-safe: the Keychain wipe is enqueued
    /// fire-and-forget on the serial mirror queue, so a slow keychain daemon
    /// cannot hitch the caller. A wipe that does not commit reports the
    /// `ada.sessionMirror.diagnostic` event with reason `adapter-removeItem-failed`
    /// to your event callbacks — treat it as "retry the sign-out", because a
    /// session blob may survive into the next launch.
    func clearPersistedState() {
        bridgeHandler.clearPersistedState()
        bridgeHandler.clearAllSessionMirrors()
    }

    /// Sign-out wipe that reports durability: removes the `UserDefaults`
    /// branding/startup cache AND the Keychain session mirror for all scopes, and
    /// reports whether the mirror wipe is confirmed gone. On `false` the Keychain
    /// delete failed or could not be confirmed and a session blob may survive into
    /// the next launch, so retry rather than treating the sign-out as complete.
    /// Distinct from ``clearPersistedState()`` so that method's `Void` binary
    /// contract stays unchanged for XCFramework consumers.
    ///
    /// Does not block. The Keychain wipe runs on the process-wide serial mirror queue and
    /// `completion` is called on the main actor when it reports, so a sign-out on the main actor
    /// stays responsive however slow the Keychain is. Prefer this over
    /// ``clearPersistedStateDurably()``, which answers the same question by freezing the caller.
    func clearPersistedStateDurably(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        bridgeHandler.clearPersistedState()
        bridgeHandler.clearAllSessionMirrorsDurably(completion: completion)
    }

    /// Blocking variant of ``clearPersistedStateDurably(completion:)`` — same wipe, same
    /// `false`-means-retry contract, returned inline.
    ///
    /// **It blocks the calling thread for up to
    /// ``AdaBridgeHandler/sessionMirrorClearDurablyTimeout`` seconds, and since ``AdaWebHost`` is
    /// `@MainActor` that thread is the main one.** There is no off-main call for an actor-correct
    /// host to make, so a slow Keychain freezes the UI for the whole bound. Use
    /// ``clearPersistedStateDurably(completion:)`` unless a synchronous answer is unavoidable.
    ///
    /// ``AdaBridgeHandler/sessionMirrorClearDurablyStartGrace`` bounds only the wait for the mirror
    /// queue's head, not the wipe: a Keychain write another mount already accepted is work this
    /// wipe is ordered behind, and if that stalls you are answered `false` at the grace instead of
    /// waiting it out. Once the wipe itself starts, the remainder of the bound is all main-thread
    /// block. The wipe still runs, in order, either way — so `false` means the wipe is unconfirmed
    /// and you should retry, not that nothing was wiped.
    @discardableResult
    func clearPersistedStateDurably() -> Bool {
        bridgeHandler.clearPersistedState()
        return bridgeHandler.clearAllSessionMirrorsDurably()
    }

    func setLanguage(language: String) {
        if usesBridgeRuntime {
            dispatchBridgeCommandWhenReady { [bridgeHandler] webView in
                bridgeHandler.setLanguage(language, to: webView)
            }
            return
        }
        evalJS("adaEmbed.setLanguage(\(jsonStr(language)));")
    }
}
