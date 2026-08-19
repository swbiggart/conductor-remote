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

Simulator builds need no signing; for a real iPhone see
[Deploy to your phone](#deploy-to-your-phone).

To point a simulator at the local relay: run `yarn start`, open the app, paste
`http://127.0.0.1:8787/#token=<token>` (token in
`~/Library/Application Support/conductor-remote/token`).

## Deploy to your phone

Routine deploy — one command from the repo root, phone on a cable (Wi-Fi works
once paired, but is slower and flakier):

```bash
yarn ios:deploy
```

It resolves your signing team (persisted in the gitignored
`ios/Signing.local.xcconfig` after the first run), regenerates the project with
XcodeGen, builds Debug for the connected iPhone with automatic signing,
installs with `devicectl`, and launches. Flags: `--device <name|udid>` when
several phones are connected, `--release`, `--no-launch`, `--list-devices`,
`--team <ID>` to override the team once.

### One-time setup

1. **Xcode → Settings → Accounts → "+"** — sign in with your Apple ID. A free
   account is fine (no paid membership needed).
2. **Cable the iPhone** to the Mac, unlock it, tap **Trust This Computer**.
3. **Enable Developer Mode** on the phone: Settings → Privacy & Security →
   Developer Mode → on (the phone reboots).
4. Run `yarn ios:deploy`. The first build mints your signing certificate — a
   macOS keychain dialog may appear: enter your login password and click
   **Always Allow**.
5. After the first install, trust the app on the phone: Settings → General →
   **VPN & Device Management** → your Apple ID → **Trust**. Then it launches.
6. **Pair with the relay**: `yarn service status` prints the relay URL — scan
   the QR in-app, or paste the `https://…#token=…` link. One-time; the token
   lives in the iOS Keychain and survives reinstalls and re-signs.

### Free-account caveats

- The signature **expires after 7 days** — the app just stops launching. The
  fix is rerunning `yarn ios:deploy`; pairing and app data survive.
- At most **3 sideloaded apps** on the phone at once, and ~**10 new app IDs
  per week** across all projects.
- No push entitlements — which is why APNs is in "Deferred" below.

### Troubleshooting

| Symptom | Fix |
|---|---|
| "no iPhone found" | Cable + unlock + re-tap Trust; `yarn ios:deploy --list-devices` to check. |
| "No Account for Team" | Add your Apple ID in Xcode → Settings → Accounts, rerun. |
| "No signing certificate" | Rerun; approve the keychain dialog (**Always Allow**). |
| `errSecInternalComponent` | Keychain locked / no GUI session — run from a local terminal, not SSH. |
| "Developer Mode" errors | Settings → Privacy & Security → Developer Mode → on → reboot → rerun. |
| "device is locked" | Unlock the phone and keep it unlocked during install. |
| `ApplicationVerificationFailed` / profile errors | The 7-day profile expired — rerun; if it persists, delete the app from the phone first. |
| "Untrusted Developer" on launch | Settings → General → VPN & Device Management → Trust. |
| Wi-Fi install stalls or drops | Use the cable — wireless `devicectl` installs are best-effort. |
| Anything else | Open `ios/ConductorRemote.xcodeproj` in Xcode once — the Signing pane surfaces account problems interactively. |

## Deferred (designed, not built)

- **APNs push + lock-screen Reply** — needs a paid Apple Developer account and
  a small relay extension (`src/apns.ts`: node:http2 + ES256 over a .p8, a
  `{apns:{deviceToken}}` subscribe variant, notify.ts device-store v2).
- **Live Activities / Dynamic Island** for the running turn; App Shortcuts;
  widgets.
