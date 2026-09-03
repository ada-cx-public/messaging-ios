# Ada Messaging iOS SDK

This README is for iOS teams embedding Ada inside a native app.

## Requirements

- iOS 15.0 or newer
- Swift 5.9 or newer for source-based installs
- A current Xcode toolchain for prebuilt XCFramework installs
- One of:
  - Swift Package Manager
  - CocoaPods
  - Carthage
  - manual `xcframework` distribution

## Recommended Install Path

Swift Package Manager is the primary installation path going forward.

The published `ada-cx-public/messaging-ios` repository ships source-based installs through Swift Package Manager and CocoaPods, plus prebuilt binary distribution for Carthage and manual `xcframework` installs.

If your team needs the broadest compiler and toolchain compatibility, prefer Swift Package Manager or CocoaPods. Carthage and manual download use the prebuilt XCFramework produced by release CI.

### Swift Package Manager (SPM)

Xcode:

1. Open `File > Add Package Dependencies...`
2. Use `https://github.com/ada-cx-public/messaging-ios.git`
3. Choose the release you want to ship
4. Add product `AdaMessaging`

`Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ada-cx-public/messaging-ios.git", from: "1.3.0"),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: ["AdaMessaging"]
    ),
]
```

### CocoaPods

```ruby
pod "AdaMessaging", :git => "https://github.com/ada-cx-public/messaging-ios", :tag => "1.3.0"
```

### Carthage

```ruby
binary "https://raw.githubusercontent.com/ada-cx-public/messaging-ios/main/AdaMessaging.json" ~> 1.0
```

Then run `carthage update --use-xcframeworks` and add `AdaMessaging.xcframework` from `Carthage/Build` to your app target.

### Manual XCFramework

Download `AdaMessaging.xcframework.zip` from [ada-cx-public/messaging-ios releases](https://github.com/ada-cx-public/messaging-ios/releases) and embed `AdaMessaging.xcframework` in Xcode with `Embed & Sign`.

## Quick Start

`AdaWebHost` remains the main public integration surface.

```swift
import AdaMessaging

let adaWebHost = AdaWebHost(
    handle: "my-bot",
    language: "en",
    metafields: [
        "plan": "pro",
        "signedIn": true,
    ],
)

adaWebHost.launchModalWebSupport(from: self)
```

Other presentation options:

- `launchModalWebSupport(from:)`
- `launchNavWebSupport(from:)`
- `launchInjectingWebSupport(into:)`

Useful runtime commands:

```swift
let sensitive = MetaFields.Builder()
    .setField(key: "authToken", value: "secure-session-token")

adaWebHost.setSensitiveMetaFields(builder: sensitive)
adaWebHost.setDeviceToken(deviceToken: "apns-device-token")
adaWebHost.setLanguage(language: "fr")
adaWebHost.reset(language: "en", resetChatHistory: true)
adaWebHost.deleteHistory()
```

Most customer apps only need `handle`. Leave `cluster` and `domain` unset unless Ada tells you your AI agent is hosted on a non-default regional cluster or custom domain.

## Upgrade From The Old iOS SDK

The safest migration is:

1. replace the old dependency
2. rename the framework import
3. keep your existing `AdaWebHost` usage

### Side-by-side mapping

| Legacy | Messaging SDK |
|---|---|
| `AdaEmbedFramework` | `AdaMessaging` |
| `AdaEmbedFramework.xcframework` | `AdaMessaging.xcframework` |
| `pod "AdaEmbedFramework"` | `pod "AdaMessaging"` |
| `import AdaEmbedFramework` | `import AdaMessaging` |

The most important compatibility point is that `AdaWebHost` stays the main public class. Most customer apps only need a dependency swap and an import rename.

### Before / after: imports

```swift
// Before
import AdaEmbedFramework

// After
import AdaMessaging
```

### Before / after: dependency

```ruby
# Before
pod "AdaEmbedFramework"

# After
pod "AdaMessaging", :git => "https://github.com/ada-cx-public/messaging-ios", :tag => "1.3.0"
```

## Important Code Changes To Make

### 1. Most apps can keep using existing `AdaWebHost(handle: ...)` call sites unless you have a reason to change them

For the normal production path, keep your setup simple:

```swift
let adaWebHost = AdaWebHost(handle: "my-bot")
adaWebHost.launchModalWebSupport(from: self)
```

Only add a cluster or domain override if Ada gives you one for your production bot. For example, if your Ada team tells you to use a non-default regional deployment such as Maple, pass the exact values they provide:

```swift
let adaWebHost = AdaWebHost(
    handle: "my-bot",
    cluster: "maple",
)
```

If Ada gives you a custom domain as well, add `domain:` with that exact value. If Ada does not give you a cluster or domain override, leave both unset.

### 2. OPTIONAL - Move runtime metadata updates to `MetaFields.Builder`

Dictionary overloads for `setMetaFields`, `setSensitiveMetaFields`, and some `reset` shapes still exist for compatibility, but they are deprecated. For new code, prefer `MetaFields.Builder`.

Recommended:

```swift
let publicFields = MetaFields.Builder()
    .setField(key: "plan", value: "pro")
    .setField(key: "signedIn", value: true)

let sensitiveFields = MetaFields.Builder()
    .setField(key: "authToken", value: "secure-session-token")

adaWebHost.setMetaFields(builder: publicFields)
adaWebHost.setSensitiveMetaFields(builder: sensitiveFields)
adaWebHost.reset(
    language: "en",
    metaFields: publicFields,
    sensitiveMetaFields: sensitiveFields,
    resetChatHistory: true,
)
```

## Important Developer Notes

- `openWebLinksInSafari` controls whether supported web links open in `SFSafariViewController`
- `zdChatterAuthCallback` is supported for Zendesk Chat authentication flows on **both**
  runtimes — the Legacy `adaEmbed.start` path and the Messaging bridge. Your callback is invoked
  once per auth cycle, including the recurring refresh, and must call its completion handler
  exactly once.
- Leaving `zdChatterAuthCallback` unset behaves **differently per runtime**, so set it if your bot
  uses authenticated Zendesk Chat. On **Messaging**, Ada resolves the handshake immediately rather
  than burning its 10-second auth timeout, so the handoff proceeds unauthenticated instead of
  stalling once per refresh cycle. On **Legacy** there is no such fast path: the injected
  `adaEmbed.start` shim always installs the callback and posts to native, but native only answers
  when your callback is set, so an unset callback leaves that handshake unanswered rather than
  resolved
- `enableProgrammaticControl` (default `false`) opens core's programmatic-control gate on the
  Messaging runtime, which is otherwise closed and rejects programmatic requests. With it on you
  can drive a send: `AdaBridgeHandler` is public with a public `init()`, and its
  `sendCommand(_:to:)` takes the web view as a parameter, so you do not need the SDK's own
  handler. Pass the `WKWebView` that `launchInjectingWebSupport(into:)` added to your view, with
  an `Encodable` of shape `{"type": "ada.sendMessage", "payload": {"body": "…"}}`. Note this works
  because those classes happen to be public, not because it is a designed host API — there is no
  typed send on `AdaWebHost`, and composer-text set and the conversation/message reads have no
  native command at all. **It also starts delivering message bodies to your app**: the gated
  `ada:message:sent` / `ada:message:received` events carry the transcript and are forwarded to the
  native bridge, so treat enabling this as a data-handling decision, not just an API unlock.
  Ignored on the Legacy runtime, which has no such gate
- `deviceToken` can be passed at initialization time or later with `setDeviceToken(deviceToken:)`
- `webViewLoadingErrorCallback` lets you surface load failures or timeouts inside your app
- if your bot flow allows camera, photo-library, or video capture uploads, add the corresponding iOS usage descriptions to your app's `Info.plist`, such as `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`, and `NSMicrophoneUsageDescription`

## Release Checklist

Before shipping a migration:

- verify your real production bot handle launches successfully
- test the exact presentation mode you ship: modal, navigation push, or inline
- confirm any event logging still receives SDK events
- test `reset()` and `deleteHistory()` if your app exposes those actions
