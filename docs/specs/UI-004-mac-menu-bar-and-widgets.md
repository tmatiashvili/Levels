---
id: UI-004
title: Mac menu bar content and desktop widgets
milestone: v0.1
status: Draft
depends_on: [UI-001, UI-003, SYNC-002]
adrs: [2, 3, 16, 17]
targets: [Levels-Mac, Widgets-Mac]
---

# UI-004: Mac menu bar content and desktop widgets

## Why

On the Mac the owner wants to see the iPhone, iPad, Watch and (later) AirPods without picking up any of them. The menu bar is always visible; desktop widgets cover the "glance at the desktop" case.

## Scope

- In: what the menu bar label shows, the popover content and its actions, the content of the device window (MAC-001 R2a, the same view as the popover), the Mac widget families and their content.
- Out: the `MenuBarExtra` scene, `LSUIElement`, login item and app lifecycle (MAC-001); the Mac's own battery reading and accessory reading (RPT, MAC-002/003); sync (SYNC).

## Behaviour

Menu bar label:

- **R1** The label shows the device that most needs attention among **other** devices (not this Mac, whose battery macOS already shows): its symbol and level, e.g. `[iphone] 18%`. "Most needs attention" = UI-003 R2 "Lowest battery", excluding this Mac.
- **R2** If that device is stale, the label keeps its symbol but shows the level in parentheses, e.g. `[iphone] (18%)`, to stay short. **Builder's call:** if this reads poorly in the menu bar, show the symbol only.
- **R3** If there are no other devices, the label is the app symbol only (a `battery.100percent` template image).
- **R4** Setting "Menu bar shows: Lowest device (default) / Icon only". With "Icon only", the label is always the app symbol.
- **R5** The label is monochrome (template image + text) so it works on the macOS 26 transparent menu bar. Its accessibility label reads like a row: "Levels: iPhone, 18 percent". **Assumption:** `MenuBarExtra` labels render as template content regardless of colour, as on earlier macOS.

Popover (`.menuBarExtraStyle(.window)`):

- **R6** Width 320 pt, height fits content up to 480 pt, then scrolls. Content top to bottom: the UI-001 `SyncStatusBanner` when needed; the UI-001 `DeviceList` with this Mac first; a footer bar with "Updated <age of newest reading>", a refresh button (`arrow.clockwise`, ⌘R), and a menu (`ellipsis.circle`) with Settings…, Hidden devices, About Levels, Quit Levels (⌘Q).
- **R7** Opening the popover calls `refreshOnForeground()` like UI-002 R3 (reason `.foreground`, no spinner). The refresh button and ⌘R (R6) call `refresh()`: an urgent `.userRefresh` report from MAC-002 plus a fetch, as UI-002 R2.
- **R8** Rows have a context menu: Rename… (this Mac's row only), Hide. Same rules as UI-002 R6/R7: the rename is written to this Mac's own record (default name: the computer name, SYNC-002 R17); hiding is local to this Mac.
- **R9** Settings opens a standard `Settings` window: "Name of this Mac" field (R8), "Menu bar shows" picker (R4), "Open at login" toggle (owned by MAC-001; this spec only places it; on by default), hidden devices list, an **Old devices** list with Remove (UI-002 R11 rules, confirmation required), and **Remove all my data…** (UI-002 R12 rules and confirmation text). Old devices are not shown in the popover list.
- **R10** Keyboard: arrow keys move through rows; Return opens nothing (no detail screen on Mac in v0.1); Esc closes the popover.

Desktop widgets:

- **R11** `Widgets-Mac` offers the same widget kind as UI-003 with families `systemSmall`, `systemMedium`, `systemLarge`, reusing `LevelsWidgetKit` views and provider unchanged. No accessory families (macOS has none for third-party desktop widgets). **Assumption:** `systemExtraLarge` adds nothing useful; skipped.
- **R12** On the Mac the default "Lowest battery" for small excludes this Mac (as R1). The configuration picker still offers this Mac.
- **R13** Desktop widgets follow ADR-0017 refresh and staleness and the macOS 26 tinted/clear widget look (accented mode) as in UI-003 R9–R10.
- **R14** Lead's call (2026-11-23): clicking a desktop widget opens `levels://device/<uuid>` (or `levels://` from a list widget), which launches or activates the Levels app; the app answers by opening its normal **device window** (MAC-001 R2a, a SwiftUI `Window` scene opened through its `levels://` URL handling) showing the popover content with that device scrolled into view and highlighted. It does not open the `MenuBarExtra` popover, which can't be opened from code. An unknown id opens the window at the top. **Assumption:** SwiftUI routes the URL to that window scene on both warm and cold launch (MAC-001 R2a); verify in QA-001.

ASCII sketches:

```
 Menu bar                                Popover (window style)
 … 🔋 [📱18%]  Wi-Fi  🔍  12:41           ┌────────────────────────────────┐
        └─ Levels label                 │ 💻 This Mac        ◕ 76% ⚡     │
                                        │                   2 min ago    │
                                        │ 📱 iPhone          ◔ 18% Low    │
                                        │                   9 min ago    │
                                        │ ⌚ Watch           ◕ 71%  🕒    │
                                        │                   3 hours ago  │
                                        ├────────────────────────────────┤
                                        │ Updated 2 min ago     ⟳   ⋯    │
                                        └────────────────────────────────┘
```

## Design

- `Levels-Mac` provides `MenuBarLabel(store:)` and `MenuBarPopover(store:)` views; MAC-001 places them in `MenuBarExtra(content:label:)` with `.menuBarExtraStyle(.window)`.
- The store is the UI-001 `DeviceListStore`; `MenuBarLabelModel` is a pure function `(rows, thisDeviceID, mode) -> LabelContent` in `LevelsUI`, so it is unit-tested. Devices with `level == nil` are never chosen as "lowest".
- Setting stored in App Group `UserDefaults` key `menuBarMode` (`lowest` | `iconOnly`).
- Liquid Glass: the window-style popover and `Settings` window use system materials. **Assumption:** the 26 `MenuBarExtra` window gets the glass background automatically; no custom `.background`.
- `Widgets-Mac`: `WidgetBundle` with the `LevelsDevicesWidget` from `LevelsWidgetKit`, families limited per R11. App Group entitlement and App Sandbox; no iCloud entitlement. It reads the cache only and never fetches (lead's call 2026-11-23, ADR-0006).

## Edge cases and failure modes

- Mac has no battery (desktop): MAC-002 R5 reports it with `level = nil`; the "This Mac" row shows the UI-001 R5a "Plugged in · no battery" state; label logic unchanged (it never shows this Mac).
- Menu bar overcrowded and the label hidden by the system → nothing to do; widgets and popover still work.
- No iCloud → banner in popover; label shows icon only.
- All other devices stale → label shows the lowest with parentheses (R2).

## Acceptance criteria

- [ ] AC1 — Given this Mac 76 %, iPhone 18 %, Watch 71 % (fresh), when the label renders in "Lowest device" mode, then it shows the iPhone symbol and "18%".
- [ ] AC2 — Given the only other device is stale at 40 %, then the label shows "(40%)".
- [ ] AC3 — Given no other devices, then the label is the app symbol only.
- [ ] AC4 — Given "Icon only", then the label is the app symbol whatever the data.
- [ ] AC5 — Given the popover opens, then this Mac is first and the list matches UI-001 order for the rest.
- [ ] AC6 — Given the refresh button or ⌘R, then `refresh()` is called once.
- [ ] AC7 — Given the desktop small widget with default config, then it shows the lowest **other** device.
- [ ] AC8 — Given VoiceOver on the menu bar item, then it reads "Levels: iPhone, 18 percent".
- [ ] AC8a — Given the Mac widget is clicked, when `levels://device/<id of iPhone>` reaches the app (running or not), then the device window opens in front with the iPhone row highlighted, and the popover stays closed (R14; manual on a real Mac).
- [ ] AC9 — Given a device unseen for 31 days, then it is absent from the popover and listed under Settings ▸ Old devices; Remove asks for confirmation and then calls `remove(_:)` once. Remove all my data asks for confirmation before calling `removeAllData()`.

## Tests

- Unit (Swift Testing): `MenuBarLabelModel` (AC1–AC4), small-widget default excluding this Mac (AC7).
- Previews: label variants; popover in light/dark, empty, iCloud off, with stale rows.
- Real hardware (Mac on macOS 26): label legibility on light and dark wallpapers with the transparent menu bar; popover glass; desktop widget in tinted and clear modes; AC6, AC8 with VoiceOver.

## Open questions

None.
