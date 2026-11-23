---
id: MAC-003
title: Mac accessory reporting
milestone: v0.3
status: Outline
depends_on: [MAC-001, MAC-002, SYNC-001, SYNC-002]
adrs: [10, 13, 15]
targets: [Levels-Mac]
---

# MAC-003: Mac accessory reporting

## Why

iPhone's Batteries widget never shows a Magic Mouse or Keyboard, and it shows AirPods only while they are near the iPhone. The Mac can read the batteries of accessories connected to it, so it reports them, and every device can see whether the mouse or the AirPods need charging.

## Scope

- In: Magic Mouse, Keyboard and Trackpad, and other Bluetooth HID devices that expose `BatteryPercent`; AirPods and Beats (left, right, case, or single battery) while connected to this Mac; connect and disconnect detection; stable UUIDv5 accessory IDs (ADR-0005); one `DeviceBattery` record per accessory component with `parentDeviceId` = this Mac.
- Out: accessories connected to iPhone, iPad or Watch (no public API); charging state for AirPods (not exposed); non-Bluetooth USB devices; alerts (ALR).

## Behaviour

Outline only, from ADR-0015:

- **R1** — HID accessories: IOKit registry, matching `AppleDeviceManagementHIDEventService` and reading `BatteryPercent`, `Product` and `DeviceAddress`. Read when a device is first matched and every 5 minutes while any is connected.
- **R2** — AirPods and Beats: `/usr/sbin/system_profiler SPBluetoothDataType -json`, parsing only `device_connected[*]` and its `device_batteryLevelLeft/Right/Case/Main` (`"NN%"` strings). The `device_not_connected` values are cached and must be ignored. Runs on power or wake triggers, on a HID match, every 5 minutes while AirPods are connected, and every 15 minutes otherwise.
- **R3** — Lead's call (2026-11-23): record ID = SYNC-002 R2's `UUIDv5(LevelsAccessoryNamespace, "accessory:" + accessoryKey + ":" + component)`, with `accessoryKey` = the uppercase colon-separated Bluetooth address and `component` = `main`, `left`, `right` or `case`. UUIDv5 is a one-way SHA-1 derivation, so the raw address is never stored or synced. The same accessory on two Macs maps to one record; the newest `updatedAt` wins (ADR-0008).
- **R3a** — Owner decision (2026-11-23): AirPods are three records (left, right, case) with one shared `accessoryGroupId`, grouped under one AirPods row in the UI (UI-001 R13).
- **R4** — Disconnect writes nothing. The record keeps its last level, and the UI shows its age.
- **R5** — Unknown or changed formats (a key is missing, or a value can't be parsed) mean that accessory is not reported. The problem is logged once per app run. Never guess.
- **R6** — AirPods support exists only in builds with `LEVELS_UNSANDBOXED`, i.e. the Developer ID configuration with App Sandbox off (ADR-0013). Sandboxed builds report HID accessories only.

## Design

To be detailed when v0.3 starts:
- two `BatteryReader` conformers (`HIDAccessoryReader` and `SystemProfilerAccessoryReader`) feeding a list of accessory readings into an `AccessoryReporter` owned by `MacAppModel`;
- an `IONotificationPort` on the main queue;
- a `Process` run with a 5 s timeout;
- JSON parsing with `JSONSerialization` into typed structs, with fixture-based unit tests built from real `system_profiler` output (redacted).

## Implementation notes (2026-11-23, pulled forward into the free-team build)

What was built, and where it differs from the outline above:

- **Data on the owner's MacBook (macOS 27.2.1), re-checked:** `ioreg -r -k BatteryPercent -l` returned nothing; `AppleDeviceManagementHIDEventService` had one entry, the built-in keyboard/trackpad (`Built-In = true`, no `BatteryPercent`, no `DeviceAddress`); `system_profiler SPBluetoothDataType -json` took about 0.1 s and listed the AirPods under `device_not_connected` with cached `device_batteryLevelLeft/Right/Case` (`"100%"`, `"100%"`, `"45%"`). No Magic peripheral or AirPods were connected, so the connected-device shapes in the fixtures are the captured file with the AirPods entry moved under `device_connected`, and hand-written HID entries with ADR-0015's key names. ADR-0015's sources stand; its **Assumptions:** are still open.
- **Code:** `AccessoryBatteryReader` (protocol), `AccessoryReading`/`AccessoryScan`, the pure `SystemProfilerBluetoothParser` and `HIDAccessoryParser`, `BluetoothAddress`, `FixedAccessoryReader` and `AccessoryReporter` are in LevelsReaders. `MacAccessoryReader` (IOKit registry read, `IONotificationPort` match/terminate on the main queue, `system_profiler` with a 5 s timeout under `LEVELS_UNSANDBOXED`) is in Levels-Mac. Fixtures are in `Shared/Tests/LevelsReadersTests/Fixtures` (fake addresses, serials and names).
- **Deviation, reader shape:** the Design names two `BatteryReader` conformers. `BatteryReader` returns one reading of the device's own battery, so accessories use their own protocol, `AccessoryBatteryReader`, with one Mac reader that merges both sources (IOKit first, so a peripheral listed by both keeps the 1 % level).
- **Deviation, reporter:** a separate `AccessoryReporter` actor reports accessories through `BatterySyncing`, next to `BatteryReporter` (which stays own-battery only). Its scans: launch, HID connect/disconnect, wake, power-state change (not every 1 % IOPS step), and the poll.
- **Triggers (2026-11-24 fix):** AirPods connected after launch were not found for up to 15 minutes, because they are audio devices and the HID notification never fires for them. Now also:
  - Bluetooth connect of any device (`IOBluetoothDevice.register(forConnectNotifications:selector:)`): the poll switches to 5 minutes at once, and scans run 3 s and 15 s after the connect (AirPods publish levels a few seconds late). Replays for devices already connected at launch are ignored.
  - Bluetooth disconnect (per-device `register(forDisconnectNotification:selector:)`): scan now; R4 still holds.
  - ⌘R / the refresh button (`.userRefresh`): scan now. Popover open (`.foreground`): scan, at most once a minute.
  - The Info.plist has `NSBluetoothAlwaysUsageDescription`; macOS asks for Bluetooth permission once.
- **Poll (ADR-0014 rule 5):** one timer, re-armed after every scan: 5 minutes while any accessory battery is connected (HID or AirPods, which also covers R1) or headphones are listed as connected, otherwise 15 minutes; 60 s tolerance. Poll scans use `ReportReason.heartbeat`, so `LocalWritePolicy` writes a level change after its 60 s gap and an unchanged accessory every 30 minutes.
- **Names:** every component record carries the plain device name ("TPods"), not "TPods — Left", so UI-001 R13's group name (shortest name) is the headset name. Components are told apart by `component`.
- **Group ID:** `accessoryGroupId = UUIDv5(LevelsAccessoryNamespace, "accessory-group:" + accessoryKey)` (`DeviceID.accessoryGroup(key:)`); one-way like the record names.
- **R5:** a device whose battery keys can't be trusted (unknown `device_batteryLevel*` key, a value that is not `NN%`, a missing or malformed address, a non-integer `BatteryPercent`) is dropped whole; each distinct problem is logged once per run, with no address in the text.
- **R6:** lead's call 16 turns the sandbox off for Debug and Release (ADR-0013 note), so `LEVELS_UNSANDBOXED` is set in both.
- **Charging:** neither source exposes it; accessory records have `isCharging = false` and no `isPluggedIn`.

## Edge cases and failure modes

- Both buds in the case: levels may update only when the case is opened.
- One bud in use: the other may report nothing.
- AirPods connected to the iPhone, not the Mac, show up as not connected: nothing is reported.
- The user renames the device: the record name changes and the ID does not.
- Several Macs report the same accessory: one record; the newest `updatedAt` wins.
- A macOS update changes the format: R5.

## Acceptance criteria

To be written when the spec becomes Ready. They will need real hardware: a Magic Mouse, a Magic Keyboard and AirPods (Pro) connected to a MacBook.

## Tests

Unit tests:
- the parser, on recorded `system_profiler` JSON fixtures (connected and not-connected AirPods, single-battery Beats, missing keys);
- the ID derivation (UUIDv5, SYNC-002 AC8 golden value).

Manual tests on real hardware:
- everything else, because no simulator offers Bluetooth accessories.

## Open questions

- Closed. Owner decision (2026-11-23): three AirPods records, one AirPods row (R3a). Lead's call (2026-11-23): same AirPods on two Macs = one record, newest `updatedAt` wins; record IDs are UUIDv5 (R3).

Not owner questions; to verify before Ready (all ADR-0015 **Assumptions**):
- With a Magic Mouse or Keyboard connected, does its `AppleDeviceManagementHIDEventService` entry have `BatteryPercent` on macOS 26?
- With AirPods connected, does `device_connected` carry left, right and case, and does IOKit carry nothing per-bud?
- Do `BatteryPercent` (1% steps) and AirPods (5% steps) update on their own while the device stays connected?
- Does `system_profiler` keep working unsandboxed under Hardened Runtime in a notarized build?
