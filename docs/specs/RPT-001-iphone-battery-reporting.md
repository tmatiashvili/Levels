---
id: RPT-001
title: iPhone battery reporting
milestone: v0.1
status: Draft
depends_on: [SYNC-001, SYNC-002, UI-001]
adrs: [6, 8, 9, 10, 11]
targets: [Shared, Levels-iOS]
---

# RPT-001: iPhone battery reporting

## Why

Other devices can only show the iPhone's battery if the iPhone writes it to iCloud. iOS suspends the app most of the time, so the iPhone must report at every chance it gets: when opened, when Shortcuts runs the intent, when the system grants background time, and when a push wakes it.

## Scope

- In: the `BatteryReader` protocol and `BatteryReading` type in Shared; `UIDeviceBatteryReader`; `FixedBatteryReader` for tests; `BatteryReporter` that turns a reading into a `DeviceBattery` (SYNC-002) and calls `BatterySyncService.report(_:reason:)` (SYNC-001); the triggers foreground, in-process change events, `BGAppRefreshTask` and silent-push piggyback; Info.plist and capabilities for these.
- Out (and where it goes instead): the App Intent and Shortcuts setup → RPT-002. iPad deltas → RPT-003. Watch → RPT-004. Mac reader → MAC-*. CloudKit writes, write throttling, the push subscription and its handler, the App Group snapshot cache → SYNC-001, ADR-0006, ADR-0008, ADR-0009. Widgets → UI-*.

## Behaviour

- **R1** The app turns on `UIDevice.isBatteryMonitoringEnabled` once at launch, before any read, and never turns it off.
- **R2** A reading converts the raw level as `Int((raw * 100).rounded())`, clamped to 0...100. A raw value below 0 gives `level == nil`. `UIDevice.BatteryState` maps to `PowerState` one to one (`.unknown`, `.unplugged`, `.charging`, `.full`; iOS never gives `.pluggedIn`). `isLowPowerMode` comes from `ProcessInfo`. The reading becomes a `DeviceBattery` with the charging flags of SYNC-002 R16 (`.charging` and `.full` → `isCharging = true, isPluggedIn = true`) and the name of SYNC-002 R17.
- **R3** A reading with `level == nil` and `powerState == .unknown` is never sent to SYNC. The reporter logs it and stops. (This is what the Simulator returns.)
- **R4** The app reports on launch and every time the scene becomes `.active`.
- **R5** While the app runs (foreground or background time), every event from `reader.changes()` triggers a report: reason `.chargerChange` when `powerState` differs from the previous reading, otherwise `.batteryChange` (level or Low Power Mode change).
- **R6** Every time the scene goes to `.background`, the app submits a `BGAppRefreshTaskRequest` for identifier `<bundle id>.battery-refresh` with `earliestBeginDate` 30 minutes ahead. Submitting again replaces the pending request.
- **R7** When the refresh task runs, the app reports, then submits the next request (R6), then completes the task. If the system expires the task first, the in-flight report is cancelled and the task completes as failed.
- **R8** When a silent push arrives (ADR-0006), the app lets SYNC handle it first (`handleRemoteNotification`, which takes no own reading, SYNC-001 R12), then reports its own battery with reason `.pushWake`, then calls the completion handler. The whole handler finishes within 25 seconds.
- **R9** The reporter does no throttling or dedup of its own beyond R3. It hands every reading to `BatterySyncService.report(_:reason:)` through `BatterySyncing` (SYNC-001). ADR-0008 decides whether and when to write; reasons `.launch`, `.appIntent`, `.chargerChange` and `.userRefresh` are urgent (SYNC-001 R5a, ADR-0008 W9). Loop safety for R8 depends on that rule skipping unchanged snapshots.
- **R10** Each successful hand-off records `lastReport[reason] = now` in App Group `UserDefaults` under the key `rpt.lastReport` (a separate key, not the ADR-0009 cache). RPT-002 reads it.
- **R11** `report` errors are logged with `os.Logger` (subsystem = bundle id, category `reporting`) and never shown to the user from this feature. The next trigger tries again.

## Design

**Shared (module `LevelsReaders`, ADR-0003). `BatteryReading` and `BatteryReader` are ADR-0010's, repeated here for convenience; `ReportReason`, `BatterySyncing`, `DeviceBattery` and `DisplayPreferencesStore` come from `LevelsModel` (SYNC-001, SYNC-002, UI-001):**

```swift
public struct BatteryReading: Sendable, Equatable {
    public enum PowerState: Sendable, Equatable { case unknown, unplugged, charging, full, pluggedIn }  // ADR-0010
    public var level: Int?
    public var powerState: PowerState
    public var isLowPowerMode: Bool
    public var readAt: Date
}

public protocol BatteryReader: Sendable {
    func read() async -> BatteryReading
    func changes() -> AsyncStream<BatteryReading>
}

// ReportReason is SYNC-001's (launch, foreground, batteryChange, chargerChange, backgroundRefresh, pushWake, appIntent, sleep, wake, heartbeat, userRefresh).

public enum ReportError: Error, Sendable { case iCloudUnavailable, syncFailed }

public actor BatteryReporter {
    public init(reader: any BatteryReader,
                sync: any BatterySyncing,          // SYNC-001; BatterySyncService conforms
                identity: any DeviceIdentityProviding,   // SYNC-001 / ADR-0007
                kind: DeviceKind,                  // .iphone, .ipad (RPT-003) or .watch (RPT-004)
                preferences: any DisplayPreferencesStore, // UI-001; supplies thisDeviceName for SYNC-002 R17
                log: ReportLog,
                clock: @Sendable () -> Date = Date.init)
    /// Reads, maps to DeviceBattery (SYNC-002 R16/R17), calls sync.report([device], reason:). Returns the reading it sent, or nil.
    /// Throws ReportError.iCloudUnavailable when sync.status is .signedOut or .restricted, ReportError.syncFailed when the outcome is .failed.
    @discardableResult
    public func reportNow(reason: ReportReason) async throws -> BatteryReading?
}

public final class FixedBatteryReader: BatteryReader { /* scripted readings for tests and previews */ }
```

- `BatterySyncing` is SYNC-001's protocol; tests fake it.
- Mapping to `DeviceBattery` follows SYNC-002: charging flags per R16, name per R17, `id` from `identity.currentDeviceID()` (nil → skip this report, SYNC-001 edge case "before first unlock").
- `ReportLog` wraps App Group `UserDefaults` (`[String: Date]` under `rpt.lastReport`).

**Levels-iOS:**

- `UIDeviceBatteryReader`: `@MainActor final class`, conforms to `BatteryReader` (`@preconcurrency` or `nonisolated` wrappers as the compiler needs). `changes()` merges `UIDevice.batteryLevelDidChangeNotification`, `UIDevice.batteryStateDidChangeNotification` and `.NSProcessInfoPowerStateDidChange` using `NotificationCenter.notifications(named:)`.
- App wiring in the SwiftUI `App`:
  - `.onChange(of: scenePhase)`: `.active` → R4; `.background` → R6.
  - A long-lived `Task` started at launch iterates `reader.changes()` → R5.
  - `.backgroundTask(.appRefresh("<bundle id>.battery-refresh")) { await refresh() }` → R7. Swift task cancellation covers expiry.
  - The `UIApplicationDelegateAdaptor` remote-notification method (owned by SYNC/ADR-0006) gets one added call: `try? await reporter.reportNow(reason: .pushWake)` after SYNC's handling → R8.
- One `BatteryReporter` instance per process, created at app start and shared with the App Intent (RPT-002) through the app's dependency container (Builder's call: `AppDependencyManager` or a static).

**Info.plist (Levels-iOS):**

| Key | Value |
|---|---|
| `BGTaskSchedulerPermittedIdentifiers` | `[$(PRODUCT_BUNDLE_IDENTIFIER).battery-refresh]` |
| `UIBackgroundModes` | `fetch`, `remote-notification` (the latter may already be added by SYNC) |

**Capabilities:** Background Modes (Background fetch, Remote notifications), App Groups (per ADR-0009), iCloud/CloudKit and Push (per SYNC).

**Concurrency:** Swift 6 strict. `BatteryReporter` is an actor so overlapping triggers (foreground + push) run one at a time. Readers hop to the main actor for UIKit.

## Edge cases and failure modes

- **Simulator / unknown reading:** R3 drops it. No record with −1 ever reaches CloudKit.
- **No iCloud account or offline:** SYNC-001 keeps the reading in the cache and pending slot; `reportNow` throws (AC4); R11 logs; next trigger retries.
- **Low Power Mode:** background refresh likely won't run (ADR-0011). Foreground, intents and push still work. The reading carries `isLowPowerMode = true`.
- **Background App Refresh off or app force-quit:** R6/R7 never run. Shortcuts (RPT-002) still works. **Assumption:** intents still run after force-quit.
- **Ping-pong between devices on push:** prevented by ADR-0008 skipping unchanged readings (W7) for the non-urgent `.pushWake` reason (R9).
- **Many events in a burst** (plug in while level changes): every event goes to SYNC; ADR-0008 coalesces. ADR-0008 keeps the latest reading in the pending slot and writes it later rather than dropping it.
- **Rounding:** levels move in 5% steps on iOS 17+ (ADR-0010). Tests must not expect 1% steps from hardware.
- **Push handler time:** if SYNC's own work takes most of the 30 s, the self-report may be cut; the 25 s cap (R8) protects the completion call.

## Acceptance criteria

- [ ] AC1 — Given a `FixedBatteryReader` returning raw 0.85, `.charging`, Low Power Mode off, when `reportNow(.foreground)` runs, then the fake sync receives one `DeviceBattery` with level 85, `isCharging == true`, `isPluggedIn == true`, Low Power Mode false, reason `.foreground`.
- [ ] AC2 — Given raw levels 0.0, 0.004, 0.996, 1.0 and −1.0, when converted, then levels are 0, 0, 100, 100 and nil.
- [ ] AC3 — Given a reading with level nil and state `.unknown`, when `reportNow` runs, then sync is not called and the result is nil.
- [ ] AC4 — Given the fake sync returns `.failed`, when `reportNow` runs, then it throws `ReportError.syncFailed`, `rpt.lastReport` is unchanged, and nothing crashes. Given status `.signedOut`, then it throws `ReportError.iCloudUnavailable`.
- [ ] AC5 — Given a successful report with reason `.backgroundRefresh`, then `rpt.lastReport["backgroundRefresh"]` equals the injected clock time.
- [ ] AC6 — Given two `reportNow` calls started at the same time, then sync receives two calls, one after the other (no overlap).
- [ ] AC7 — Given the app moves to background, then a `BGAppRefreshTaskRequest` with id `<bundle id>.battery-refresh` and earliest begin ≥ 29 min ahead is pending (check with `BGTaskScheduler.shared.pendingTaskRequests()`).
- [ ] AC8 — Given a pending refresh request, when the task is launched from the debugger (`_simulateLaunchForTaskWithIdentifier:`), then one report with reason `.backgroundRefresh` is sent and a new request is pending.
- [ ] AC9 — Given the app is open on a real iPhone, when the charger is connected, then within 60 s the iPhone's CloudKit record shows on power (subject to ADR-0008 timing).
- [ ] AC10 — Given the app is in the background on a real iPhone, when a change from another device's record arrives as a silent push, then the iPhone's own record `updatedAt` refreshes if its level or state changed since the last write.
- [ ] AC11 — Given a real iPhone, when the app launches, then the reported level equals the status-bar percentage rounded to the nearest 5 (or exact, if iOS reports 1%).
- [ ] AC12 — Given the Info.plist, then `BGTaskSchedulerPermittedIdentifiers` contains the refresh id and `UIBackgroundModes` contains `fetch` and `remote-notification`.

## Tests

- **Unit (Swift Testing, Simulator OK):** AC1–AC6 with `FixedBatteryReader`, a fake `BatterySyncing` and an in-memory `ReportLog`. AC12 as a test that loads the built Info.plist.
- **Integration on Simulator:** AC7 (pending requests can be inspected on Simulator).
- **Real hardware only:** AC8 (Apple's debugger command needs a device: [Starting and terminating tasks during development](https://developer.apple.com/documentation/backgroundtasks/starting-and-terminating-tasks-during-development)), AC9, AC10 (silent push is not delivered on Simulator reliably), AC11. The Simulator reports unknown battery (ADR-0010), so any check of real values needs an iPhone.

## Open questions

- None for the owner. (Thresholds for automations are in RPT-002.)
