# Levels

A native Apple app that shows the battery level of every device in your ecosystem (iPhone, iPad, Mac, Apple Watch and their accessories) in one place, on every device.

## Problem

iPhone's built-in Batteries widget shows only the iPhone and accessories paired to it (AirPods, Watch). It never shows the Mac or iPad. AirPods and the Watch report their battery through Apple's private protocols (Continuity BLE advertisements, the Watch companion link), and third-party apps can't use them. So you can't check whether the MacBook in your bag is charged without taking it out.

## Core idea

**Every device runs the app, reports its own battery to iCloud, and every device shows all of them.**

```
 ┌────────┐   ┌────────┐   ┌────────┐   ┌────────┐
 │ iPhone │   │  iPad  │   │  Mac   │   │ Watch  │
 └───┬────┘   └───┬────┘   └───┬────┘   └───┬────┘
     │ report     │ report     │ report     │ report
     │            │            │ + Mac-connected accessories
     ▼            ▼            ▼            ▼
 ┌──────────────────────────────────────────────────┐
 │        CloudKit private DB (one record/device)   │
 └──────────────────────────────────────────────────┘
     │ silent push (CKQuerySubscription) on any change
     ▼
 every device → reload widgets / complications / menu bar
```

## Reading battery levels

| Device | API | Notes |
|---|---|---|
| iPhone / iPad | `UIDevice.current.batteryLevel` | Set `isBatteryMonitoringEnabled = true` first. Reports in 5% steps. |
| Apple Watch | `WKInterfaceDevice.current().batteryLevel` | Set `isBatteryMonitoringEnabled = true` first. |
| Mac | IOKit `IOPSCopyPowerSourcesInfo` | `IOPSNotificationCreateRunLoopSource` notifies on change, so no polling. |
| AirPods, Magic Mouse/Keyboard/Trackpad | Read on the Mac via `ioreg` / Bluetooth prefs | Only while connected to the Mac. iOS keeps this private. |

Mac example:

```swift
import IOKit.ps

func readBattery() -> (pct: Int, charging: Bool)? {
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
    guard let src = list.first,
          let d = IOPSGetPowerSourceDescription(info, src)?
              .takeUnretainedValue() as? [String: Any] else { return nil }
    return (d[kIOPSCurrentCapacityKey] as? Int ?? 0,
            d[kIOPSIsChargingKey] as? Bool ?? false)
}
```

## Sync

- **CloudKit private database**, record type `DeviceBattery`:
  - `deviceId` (stable UUID kept in Keychain)
  - `name`, `type` (iphone / ipad / mac / watch / accessory), `parentDeviceId` (for accessories)
  - `level` (0–100), `isCharging`, `isLowPowerMode`
  - `updatedAt`
- Overwrite your own record on change, saving at most about once a minute.
- A `CKQuerySubscription` on `DeviceBattery` sends a silent push. The receiver refreshes its cache and calls `WidgetCenter.shared.reloadAllTimelines()`.
- An App Group shared container caches the latest snapshot so widgets render instantly.

### Nearby mode (optional, later)

Over Bluetooth LE, the Mac advertises a custom GATT service with a battery characteristic (`CBPeripheralManager`), and the iPhone subscribes (`CBCentralManager`). This gives fast updates with no cloud when the devices are within about 10 m, and CloudKit covers everything else.

## Display

- Shared SwiftUI view package used by every target.
- **iOS / iPadOS:** app, Home Screen widgets (small / medium / large) and lock-screen widgets (`.accessoryCircular` with `Gauge`).
- **macOS:** menu-bar app (`LSUIElement`), registered as a login item via `SMAppService.mainApp.register()`, plus desktop widgets.
- **watchOS:** app and complications.
- Always show "updated X min ago" so stale values are obvious.

## Background update strategy (the hard part)

iOS won't let the app run continuously, so the iPhone's own reading can go stale. Mitigations:

1. Report on every app launch / foreground.
2. `BGAppRefreshTask`, which runs irregularly.
3. **App Intent "Report Battery" plus Shortcuts automations** that run when the battery level crosses thresholds (every 10–20%). This is the most reliable option.
4. Report when charging starts or stops.

The Mac agent runs continuously while the Mac is awake. A sleeping Mac stops reporting, and the UI shows its last reading.

## Project structure (planned)

```
Levels/
├── Shared/            # Models, CloudKit sync, battery readers, SwiftUI views (Swift package)
├── Levels-iOS/    # iPhone/iPad app + App Intents
├── Levels-Mac/    # Menu-bar agent + accessory reader
├── Levels-Watch/  # watchOS app
├── Widgets-iOS/       # WidgetKit extension (home + lock screen)
├── Widgets-Mac/       # WidgetKit extension (desktop)
└── Complications/     # watchOS widgets
```

## Roadmap

- [ ] **v0.1 MVP:** Mac agent and iPhone app with a widget, synced via CloudKit
- [ ] **v0.2:** iPad and Apple Watch (mostly shared code)
- [ ] **v0.3:** the Mac reports its connected accessories (AirPods, Magic peripherals)
- [ ] **v0.4:** low-battery alerts (the device receiving the silent push posts a local notification)
- [ ] **v0.5:** 7-day history and charts, low-power-mode tracking
- [ ] **Later:** BLE nearby mode, family sharing

## Requirements and constraints

- **Paid Apple Developer account ($99/year)** for the CloudKit, push and App Group entitlements. Free provisioning can't use iCloud or push, and the app expires after 7 days.
- All devices signed in with the same Apple ID and iCloud enabled.
- Widget refresh timing is controlled by iOS (expect minutes to roughly 30 minutes, not real time).
- Data stays in the user's private iCloud database. There's no backend and no analytics.
