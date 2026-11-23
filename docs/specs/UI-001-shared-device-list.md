---
id: UI-001
title: Shared device list components and store
milestone: v0.1
status: Draft
depends_on: [SYNC-001, SYNC-002]
adrs: [2, 3, 16, 17]
targets: [Shared]
---

# UI-001: Shared device list components and store

## Why

Every surface in Levels shows the same thing: each device, its level, whether it is charging, and how old the reading is. Building the row, the sorting, the freshness rule and the empty states once keeps every surface consistent and testable without a device.

## Scope

- In: `LevelsModel` presentation helpers (sorting, display preferences; freshness itself is SYNC-002's `FreshnessRule`); `LevelsUI` components (`BatteryRing`, `BatteryBar`, `DeviceSymbol`, `AgeText`, `DeviceRow`, `DeviceList`, `EmptyStateView`, `SyncStatusBanner`); `DeviceListStore`.
- Out: CloudKit, cache format and change notifications (SYNC-001/002); reading the battery (RPT); screen layouts (UI-002…006); widget timeline provider (UI-003).

## Behaviour

- **R1** Sort order (ADR-0016): this device first; then by level ascending, with no-battery devices (`level == nil`) after all others; ties by display name (localised, case-insensitive), then `deviceId`.
- **R2** Hidden devices are not shown anywhere except the "Hidden devices" section of settings. Hiding is local to the device where it was done (v0.1); it does not sync.
- **R3** A device's display name is the record's `name`. Only **this** device can be renamed, in the app: the new name is saved as `DisplayPreferences.thisDeviceName` and reported (SYNC-002 R17, ADR-0008 W8), so it shows on every device. Other devices' names can't be changed here; they are renamed on the device itself. An empty rename resets to the default name (SYNC-002 R17).
- **R4** Freshness is SYNC-002's `FreshnessRule` (ADR-0017 table): iPhone/iPad/Watch stale after 2 h, Mac and accessories after 65 min, a Mac or accessory actively charging (`isCharging` and level < 100) after 30 min; a Mac or accessory full on the charger uses its normal threshold. An iPhone, iPad or Watch keeps its normal 2 h threshold while charging (lead's call 2026-11-23, ADR-0017). Exactly at the threshold counts as fresh.
- **R5** A fresh row shows symbol, name, level as a percentage, ring or bar, `bolt.fill` when charging, `leaf.fill` when Low Power Mode is on, and age text ("5 minutes ago").
- **R6** A stale row shows the same level, dimmed, with a `clock` badge, no charging bolt, and age text. Its accessibility label ends with ", out of date".
- **R5a** **No battery** (`level == nil`, a desktop Mac, ADR-0015): the row shows the `desktopcomputer` symbol, no gauge and no percentage, and the text "Plugged in · no battery" plus age text. Never shown as low. Accessibility label: "<name>, plugged in, no battery, updated <age>".
- **R7** Low = level ≤ 20 % (never for `level == nil`). Low rows tint the gauge red and add the word "Low" (localised) next to the percentage, so colour is not the only cue. Charging tints green.
- **R8** Age text uses `Text(.currentDate, format: .reference(to: updatedAt, allowedFields: [.minute, .hour, .day]))`, so it updates without code. A reading less than a minute old shows "now".
- **R9** Each row is one accessibility element: "<name>, <level> percent[, charging][, low power mode], updated <age>[, out of date]".
- **R10** At Dynamic Type `.accessibility1` and larger, a row stacks vertically (symbol + name on top, gauge + level + age below). Nothing truncates the level.
- **R11** Empty and error states (`DeviceListStore.state`):
  - `.loading` (first load only, before the cache is read): a `ProgressView`, no text.
  - `.empty`: "No devices yet. Install Levels on your other devices, signed in to the same Apple ID."
  - `.onlyThisDevice`: this device's row, then a footer "Other devices appear here when they run Levels."
  - `.noICloud`: last known rows (if any) plus banner "iCloud is off. Turn on iCloud to see your other devices." with a button that opens Settings (iOS/iPadOS: `UIApplication.openSettingsURLString`; macOS: a link to System Settings ▸ Apple Account; watchOS: text only).
  - `.syncError(message)`: last known rows plus a dismissible banner "Couldn't update. Showing the last known levels."
- **R12** The store refreshes when the snapshot source reports a change and on `refresh()` / `refreshOnForeground()`; the list animates row moves.
- **R13** **Accessory grouping (v0.3).** Owner decision (2026-11-23): AirPods are three records (left, right, case) that share `accessoryGroupId` (ADR-0005, ADR-0015). Records with the same `accessoryGroupId` show as **one** row named after the headset (e.g. "AirPods Pro"), with the left, right and case levels side by side; a missing component is left out. The row sorts, and counts as "lowest", by its lowest component. Each component keeps its own age and staleness. Before v0.3 no accessory records exist, so this rule is idle.
- **R14** **Old devices.** Devices with `FreshnessRule.isRetired` (no reading for 30 days, ADR-0005) are left out of `rows` and listed in `oldRows`, in the same order. Screens show them in an "Old devices" section (UI-002 R11). This device is never old.

ASCII sketch of the shared list (compact width):

```
┌──────────────────────────────────────────┐
│ ⚠ iCloud is off. Turn on iCloud…  [Open] │  ← SyncStatusBanner (only when needed)
├──────────────────────────────────────────┤
│ 📱 iPhone (this device)   ◔ 62%  ⚡       │
│                              2 minutes ago│
│ 💻 MacBook Pro            ◔ 18% Low       │
│                             12 minutes ago│
│ ⌚ Apple Watch            ◕ 81%           │
│                              3 hours ago 🕒│  ← stale: dimmed, clock badge
└──────────────────────────────────────────┘
```

## Design

Types (Swift 6, strict concurrency):

```swift
// LevelsModel (Foundation only). Freshness and FreshnessRule are defined in SYNC-002.
public enum DeviceOrdering {
    public static func sorted(_ devices: [DeviceBattery],
                              thisDeviceID: DeviceID?,
                              preferences: DisplayPreferences) -> [DeviceBattery]
}
public struct DisplayPreferences: Codable, Sendable, Equatable {
    public var hidden: Set<DeviceID>        // local to this device (R2)
    public var thisDeviceName: String?      // in-app rename of this device; nil = default (SYNC-002 R17)
}
public protocol DisplayPreferencesStore: Sendable {
    func load() -> DisplayPreferences
    func save(_ p: DisplayPreferences)
}   // default impl: JSON in App Group UserDefaults, key "displayPreferences"

// LevelsUI
public protocol DeviceSnapshotSource: Sendable {
    func current() async throws -> SnapshotFile             // SYNC-002 cache
    func changes() -> AsyncStream<Void>                     // fires after the cache changes
    func requestRefresh(userInitiated: Bool) async throws   // true: reporter .userRefresh + SYNC-001 refresh(.userPull); false: .foreground + refresh(.foreground)
    func setThisDeviceName(_ name: String?) async           // saves DisplayPreferences.thisDeviceName, then reports (W8)
    func remove(_ id: DeviceID) async throws                // SYNC-001 R15
    func removeAllData() async throws                       // SYNC-001 R15a
    func resumeReporting() async                            // SYNC-001 R15a
}
@Observable @MainActor public final class DeviceListStore {
    public enum State: Equatable { case loading, empty, onlyThisDevice, loaded, noICloud, syncError(String) }
    public private(set) var rows: [DeviceRowModel]
    public private(set) var oldRows: [DeviceRowModel]    // R14
    public private(set) var state: State
    public private(set) var isRefreshing: Bool
    public init(source: some DeviceSnapshotSource, preferences: some DisplayPreferencesStore)
    public func start() async          // reads once, then loops over changes()
    public func refresh() async        // user refresh (pull, button, ⌘R): requestRefresh(userInitiated: true), spinner; never throws, maps errors to state
    public func refreshOnForeground() async   // foreground / popover open: requestRefresh(userInitiated: false), no spinner
    public func renameThisDevice(to name: String?) async   // R3; nil or empty resets
    public func setHidden(_ id: DeviceID, _ hidden: Bool)
    public func remove(_ id: DeviceID) async throws      // UI-002 R11 → SYNC-001 R15
    public func removeAllData() async throws             // UI-002 R12 → SYNC-001 R15a
    public func resumeReporting() async                  // UI-002 R12 → SYNC-001 R15a
}
public struct DeviceRowModel: Identifiable, Equatable, Sendable {
    public let id: DeviceID; public let name: String; public let kind: DeviceKind
    public let level: Int?                      // nil = no battery (R5a)
    public let isCharging: Bool; public let isPluggedIn: Bool?; public let isLowPowerMode: Bool
    public let updatedAt: Date; public let isThisDevice: Bool
}
```

- `SnapshotFile`, `DeviceBattery`, `DeviceID`, `DeviceKind`, `Freshness`, `FreshnessRule` and the `ownDeviceID` / `syncStatus` fields come from SYNC-002; `SyncStatus` from SYNC-001. `DeviceListStore.State` maps `.signedOut` / `.restricted` to `.noICloud`. `AgeText` uses `readingDate` (SYNC-002 R8), not raw `updatedAt`.
- Freshness is computed in the view at render time (`TimelineView(.everyMinute)` wraps the list in apps), so a row goes stale on screen without a store update. Widgets get it from timeline entries (ADR-0017).
- Components: `BatteryRing(level:isCharging:isLow:)` = `Gauge` `.accessoryCircularCapacity`; `BatteryBar` = `Gauge` `.linearCapacity` (apps) / `.accessoryLinearCapacity` (accessory families); `DeviceSymbol(kind:)` per ADR-0016 table; `AgeText(updatedAt:)` per R8.
- Strings in `LevelsUI/Resources/Localizable.xcstrings`; percentages with `level.formatted(.percent)` on `Double(level)/100`.
- **Builder's call:** whether `DeviceList` is a `List` or a `LazyVStack`; `List` is preferred for free swipe actions on iOS.

## Edge cases and failure modes

- `level` outside 0…100 → clamp for display, log once.
- `updatedAt` in the future (clock skew) → treat as "now" for age and fresh.
- Device record removed (SYNC) while shown → row disappears with animation; a stale rename/hidden entry for that id is ignored.
- Two devices with the same name → both shown; tie broken by `deviceId`.
- Snapshot source throws on first read → `.syncError`, empty list, banner.
- `ownDeviceID` unknown (first launch before RPT registered) → no row pinned first, and rename is disabled.

## Acceptance criteria

- [ ] AC1 — Given devices iPhone 62 % (this), Mac 18 %, Watch 81 %, iPad 18 % named "Alpha", when sorted, then the order is iPhone, iPad "Alpha", Mac, Watch.
- [ ] AC2 — Given a Mac reading 66 min old and not charging, when freshness is evaluated, then it is `stale`; given 65 min exactly, `fresh`.
- [ ] AC3 — Given a Mac reading 40 min old and charging at 60 %, then `stale`; not charging, then `fresh`; charging (full) at 100 %, then `fresh`. Given an iPhone reading 90 min old and charging at 60 %, then `fresh` (charging doesn't shorten the iPhone threshold).
- [ ] AC4 — Given a device is hidden, when the list renders, then it is not in `rows`.
- [ ] AC5 — Given this device is renamed to "Work Mac", then `setThisDeviceName("Work Mac")` is called once, and once the record carries the name, its row and accessibility label use "Work Mac". Given another device, then no rename action is offered.
- [ ] AC6 — Given a fresh charging Mac at 45 % updated 5 min ago, then the accessibility label is "MacBook Pro, 45 percent, charging, updated 5 minutes ago".
- [ ] AC7 — Given level 20 %, then the row shows "Low"; at 21 %, it doesn't.
- [ ] AC8 — Given the snapshot has no devices and sync status OK, then state is `.empty` and the empty text shows.
- [ ] AC9 — Given sync status `.signedOut` and two cached devices, then both rows and the iCloud banner show.
- [ ] AC10 — Given the source emits a change with a new level, when the store handles it, then `rows` update without calling `refresh()`.
- [ ] AC11 — Given Dynamic Type `.accessibility3`, then the row is stacked and the percentage is fully visible (preview/snapshot).
- [ ] AC12 — Given `updatedAt` 2 min in the future, then the age shows "now" and the device is fresh.
- [ ] AC13 — Given a Mac with `level == nil`, then its row shows `desktopcomputer`, "Plugged in · no battery", no gauge and no "Low", and it sorts after devices with a level (R1, R5a).
- [ ] AC14 — Given AirPods left 40 %, right 35 %, case 80 % sharing one `accessoryGroupId`, then one row shows all three levels and sorts as 35 % (R13).
- [ ] AC15 — Given a Mac last seen 31 days ago, then it is in `oldRows`, not `rows`; at 29 days it is in `rows` (R14).

## Tests

- Unit (Swift Testing, `LevelsModelTests`, `LevelsUITests`, no simulator needed for model tests): AC1–AC10, AC12–AC15. Use a fake `DeviceSnapshotSource` and a fixed `now`; parameterised tests for the freshness table.
- Previews: every `State`, light/dark, Dynamic Type default and `.accessibility3`, a stale row, a low row, a charging row. Previews are required, not optional.
- Snapshot (AC11 and visual states): **Builder's call** whether to add `swift-snapshot-testing` as a test-only dependency; otherwise check previews by hand before each release.
- Real hardware: VoiceOver reading of a row on an iPhone (one manual pass per release).

## Open questions

None.
