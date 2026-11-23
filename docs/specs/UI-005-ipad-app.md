---
id: UI-005
title: iPad app layout
milestone: v0.2
status: Draft
depends_on: [UI-001, UI-002, UI-003]
adrs: [2, 3, 16]
targets: [Levels-iOS]
---

# UI-005: iPad app layout

## Why

The iPad runs the same universal app as the iPhone (ADR-0003). On a large screen a single narrow list wastes space; a grid of device cards reads better. Everything not listed here behaves exactly as UI-002.

## Scope

- In: layout deltas from UI-002 for regular width; windowing and resizing; keyboard shortcuts; iPad as a reporting device.
- Out: anything identical to UI-002; widgets (UI-003 R12 already covers iPad).

## Behaviour

- **R1** Size class decides layout, not device type: compact width (Slide Over, narrow windows) uses the UI-002 list unchanged; regular width uses a grid of cards.
- **R2** Grid: `LazyVGrid` with adaptive columns (minimum 220 pt), cards in UI-001 order. A card is the UI-001 row stacked: symbol + name, large `BatteryRing` with %, state icons, age text. Stale/low/charging rules as UI-001.
- **R3** Tapping a card opens Device detail (UI-002 R4) as a sheet in regular width instead of a push.
- **R4** Pull to refresh works on the grid. Keyboard: ⌘R refreshes (both call `refresh()`, an urgent `.userRefresh` report plus a fetch, as UI-002 R2; foreground uses `refreshOnForeground()` as UI-002 R3), ⌘, opens Settings, arrow keys + Space/Return move through and open cards.
- **R5** The app supports free window resizing and multiple windows on iPadOS 26; all windows share one `DeviceListStore`. **Assumption:** iPadOS 26 windowing needs no extra opt-in beyond supporting all sizes (no `UIRequiresFullScreen`).
- **R5a** Old devices and Remove all my data work as UI-002 R11–R12. In regular width, Old devices is a collapsed section below the grid.
- **R6** This iPad is pinned first and labelled "(this iPad)". Rename works as UI-002 R6 for this iPad only (default name "iPad", SYNC-002 R17); the new name is written to the iPad's own record. Hiding stays local to the iPad.

ASCII sketch (regular width):

```
┌──────────────────────────────────────────────────────────────────┐
│ Levels                                                      [⚙]  │
│ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌───────────┐ │
│ │ 📱 This iPad │ │ 💻 MacBook   │ │ 📱 iPhone    │ │ ⌚ Watch   │ │
│ │   ╭─────╮    │ │   ╭─────╮    │ │   ╭─────╮    │ │  ╭─────╮  │ │
│ │   │ 64% │⚡  │ │   │ 18% │Low │ │   │ 55% │    │ │  │ 71% │🕒 │ │
│ │   ╰─────╯    │ │   ╰─────╯    │ │   ╰─────╯    │ │  ╰─────╯  │ │
│ │ 1 min ago    │ │ 12 min ago   │ │ 40 min ago   │ │ 3 h ago   │ │
│ └──────────────┘ └──────────────┘ └──────────────┘ └───────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

## Design

- `DevicesScreen` switches on `@Environment(\.horizontalSizeClass)`: `.compact` → UI-001 `DeviceList`; `.regular` → `DeviceGrid` (new, in `LevelsUI` so the Mac could reuse it later).
- `DeviceCard` in `LevelsUI`, built from the same parts as `DeviceRow`.
- Keyboard shortcuts via `.keyboardShortcut` on toolbar buttons.

## Edge cases and failure modes

- Window resized across the compact/regular boundary → layout switches without losing an open detail sheet.
- iPad without cellular offline → same as UI-002.

## Acceptance criteria

- [ ] AC1 — Given regular width and four devices, then four cards show in UI-001 order.
- [ ] AC2 — Given compact width (narrow window), then the UI-002 list shows.
- [ ] AC3 — Given a card tap in regular width, then Device detail opens as a sheet.
- [ ] AC4 — Given ⌘R with a hardware keyboard, then `refresh()` is called once.
- [ ] AC5 — Given two windows open, when this iPad is renamed or a device is hidden in one, then the other updates.

## Tests

- Unit: none new beyond UI-001.
- UI tests (iPad simulator): AC1–AC3, AC5.
- Previews: grid at several widths, Dynamic Type `.accessibility3`.
- Real hardware (iPad): AC4 with a keyboard; resize/multiple windows; Lock Screen and Home Screen widgets once.

## Open questions

None.
