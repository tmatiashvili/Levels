---
id: RPT-004
title: Apple Watch battery reporting
milestone: v0.2
status: Draft
depends_on: [RPT-001, SYNC-001, SYNC-002]
adrs: [4, 6, 8, 9, 10, 12]
targets: [Shared, Levels-Watch, Widgets-Watch]
---

# RPT-004: Apple Watch battery reporting

## Why

The iPhone's own Batteries widget shows the watch, but the Mac and iPad never do. The watch app writes its own battery to iCloud so every device can show it. The watch has no Shortcuts automations, so it reports whenever watchOS lets it run.

## Scope

- In: `WatchBatteryReader`; reuse of `BatteryReporter` (RPT-001) on watchOS; triggers app active, background refresh and silent-push piggyback; watch Info.plist and capabilities; complication guidance.
- Out (and where it goes instead): CloudKit writes, throttling, push subscription → SYNC-001, ADR-0006, ADR-0008. Complication UI → UI-*. WatchConnectivity → not used (ADR-0012).

## Behaviour

- **R1** The watch app turns on `WKInterfaceDevice.current().isBatteryMonitoringEnabled` at launch, before any read, and never turns it off.
- **R2** Level conversion, unknown handling and state mapping are the same as RPT-001 R2–R3 (`WKInterfaceDeviceBatteryState` → `PowerState`).
- **R3** The watch reports on launch and every time the app's `scenePhase` becomes `.active`.
- **R4** The watch has no battery-change events (ADR-0010). While the app stays active, it does **not** poll. One report per activation is enough.
- **R5** After every report and every time the app goes to background, the app schedules a background refresh 30 minutes ahead with `WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate:userInfo:)`. Only one is pending at a time.
- **R6** When the refresh runs (SwiftUI `.backgroundTask(.appRefresh)`), the app reports, schedules the next refresh (R5), and returns. If the task is cancelled, it stops and still schedules the next one.
- **R7** When a silent push arrives (ADR-0006), the watch lets SYNC handle it (SYNC-001 R12, no own reading), then reports itself with reason `.pushWake`, then completes within 25 seconds.
- **R8** The complication (widget extension) never reads the battery and never writes to CloudKit. It renders from the App Group cache (ADR-0009).
- **R9** Reports go straight to CloudKit through `BatterySyncService` (SYNC-001). No WatchConnectivity.
- **R10** The device `kind` is `.watch`; the default name is "Apple Watch" (SYNC-002 R17).
- **R11** Report reasons and `rpt.lastReport` work as in RPT-001 (R10), using the watch's own App Group.

## Design

- **Shared:** reuse `BatteryReading`, `BatteryReader` (ADR-0010), `BatteryReporter`, `ReportLog` (RPT-001) and `ReportReason`, `BatterySyncing` (SYNC-001). They must compile for watchOS (no UIKit imports in Shared). `BatteryReporter` is created with `kind: .watch`.
- **Levels-Watch:**

```swift
@MainActor
final class WatchBatteryReader: BatteryReader {
    init()                                   // sets isBatteryMonitoringEnabled = true
    func read() async -> BatteryReading      // WKInterfaceDevice + ProcessInfo
    func changes() -> AsyncStream<BatteryReading>  // only NSProcessInfoPowerStateDidChange
}
```

- App wiring in the watch `App`:
  - `.onChange(of: scenePhase)`: `.active` → R3; `.background` → R5.
  - `.backgroundTask(.appRefresh) { _ in await refresh() }` → R6.
  - `WKApplicationDelegateAdaptor` remote-notification method (owned by SYNC) adds `try? await reporter.reportNow(reason: .pushWake)` → R7.
- **Info.plist / capabilities (Levels-Watch):** Background Modes → Remote notifications (`UIBackgroundModes: [remote-notification]`, may already be set by SYNC); iCloud/CloudKit, Push, App Groups per SYNC and ADR-0009. **Assumption:** on a single-target watchOS 26 app the key is `UIBackgroundModes`, not `WKBackgroundModes`; check Xcode's capability editor.
- **Complication placement:** owner decision (2026-11-23): the owner keeps a Levels complication on the daily watch face; this is the operating assumption for R5–R6 and AC7. The in-app watch settings screen still says: "For fresher watch battery, add a Levels complication to the face you wear." The background budget depends on it ([WKApplicationRefreshBackgroundTask](https://developer.apple.com/documentation/watchkit/wkapplicationrefreshbackgroundtask)).
- **Concurrency:** Swift 6 strict; `BatteryReporter` is an actor; `WatchBatteryReader` hops to the main actor.

## Edge cases and failure modes

- **No complication on the active face:** background refresh is rare or never. Freshness comes from opening the app and pushes. Expected (ADR-0012).
- **Watch away from iPhone, no Wi-Fi, no cellular:** SYNC fails or queues; next trigger retries.
- **Watch in Low Power Mode:** **Assumption:** background refresh and pushes mostly stop. The reading carries `isLowPowerMode` when it does send.
- **Watch on its charger:** state `.charging` / `.full`; reports when the app wakes. A watch charging overnight with no complication may show a stale "on power" record; acceptable.
- **Simulator:** battery unknown (**Assumption:** same as iOS Simulator); R2 drops it. Silent push not delivered on watch Simulator ([forum 826180](https://developer.apple.com/forums/thread/826180), anecdotal).
- **Silent push unreliable on watchOS:** reported on forums ([forum 126286](https://developer.apple.com/forums/thread/126286)). R7 is a bonus, never relied on.

## Acceptance criteria

- [ ] AC1 — Given `WatchBatteryReader` with raw −1.0 and `.unknown`, when `reportNow` runs, then sync is not called.
- [ ] AC2 — Given a `FixedBatteryReader` returning 0.42 unplugged, when `reportNow(.foreground)` runs on watchOS, then sync receives level 42, `isCharging == false`, `isPluggedIn == false`, kind `.watch`.
- [ ] AC3 — Given the app moves to background, then a background refresh is scheduled for about 30 minutes ahead (the scheduling call is made once, through an injectable scheduler).
- [ ] AC4 — Given the refresh handler runs and `reportNow` throws, then the next refresh is still scheduled.
- [ ] AC5 — Given the complication target, then it has no reference to `WKInterfaceDevice` battery APIs or `BatterySyncService.report` (checked by a build-time grep test or code review).
- [ ] AC6 — Given a real watch, when the Levels app opens, then within 60 s the Mac or iPhone shows the watch level within 5% of the watch's Control Center value.
- [ ] AC7 — Given a real watch with a Levels complication on the active face and the app not opened, when 2 hours pass, then the watch record's `updatedAt` has advanced at least once.
- [ ] AC8 — Given a real watch away from the iPhone on known Wi-Fi, when the app opens, then the record still updates.

## Tests

- **Unit (Swift Testing, watchOS Simulator OK):** AC1–AC4 with fakes for reader, sync, clock and refresh scheduler.
- **Static check:** AC5.
- **Real hardware only:** AC6–AC8. The watch Simulator has no real battery and its background budget isn't realistic. AC7 depends on the system budget, so a failure means "investigate", not "broken"; log refresh runs with `os.Logger` to see them.

## Open questions

- None. Owner decision (2026-11-23): yes, a Levels complication stays on the daily watch face.
