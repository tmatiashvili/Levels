---
id: DEMO-001
title: Try with sample devices (demo mode)
milestone: free-team   # needed before the first App Store submission (REL-001 R12)
status: Ready
depends_on: [NET-004, UI-002, UI-003, MON-001, MON-002]
adrs: [3, 9, 17, 20, 21]
targets: [Shared, Levels-iOS, Widgets-iOS]
---

# DEMO-001: Try with sample devices (demo mode)

## Why

Levels for iPhone shows the battery of a Mac and the AirPods connected to it. That needs a Mac running the Levels Mac app, paired on the same Wi-Fi. App Review usually tests on an iPhone alone, so it sees one row and a "Connect to your Mac" card, and may reject the app under guideline 2.1 or 4.2 ([release checklist](../release-checklist.md), "Biggest App Review risk"). Curious people who install the app before they have the Mac app have the same problem. Demo mode lets anyone see the app working with sample devices, without a Mac (lead's call 36).

## Scope

- In: the "Try with sample devices" entry points; the sample data; the "Sample devices" banner and Exit; how demo mode swaps the iPhone's sync and list; the iPhone widget while demo mode is on; Levels Pro gating in demo mode; the review notes.
- Out (and where it goes instead): the paywall and the gate themselves → MON-001, MON-002 (demo mode only uses them); the Mac app has no demo mode (it reads its own battery); the App Store screenshots → REL-001 R11 (they may be taken in demo mode).

## Behaviour

- **R1** **Entry points.** A **Try with sample devices** button appears in two places: on the "Connect to your Mac" card of the first-run (not paired) state (NET-004 R1), and on the Connect screen (NET-004 R2, R3), under **Continue** and at the bottom of the Mac picker. It is a button, not a launch argument: App Review can't pass arguments. Tapping it closes the Connect screen and shows the sample list at once.
- **R2** **Sample data.** Demo mode shows a fixed set, with generic names only (never the owner's or the reviewer's names):

  | Device | Level | State | Age |
  |---|---|---|---|
  | iPhone (this iPhone) | 62% | charging | 1 min |
  | MacBook Pro | 54% | on battery | 2 min |
  | AirPods Pro, left / right / case | 40% / 35% / 80% | case charging | 4 min |
  | Apple Watch | 71% | Low Power Mode | 3 h (stale) |
  | iPad | 12% (low) | on battery | 9 min |

  The AirPods belong to the MacBook Pro (one grouped row, owner decision E). Ages are measured from "now" every time the list reads the data, so they always look live: "1 min ago", never "3 days ago". The Watch stays stale and the iPad stays low, so the reviewer sees those states too.
- **R3** **Banner.** While demo mode is on, a bar at the bottom of every iPhone screen says "Sample devices" and "These aren't your devices." with an **Exit** button. It stays on the list and on the detail screens. Settings shows a "Sample devices" section with the same **Exit**.
- **R4** **Detail screens** open for every sample row and show the same content as for a real device (UI-002 R4–R7). Rename and Hide work, but only in memory: they never change the real display preferences.
- **R5** **Never touches real data.** Demo mode never writes the App Group snapshot cache, never changes the real display preferences, never deletes or changes the Mac pairing in the Keychain, never contacts the network (no Bonjour browse, no fetch, no long-poll, no post to the Mac) and never pairs. "Remove all my data" in demo mode does nothing and says "Exit sample devices first."
- **R6** **This iPhone's reports** while demo mode is on go to the demo sync service, which drops them. The real Mac doesn't get this iPhone's battery until demo mode ends; then the app reports once and refreshes from the Mac.
- **R7** **Survives relaunch.** The on/off flag lives in App Group `UserDefaults` (`demoMode.isOn`), so the app opens in demo mode after a relaunch and the widget can read it.
- **R8** **Exit** turns the flag off, drops the sample list, returns to the real list with the real pairing as it was, reports this iPhone's battery, refreshes from the Mac (if paired) and reloads widget timelines. Pairing a real Mac while demo mode is on ends demo mode the same way.
- **R9** **Levels Pro applies normally.** The gate (MON-001 R19, R20) filters the sample list exactly like a real one; in demo mode the sample MacBook Pro is the free Mac. A free user sees this iPhone and the MacBook Pro as normal rows and the rest as the locked card (MON-002 R7), and can open the paywall and buy. A Pro user sees everything. Demo mode never grants or fakes Pro.
- **R10** **Widgets.** While the flag is on, the iPhone widget shows the sample data instead of the cache, with fresh ages, and never fetches from the Mac (NET-004 R14 variant B is skipped). Medium and large show a "Sample devices" footer. Widget families are gated by Levels Pro as usual (MON-001 R14–R17). Entering and leaving demo mode reload all timelines; after Exit the widget shows the real cache again.
- **R11** **Review notes** tell App Review where the button is (release checklist template).

## Design

Shared:

- `LevelsModel/DemoMode.swift`
  - `DemoModeSetting` (`Sendable`): `isOn`, `setOn(_:)`, key `demoMode.isOn`, App Group suite or in memory (same shape as `ReportingSetting`).
  - `SampleDevices`: fixed IDs (`iPhoneID`, `macID`, `watchID`, `iPadID`, `airPodsGroup`) and `snapshot(now:) -> SnapshotFile` (R2), `isSample(_ file:)`. `syncStatus` is `.localOnly`, so no hub banner shows.
- `LevelsSync/DemoSyncService.swift`
  - `DemoSyncService: BatterySyncing`: `report` drops the readings (`.skipped`), `status` is `.localOnly`, `refresh` returns `true`. It holds no cache and no transport.
  - `DemoAwareSync: BatterySyncing`: wraps the real sync; while `DemoModeSetting.isOn` every call goes to the `DemoSyncService`, otherwise to the real one. The app puts it between the reporter and the hub (`LocalNetworkSyncService`), so the reporter and the list source don't change (R6).
- `LevelsUI/Store/DemoSnapshotSource.swift`: a `DeviceSnapshotSource` over `SampleDevices.snapshot(now:)`, read fresh on every `current()` (R2 ages). Rename is kept in memory; `remove` and `removeAllData` throw `DemoSnapshotSource.DemoError.notInDemo` ("Exit sample devices first."). The demo `DeviceListStore` uses an `InMemoryDisplayPreferencesStore` (R4, R5).
- `LevelsUI/Views/SampleDevicesBanner.swift`: the R3 bar.
- `LevelsWidgetKit`: `DevicesProvider` reads the flag first; when on it uses the sample snapshot and default display preferences, skips the fetch, and returns one entry with a reload after 30 minutes so ages stay fresh (R10). `DeviceEntry.isSample` drives the footer.

Levels-iOS:

- `AppModel` keeps the real store (`realStore`) and, while demo mode is on, a demo store; `store` returns the one on screen, so the screens and the root `.environment` follow it. Hub calls that reach the network (`refresh`, `startLiveUpdates`, the path monitor, background refresh) are skipped while demo mode is on. `enterDemo()` and `exitDemo()` live in `Demo/AppModel+Demo.swift`.
- **Levels Pro hook:** `AppModel.configureStore(_:isDemo:)` is called for the real store and for every demo store. When the Pro work sets `store.gate`, it sets it there, with `freeMacID: SampleDevices.macID` for the demo store (R9). The widget's gate does the same when `DemoModeSetting.isOn`.

**Builder's call:** the sample iPhone is a fixed row, not this iPhone's real reading. The widget can't see the app's memory, and a fixed row keeps the app and the widget the same.

**Builder's call:** the banner sits at the bottom of the `NavigationStack`, so it stays visible on detail screens without covering the navigation bar.

## Edge cases and failure modes

- Demo mode on at launch: the app starts with the demo list, still starts the reporter (its reports are dropped, R6) and does not refresh from the Mac.
- Demo mode entered while paired: the long-poll stops; the pairing and the cache stay as they are.
- A widget deep link to a sample device after Exit: the ID is unknown, so the app shows the list (UI-002 edge case).
- No App Group: the flag falls back to the app's own defaults; the widget then can't see it and shows the cache.
- Pairing from Settings while in demo mode: demo mode ends when pairing succeeds (R8).

## Acceptance criteria

- [ ] AC1 — Given demo mode off and not paired, when the user taps **Try with sample devices** on the Connect card or the Connect screen, then the list shows the R2 devices and the banner (R1–R3).
- [ ] AC2 — Given `SampleDevices.snapshot(now:)` at two different times, then every age is the same and the names are the generic ones in R2; the Watch is stale, the iPad is low, the AirPods are one grouped row of three records under the MacBook Pro (R2).
- [ ] AC3 — Given demo mode on, when the reporter reports, the list refreshes, a row is renamed or hidden, then the real cache file and the real display preferences are unchanged and the real sync gets no call (R5, R6).
- [ ] AC4 — Given demo mode on, when the user taps Exit, then the flag is off, the real sync gets calls again and the real cache and pairing are as before (R8).
- [ ] AC5 — Given the flag set in App Group defaults, when a new `DemoModeSetting` reads it, then it is on (R7).
- [ ] AC6 — Given demo mode on and a free gate with the sample Mac as free Mac, then the list shows this iPhone and the MacBook Pro and counts the rest as locked (R9). Pending the Pro merge.
- [ ] AC7 — Given the flag on, then the widget's entry holds the sample snapshot, never fetches, and medium and large show the footer; given it off, the cache (R10).
- [ ] AC8 — Manual, iPhone with no Mac: install, tap Try with sample devices, open each detail, add the widget, open the paywall from the locked card, Exit; the list is back to the real state.

## Tests

AC2–AC5 and AC7 are unit tests in Shared (Swift Testing): `DemoModeTests` (LevelsModelTests), `DemoSyncTests` (LevelsSyncTests, with a real `SnapshotCache` in a temp folder and a recording real sync), `DemoSnapshotSourceTests` (LevelsUITests) and `DemoWidgetTests` (LevelsWidgetKitTests). AC6 joins `ProGateTests` once the gate is on integration. AC1 and AC8 are manual: the buttons and the banner are app UI. Render previews (`ImageRenderer`) of the list and the widget in demo mode are written by the opt-in snapshot harnesses (`LEVELS_APP_SNAPSHOTS`, `LEVELS_WIDGET_SNAPSHOTS`).

## Open questions

None for the owner. Demo mode is a lead's call (36) because the release checklist and REL-001 flagged it as needed before the first submission.
