---
id: UI-002
title: iPhone app screens
milestone: v0.1
status: Draft
depends_on: [UI-001, SYNC-001, SYNC-002, RPT-001, RPT-002]
adrs: [2, 3, 5, 16, 17, 19]
targets: [Levels-iOS]
---

# UI-002: iPhone app screens

> **Note (owner decision M, 2026-11-24):** the free-team iPhone build gets its data from the Mac on the home Wi-Fi, not iCloud (ADR-0020). [NET-004](NET-004-iphone-app-and-widgets-local.md) R1–R11 change this spec for that build: first-run "Connect to your Mac", hub banners instead of the iCloud banner, Settings ▸ Mac, no Remove for old devices (remove them on the Mac), the hub form of Remove all my data, and the About text. Everything else here applies as written.

## Why

The iPhone app is where the owner sees all devices at a glance, forces a refresh, renames this iPhone, hides devices, and sets up the Shortcuts automation that keeps the iPhone's own reading fresh.

## Scope

- In: device list screen (including the "Old devices" section), device detail screen, settings screen (rename this device, hide/unhide, Shortcuts setup guide link, Remove all my data, about), pull to refresh, deep links from widgets.
- Out: widgets (UI-003); iPad layout (UI-005); the Shortcuts guide content and the "Report Battery" intent (RPT-002); sync and reporting behaviour (SYNC, RPT); alerts (ALR, v0.4); history (HIS, v0.5).

## Behaviour

- **R1** Launch opens the **Devices** screen: a `NavigationStack` with large title "Levels", the UI-001 `DeviceList`, and a toolbar button (`gearshape`) that opens Settings as a sheet.
- **R2** Pull to refresh (`.refreshable`) calls `DeviceListStore.refresh()`, which reports this iPhone's battery (RPT-001) with the urgent reason `.userRefresh` and fetches all records (SYNC-001 `refresh(.userPull)`). Lead's call (2026-11-23): `.userRefresh` writes even if the reading is unchanged, so this iPhone's "updated" age moves, but it still respects the 10 s floor (SYNC-001 R5a). The spinner stays until both finish or 15 s pass, whichever is first.
- **R3** Moving to the foreground calls `DeviceListStore.refreshOnForeground()`: the same report and fetch, with reason `.foreground` (not urgent) and without the spinner (RPT and SYNC decide what actually runs).
- **R4** Tapping a row pushes **Device detail**: large `BatteryRing`, level, state lines (Charging / Plugged in, not charging / Not charging, or "Plugged in · no battery" when `level == nil`; Low Power Mode on/off), "Updated" absolute time plus relative age, device type, and buttons "Rename" (this iPhone only) and "Hide from Levels". For a stale device a line explains: "This device hasn't reported for 3 hours. It may be asleep, off or offline."
- **R5** Swipe actions on a row: "Hide" (trailing). Context menu: Rename (this iPhone's row only), Hide.
- **R6** **Rename** applies to this iPhone only. It shows an alert with a text field prefilled with the current name; empty input resets to the default name ("iPhone", SYNC-002 R17). Saving calls `DeviceListStore.renameThisDevice(to:)` (UI-001), which writes the name to this iPhone's own record, so every device shows it. The default name is the model name because iOS returns only a generic `UIDevice.name` without the user-assigned-device-name entitlement (ADR-0007 rule 8). Other devices are renamed on themselves.
- **R7** **Hide** removes the row from the app and from this device's widgets after the next widget reload; it is undoable from Settings ▸ Hidden devices. Hiding is local to this iPhone (v0.1).
- **R8** **Settings** sheet sections: "This iPhone" (row "Name" showing the current name, opens R6); "Keep this iPhone up to date" (row "Set up Shortcuts automation" opening the RPT-002 guide; shows a checkmark if RPT-002 reports it is set up, else nothing); "Hidden devices" (list with Unhide); "Data" ("Remove all my data", R12); "About" (version, "Data stays in your iCloud. No analytics."). Done button closes the sheet.
- **R9** Deep link `levels://device/<uuid>` opens the list and pushes that device's detail; an unknown id opens just the list.
- **R10** After a rename, hide, unhide or remove, the app calls `WidgetCenter.shared.reloadAllTimelines()` (free while foreground, ADR-0017).
- **R11** **Old devices** (lead's call, 2026-11-23). Devices with no reading for 30 days (UI-001 R14, ADR-0005) leave the main list and appear in a collapsed "Old devices" section at the bottom of the Devices screen. Each old row has a **Remove** action (swipe and detail button). Remove shows a confirmation: "Remove <name>? It will come back if that device runs Levels again." Confirming calls `DeviceListStore.remove(_:)`, which deletes that record and its accessories (SYNC-001 R15). Nothing is ever removed automatically. This device is never old and can't be removed.
- **R12** **Remove all my data** (lead's call, 2026-11-23; ADR-0019 §6). Settings ▸ "Data" has a destructive "Remove all my data" row. It shows a confirmation that explains the effect: "This deletes every device's battery data from your iCloud. Turn off Levels on your other devices first, or they will add themselves back." Confirming calls `DeviceListStore.removeAllData()` (UI-001, SYNC-001 R15a): the `Levels` zone is deleted, the cache cleared, widgets reloaded, and this iPhone stops reporting. The list then shows a "Reporting is off" banner with **Turn on reporting**, which calls `DeviceListStore.resumeReporting()`: it re-creates the zone and writes only this iPhone's own record. Offline or signed out: an error alert, nothing deleted.

ASCII sketches:

```
 Devices                         Device detail                Settings (sheet)
┌───────────────────────┐      ┌───────────────────────┐    ┌───────────────────────┐
│ Levels           [⚙]  │      │ < Levels              │    │ Settings        [Done]│
│                       │      │                       │    │ KEEP THIS IPHONE UP…  │
│ 📱 iPhone (this)  62%⚡│      │        ╭───╮          │    │ Set up Shortcuts   >  │
│            2 min ago  │      │        │18%│  Low     │    │ HIDDEN DEVICES        │
│ 💻 MacBook Pro 18% Low│ tap→ │        ╰───╯          │    │ Old iPad    [Unhide]  │
│           12 min ago  │      │ MacBook Pro           │    │ ABOUT                 │
│ ⌚ Watch   81%  🕒dim  │      │ Not charging          │    │ Version 0.1           │
│           3 hours ago │      │ Low Power Mode: off   │    │ Data stays in your    │
│   ↓ pull to refresh   │      │ Updated 14:02         │    │ iCloud. No analytics. │
└───────────────────────┘      │ (12 minutes ago)      │    └───────────────────────┘
                               │ [Rename] [Hide]       │
                               └───────────────────────┘
```

## Design

- `LevelsApp` (`@main`) creates one `DeviceListStore` with the app's `DeviceSnapshotSource` (wires SYNC-002 cache + SYNC-001 + RPT-001) and injects it with `.environment(store)`.
- Views in `Levels-iOS`: `DevicesScreen`, `DeviceDetailScreen`, `SettingsSheet`, `HiddenDevicesSection`. All row/gauge views come from `LevelsUI`.
- Navigation: `NavigationStack(path:)` with `[DeviceID]` path; `.onOpenURL` parses `levels://device/<uuid>`.
- Info.plist: `CFBundleURLTypes` with scheme `levels`. Entitlements: App Group, iCloud (owned by SYNC).
- Liquid Glass: use standard `NavigationStack`, toolbar and sheet; no custom backgrounds, so the system applies glass to bars and sheets.
- **Builder's call:** the "set up" checkmark in R8 only if RPT-002 offers a way to know; otherwise omit it.

## Edge cases and failure modes

- No iCloud account → UI-001 `.noICloud` banner; pull to refresh still reports locally and ends quickly.
- Offline → refresh ends after the SYNC-001 error; banner "Couldn't update…"; rows stay.
- Device record deleted while its detail is open → pop back to the list.
- Rename to a very long name → trimmed to 40 characters.
- Two iPhones both called "iPhone" (default names) → both shown, ordered by `deviceId` (UI-001); the Settings "Name" row nudges the owner to rename.

## Acceptance criteria

- [ ] AC1 — Given three cached devices, when the app launches, then the list shows them in UI-001 order within 1 s, before any network call ends.
- [ ] AC2 — Given the list, when the user pulls to refresh, then `refresh()` is called once, the reporter gets reason `.userRefresh` (foreground gets `.foreground`), and the spinner ends within 15 s even if the network hangs.
- [ ] AC3 — Given a row, when tapped, then the detail shows level, charging state, Low Power Mode, absolute and relative update time.
- [ ] AC4 — Given a stale Mac, when its detail opens, then the "hasn't reported" line is shown with the correct age.
- [ ] AC5 — Given "Rename" on this iPhone with "Work Phone", when saved, then `renameThisDevice(to: "Work Phone")` is called; with an empty field, then it is called with `nil` and the name returns to "iPhone". Given another device's detail, then no Rename button is shown.
- [ ] AC6 — Given a device is hidden, then it leaves the list, appears under Settings ▸ Hidden devices, and Unhide restores it.
- [ ] AC7 — Given the URL `levels://device/<id of Mac>`, when opened, then the Mac's detail is shown.
- [ ] AC8 — Given hide/rename, then `reloadAllTimelines()` is called once.
- [ ] AC9 — Given Settings, when "Set up Shortcuts automation" is tapped, then the RPT-002 guide opens.
- [ ] AC10 — Given a Mac last seen 31 days ago, then it is not in the main list and appears under "Old devices"; this iPhone never appears there (R11).
- [ ] AC11 — Given an old device, when Remove is chosen, then a confirmation shows; Cancel changes nothing; Remove calls `remove(_:)` once and the row disappears (R11).
- [ ] AC12 — Given "Remove all my data", when the confirmation is cancelled, then `removeAllData()` is not called; when confirmed, it is called once, the list is empty and the "Reporting is off" banner shows (R12).
- [ ] AC13 — Given reporting is off after R12, when "Turn on reporting" is tapped, then `resumeReporting()` runs once and only this iPhone's row returns (R12).
- [ ] AC14 — Given `removeAllData()` throws (offline), then an error alert shows and the cached rows stay (R12).

## Tests

- Unit (Swift Testing): URL parsing (AC7), rename trimming/reset (AC5), store calls (AC2, AC8, AC11–AC14) with fakes.
- UI tests (XCUITest, simulator): AC1, AC3, AC6, AC9, AC10 with a seeded fake snapshot source selected by a launch argument.
- Real hardware: Remove and Remove all my data against real CloudKit (QA-001 QA1-51…55).
- Previews: each screen in light/dark and with a stale and a low device.
- Real hardware (iPhone): pull to refresh against real CloudKit with the Mac agent running (AC2 end to end); VoiceOver pass through list → detail → settings.

## Open questions

None.
