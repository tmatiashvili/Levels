---
id: UI-003
title: iPhone and iPad widgets (Home Screen, Lock Screen, StandBy)
milestone: v0.1
status: Draft
depends_on: [UI-001, SYNC-002]
adrs: [2, 3, 16, 17]
targets: [Shared, Widgets-iOS]
---

# UI-003: iPhone and iPad widgets

> **Note (owner decision M, 2026-11-24):** in the free-team hub build, [NET-004](NET-004-iphone-app-and-widgets-local.md) R12–R15 change the empty states, add an "Away from Mac" footer, and pick how the widget gets data: variant A reads the App Group cache as this spec says; variant B fetches from the Mac in `getTimeline` (pending the free-team probe, lead's call 23). Everything else here applies as written.

## Why

The point of Levels is not having to open anything: a glance at the Home Screen, Lock Screen or StandBy should answer "is my MacBook charged?".

## Scope

- In: one widget kind `LevelsDevicesWidget` with families `systemSmall`, `systemMedium`, `systemLarge`, `accessoryCircular`, `accessoryRectangular`, `accessoryInline`; configuration; timeline provider; StandBy; Liquid Glass/accented rendering; deep links. Shared code in `LevelsWidgetKit` so UI-004 and UI-006 reuse it.
- Out: reload triggers inside sync (SYNC-001, rule in ADR-0017); interactive buttons in widgets (none in v0.1); Live Activities; Control Center controls.

## Behaviour

- **R1** Configuration: `AppIntentConfiguration` with `SelectDeviceIntent { device: DeviceChoice }`. `DeviceChoice` is an `AppEntity` with two kinds of value: "Lowest battery" (default) and each known non-hidden device by name. The choice matters only for single-device families (`systemSmall`, `accessoryCircular`, `accessoryInline`); list families ignore it.
- **R2** "Lowest battery" = the non-hidden device with the lowest level among fresh devices (devices with `level == nil` are never chosen); if none are fresh, the lowest among all; if no devices, the empty state. This device is included.
- **R3** Families:

  | Family | Content |
  |---|---|
  | `systemSmall` | one device: symbol + name, large `BatteryRing` with %, age text |
  | `systemMedium` | up to 4 devices in a row of rings, each with symbol, % and short name; one shared age line for the oldest shown reading |
  | `systemLarge` | up to 8 devices as `DeviceRow`s (bar + % + age), UI-001 order; "+N more" if cut |
  | `accessoryCircular` | one device: `Gauge` `.accessoryCircularCapacity`, device symbol as label, % as current value |
  | `accessoryRectangular` | up to 3 devices, one line each: symbol, %, mini `accessoryLinearCapacity` bar; first line in UI-001 order |
  | `accessoryInline` | one device: "[laptop symbol] MacBook 18% · 12m" style text (symbol + short name + % + short age) |

- **R4** List families use UI-001 sort order and hide hidden devices. Stale devices follow UI-001 R6 (dimmed + `clock`); no-battery devices follow UI-001 R5a.
- **R5** Age text per ADR-0017 (`DateReference`); no reload is needed for it to advance.
- **R6** Timeline per ADR-0017: entry now + one per future stale transition (≥ 5 min apart), policy `.atEnd`, or `.after(now + 6 h)` if no transitions.
- **R7** Tapping a single-device widget opens `levels://device/<uuid>`; list widgets use per-row `Link`s in `systemMedium`/`systemLarge` and open the list from accessory families.
- **R8** Empty states (ADR-0017 §6): never run → "Open Levels to start"; iCloud off → `icloud.slash` + "iCloud off" plus any cached rows; only this device → that device + (large/medium only) "Other devices appear when they run Levels". Accessory families show `battery.0percent` symbol and "—" when there is no data.
- **R9** Rendering modes: read `widgetRenderingMode`. In `.accented` (tinted/clear Home Screen) and `.vibrant` (Lock Screen), gauges are `widgetAccentable()`, symbols use `.widgetAccentedRenderingMode(.accented)`, and "Low"/charging are shown with text/symbols because colours turn white. Full colour only in `.fullColor`.
- **R10** `containerBackground(.fill.tertiary, for: .widget)` on system families so the system can swap it for glass. Accessory families use `AccessoryWidgetBackground()` behind circular content.
- **R11** StandBy: `systemSmall` is the StandBy family on iPhone; it must stay legible at StandBy scale and in night mode (red tint). No StandBy-specific code beyond honouring rendering mode. **Assumption:** StandBy picks `systemSmall` widgets and renders them in `.vibrant` in night mode.
- **R12** iPad: the same extension provides the same families on the iPad Home Screen and Lock Screen; UI-005 adds no widget changes.

ASCII sketches:

```
systemSmall          systemMedium                          systemLarge
┌──────────────┐     ┌──────────────────────────────────┐  ┌──────────────────────────┐
│ 💻 MacBook   │     │  📱    💻     ⌚     🎧           │  │ 📱 iPhone   ████████░ 82%│
│   ╭─────╮    │     │ ◕82%  ◔18%   ◕71%   ◑50%        │  │ 💻 MacBook  ██░░░░░░ 18% │
│   │ 18% │Low │     │ iPhone MacBook Watch AirPods     │  │    Low · 12 min ago      │
│   ╰─────╯    │     │ oldest: 12 minutes ago           │  │ ⌚ Watch    ███████░ 71% │
│ 12 min ago   │     └──────────────────────────────────┘  │ 🕒 3 hours ago (dimmed)  │
└──────────────┘                                           │ …  +2 more               │
                                                           └──────────────────────────┘
accessoryCircular   accessoryRectangular            accessoryInline
   ╭────╮           ┌────────────────────────┐      💻 MacBook 18% · 12m
   │ 💻 │           │ 📱 82% ████████░       │
   │18% │           │ 💻 18% ██░░░░░░        │
   ╰────╯           │ ⌚ 71% ███████░        │
                    └────────────────────────┘
```

## Design

- `LevelsWidgetKit` (shared by UI-003/004/006):
  - `DeviceEntry: TimelineEntry { date: Date; snapshot: SnapshotFile?; selection: DeviceChoice; preferences: DisplayPreferences }`.
  - `DevicesProvider: AppIntentTimelineProvider` reads the SYNC-002 `SnapshotCache` synchronously (no network), applies `DisplayPreferences`, builds entries with `FreshnessRule.staleDate(for:)` (SYNC-002).
  - `DeviceChoice: AppEntity` + `DeviceChoiceQuery: EntityQuery` (suggestions from the cache, plus the fixed "Lowest battery" entity).
  - `SelectDeviceIntent: WidgetConfigurationIntent`.
  - Family views: `SmallDeviceView`, `MediumDevicesView`, `LargeDevicesView`, `CircularDeviceView`, `RectangularDevicesView`, `InlineDeviceView`, each taking an entry; all with previews for every state.
- `Widgets-iOS` target: `@main struct LevelsWidgets: WidgetBundle` with `LevelsDevicesWidget` (kind `"LevelsDevices"`), `.supportedFamilies([...R3])`, `.configurationDisplayName("Battery Levels")`, `.description("See the battery of all your devices.")`.
- Entitlements: App Group and the keychain access group (ADR-0007, SYNC-001 entitlements); no iCloud, no push. Lead's call (2026-11-23): widgets read the App Group cache only and never fetch from iCloud (ADR-0006, SYNC-001 R14). Links `LevelsModel`, `LevelsUI`, `LevelsWidgetKit`; never `LevelsSync`/`LevelsReaders` (ADR-0003).
- Placeholder/snapshot: `placeholder(in:)` returns a redacted sample of three devices; the gallery snapshot uses sample data, not the cache.
- **Builder's call:** truncating names in medium widgets (first word vs character limit).

## Edge cases and failure modes

- Selected device later hidden or deleted → fall back to "Lowest battery" behaviour and show its name.
- Cache unreadable (corrupt file) → empty state "Open Levels to start", log the error.
- More than 8 devices in large → "+N more".
- Budget exhausted → widget shows older values but the age text stays truthful (ADR-0017).
- Clock skew (future `updatedAt`) → treated as now (UI-001).

## Acceptance criteria

- [ ] AC1 — Given devices iPhone 82 %, Mac 18 %, Watch 71 % (all fresh) and default config, when `systemSmall` renders, then it shows the Mac at 18 % with "Low".
- [ ] AC2 — Given the small widget configured for the Watch, then it shows the Watch regardless of levels.
- [ ] AC3 — Given 10 devices, when `systemLarge` renders, then 8 rows and "+2 more" show, in UI-001 order.
- [ ] AC4 — Given a Mac reading 20 min old and not charging, when the provider builds a timeline at time T, then it contains an entry at T and one at T+45 min (65-minute Mac threshold, ADR-0017), and the second entry renders the Mac as stale. Given an iPhone full on the charger (`isCharging`, 100 %) 20 min old, then its stale entry is at T+100 min (2 h threshold, not the 30-minute charging one).
- [ ] AC5 — Given no stale transitions in the next 24 h, then the reload policy is `.after(T + 6 h)`.
- [ ] AC6 — Given no cache file, then every family shows its empty state.
- [ ] AC7 — Given `widgetRenderingMode == .accented`, then the low device still shows the word "Low" and the charging device shows `bolt.fill` (preview check).
- [ ] AC8 — Given a tap on the small widget showing the Mac, then the app opens on the Mac's detail.
- [ ] AC9 — Given a hidden device, then no family shows it, and it isn't offered in the configuration picker.

## Tests

- Unit (Swift Testing, `LevelsWidgetKitTests`): selection (AC1, AC2, AC9), large truncation (AC3), timeline entries and policy (AC4, AC5), empty cache (AC6). Provider takes an injected `now` and cache reader.
- Previews: every family × {normal, low, charging, stale, empty, iCloud off} × {fullColor, accented, vibrant}. Use `#Preview(as: .systemSmall)` timelines.
- Real hardware (iPhone): add each family on Home Screen and Lock Screen; check tinted and clear Home Screen; StandBy in night mode (R11); tap deep link (AC8); observe a Mac going stale without opening the app.
- Real hardware (iPad): Home Screen and Lock Screen placement once (R12).

## Open questions

None.
