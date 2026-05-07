//
//  AdaMessagingVersion.swift
//  AdaMessaging
//

import Foundation

enum AdaMessagingVersion {
    static let placeholderVersion = "0.0.0"
    static let packageVersion = "1.1.1"

    private static let semverPattern = #"^\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"#

    static var current: String? {
        resolve(
            packageVersion: packageVersion,
            frameworkBundle: Bundle(for: AdaWebHost.self),
            mainBundle: .main,
        )
    }

    static func resolve(
        packageVersion rawPackageVersion: String,
        frameworkBundle: Bundle,
        mainBundle: Bundle,
    ) -> String? {
        if let packageVersion = normalizeSemver(rawPackageVersion),
           packageVersion != placeholderVersion {
            return packageVersion
        }

        let rawFrameworkVersion = frameworkBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if !sameBundle(frameworkBundle, mainBundle),
           let frameworkVersion = normalizeSemver(rawFrameworkVersion) {
            return frameworkVersion
        }

        return normalizeSemver(rawPackageVersion)
    }

    static func normalizeSemver(_ rawVersion: String?) -> String? {
        guard let rawVersion else {
            return nil
        }

        let trimmedVersion = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVersion.isEmpty else {
            return nil
        }

        return trimmedVersion.range(of: semverPattern, options: .regularExpression) != nil
            ? trimmedVersion
            : nil
    }

    private static func sameBundle(_ lhs: Bundle, _ rhs: Bundle) -> Bool {
        lhs.bundleURL.standardizedFileURL == rhs.bundleURL.standardizedFileURL
    }
}
