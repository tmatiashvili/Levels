# ADR-0010: Read battery through one `BatteryReader` protocol in Shared, one implementation per platform

- **Status:** Proposed
- **Date:** 2026-11-23
- **Deciders:** project owner
- **Related:** ADR-0005, ADR-0008, ADR-0011, ADR-0012, ADR-0013, SYNC-001, SYNC-002, RPT-001, RPT-003, RPT-004, MAC-*

## Context

Four platforms read their own battery with three different APIs. Every reporting path (app foreground, background refresh, App Intent, silent push, Mac agent) needs the same answer: level, charging state and Low Power Mode. Tests need a fake, because the Simulator has no battery.

Verified facts:

- **iPhone / iPad — `UIDevice`.** `batteryLevel` is 0.0–1.0. If battery monitoring is off, the state is `.unknown` and the level is −1.0. `isBatteryMonitoringEnabled` defaults to `false`; while it is `false` the system posts no battery notifications and the app cannot read level or state. ([batteryLevel](https://developer.apple.com/documentation/uikit/uidevice/batterylevel), [isBatteryMonitoringEnabled](https://developer.apple.com/documentation/uikit/uidevice/isbatterymonitoringenabled))
- `UIDevice.batteryLevelDidChangeNotification` posts "no more frequently than once per minute". `batteryStateDidChangeNotification` posts on state changes. Both need monitoring on, and both reach the app only while its process is running. ([level notification](https://developer.apple.com/documentation/uikit/uidevice/batteryleveldidchangenotification), [state notification](https://developer.apple.com/documentation/uikit/uidevice/batterystatedidchangenotification))
- **Granularity.** Since iOS 17, `batteryLevel` is rounded to the nearest 0.05. Apple engineers on the developer forums called this intentional, with no API to get finer values. Another Apple reply says some iOS versions round to 1% and others to 5%. ([forum 732903](https://developer.apple.com/forums/thread/732903), [forum 788911](https://developer.apple.com/forums/thread/788911), June 2025: "expected and intended behavior")
  - **Assumption:** iOS/iPadOS 26 still rounds to 5%. No Apple text about 26 was found. The design must work for both 1% and 5%.
- **Apple Watch — `WKInterfaceDevice`.** `batteryLevel` is 0.0–1.0, or −1.0 when `batteryState` is `.unknown` (for example, monitoring off). `isBatteryMonitoringEnabled` defaults to `false` and enables both properties. ([batteryLevel](https://developer.apple.com/documentation/watchkit/wkinterfacedevice/batterylevel), [isBatteryMonitoringEnabled](https://developer.apple.com/documentation/watchkit/wkinterfacedevice/isbatterymonitoringenabled))
  - **Assumption:** `WKInterfaceDevice` posts no battery-change notifications, so the watch must read on demand.
  - **Assumption:** the watch level has no documented rounding; treat it like iOS (1% or 5%).
- **Low Power Mode — `ProcessInfo.isLowPowerModeEnabled`** exists on iOS, iPadOS, macOS 12+ and watchOS. Changes post `NSProcessInfoPowerStateDidChange`. In Low Power Mode the system pauses "discretionary and background activities". ([isLowPowerModeEnabled](https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled))
  - **Assumption:** on watchOS, `isLowPowerModeEnabled` reflects the watch's own Low Power Mode.
- **Simulator.** It has no battery. Apple's old BatteryStatus sample says the Simulator always returns unknown state. ([BatteryStatus ReadMe](https://developer.apple.com/library/archive/samplecode/BatteryStatus/Listings/ReadMe_txt.html)) Real values need real hardware.
- **Mac — IOKit** (`IOPSCopyPowerSourcesInfo`, `IOPSNotificationCreateRunLoopSource`) is owned by ADR-0013..0015 and the MAC specs.
- In Swift 6, `UIDevice` and `WKInterfaceDevice` are main-actor types, so reads must hop to the main actor.

## Decision

Put a `BatteryReader` protocol and a `BatteryReading` value type in the Shared package. Each platform supplies one implementation. Readers only read; they never talk to CloudKit. The protocol, the value type and `FixedBatteryReader` live in the `LevelsReaders` module (ADR-0003); platform implementations live in the app targets. The reporter (`BatteryReporter` in RPT-001/RPT-004, `MacBatteryReporter` in MAC-002) maps a `BatteryReading` to the `DeviceBattery` (SYNC-002) that `BatterySyncService.report(_:reason:)` (SYNC-001) accepts.

```swift
public struct BatteryReading: Sendable, Equatable {
    public enum PowerState: Sendable, Equatable {
        case unknown, unplugged, charging, full
        case pluggedIn   // on external power, neither charging nor full (Mac: held at a limit, paused, or no battery)
    }
    public var level: Int?            // 0...100; nil when unknown
    public var powerState: PowerState
    public var isLowPowerMode: Bool
    public var readAt: Date
}

public protocol BatteryReader: Sendable {
    /// Current values. Never throws; unknown is a valid answer.
    func read() async -> BatteryReading
    /// Emits a new reading on every change the platform tells us about,
    /// only while this process runs. Platforms without change events emit nothing.
    func changes() -> AsyncStream<BatteryReading>
}
```

Rules every implementation follows:

1. **Level conversion.** `level = Int((raw * 100).rounded())`, clamped to 0...100. A raw value below 0 gives `nil`. No smoothing, no extrapolation.
2. **Monitoring.** Turn `isBatteryMonitoringEnabled` on when the reader is created and leave it on for the process lifetime. Never read before it is on.
3. **Low Power Mode** comes from `ProcessInfo.processInfo.isLowPowerModeEnabled` on every platform, and `NSProcessInfoPowerStateDidChange` feeds `changes()`.
4. **Notification-driven, not polling, where the platform offers events.** iOS/iPadOS: `changes()` merges the level, state and power-state notifications. Mac: the IOKit run-loop source (MAC agent). watchOS: no battery events, so `changes()` emits only on Low Power Mode changes; the watch reads on demand at each trigger in ADR-0012. No timers anywhere.
5. **Isolation.** The UIKit and WatchKit readers are `@MainActor` final classes; `read()` is `async` so any caller can await it. The reading type is `Sendable`.
6. **Charging flags.** A reading maps to the model as SYNC-002 R16 says: `isCharging = charging || (onExternalPower && full)`, `isPluggedIn = onExternalPower`. So `.charging` and `.full` give `isCharging = true, isPluggedIn = true`; `.pluggedIn` gives `false, true`; `.unplugged` gives `false, false`; `.unknown` gives `false, nil`. iOS and watchOS never produce `.pluggedIn`.
7. **Testing.** Shared ships a `FixedBatteryReader` (returns scripted readings, can emit scripted changes) for unit tests and previews.

Implementations: `UIDeviceBatteryReader` (Levels-iOS, used by iPhone and iPad), `WatchBatteryReader` (Levels-Watch), `IOKitBatteryReader` (Levels-Mac, per MAC specs).

## Options considered

### Option A — protocol in Shared, per-platform implementations (chosen)
- Pros: one shape for all reporting paths and the UI; easy fakes; the Mac agent plugs in without touching iOS code; reporting logic is testable without hardware.
- Cons: a little indirection; the watch implementation can't honour `changes()` for level and state.

### Option B — call the platform APIs directly at each call site
- Pros: no abstraction; fewest files.
- Cons: level conversion, unknown handling and Low Power Mode logic get copied 5+ times; nothing testable on Simulator.

### Option C — poll on a timer in addition to notifications
- Pros: catches changes the notifications miss.
- Cons: timers don't run while the app is suspended, which is exactly when changes are missed; costs battery while the app runs. Notifications already cover the running case.

### Option D — try to recover 1% precision (private APIs, IOKit on iOS)
- Pros: finer numbers.
- Cons: private API, breaks App Store review and can break on any update. 5% is good enough for "do I need to charge it?".

## Consequences

- Positive: one tested conversion; UI and sync never see −1.0; Mac work is independent.
- Negative / accepted risks: iPhone and iPad show 5% steps (for example 85%, never 87%). The watch only reads when something wakes the app.
- Follow-ups: the UI specs should not imply 1% precision. If a real device on iOS 26 shows 1% steps, nothing changes in the code; update the Assumption here.

## References

- [UIDevice.batteryLevel](https://developer.apple.com/documentation/uikit/uidevice/batterylevel)
- [UIDevice.isBatteryMonitoringEnabled](https://developer.apple.com/documentation/uikit/uidevice/isbatterymonitoringenabled)
- [UIDevice.batteryLevelDidChangeNotification](https://developer.apple.com/documentation/uikit/uidevice/batteryleveldidchangenotification)
- [UIDevice.batteryStateDidChangeNotification](https://developer.apple.com/documentation/uikit/uidevice/batterystatedidchangenotification)
- [WKInterfaceDevice.batteryLevel](https://developer.apple.com/documentation/watchkit/wkinterfacedevice/batterylevel)
- [WKInterfaceDevice.isBatteryMonitoringEnabled](https://developer.apple.com/documentation/watchkit/wkinterfacedevice/isbatterymonitoringenabled)
- [ProcessInfo.isLowPowerModeEnabled](https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled)
- Developer forums on 5% rounding: [732903](https://developer.apple.com/forums/thread/732903), [788911](https://developer.apple.com/forums/thread/788911)
- [BatteryStatus sample ReadMe (Simulator returns unknown)](https://developer.apple.com/library/archive/samplecode/BatteryStatus/Listings/ReadMe_txt.html)
