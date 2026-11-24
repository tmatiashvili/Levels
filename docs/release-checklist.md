# Release checklist

How Levels ships (ADR-0022): the iPhone app (with its widget) through the App Store, the Mac app (with its widget) as a free notarized download from our own site. [REL-001](specs/REL-001-app-store-readiness.md) holds the rules; this page tracks what is done and what is left. Status as of 2026-11-24, on branch `chore/release-readiness`.

> **Biggest App Review risk: the reviewer cannot pair a Mac.**
>
> Levels for iPhone shows the Mac's battery and the AirPods connected to it. That needs a Mac running the Levels Mac app, and that app is not on the App Store: today the iPhone pairs with it on the same Wi-Fi; after enrollment iCloud may replace the hub (lead's call 27), which still needs a Mac signed in to the same Apple Account. App Review usually tests on an iPhone alone, often on an office network that blocks Bonjour. A reviewer who sees one battery row and a "Connect to your Mac" card can reject the app under **2.1 (App Completeness, "we were unable to review your app")** or **4.2 (Minimum Functionality)**. This is a common reason for rejection.
>
> Before the first submission, do both of these:
>
> 1. **Add a demo mode** (recommended; not built, and REL-001 says it needs an owner decision first). A "Try with sample devices" button on the Connect card (a button, not a launch argument: App Review can't pass arguments) that fills the list with sample devices: a MacBook, AirPods with left, right and case, an Apple Watch. The pieces exist: `InMemorySnapshotSource` and `PreviewFixtures` in LevelsUI. Show the widget with the same data while demo mode is on. Mark it clearly ("Sample data") and turn it off when a real Mac pairs. If the app has a paywall, the paywall must be reachable and purchasable in demo mode too.
> 2. **Write review notes** (template below) with a link to the notarized Mac download, the exact pairing steps, and a short screen recording of pairing on real hardware. Attach the recording in App Store Connect under App Review Information.

## Done on this branch

| Area | What | Where |
|---|---|---|
| Privacy manifests | `PrivacyInfo.xcprivacy` in each app and widget extension: no tracking, no tracking domains, no collected data. Required-reason API: UserDefaults (`CA92.1` own app, `1C8F.1` App Group). Checked against the Release binaries: of the required-reason APIs only `NSUserDefaults` is referenced (no file-timestamp, boot-time, disk-space or keyboard APIs). The Shared package is first-party code linked statically into each bundle, so the bundle's manifest covers it; it doesn't need its own. | `Levels-Mac/`, `Levels-iOS/`, `Widgets-Mac/`, `Widgets-iOS/` |
| Version | `MARKETING_VERSION = 1.0.0`, `CURRENT_PROJECT_VERSION = 1`, set only in `Config/Levels.xcconfig`, so apps and extensions always match (App Store Connect rejects a mismatch). Verified in the built Info.plists. | `Config/Levels.xcconfig` |
| Release build | Release: `-O`, `-Os`, whole module, dead-code stripping (was off for the Mac targets), `VALIDATE_PRODUCT`, symbols stripped, dSYMs on, no testability, no `DEBUG` condition. Debug is unchanged. | `Config/Levels.xcconfig` |
| Copyright | `NSHumanReadableCopyright` on every bundle (Finder's Get Info, the Mac About panel). Change the holder in `LEVELS_COPYRIGHT` if it should be a company. | `Config/Levels.xcconfig` |
| Export compliance | `ITSAppUsesNonExemptEncryption = NO` on both apps (see below). | `Config/Levels-iOS.xcconfig`, `Config/Levels-Mac.xcconfig` |
| Category | `LSApplicationCategoryType = public.app-category.utilities` on iOS (the Mac Info.plist already had it). The App Store category itself is chosen in App Store Connect. | `Config/Levels-iOS.xcconfig` |
| Debug-only code | The widget render gallery (sample entries with a personal device name) is now `#if DEBUG`, so it is not compiled into Release widgets. Other test hooks were already `#if DEBUG`: `LevelsOpenPairingAtLaunch` (Mac), the `snapshot.json` log dump (both apps), `ConnectMacFlowModel._receive` (iOS). SwiftUI `#Preview` blocks use only generic sample data. | `Shared/Sources/LevelsWidgetKit/WidgetRenderGallery.swift` |
| Mac notarization | `scripts/release-mac.sh`: archive, Developer ID export, signature checks (Developer ID, Hardened Runtime, no `get-task-allow`), notarize and staple the app, zip, DMG signed, notarized and stapled, Gatekeeper check. Stops at once with instructions when there is no Developer ID identity or notary profile. | `scripts/release-mac.sh` |
| iOS archive | `scripts/archive-ios.sh`: archive, checks that extension versions match and privacy manifests are present, export for App Store Connect (`.ipa`, or `--upload`). Stops at once when there is no Apple Distribution identity. | `scripts/archive-ios.sh` |
| Download checksum | `release-mac.sh` writes `SHA256SUMS.txt` for the download page (REL-001 R18). | `scripts/release-mac.sh` |
| Build proof | Release builds of Levels-Mac and Levels-iOS (generic device) succeed with the free team; `swift test` passes. | – |

REL-001 R1 items not on this branch: `Levels.storekit` (MON-001, another branch), legal drafts (in `docs/legal/`, owner review pending), screenshots.

Already in place before this branch, checked and kept:

- `NSLocalNetworkUsageDescription` and `NSBonjourServices` (`_levels._tcp`) on the iPhone app, its widget (it fetches from the Mac, decision 29) and the Mac app. The iPhone string differs from the REL-001 R6 draft and is kept on purpose: it also says the iPhone sends its own battery to the Mac, which is true, and App Review compares the string with what the app does.
- `NSBluetoothAlwaysUsageDescription` on the Mac (IOBluetooth). The iPhone uses no Bluetooth API, so it has no Bluetooth string.
- Hardened Runtime on both Mac targets; `CFBundleDisplayName`; app icons.
- Notifications need no Info.plist key on either platform (the permission prompt comes from `requestAuthorization`).

### Export compliance: why "No" is the right answer

Levels uses encryption only through Apple's operating system:

- TLS 1.3 with a pre-shared key, via Network.framework, between the iPhone and the owner's Mac.
- CryptoKit X25519 key agreement, HKDF and SHA-256 to derive that key during pairing.
- The Keychain to store it.

There is no custom or proprietary cipher and no third-party crypto library. The encryption authenticates the owner's own devices and protects the link between them. Encryption that is built into the OS and used this way is exempt from U.S. export documentation, and Apple's guidance for apps that only call the OS's crypto is to set `ITSAppUsesNonExemptEncryption = NO`. CryptoKit is part of the OS, so using it doesn't change the answer. Revisit this if the app ever adds its own crypto code or a non-Apple crypto library. (Selling in France still needs no separate declaration for this use.)

### Mac entitlements audit

| Entitlement | Levels-Mac | Widgets-Mac | Note |
|---|---|---|---|
| App Sandbox | off | on | Off by design: the AirPods reader runs `system_profiler`, which returns nothing inside the sandbox. This rules out the Mac App Store; Developer ID is fine. |
| Hardened Runtime | on, no exceptions | on | Required for notarization. |
| `network.client` | yes | no | No effect outside the sandbox; harmless. The hub listens without `network.server` because the app isn't sandboxed. |
| App Group `<TEAMID>.<rdns>.levels` | yes | yes | Team-prefixed, so no registration needed. |
| `keychain-access-groups` | yes | yes | Needs a provisioning profile; Xcode's automatic signing makes a Developer ID profile on export. |
| `get-task-allow` | Debug signing only | same | Development signing adds it; the Developer ID export removes it. `release-mac.sh` fails if it survives. |

## Needs the paid Apple Developer Program

Do these in order after enrolling.

### Accounts and signing

- [ ] Enroll in the Apple Developer Program. Set `DEVELOPMENT_TEAM` in `Config/Levels.xcconfig` to the paid Team ID.
- [ ] Check the bundle IDs `com.tmatiashvili.levels` and `com.tmatiashvili.levels.widgets` register under the paid team. If Xcode says they are taken (the free Personal Team registered them), change `LEVELS_RDNS` before anything ships; once the app is on sale the bundle ID can't change.
- [ ] Register the App Group `group.<rdns>.levels` (iOS) in the paid team.
- [ ] If v1.0 includes iCloud sync or push: put the iCloud and push entitlements back (SETUP.md, "Paid team" block) and check the exported entitlements show `production`. If v1.0 is local-network only, leave them out.
- [ ] Create certificates: Developer ID Application (Mac) and Apple Distribution (iOS), or use cloud signing (`archive-ios.sh --cloud-signing`).
- [ ] `xcrun notarytool store-credentials levels-notary --apple-id <id> --team-id <TEAMID> --password <app-specific password>`.

### Mac download

- [ ] `scripts/release-mac.sh --notary-profile levels-notary`. Install the DMG on a second Mac that has never run Levels; check there is no Gatekeeper warning, the menu-bar item appears, the widget appears in the gallery, AirPods show up, and an iPhone pairs.
- [ ] Host the DMG on HTTPS (our site). App Review needs this link.
- [ ] Decide how Mac updates reach users (REL-001 open question 1; the lead recommends a small own version check, since Sparkle is third-party code). Without one, every user stays on 1.0.0.

### App Store Connect (iPhone)

- [ ] Create the app record: name, primary language, bundle ID, SKU. Category: Utilities.
- [ ] In-app purchase products, if the paywall ships in 1.0. Their IDs must match the StoreKit configuration file and be submitted with the first build.
- [ ] App Privacy ("nutrition label"): **Data Not Collected**. This matches the privacy manifests. Battery readings go only between the owner's devices; we run no server.
- [ ] Privacy policy URL (required even when no data is collected) and support URL.
- [ ] Age rating questionnaire (no objectionable content, so 4+).
- [ ] Export compliance: answered by `ITSAppUsesNonExemptEncryption = NO`; App Store Connect won't ask.
- [ ] Screenshots: 6.9" iPhone at least (1320 × 2868), one set. Use realistic data: Mac, AirPods, Watch, this iPhone, plus a home-screen widget. If demo mode exists, take them from it so the store matches what a reviewer sees.
- [ ] Description, keywords, promotional text, "What's New".
- [ ] `scripts/archive-ios.sh --build-number 1 --upload`, then test with TestFlight on a real iPhone paired to the notarized Mac build.
- [ ] App Review Information: contact, notes (below), the pairing recording. No sign-in, so no demo account.

### App Review notes (template)

> Levels shows the battery levels of your own Apple devices in one place. The iPhone app shows this iPhone's battery right away. To see a Mac's battery and the AirPods connected to it, the iPhone pairs with the free Levels app for Mac, which is distributed outside the Mac App Store because it reads accessory batteries with a system tool the sandbox does not allow.
>
> To test without a Mac: tap **Try with sample devices** on the "Connect to your Mac" card. *(Only if demo mode is built.)*
>
> To test with a Mac (macOS 26 or later, same Wi-Fi as the iPhone, a network that allows Bonjour/mDNS; a phone hotspot works):
> 1. Download Levels for Mac from <URL> and open it. Its icon appears in the menu bar.
> 2. On the iPhone, open Levels, tap **Connect**, tap **Continue** and allow Local Network access.
> 3. On the Mac, click the menu-bar icon, then ⋯ > Settings… > iPhone > **Pair iPhone…**. A 6-digit code appears.
> 4. On the iPhone, pick the Mac, type the code and tap **Connect**. Both screens show the same number; tap **They match** on the iPhone and click **They match** on the Mac.
> 5. The Mac and any AirPods connected to it appear in the list and in the Levels widget.
>
> Local Network access is used only to find and talk to the user's own Mac. The link is TLS-encrypted with a key made during pairing. No data leaves the user's devices; there is no account and no server. A screen recording of these steps is attached.

Steps checked against the UI on 2026-11-24; check them again if the pairing screens change.

## Other launch risks and open items

- **iPad.** The app is iPhone only (`TARGETED_DEVICE_FAMILY = 1`), but iPhone apps also run on iPad, and App Review sometimes tests there. Check the iPhone layout in the iPad compatibility window, portrait and landscape.
- **Local Network permission.** Reviewers often tap "Don't Allow". The pairing flow then says Local Network access is off and offers Open Settings; check this on a fresh install, and check the Mac's own Local Network prompt (macOS 15+) on a Mac that has never run Levels.
- **Background refresh claims.** `UIBackgroundModes` has `fetch`. Don't describe "always up to date" in the store text; iOS decides when the app runs (the app already says so and points to Shortcuts automations).
- **Mac download link in the iPhone app.** The Mac app is free (decision 32), so linking to it is allowed, but the link and the download page must never mention Pro or prices (REL-001 R13, guideline 3.1.1).
- **Accessibility** (quick pass 2026-11-24). Rings are hidden from VoiceOver and each row reads as one element ("name, level, charging, age"); icon-only buttons (Mac refresh and ⋯, iOS Settings) have labels; rows stack at accessibility text sizes and the level never truncates. Not yet done: a full VoiceOver walk through pairing on a device, the history chart's audio graph or summary, and the Mac widget at large text.
- **Warnings in Release.** Two Swift warnings remain in shared code (a `self` capture in `LevelsNet/HubListener.swift`, an unused result in `LevelsReaders/AccessoryReporter.swift`). Not crashes; worth clearing before 1.0.
- **Crash audit** (2026-11-24). No `fatalError` or `try!` in app code. The force unwraps are on constant literals (UUIDs, `levels://` URLs, the Settings URL, a TLS cipher-suite constant). The `precondition`s guard programmer errors only; data from the network or CloudKit is validated before it reaches them (`hasConsistentAccessory`).
