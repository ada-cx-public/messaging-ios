import Foundation
import WebKit

// MARK: - Commands

public extension AdaWebHost {
    func setDeviceToken(deviceToken: String) {
        self.deviceToken = deviceToken
        if usesBridgeRuntime {
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
        message: "This method will be deprecated in the future, please upgrade to MetaFields.Builder.",
        renamed: "setMetaFields(builder:)"
    )
    func setMetaFields(_ fields: [String: Any]) {
        if usesBridgeRuntime {
            guard webHostLoaded, let webView else { return }
            bridgeHandler.setMetaFields(fields, to: webView)
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
        message: "This method will be deprecated in the future, please upgrade to MetaFields.Builder.",
        renamed: "setSensitiveMetaFields(builder:)"
    )
    func setSensitiveMetaFields(_ fields: [String: Any]) {
        if usesBridgeRuntime {
            guard webHostLoaded, let webView else { return }
            bridgeHandler.setSensitiveMetaFields(fields, to: webView)
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
            guard webHostLoaded, let webView else { return }
            bridgeHandler.setMetaFields(metaFields, to: webView)
            return
        }
        guard let json = try? JSONSerialization.data(withJSONObject: metaFields, options: []),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        evalJS("adaEmbed.setMetaFields(\(jsonString));")
    }

    func setSensitiveMetaFields(builder: MetaFields.Builder) {
        let metaFields = builder.build().metaFields
        if usesBridgeRuntime {
            guard webHostLoaded, let webView else { return }
            bridgeHandler.setSensitiveMetaFields(metaFields, to: webView)
            return
        }
        guard let json = try? JSONSerialization.data(withJSONObject: metaFields, options: []),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        evalJS("adaEmbed.setSensitiveMetaFields(\(jsonString));")
    }

    /// Re-initialize chat and optionally reset history, language, meta data, etc
    /// When this method is depreciated, the 4 override reset methods should be replaced
    @available(
        *,
        deprecated,
        message: "This method will be deprecated in the future, please upgrade to MetaFields.Builder.",
        renamed: "reset(metaFields:sensitiveMetaFields:)"
    )
    func reset(
        language: String? = nil,
        greeting: String? = nil,
        metaFields: [String: Any]? = nil,
        sensitiveMetaFields: [String: Any]? = nil,
        resetChatHistory: Bool? = true,
    ) {
        if usesBridgeRuntime {
            guard webHostLoaded, let webView else { return }
            bridgeHandler.reset(
                language: language,
                greeting: greeting,
                metaFields: metaFields,
                sensitiveMetaFields: sensitiveMetaFields,
                resetChatHistory: resetChatHistory ?? true,
                to: webView,
            )
            return
        }
        let data: [String: Any?] = [
            "language": language,
            "greeting": greeting,
            "metaFields": metaFields,
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
        if usesBridgeRuntime {
            guard webHostLoaded, let webView else { return }
            bridgeHandler.reset(
                language: language,
                greeting: greeting,
                metaFields: metaFields.build().metaFields,
                sensitiveMetaFields: nil,
                resetChatHistory: resetChatHistory ?? true,
                to: webView,
            )
            return
        }
        let data: [String: Any?] = [
            "language": language,
            "greeting": greeting,
            "metaFields": metaFields.build().metaFields,
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
        if usesBridgeRuntime {
            guard webHostLoaded, let webView else { return }
            bridgeHandler.reset(
                language: language,
                greeting: greeting,
                metaFields: nil,
                sensitiveMetaFields: sensitiveMetaFields.build().metaFields,
                resetChatHistory: resetChatHistory ?? true,
                to: webView,
            )
            return
        }
        let data: [String: Any?] = [
            "language": language,
            "greeting": greeting,
            "metaFields": nil,
            "sensitiveMetaFields": sensitiveMetaFields.build().metaFields,
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
        if usesBridgeRuntime {
            guard webHostLoaded, let webView else { return }
            bridgeHandler.reset(
                language: language,
                greeting: greeting,
                metaFields: metaFields.build().metaFields,
                sensitiveMetaFields: sensitiveMetaFields.build().metaFields,
                resetChatHistory: resetChatHistory ?? true,
                to: webView,
            )
            return
        }
        let data: [String: Any?] = [
            "language": language,
            "greeting": greeting,
            "metaFields": metaFields.build().metaFields,
            "sensitiveMetaFields": sensitiveMetaFields.build().metaFields,
            "resetChatHistory": resetChatHistory,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: data, options: .fragmentsAllowed),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        evalJS("adaEmbed.reset(\(jsonString));")
    }

    func reset(language: String? = nil, greeting: String? = nil, resetChatHistory: Bool? = true) {
        if usesBridgeRuntime {
            guard webHostLoaded, let webView else { return }
            bridgeHandler.reset(
                language: language,
                greeting: greeting,
                resetChatHistory: resetChatHistory ?? true,
                to: webView,
            )
            return
        }
        let data: [String: Any?] = [
            "language": language,
            "greeting": greeting,
            "metaFields": nil,
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
            guard webHostLoaded, let webView else { return }
            bridgeHandler.deleteHistory(to: webView)
            return
        }
        evalJS("adaEmbed.deleteHistory();")
    }

    func triggerAnswer(answerId: String) {
        if usesBridgeRuntime {
            if webHostLoaded {
                guard let webView else { return }
                bridgeHandler.triggerAnswer(responseId: answerId, to: webView)
                return
            }

            debugPrint("AdaWebHost.triggerAnswer failed, webView needs to be initialized.")
            return
        }

        if webHostLoaded {
            evalJS("adaEmbed.triggerAnswer(\(jsonStr(answerId)));")
            return
        }

        debugPrint("AdaWebHost.triggerAnswer failed, webView needs to be initialized.")
    }

    func setLanguage(language: String) {
        if usesBridgeRuntime {
            if webHostLoaded {
                guard let webView else { return }
                bridgeHandler.setLanguage(language, to: webView)
                return
            }

            debugPrint("AdaWebHost.setLanguage failed, webView needs to be initialized.")
            return
        }

        if webHostLoaded {
            evalJS("adaEmbed.setLanguage(\(jsonStr(language)));")
            return
        }

        debugPrint("AdaWebHost.setLanguage failed, webView needs to be initialized.")
    }
}
