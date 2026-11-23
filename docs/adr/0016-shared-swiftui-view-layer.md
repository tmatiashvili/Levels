# ADR-0016: One shared SwiftUI view layer fed by an @Observable store; thin per-platform shells

- **Status:** Proposed
- **Date:** 2026-11-23
- **Deciders:** project owner
- **Related:** ADR-0002, ADR-0003, ADR-0017, SYNC-001, SYNC-002, UI-001…UI-006

## Context

The same information (device, level, charging, age of the reading) appears in seven places: iPhone app, iPad app, Mac menu bar popover, three widget extensions and the watch app. Facts:

- SwiftUI's `Gauge` has built-in styles that fit battery display: `accessoryCircularCapacity` (closed ring, partly filled), `linearCapacity` and `accessoryLinearCapacity` (bar filling leading to trailing), on iOS, macOS and watchOS ([GaugeStyle](https://developer.apple.com/documentation/swiftui/gaugestyle)). Accessory styles are the ones the system tints correctly on the Lock Screen and watch faces.
- In tinted/clear (Liquid Glass) mode, widgets render in `accented` mode: primary and accent content turn white on iOS/macOS, accent content takes the watch-face colour on watchOS ([Optimizing for accented rendering and Liquid Glass](https://developer.apple.com/documentation/widgetkit/optimizing-your-widget-for-accented-rendering-mode-and-liquid-glass)). So colour alone can't carry meaning such as "low" or "charging".
- SF Symbols checked in the system symbol catalogue on macOS 27.2 (`CoreGlyphs.bundle/name_availability.plist`); all exist: `iphone`, `ipad`, `laptopcomputer`, `desktopcomputer`, `macmini`, `display`, `applewatch`, `airpods`, `airpods.pro`, `airpods.max`, `airpods.chargingcase`, `beats.headphones`, `headphones`, `magicmouse`, `computermouse`, `keyboard`, `applepencil`, `bolt.fill`, `battery.0percent`…`battery.100percent`, `battery.100percent.bolt`, `icloud.slash`, `exclamationmark.icloud`, `leaf.fill`. There is **no** trackpad symbol (`trackpad`, `magictrackpad` missing).
- Observation's `@Observable` works on all 26 platforms; Swift 6 strict concurrency requires the UI store to be `@MainActor`.

## Decision

1. **Shared views live in `LevelsUI`** (ADR-0003). Each platform target only supplies a shell: navigation container, toolbar, settings entry, window/scene setup.
2. **One store, `DeviceListStore`** (`@Observable`, `@MainActor`), owns the list state for apps. It reads from a `DeviceSnapshotSource` protocol (implemented in the app by SYNC-002's `SnapshotCache` plus SYNC-001's `BatterySyncService`), never from CloudKit directly. Widgets don't use the store; they call the same pure functions in `LevelsModel` (`DeviceOrdering`, `FreshnessRule`) from their timeline provider. Full API in UI-001.
3. **Battery indicator is built on `Gauge`, not custom drawing.** `BatteryRing` = `Gauge` with `.accessoryCircularCapacity`; `BatteryBar` = `Gauge` with `.linearCapacity` in apps and `.accessoryLinearCapacity` in accessory widgets. Charging adds `bolt.fill`; low (≤ 20 %) adds a text/shape cue, not only red. Tint: green when charging, red when ≤ 20 %, otherwise `.primary`; marked `widgetAccentable()` so accented mode stays legible.
4. **Device symbols** map from the `type` field (SYNC-002):

   | type | Symbol | Notes |
   |---|---|---|
   | iphone | `iphone` | |
   | ipad | `ipad` | |
   | mac (portable, has a battery) | `laptopcomputer` | |
   | mac (desktop, no battery) | `desktopcomputer` | `type = mac` with `level == nil` (MAC-002 R5) |
   | watch | `applewatch` | |
   | accessory: AirPods / Pro / Max / case | `airpods` / `airpods.pro` / `airpods.max` / `airpods.chargingcase` | v0.3; needs a subtype from RPT/SYNC, else `headphones` |
   | accessory: mouse / keyboard / trackpad / other | `magicmouse` / `keyboard` / `rectangle.and.hand.point.up.left` / `battery.100percent` | no trackpad symbol exists |

5. **Sorting (one function, everywhere):** this device first; then the rest by level ascending (the one that needs a charger first); ties by display name (localised, case-insensitive), then `deviceId`. Stale devices keep their position and are only dimmed (ADR-0017), because a dead MacBook that stopped reporting is exactly what the user must see. Devices with no battery (`level == nil`) sort after all devices with a level. Hidden devices are removed. Accessories (v0.3) are listed directly under their parent device and are not sorted on their own.
6. **Accessibility:** every row is one accessibility element with a label like "MacBook Pro, 45 percent, charging, updated 5 minutes ago" (and "out of date" when stale). Dynamic Type up to the accessibility sizes: rows switch from horizontal to stacked layout at `.accessibility1`. Information is never carried by colour alone. Reduce Transparency/Increase Contrast are left to the system materials.
7. **Localisation-ready:** all user-facing text uses String Catalogs (`Localizable.xcstrings` per module, `LocalizedStringResource` in the model). Numbers use `.percent` formatting, dates use `DateReference`/`Date.RelativeFormatStyle`. English is the only shipped language for now.
8. **Design language:** standard SwiftUI containers and materials so the 26 releases apply Liquid Glass themselves; no custom blur or glass imitation. Widgets use `containerBackground(_:for:)` and read `widgetRenderingMode`.

## Options considered

### Option A — `Gauge` with system styles (chosen)
- Pros: correct in accented/vibrant rendering for free; accessibility value built in; less code.
- Cons: limited control over line width and colours in app contexts.

### Option B — custom `Shape` ring and bar
- Pros: full visual control, one look everywhere.
- Cons: must re-implement accented-mode behaviour, accessibility value and vibrancy per family; more snapshot work.

### Option C — per-platform views with no shared layer
- Pros: each platform tuned.
- Cons: seven copies of the same row; drift. Rejected.

## Consequences

- Positive: one row component, one sorting rule, one staleness rule; most UI logic testable without a device.
- Negative / accepted risks: `Gauge` look in app (non-accessory) contexts is less custom. A custom `GaugeStyle` can be added later without changing call sites.
- Follow-ups: SYNC-002 must expose the current device's id and a device subtype for accessories (v0.3).

## References

- [GaugeStyle](https://developer.apple.com/documentation/swiftui/gaugestyle)
- [Optimizing your widget for accented rendering mode and Liquid Glass](https://developer.apple.com/documentation/widgetkit/optimizing-your-widget-for-accented-rendering-mode-and-liquid-glass)
- [SF Symbols](https://developer.apple.com/sf-symbols/)
- [SystemFormatStyle.DateReference](https://developer.apple.com/documentation/swiftui/systemformatstyle/datereference)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
