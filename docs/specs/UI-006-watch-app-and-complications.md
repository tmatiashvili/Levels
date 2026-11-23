---
id: UI-006
title: Watch app and watch widgets (complications and Smart Stack)
milestone: v0.2
status: Draft
depends_on: [UI-001, UI-003, SYNC-001, SYNC-002]
adrs: [2, 3, 16, 17]
targets: [Levels-Watch, Widgets-Watch]
---

# UI-006: Watch app and watch widgets

## Why

The wrist is the quickest glance of all: a complication showing the MacBook or iPhone level means never wondering before leaving the house.

## Scope

- In: watch app list and detail; the watch widget extension (`Widgets-Watch`, formerly the README's `Complications/`, ADR-0003) with families `accessoryCircular`, `accessoryCorner`, `accessoryRectangular`, `accessoryInline`, shown on watch faces and in the Smart Stack.
- Out: watch battery reading and reporting (RPT); watch sync and push (SYNC); Live Activities and controls.

## Behaviour

Watch app:

- **R1** One `NavigationStack` with a `List` of compact rows (symbol, short name, %, gauge bar; age on a second line). UI-001 order, with this watch first, hidden devices removed (hidden list is per device; the watch has its own). Old devices (UI-002 R11) are left out; they are removed from iPhone, iPad or Mac.
- **R2** Tapping a row opens a detail: large `BatteryRing`, level, charging (or "Plugged in · no battery", UI-001 R5a), age. Names come from each device's record, so renames done on the iPhone, iPad or Mac show here. This watch's own detail has "Rename" (text input or dictation, UI-002 R6 rules; default "Apple Watch", SYNC-002 R17), written to the watch's record. No hide on the watch in v0.2: hiding is local per device, and the watch's hidden set is empty.
- **R3** Opening the app or bringing it to the foreground triggers `refreshOnForeground()` (reason `.foreground`, UI-002 R3); the Digital Crown scrolls the list; no pull to refresh on watchOS, so the watch never sends `.userRefresh`.
- **R4** Empty/no iCloud/error states per UI-001 R11 in short form: "No devices yet", "iCloud off", "Couldn't update".

Watch widgets:

- **R4a** Operating assumption (owner decision, 2026-11-23): the owner keeps a Levels complication on the daily watch face, which gives the watch app its background refresh budget (ADR-0012, RPT-004).
- **R5** One widget kind (same `LevelsWidgetKit` provider and `SelectDeviceIntent` as UI-003; default "Lowest battery", including this watch, excluding devices with no battery).

  | Family | Where | Content |
  |---|---|---|
  | `accessoryCircular` | faces, Smart Stack small slots | `Gauge` `.accessoryCircularCapacity`, device symbol, % |
  | `accessoryCorner` | corner of faces that support it | device symbol in the corner, `Gauge` in `.widgetLabel` with % |
  | `accessoryRectangular` | Smart Stack and faces | up to 3 devices: symbol, %, `accessoryLinearCapacity` bar; age of the oldest shown |
  | `accessoryInline` | faces with an inline slot | "💻 18% · 12m" |

- **R6** Staleness, age text and timelines per ADR-0017. Accented content takes the watch-face colour; `fullColor` image rendering is ignored on watchOS, so meaning is carried by symbols/text, as in UI-003 R9.
- **R7** Smart Stack: provide `TimelineEntryRelevance` with a higher score when the shown device is ≤ 20 % and not charging, so the stack can surface it. **Assumption:** this hint affects Smart Stack ordering on watchOS 26; Apple also added newer relevance APIs in watchOS 26 that are not adopted here.
- **R8** Tapping any watch widget opens the watch app list (deep link to detail is optional, **Builder's call**).

ASCII sketches:

```
 Watch app list          accessoryRectangular       accessoryCircular   accessoryCorner
┌──────────────────┐   ┌─────────────────────┐        ╭────╮           ╭──── 18%
│ ⌚ This Watch 71%│   │ 💻 18% ██░░░░░░     │        │ 💻 │           │ 💻
│   ███████░ 2m    │   │ 📱 55% █████░░░     │        │18% │
│ 💻 MacBook 18%   │   │ ⌚ 71% ███████░     │        ╰────╯
│   ██░░░░ Low 12m │   └─────────────────────┘
│ 📱 iPhone  55%   │
│   █████░ 40m     │   accessoryInline:  💻 18% · 12m
└──────────────────┘
```

## Design

- `Levels-Watch`: `@main` app creates a `DeviceListStore` with the watch's `DeviceSnapshotSource` (SYNC-002 cache + SYNC-001 on watchOS); views `WatchDeviceList`, `WatchDeviceDetail` built from `LevelsUI` parts (`DeviceSymbol`, `BatteryBar`, `BatteryRing`, `AgeText`).
- `Widgets-Watch`: watchOS widget extension embedded in the watch app ([Creating accessory widgets and watch complications](https://developer.apple.com/documentation/widgetkit/creating-accessory-widgets-and-watch-complications)); `WidgetBundle` with the shared `LevelsDevicesWidget` and families per R5. App Group entitlement shared with the watch app (`group.<rdns>.levels`, ADR-0003); no iCloud entitlement. It reads the cache only and never fetches (lead's call 2026-11-23, ADR-0006).
- `accessoryCorner` view uses `.widgetCurvesContent()` for the label and `.widgetLabel { Gauge… }`. **Builder's call:** exact corner layout after checking on a real face.
- Text sizes from the system; no custom fonts.

## Edge cases and failure modes

- Watch offline (no phone, no Wi-Fi) → shows cache with honest ages; widgets go stale on schedule.
- Watch never synced (iCloud not set up on watch) → "Open Levels on your watch" in widgets, "iCloud off" in app.
- Very small face slots → `accessoryCircular` shows % only if the symbol doesn't fit (**Builder's call**).

## Acceptance criteria

- [ ] AC1 — Given this watch 71 %, Mac 18 %, iPhone 55 %, when the app opens, then rows are Watch, Mac, iPhone.
- [ ] AC2 — Given default config, when `accessoryCircular` renders, then it shows the Mac at 18 %.
- [ ] AC3 — Given four devices, when `accessoryRectangular` renders, then it shows the first three in UI-001 order.
- [ ] AC4 — Given a Mac reading 25 min old and not charging, when the timeline is built at T, then an entry at T+40 min renders it stale (65-minute Mac threshold, ADR-0017).
- [ ] AC5 — Given the Mac at 18 % not charging, then the entry relevance score is higher than when it is at 60 %.
- [ ] AC6 — Given no cache, then every family shows its empty state.

## Tests

- Unit (Swift Testing): shared provider tests from UI-003 extended with watch families (AC2–AC6).
- Previews: each family × {normal, low, charging, stale, empty} in accented rendering.
- Real hardware (Apple Watch on watchOS 26): add each family to a face that supports it; Smart Stack appearance and relevance (R7); app list scroll with Digital Crown; VoiceOver on a complication.

## Open questions

- Should hiding sync between devices (so the watch follows the iPhone)? Renames already sync, because each device writes its own name to its record. Recommended: yes, later, by SYNC storing the hidden set in iCloud; until then the watch hides nothing.
