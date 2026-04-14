//
//  MetaFields.swift
//  AdaMessaging
//

public class MetaFields {
    private(set) var metaFields: [String: Any] = [:]

    init(metaFields: [String: Any]) {
        self.metaFields = metaFields
    }

    public class Builder {
        private var metaFields: [String: Any] = [:]

        public init() {
            metaFields = [:]
        }

        public func setField(key: String, value: String) -> MetaFields.Builder {
            metaFields[key] = value
            return self
        }

        public func setField(key: String, value: Bool) -> MetaFields.Builder {
            metaFields[key] = value
            return self
        }

        public func setField(key: String, value: Int) -> MetaFields.Builder {
            metaFields[key] = value
            return self
        }

        public func setField(key: String, value: Float) -> MetaFields.Builder {
            metaFields[key] = value
            return self
        }

        public func setField(key: String, value: Double) -> MetaFields.Builder {
            metaFields[key] = value
            return self
        }

        func build() -> MetaFields {
            MetaFields(metaFields: metaFields)
        }
    }
}
