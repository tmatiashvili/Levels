# ADR-0015: Read Magic peripherals from the IOKit registry and AirPods from system_profiler; desktop Macs publish a battery-less record

- **Status:** Proposed
- **Date:** 2026-11-23
- **Deciders:** project owner
- **Related:** ADR-0010 (BatteryReader), ADR-0013, ADR-0014, SYNC-002 (`DeviceBattery`, `parentDeviceId`), MAC-002, MAC-003

## Context

In v0.3 the Mac reports the battery of accessories connected to it: AirPods (left, right, case) and the Magic Mouse, Keyboard and Trackpad. iOS keeps this private, so the Mac is the only place Levels can get it. macOS has no documented public API for accessory battery levels. Every option relies on undocumented data, so the choice is about which undocumented source is most stable, works in the sandbox and needs the least code.

This ADR also settles what a Mac without an internal battery (Mac mini, iMac, Mac Studio, Mac Pro) publishes.

### Facts verified on this Mac (macOS 27.2.1, MacBook; addresses and serials redacted)

- **IOKit registry.** `IOServiceGetMatchingServices(IOServiceMatching("AppleDeviceManagementHIDEventService"))` plus `IORegistryEntryCreateCFProperty` works **inside the App Sandbox** (ADR-0013 probe). The only entry on this Mac was the internal keyboard and trackpad, which has no `BatteryPercent`, and no Bluetooth HID accessory was connected. So **Assumption:** a connected Magic Mouse, Keyboard or Trackpad shows `BatteryPercent` (an integer 0–100) on its `AppleDeviceManagementHIDEventService` entry. Open-source code relies on it: AirBattery's `MagicBattery.swift` matches `AppleDeviceManagementHIDEventService`, plus the legacy classes `AppleBluetoothHIDKeyboard`, `BNBTrackpadDevice` and `BNBMouseDevice`, and reads `BatteryPercent`.
- **AirPods.** `system_profiler SPBluetoothDataType -json` returns, per device, `device_batteryLevelCase`, `device_batteryLevelLeft` and `device_batteryLevelRight` as strings such as `"45%"`, plus `device_minorType` (`Headphones`), `device_vendorID` (`0x004C` = Apple), `device_productID` and `device_address`. Single-battery devices use `device_batteryLevelMain`. On this Mac the AirPods were listed under **`device_not_connected` with values still present**. These are cached last-known levels, so only the `device_connected` list may be used. The run took about 0.06 s. **In the App Sandbox the output is empty** (ADR-0013).
- **AirPods in IOKit.** `ioreg -r -k BatteryPercent` found nothing while the AirPods were not connected. **Assumption:** AirPods do not show per-bud levels in the IOKit registry even when connected; AirBattery doesn't read them there either. Not verified with AirPods connected.
- **Bluetooth plist.** `/Library/Preferences/com.apple.Bluetooth.plist` is 321 bytes on this Mac and has no battery keys. The `BatteryPercentLeft/Right/Case` keys that older tools parse are gone. It is readable only outside the sandbox or with `com.apple.security.device.bluetooth`.
- **IOBluetooth.** `IOBluetoothDevice` has undocumented selectors (`batteryPercentSingle`, `batteryPercentLeft`, `batteryPercentRight`, `batteryPercentCase`) that AirBattery calls through `responds(to:)` and KVC. Using them is **private API**. `IOBluetoothDevice.pairedDevices()` returned 0 devices in the probe, probably because Bluetooth permission was missing (**Assumption:**).

## Decision

**Sources (in the Mac target, each a `BatteryReader` per ADR-0010):**

1. **Magic peripherals and other Bluetooth HID devices:** IOKit registry. Match `AppleDeviceManagementHIDEventService` and read `BatteryPercent`, `Product`, `DeviceAddress` and `VendorID`/`ProductID`. Sandbox-safe; no child process.
2. **AirPods and Beats (left, right, case, or single):** run `/usr/sbin/system_profiler SPBluetoothDataType -json` (absolute path, no shell) and parse **only** `device_connected` entries that have any `device_batteryLevel*` key. Needs the sandbox off. This is why ADR-0013 drops the sandbox in the Developer ID build at v0.3. Compiled under `LEVELS_UNSANDBOXED`; without it AirPods are not reported.
3. **Not used:** the Bluetooth plist (no longer has battery data), private `IOBluetoothDevice` selectors (private API; would block the App Store), and parsing `ioreg` text (the registry API returns the same data typed, without a child process).

**Connect and disconnect:**
- Magic peripherals: `IOServiceAddMatchingNotification` for `kIOFirstMatchNotification` and `kIOTerminatedNotification` on `AppleDeviceManagementHIDEventService`, on an `IONotificationPort` set to the main dispatch queue. Connecting reads the device now; disconnecting writes nothing (the record keeps its last value and `updatedAt`).
- AirPods: no public notification without IOBluetooth permission. Run `system_profiler` on each power-source change, on wake, when a HID device matches, and **every 5 minutes while the last run found any connected AirPods, otherwise every 15 minutes**. **Assumption:** 15 minutes is an acceptable delay for noticing newly connected AirPods; `IOBluetoothDevice.register(forConnectNotifications:)` is the upgrade path if not.
- Battery changes while connected: re-read on the same 5-minute timer. `BatteryPercent` changes in 1% steps and AirPods in 5% steps (**Assumption:** from observation reports, not documented). Saves go through SYNC-001's per-record rate limit.

**Identity and record naming:**
- Lead's call (2026-11-23): an accessory's record name is the UUIDv5 of ADR-0005 / SYNC-002 R2: `UUIDv5(LevelsAccessoryNamespace, "accessory:" + accessoryKey + ":" + component)`, where `accessoryKey` is the uppercase colon-separated Bluetooth address and `component` is `main`, `left`, `right` or `case`. (This replaces the earlier `acc-` + SHA-256 scheme.)
- Owner decision (2026-11-23): AirPods are three records (left, right, case) sharing one `accessoryGroupId`, shown as one AirPods row (UI-001 R13). Single-battery devices use `main`.
- Each component is a separate `DeviceBattery` with `type = accessory`, `parentDeviceId` = the reporting Mac's `deviceId`, and a name such as "AirPods Pro — Left" (SYNC-002 owns the fields). Lead's call (2026-11-23): the same accessory on two Macs maps to the **same record**; the newest `updatedAt` wins (ADR-0008), and `parentDeviceId` then means "last seen on".
- Privacy: the raw Bluetooth address is never stored or synced. UUIDv5 hashes the namespace and the address with SHA-1, so the record name is still a one-way derivation. It is not a secret: a fixed namespace over a 48-bit address can be brute-forced. Its purpose is to keep raw hardware identifiers out of the record. The data lives only in the owner's private CloudKit database (ADR-0004..0009). Names come from the device name the user set (it may contain a person's name, e.g. "Anna's AirPods") and stay in the private DB.

**Desktop Mac (no internal battery):**
- The Mac **publishes its own record with `type = mac` and `level = nil`** (no battery), so its accessories have a parent with a name and the UI can group them. UI-004 and the widgets decide how to show it, e.g. "Mac mini — on power" or hidden when it has no accessories. SYNC-002 makes `level` optional (R3) and the UI specs show such a device as "plugged in, no battery".
- A UPS reported through IOPS (`kIOPSTypeKey = "UPS"`) is ignored. Only `InternalBattery` counts.

## Options considered

### Option A — IOKit registry for HID + `system_profiler` for AirPods (chosen)
- Pros: typed, sandbox-safe reads for Magic peripherals; the only working source of AirPods left/right/case without private API; proven by AirBattery; `system_profiler` is fast (~0.06 s).
- Cons: both sources are undocumented and could change in any macOS release. AirPods need the sandbox off and a poll.

### Option B — Parse `ioreg` output
- Pros: works in the sandbox (verified).
- Cons: same data as Option A source 1 but as text and from a child process; no AirPods per-bud data. Rejected.

### Option C — Bluetooth plist
- Pros: historically had per-bud keys.
- Cons: no battery data on current macOS (verified). Rejected.

### Option D — IOBluetooth private selectors
- Pros: per-bud levels; connect notifications.
- Cons: private API (App Store rejection), needs Bluetooth permission, unverified on macOS 26. Rejected; kept as a fallback if `system_profiler` loses its battery fields.

## Consequences

- Positive: v0.3 needs no private API. Magic peripherals would also work in an App Store build.
- Negative / accepted risks: a macOS update could rename `device_batteryLevel*` or `BatteryPercent`. MAC-003 must fail soft, reporting nothing rather than wrong values, and log the change. AirPods charging state is not exposed by `system_profiler`, so `isCharging` is `false` for AirPods (**Assumption:** that no charging field exists).
- Follow-ups: verify everything marked **Assumption:** with a Magic Mouse, a Magic Keyboard and AirPods connected, before MAC-003 moves from Outline to Ready. SYNC-002 allows `level = nil` (done). The accessory ID scheme is settled (UUIDv5, lead's call 2026-11-23).

## References

- IOKit `IOServiceGetMatchingServices`: https://developer.apple.com/documentation/iokit/1514494-ioservicegetmatchingservices
- IOKit `IOServiceAddMatchingNotification`: https://developer.apple.com/documentation/iokit/1514362-ioserviceaddmatchingnotification
- Accessing hardware from applications (IOKitLib): https://developer.apple.com/library/archive/documentation/DeviceDrivers/Conceptual/AccessingHardware/AH_IOKitLib_API/AH_IOKitLib_API.html
- AirBattery, `MagicBattery.swift`: https://github.com/lihaoyun6/AirBattery
- AirpodsBattery-Monitor-For-Mac, plist and system_profiler parsing: https://github.com/mohamed-arradi/AirpodsBattery-Monitor-For-Mac
