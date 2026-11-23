---
id: MAC-002
title: Mac battery reporter
milestone: v0.1
status: Draft
depends_on: [SYNC-001, SYNC-002, UI-001]
adrs: [5, 8, 10, 13, 14, 15, 17]
targets: [Levels-Mac]
---

# MAC-002: Mac battery reporter

## Why

Other devices can only show the Mac's battery if the Mac reports it, accurately and promptly. Unlike iOS, the Mac agent runs all the time, so it can report every meaningful change as it happens, without polling.

## Scope

- In: an IOKit power-source reader implementing ADR-0010's `BatteryReader` for the Mac; change notifications bridged to Swift concurrency; Low Power Mode; triggers (launch, change, wake, sleep, heartbeat); the Mac without an internal battery; handing readings to SYNC-001.
- Out (and where it goes instead): saving, rate limiting and record layout (SYNC-001, SYNC-002); accessories (MAC-003); history (HIS, v0.5); alerts (ALR, v0.4); UI (UI-004).

## Behaviour

- **R1** — The reader takes the Mac's battery from `IOPSCopyPowerSourcesInfo()` / `IOPSCopyPowerSourcesList()`, using the first source whose `kIOPSTypeKey` is `kIOPSInternalBatteryType` and whose `kIOPSIsPresentKey` is `true`. Any other source (UPS, external) is ignored.
- **R2** — `level = round(current / max × 100)`, clamped to 0…100, where `current = kIOPSCurrentCapacityKey` and `max = kIOPSMaxCapacityKey`. If `max` is missing or ≤ 0, use `current` as a percentage, clamped. (On Apple Silicon IOPS already reports `max = 100`, verified on this Mac, but the formula is used everywhere.)
- **R3** — `PowerState` (ADR-0010): `kIOPSIsChargingKey == true` → `.charging`; else on AC (`kIOPSPowerSourceStateKey == kIOPSACPowerValue`) and `kIOPSIsChargedKey == true` → `.full`; else on AC → `.pluggedIn` (held at 80% by Optimized Charging, or paused); else `.unplugged`. The model flags follow SYNC-002 R16: `isCharging = charging || (onExternalPower && full)`, `isPluggedIn = onExternalPower`. So a Mac at 100% on AC has `isCharging = true`, and one held at 80% has `isCharging = false, isPluggedIn = true`.
- **R4** — `isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled` (verified readable on macOS).
- **R5** — **No internal battery** (desktop Mac, or no present `InternalBattery` source). The reading has `level = nil` and `powerState = .pluggedIn` (so `isCharging = false`, `isPluggedIn = true`), and is still reported (ADR-0015 decision). The UI shows it as "plugged in, no battery" (UI-001).
- **R6** — **Triggers.** The reporter reads and offers a reading to SYNC-001 on:
  - (a) start;
  - (b) every IOPS change notification;
  - (c) `NSProcessInfoPowerStateDidChange` (Low Power Mode toggled);
  - (d) `NSWorkspace.didWakeNotification` (MAC-001 calls `report(reason: .wake)`);
  - (e) `NSWorkspace.willSleepNotification` (MAC-001 calls `report(reason: .sleep)`);
  - (e2) a silent push, after SYNC-001 has handled it (MAC-001 R9 calls `report(reason: .pushWake)`);
  - (e3) a user refresh from the popover (refresh button or ⌘R; UI-004 R7 calls `report(reason: .userRefresh)`);
  - (f) a **heartbeat every 30 minutes** (timer tolerance 5 min), so a Mac that sits unchanged on power (including full on the charger) still looks fresh. ADR-0008 W6 writes it when the last accepted write is ≥ 30 min old, so while the Mac is awake its age stays under ADR-0017's 65-minute Mac threshold.
- **R7** — **Change filter.** For (b) and (c), the reporter offers a reading only if `level`, `powerState` or `isLowPowerMode` differs from the last offered reading. IOPS also fires on time-remaining updates; those are dropped.
- **R8** — **Reasons and urgency.** Each trigger maps to a SYNC-001 `ReportReason`: (a) `.launch`, (b) `.chargerChange` if `powerState` changed, else `.batteryChange`, (c) `.batteryChange`, (d) `.wake`, (e) `.sleep`, (e2) `.pushWake` (not urgent), (e3) `.userRefresh`, (f) `.heartbeat`. `.launch`, `.chargerChange`, `.wake`, `.sleep` and `.userRefresh` are urgent (SYNC-001 R5a, ADR-0008 W9: skip the 60 s gap, keep the 10 s floor). The others follow ADR-0008 W1–W8 and SYNC-001 coalesces them: the latest reading wins.
- **R9** — The reporter never polls IOPS on a timer other than the R6(f) heartbeat.
- **R10** — Reading failures (`IOPSCopyPowerSourcesInfo` returns nothing) are logged once per run. The reporter offers nothing and tries again on the next trigger. It does not crash, and it does not publish `level = nil` because of a failure: R5 applies only when IOPS answers and has no battery.

## Design

**Reader (conforms to ADR-0010 `BatteryReader` and returns its `BatteryReading`)**

```swift
/// Pure, unit-testable: maps one IOPS description dictionary list to a reading.
/// nil descriptions (IOPS answered nothing) → level nil, .unknown (R10: never sent).
enum MacPowerMapper {
    static func reading(from descriptions: [[String: any Sendable]]?, lowPowerMode: Bool, now: Date) -> BatteryReading
}

struct IOKitBatteryReader: BatteryReader {             // ADR-0010
    func read() async -> BatteryReading              // R1–R5, R10; never throws
    func changes() -> AsyncStream<BatteryReading>    // IOPS stream + Low Power Mode, below
}
```

- The mapper takes plain dictionaries keyed by the `kIOPS*` string constants, so tests feed fixtures (a MacBook charging, on AC at 80% not charging, on battery, a desktop with no source, a UPS only, max ≠ 100) with no IOKit at all.

**Change stream: IOPS run-loop source bridged to `AsyncStream`**

```swift
final class PowerSourceChanges: Sendable {
    /// One element per IOPS notification. Finishing the stream removes the run-loop source.
    static func stream() -> AsyncStream<Void>
}
```

Implementation rules (Swift 6 strict concurrency):

1. **Callback.** `IOPSNotificationCreateRunLoopSource` takes a `@convention(c)` callback and an `UnsafeMutableRawPointer?` context. Pass `Unmanaged.passRetained(box).toOpaque()`, where `box` is a `final class Box: Sendable { let continuation: AsyncStream<Void>.Continuation }`. `Continuation` is `Sendable`, so the box is truly `Sendable`; no `@unchecked`.
2. **Inside the callback:** `Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue().continuation.yield()`. Nothing else: no IOKit reads in the callback.
3. **Run loop.** Add the source with `CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)` so it fires while a menu is tracking. The main run loop always runs in an `NSApplication` app.
4. **Teardown.** In `continuation.onTermination`, hop to the main actor (`Task { @MainActor in … }`), call `CFRunLoopRemoveSource`, then release the box (`Unmanaged…release()`).
5. **Buffering.** `bufferingPolicy: .bufferingNewest(1)`: bursts collapse to one element, and the consumer re-reads the full state anyway.

**Low Power Mode changes:** `NotificationCenter.default.notifications(named: .NSProcessInfoPowerStateDidChange)`, merged into the same consumer loop.

**Reporter**

```swift
@MainActor final class MacBatteryReporter {
    init(reader: some BatteryReader,
         sync: any BatterySyncing,                 // SYNC-001; BatterySyncService conforms
         identity: any DeviceIdentityProviding,    // SYNC-001 / ADR-0007
         preferences: any DisplayPreferencesStore, // UI-001; thisDeviceName (SYNC-002 R17)
         clock: some Clock<Duration>)
    func start()                                   // R6(a), begins consuming the streams and the heartbeat
    func report(reason: ReportReason)              // called by MAC-001 with .sleep / .wake / .pushWake, and by UI-004 with .userRefresh
    func stop()
}
```

- One `Task` loops over the merged triggers: the IOPS stream, Low Power notifications, and a heartbeat `clock.sleep(for: .minutes(30), tolerance: .minutes(5))`. On each it calls `reader.read()`, applies R7, maps the reading to a `DeviceBattery` (SYNC-002 R16/R17) and calls `sync.report([device], reason:)` with the R8 reason. At v0.3 MAC-003 adds its accessory records to the same call.
- Field mapping into `DeviceBattery` belongs to SYNC-002: `kind = .mac`, `name` per SYNC-002 R17 (the user's in-app rename, else the computer name, else "Mac").
- **Builder's call:** IOPS reads are cheap and synchronous. Calling them on the main actor is acceptable. Move them to a nonisolated `async` function only if profiling shows main-thread time above 1 ms.

**App Nap (ADR-0014):** no `beginActivity` by default. If AC6 fails on hardware, wrap the read-and-offer step in `ProcessInfo.processInfo.performActivity(options: .userInitiated, reason: "Report battery")`.

**Entitlements:** none beyond MAC-001's. IOPS works in the App Sandbox (verified, ADR-0013).

**Improvements over the README sample:**
- it picks the internal battery instead of `list.first`;
- it normalises by max capacity;
- it treats "no battery" separately from "read failed";
- it separates on-AC from charging;
- it adds Low Power Mode;
- it uses notifications instead of polling.

## Edge cases and failure modes

- **Desktop Mac.** R5: `level = nil`. The UI decides how to show it (UI-004).
- **UPS attached to a desktop.** Ignored (R1), so the record still says no internal battery.
- **Battery removed or serviced** (`kIOPSIsPresentKey == false`). Treated as no battery (R5). **Assumption:** rare enough not to need its own state.
- **Optimized Charging hold at 80%.** `.pluggedIn`: `isCharging = false`, `isPluggedIn = true` (SYNC-002 R16).
- **IOPS notification storms** (dozens per minute while charging). R7 filter plus `.bufferingNewest(1)` plus SYNC-001 coalescing.
- **Sleep.** R6(e) is best effort. The save may not finish before sleep (ADR-0014).
- **Clock change or time-zone change.** The heartbeat uses a monotonic `ContinuousClock`; `updatedAt` is SYNC-001's concern.
- **Intel Macs on macOS 26.** **Assumption:** IOPS may report `max` in mAh-like units on some Intel models. R2 normalisation covers it either way.

## Acceptance criteria

- [ ] AC1 — Given an IOPS description with `CurrentCapacity = 4074`, `MaxCapacity = 6210`, `Type = InternalBattery`, `IsPresent = true`, when mapped, then `level == 66`. (Unit)
- [ ] AC1a — Given AC power, `IsCharging = false`, `IsCharged = true` and capacity 100, when mapped, then `powerState == .full` and the model has `isCharging == true`, `isPluggedIn == true`. (Unit)
- [ ] AC2 — Given `PowerSourceState = AC Power`, `IsCharging = false` and `IsCharged = false` (held at 80%), when mapped, then `powerState == .pluggedIn`, so `isCharging == false` and `isPluggedIn == true`. (Unit)
- [ ] AC3 — Given an empty source list, or only a `UPS` source, when mapped, then `level == nil` and `powerState == .pluggedIn`. Given `nil` descriptions (read failure), then `powerState == .unknown` and nothing is offered (R10). (Unit)
- [ ] AC4 — Given the last offered reading equals the new one, when an IOPS change fires, then nothing is offered to sync. Given a different `level`, then one reading is offered with reason `.batteryChange`; given a different `powerState`, with `.chargerChange`. Given `report(reason: .wake)`, the reason passed to sync is `.wake`. (Unit with fake reader and fake sync)
- [ ] AC5 — Given a fake clock, when 30 minutes pass with no changes, then exactly one reading with reason `.heartbeat` is offered. (Unit)
- [ ] AC6 — Given a MacBook on battery with the app idle and the popover closed, when the charger is plugged in, then the Mac's record shows `isCharging = true` and `isPluggedIn = true` within 90 s. (Manual on real MacBook; checks App Nap)
- [ ] AC7 — Given a MacBook, when Low Power Mode is toggled in System Settings → Battery, then a reading with the new `isLowPowerMode` is offered within 5 s. (Manual on real MacBook; log check)
- [ ] AC8 — Given a desktop Mac (Mac mini or iMac), when the app starts, then its record has `type = mac` and `level = nil`. (Manual on real desktop Mac)
- [ ] AC9 — Given `PowerSourceChanges.stream()` is consumed and then cancelled, when the consuming task ends, then the run-loop source is removed (no further callbacks) and the box is released. (Unit test that runs the main run loop + a leak check in Instruments)
- [ ] AC10 — Given the Mac target is built with Swift 6 strict concurrency complete, then MAC-002's files produce no concurrency warnings and contain no `@unchecked Sendable` or `nonisolated(unsafe)`. (CI build)
- [ ] AC11 — Given the level shown by `pmset -g batt`, when the reporter reads, then its `level` matches within ±1. (Manual on real MacBook)

## Tests

- **Unit (Swift Testing):**
  - AC1–AC3: `MacPowerMapper` on fixture dictionaries.
  - AC4 and AC5: the reporter with fake reader, fake sync and a test clock.
  - AC9: the stream teardown on the main run loop.
- **Build check:** AC10.
- **Real hardware, manual:** AC6, AC7 and AC11 need a MacBook, because charging, Low Power Mode and real IOPS values can't be simulated. AC8 needs a desktop Mac.

## Open questions

- None for the owner. (SYNC-002 already has optional `level` and `isPluggedIn`; this spec uses them.)
