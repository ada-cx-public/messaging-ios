// swift-tools-version: 5.9
//
// Source-distribution Package.swift for local development and CI testing.
//
// External SDK consumers should add the public distribution package:
//   .package(url: "https://github.com/ada-cx-public/messaging-ios.git", from: "<version>")
// See README.md for full Swift Package Manager installation instructions.
//
// Notes for source distribution:
// - Storyboard/xib loading falls back to Bundle(for:) — this works correctly
//   for both manual import and SPM source builds as long as the module bundle
//   contains the compiled resources.
// - For binary distribution (.xcframework), none of these caveats apply.

import PackageDescription

let package = Package(
	name: "AdaMessaging",
	defaultLocalization: "en",
	platforms: [
		.iOS(.v16),
	],
	products: [
		.library(
			name: "AdaMessaging",
			targets: ["AdaMessaging"]
		),
	],
	targets: [
		.target(
			name: "AdaMessaging",
			path: "MessagingFramework",
			exclude: [
				"MessagingFramework.h", // Objective-C umbrella header — not needed for Swift SPM
				"Info.plist", // Framework Info.plist is unused by SPM
			],
			resources: [
				.process("Assets.xcassets"),
				.process("AdaWebHostViewController.storyboard"),
				.copy("PrivacyInfo.xcprivacy"),
			],
			swiftSettings: [
				// Incrementally adopt Swift 6 concurrency features.
				// These enable stricter checking without requiring a full Swift 6 language mode.
				.enableUpcomingFeature("InferSendableFromCaptures"),
				.enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
			]
		),
		// ExampleApp is intentionally omitted from SPM targets.
		// It uses UIKit which SPM can't build on macOS (SourceKit-LSP host platform).
		// SourceKit-LSP resolves ExampleApp via xcode-build-server (buildServer.json).
		.testTarget(
			name: "AdaMessagingTests",
			dependencies: ["AdaMessaging"],
			path: "MessagingFrameworkTests",
			exclude: ["Info.plist"]
		),
	]
)
