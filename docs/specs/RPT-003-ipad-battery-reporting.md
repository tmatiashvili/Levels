---
id: RPT-003
title: iPad battery reporting
milestone: v0.2
status: Draft
depends_on: [RPT-001, RPT-002]
adrs: [10, 11]
targets: [Levels-iOS]
---

# RPT-003: iPad battery reporting

## Why

The iPad is the device most likely to be found flat after days in a drawer. It runs the same app as the iPhone, so it can report the same way. This spec lists only what differs from RPT-001 and RPT-002.

## Scope

- In: iPad differences in device type, triggers, setup guide and tests.
- Out (and where it goes instead): everything shared with iPhone → RPT-001, RPT-002. Device naming and `type` field → SYNC-002 / ADR-0007.

## Behaviour

All rules of RPT-001 and RPT-002 apply unchanged, plus:

- **R1** The reported device's `kind` is `.ipad` when `UIDevice.current.userInterfaceIdiom == .pad`, otherwise `.iphone`. It is passed as `kind` to `BatteryReporter` (RPT-001). The default name is "iPad" (SYNC-002 R17).
- **R2** Multiple scenes (Stage Manager, Split View): reporting is per process, not per scene. Report when the **first** scene becomes `.active`, and submit the refresh request when the **last** scene goes to `.background`. Use the app-level `scenePhase` from the `App` struct, which already aggregates scenes.
- **R3** The setup guide and hint card say "iPad" instead of "iPhone" (use `userInterfaceIdiom`).
- **R4** No other differences: same intent, same Info.plist, same refresh id.

## Design

- No new types. The app passes `kind` from R1 to `BatteryReporter.init` (RPT-001).
- iPad-only apps on Mac ("Designed for iPad") are out of scope; the Mac uses the Mac agent (MAC-*). **Builder's call:** turn off "Designed for iPad" availability on Mac in App Store Connect later.

## Edge cases and failure modes

- **iPad idle for days:** it gets little background refresh and few battery crossings. The record keeps its old `updatedAt`; the UI shows it as stale. This is expected (ADR-0011).
- **Wi-Fi-only iPad away from Wi-Fi:** reports fail; SYNC queues; next trigger retries.
- **Battery Level trigger on iPadOS:** **Assumption:** available and identical to iPhone (ADR-0011). If missing, only the Charger automation and RPT-001 triggers apply; update the guide.
- **iPad without a battery state change for a long time on a charger (always docked):** state stays `.full`; no new reports; correct.

## Acceptance criteria

- [ ] AC1 — Given `userInterfaceIdiom == .pad`, when a `DeviceBattery` is built, then its `kind` is `.ipad`; given `.phone`, then `.iphone`.
- [ ] AC2 — Given two scenes open, when one goes to background and the other stays active, then no refresh request is submitted and no extra report runs; when the last one goes to background, then one request is submitted.
- [ ] AC3 — Given an iPad, when the hint card shows, then its text says "iPad".
- [ ] AC4 — Given a real iPad with a "Charger — Run Immediately" automation, when the charger is plugged in with Levels in the background, then within 2 minutes another device shows the iPad on power.
- [ ] AC5 — Given a real iPad, when Levels opens, then the reported level matches the status bar rounded to 5% (or exact).

## Tests

- **Unit (Swift Testing):** AC1, AC3 (inject the idiom).
- **UI test on iPad Simulator:** AC2 with two windows.
- **Real hardware only:** AC4, AC5 (no battery or automations on Simulator, ADR-0010).

## Open questions

- None.
