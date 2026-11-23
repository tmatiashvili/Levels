# ADR-0003: One checked-in Xcode project plus a local Swift package split into modules

- **Status:** Proposed
- **Date:** 2026-11-23
- **Deciders:** project owner
- **Related:** ADR-0002, ADR-0004…0009 (sync), ADR-0010…0012 (reporting), ADR-0013…0015 (Mac agent), ADR-0016, ADR-0017, SYNC-002

## Context

Levels has four apps' worth of platforms (iPhone + iPad, Mac, Watch) and three widget extensions. Facts that shape the structure:

- watchOS complications are WidgetKit widgets in a **watchOS widget extension** embedded in the watch app. Apple's setup steps are "add a new watchOS widget extension target" next to the iOS widget extension ([Creating accessory widgets and watch complications](https://developer.apple.com/documentation/widgetkit/creating-accessory-widgets-and-watch-complications)). The same extension also feeds the Smart Stack. So the README's `Complications/` folder is really the watch widget extension; this ADR renames it `Widgets-Watch/`.
- Widget extensions have tight memory limits and must render from a local cache (SYNC-002), so they should not link CloudKit code or battery readers they don't use. **Assumption:** the widget extension memory limit is about 30 MB; it has not been checked for the 26 releases.
- App Group identifiers use the form `group.<group name>` on all platforms. On macOS the form `<team identifier>.<group name>` also exists and needs no registration ([App Groups entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups)). A `group.` identifier registered on the developer site works on all four platforms, but on macOS 15 and later it avoids the container prompt only if the embedded provisioning profile authorises it (possible since February 2025); the Team ID–prefixed form always avoids it (ADR-0009).
- A companion watch app's bundle ID must start with the iOS app's bundle ID. **Assumption:** still true for watchOS 26 apps that have an iOS companion.
- Universal purchase (one App Store listing for iOS and Mac) needs the iOS and Mac apps to share one bundle ID. **Assumption:** checked against memory of App Store Connect help, not re-verified today.
- Since Xcode 16, folders in an Xcode project can be "synchronized folders": files added on disk join the target without editing `project.pbxproj`. That removes most of the merge pain that made generators like XcodeGen and Tuist popular. **Assumption:** verified from memory of Xcode 16 release notes only.

## Decision

1. **One Xcode project, `Levels.xcodeproj`, checked in**, using synchronized folders. No project generator.
2. **One local Swift package, `Shared/`, holding all code that isn't a target's entry point.** Targets stay thin: `@main`, `WidgetBundle`, entitlements, Info.plist, asset catalogs.
3. **The package splits into five library products:**

   | Module | Contains | Depends on | Linked by |
   |---|---|---|---|
   | `LevelsModel` | `DeviceBattery` value types and the App Group snapshot cache `SnapshotCache` reader/writer (both defined by SYNC-002), staleness rules `FreshnessRule` (ADR-0017, SYNC-002), sorting, display preferences (hidden devices, this device's name), and the Foundation-only sync seam `BatterySyncing` with `ReportReason`, `ReportOutcome` and `SyncStatus` (SYNC-001). Foundation only. | — | everything |
   | `LevelsSync` | CloudKit sync: `BatterySyncService`, `CloudDatabase`, `WritePolicy` (SYNC-001, ADR-0004…0009) and the `CKRecord` mapping `DeviceBatteryRecord` (SYNC-002) | `LevelsModel` | apps |
   | `LevelsReaders` | `BatteryReader`, `BatteryReading`, `FixedBatteryReader` (ADR-0010), `BatteryReporter` and `ReportLog` (RPT-001…004). Talks to sync only through `BatterySyncing`. Platform readers that need UIKit/WatchKit/IOKit live in the app targets (ADR-0010). | `LevelsModel` | apps (and the Mac agent per MAC-001) |
   | `LevelsUI` | shared SwiftUI views and the `@Observable` store (ADR-0016, UI-001) | `LevelsModel` | apps, widget extensions |
   | `LevelsWidgetKit` | timeline provider, device `AppEntity`, widget configuration intent, widget views per family (UI-003/004/006) | `LevelsModel`, `LevelsUI` | widget extensions, apps (for `WidgetCenter` reload calls and the shared entity) |

   Rule: widget extensions never link `LevelsSync` or `LevelsReaders`. `LevelsUI` never imports CloudKit; it gets data through a protocol (UI-001). This constrains SYNC-002: the snapshot cache type must live in `LevelsModel` (Foundation only) so widgets can read it.
4. **Targets and folders** (replaces the README "Project structure" tree):

   ```
   Levels/
   ├── Levels.xcodeproj
   ├── Shared/                 # Swift package: LevelsModel, LevelsSync, LevelsReaders, LevelsUI, LevelsWidgetKit (+ Tests/)
   ├── Levels-iOS/             # iPhone + iPad universal app (App Intents incl. "Report Battery", RPT-002)
   ├── Levels-Mac/             # menu-bar agent (MAC-001…003)
   ├── Levels-Watch/           # watchOS app (companion of Levels-iOS, runs on its own)
   ├── Widgets-iOS/            # iOS/iPadOS widget extension: Home Screen, Lock Screen, StandBy
   ├── Widgets-Mac/            # macOS widget extension: desktop and Notification Center
   └── Widgets-Watch/          # watchOS widget extension: complications + Smart Stack (was "Complications/")
   ```

5. **Identifiers** (`<rdns>` is the owner's reverse-DNS prefix, e.g. `com.example`; `<TEAMID>` is the Team ID):

   | Thing | Identifier |
   |---|---|
   | iOS/iPadOS app | `<rdns>.levels` |
   | iOS widget extension | `<rdns>.levels.widgets` |
   | Watch app | `<rdns>.levels.watchkitapp` |
   | Watch widget extension | `<rdns>.levels.watchkitapp.widgets` |
   | Mac app | `<rdns>.levels` (same as iOS, keeps universal purchase possible) |
   | Mac widget extension | `<rdns>.levels.widgets` (**Assumption:** extensions may share an ID across platforms like their apps) |
   | App Group, iOS/iPadOS app, iOS widget extension, watch app, watch widget extension | `group.<rdns>.levels` |
   | App Group, Mac app and Mac widget extension | `<TEAMID>.<rdns>.levels` (lead's call 2026-11-23: Team ID–prefixed form, no profile dependency for the group, ADR-0009, ADR-0013) |
   | iCloud container (apps only; widgets don't need it) | `iCloud.<rdns>.levels` |
   | URL scheme (widget deep links) | `levels://` |

   If the shared Mac/iOS bundle ID causes a signing or provisioning problem, the fallback is `<rdns>.levels.mac` and giving up universal purchase; record that in a new ADR.
6. **Signing:** Xcode automatic signing, one paid team, `DEVELOPMENT_TEAM` and `<rdns>` set once in a checked-in `Config/Levels.xcconfig` that every target includes. Entitlements files are checked in. The Mac app is sandboxed unless ADR-0013…0015 say otherwise.
7. **Tests:** Swift Testing targets inside the package (`LevelsModelTests`, `LevelsUITests`, `LevelsWidgetKitTests`, plus what sync/reporting own). They run with `swift test` where they don't need UIKit, and from the Xcode scheme `Levels-All` otherwise.

## Options considered

### Option A — one Xcode project + local Swift package, split into modules (chosen)
- Pros: no extra tool; Xcode-native previews and signing; module boundaries enforce "widgets don't link CloudKit"; logic tests run fast with no simulator.
- Cons: the project file is still checked in; a few target settings repeat across seven targets.

### Option B — XcodeGen or Tuist generating the project
- Pros: project defined in text; no `pbxproj` conflicts.
- Cons: an extra tool and its version to keep working for a one-person project; synchronized folders already remove most conflicts; generated projects drift from Xcode features.

### Option C — Swift Package–first with one `Shared` module
- Pros: simplest package.
- Cons: widget extensions would link CloudKit and IOKit code; no compiler check on layering; slower incremental builds.

## Consequences

- Positive: clear ownership per module matches the ADR areas; widget binaries stay small; most logic is testable without a device.
- Negative / accepted risks: five modules is more ceremony than one; cross-module `public` APIs must be designed.
- Follow-ups: update the README "Project structure" tree and the "watchOS: app and complications" line to match this ADR (this ADR is the source of truth until then). Owner decision (2026-11-23): bundle IDs and the Team ID stay placeholders (`<rdns>`, `<TEAMID>`) in these docs; the owner fills them in when the Xcode project is created.

## References

- [Creating accessory widgets and watch complications](https://developer.apple.com/documentation/widgetkit/creating-accessory-widgets-and-watch-complications)
- [App Groups entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups)
- [Register an app group](https://developer.apple.com/help/account/manage-identifiers/register-an-app-group)
- [WWDC22 — Complications and widgets: Reloaded](https://developer.apple.com/videos/play/wwdc2022/10050)
