# Conductor Remote for iOS

Native SwiftUI client of the relay in `../src` — same HTTP API the PWA uses,
rebuilt as an iOS-native app. Design notes: Flighty-style live workspace board
(status ring around the repo avatar), Claude-iOS conversation surface, Working
Copy-style diffs, staged agent settings riding each send.

## Layout

- `ConductorKit/` — SwiftPM package holding everything testable: wire models
  (mirroring `web/src/lib/types.ts`), the `APIClient` actor (ETags, timeout
  tiers, `x-client-timeout-ms`), `PollingEngine`, send pipeline, read marks,
  drafts, transcript grouping. **UIKit-free on purpose**: it also builds for
  macOS, so it compiles and tests without Xcode.
- `App/Sources/` — the SwiftUI app target (needs Xcode 26).
- `project.yml` — XcodeGen spec; the `.xcodeproj` is generated and gitignored.

## Building

Without Xcode (Kit only — CI-grade verification):

```bash
cd ios/ConductorKit
swift build && swift test
```

Note: the machine's Command Line Tools install can carry a stale
`PackageDescription.private.swiftinterface` that breaks *every* SwiftPM
manifest ("Undefined symbols … Package.__allocating_init"). Workaround used
here: `brew install swift` and run `/opt/homebrew/opt/swift/bin/swift` instead.
A healthy CLT or any Xcode toolchain also works.

Full app (needs Xcode 26 from the App Store, then):

```bash
sudo xcode-select -s /Applications/Xcode.app
brew install xcodegen        # already installed on this Mac
cd ios && xcodegen generate
xcodebuild -project ConductorRemote.xcodeproj -scheme ConductorRemote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Simulator builds need no signing. For a device build, set your team in Xcode's
Signing pane (kept in the gitignored project) — free provisioning works but
re-signs every 7 days and cannot use push entitlements.

To point a simulator at the local relay: run `yarn start`, open the app, paste
`http://127.0.0.1:8787/#token=<token>` (token in
`~/Library/Application Support/conductor-remote/token`).

## Deferred (designed, not built)

- **APNs push + lock-screen Reply** — needs a paid Apple Developer account and
  a small relay extension (`src/apns.ts`: node:http2 + ES256 over a .p8, a
  `{apns:{deviceToken}}` subscribe variant, notify.ts device-store v2).
- **Live Activities / Dynamic Island** for the running turn; App Shortcuts;
  widgets.
