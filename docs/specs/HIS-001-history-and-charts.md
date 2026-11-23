---
id: HIS-001
title: 7-day history, charts and low-power-mode tracking
milestone: v0.5
status: Ready
depends_on: [SYNC-002, MAC-002, MAC-003, UI-001, UI-004]
adrs: [3, 8, 9, 10, 14, 16, 17, 18, 19]
targets: [Shared, Levels-Mac]
---

# HIS-001: 7-day history, charts and low-power-mode tracking

## Why

A single number says where a device is now. A week of levels says how fast it drains, when it is usually charged, and whether the Mac quietly drained overnight. That helps answer "will it last the day?" and spot a battery going bad.

## Scope

Build-ready for the Mac-first build (owner decision K): history is **local only** on the Mac (lead's call 19).

- In: a local 7-day history of every accepted report of this Mac and its connected accessories (MAC-002, MAC-003), Low Power Mode included; pruning; a Swift Charts chart per device in the Mac device window; "Remove all my data" and "Remove" delete history too.
- Out: predictions ("lasts until 18:00"), battery health and cycle count, history longer than 7 days, export, widget sparklines, a popover sparkline (R9), history on iPhone, iPad and Watch, and any sync. The synced daily summary is the **Later** section below; it waits for the paid team (owner decision K).

## Behaviour

- R1 — **What is sampled.** Every *accepted report* is a candidate sample, for each reading in it: the Mac's own reading (MAC-002, all reasons, Low Power Mode changes included because `NSProcessInfoPowerStateDidChange` already triggers a report) and each accessory component (MAC-003; AirPods are three records, owner decision E). A report is accepted when reporting is on (SYNC-001 R15a) and sync answers anything but `.failed` — the same rule the reporter uses for its report log. Readings with no level, or from a newer schema, are not sampled.
- R2 — **What a sample holds.** Time (minute precision), level 0–100, charging, plugged in, Low Power Mode, and a "segment ends" flag. Nothing else: no name, no kind, no reason.
- R3 — **Thinning.** A candidate is dropped when its level, charging, plugged-in and Low Power Mode equal the last sample's and it is less than 10 min after it. A candidate in the same minute as the last sample replaces it. So a sample is kept on every change and at least every 30 min while the Mac is awake (the heartbeat, lead's call 6c).
- R4 — **Sleep.** A report with reason `.sleep` sets "segment ends" on its sample (or on the last sample, when thinning drops it), so the line stops where the Mac went to sleep.
- R5 — **Retention.** Samples older than 7 days are dropped (lead's call 6d). Pruning runs at launch, on every write for that device, on every read, and at most once an hour across all devices inside a write. No extra timer (lead's call 10). A device whose newest sample is older than 7 days loses its file.
- R6 — **Size bounds.** At most 10,200 samples per device (one a minute for 7 days is 10,080); beyond that the oldest go. 4 bytes per sample, so at most about 40 KB per device file.
- R7 — **Clock.** A sample more than 5 min in the future is dropped. Samples are kept sorted by time, so a clock set back inserts in order rather than corrupting the file.
- R8 — **The chart.** The device window shows a device's chart when its row is selected: level over time (0–100 %), one line per battery (an AirPods group shows Left, Right and Case), the last 24 h by default with a 7-day option. Charging periods and Low Power Mode periods are shaded bands behind the lines. A legend names the bands (and the lines, when there are several). A summary line gives the low and high of the range.
- R9 — **Gaps.** A line breaks where two samples are more than 45 min apart (1.5 × the 30-min heartbeat; accessories are polled every 5–15 min), or after a sample marked "segment ends". A disconnected accessory or a sleeping Mac shows as empty space, never a straight line across. The last segment is drawn to "now" only when its last sample is less than 45 min old.
- R10 — **Empty.** No samples in the chosen range: the chart area shows "No history yet" and why ("Levels records battery levels while it runs.").
- R11 — **Where it appears.** Mac device window only (UI-004, decision 12). The popover is unchanged: no sparkline in v0.5 (it would change the popover height rules of UI-004 R6 and adds little; the window is one click away). Widgets show no history (lead's call 17: no extra reloads).
- R12 — **Privacy (ADR-0019).** History never leaves the Mac. "Remove all my data" deletes the history folder before it resets the cache; "Remove" on an old device deletes that device's history. Logs carry counts and record names (UUIDs), never device names.

## Design

### Storage (lead's call 19)

One small binary file per device in the app's own **Application Support** folder: `~/Library/Application Support/<bundle id>/History/<record name>.history`. Not the App Group (ADR-0009): only the Mac app writes and reads history, and widgets show none (R11), so the App Group's cross-process coordination buys nothing; keeping it out also keeps `snapshot.json` small (ADR-0009 follow-up: under about 64 KB). Not SwiftData: ADR-0009 Option C leaves the choice to this spec, and for a few thousand fixed-size rows per device a packed file is smaller, needs no schema migration, and tests as plain bytes. The app is unsandboxed (lead's call 16), so the folder is the user's Application Support; the bundle-ID subfolder keeps it the app's own.

File format, version 1 (big-endian):

| Bytes | Field |
|---|---|
| 0 | format version (1) |
| 1–4 | base time: minutes since 2001-01-01 UTC (UInt32) |
| 5… | samples, 4 bytes each: minutes after base (UInt16), level (UInt8), flags (UInt8: bit 0 charging, bit 1 plugged in, bit 2 Low Power Mode, bit 3 segment ends) |

Base time is the first sample's minute, so offsets stay under 10,080 (UInt16 holds 45 days). An unknown version or a truncated file reads as empty history and is replaced on the next write (logged as an error).

### Types (Shared)

- `LevelsModel/History`: `HistorySample` (value), `HistoryCodec` (bytes ↔ samples), `HistoryPolicy` (constants and the pure `appending`/`pruned` rules of R3–R7), `HistoryStore` (actor: one file per device, in-memory cache, `record(_:reason:)`, `samples(for:)`, `remove(_:)`, `removeAll()`, `pruneAll()`), and `HistoryRecordingSync`, a `BatterySyncing` decorator that records accepted reports (R1) and passes everything else through. Foundation only (ADR-0003).
- `LevelsUI`: `HistoryChartModel` (pure: samples per battery → line segments, bands, domain, summary; unit-tested), `HistoryRange` (`.day`, `.week`), and `DeviceHistoryView` (Swift Charts: `LineMark` per segment, `PointMark` for single-sample segments, `RectangleMark` bands; ADR-0016).
- `Levels-Mac`: `MacAppModel` builds the store, wraps the sync (`LoggingSync(base: HistoryRecordingSync(base: local, …))`), deletes history in "Remove all my data" and "Remove"; `DeviceWindowView` wraps the list in a `NavigationStack` whose rows push `DeviceHistoryView`.

### Chart design

- Lines 2 px; categorical slots in fixed order (blue, orange, aqua) for Left, Right, Case; a single device uses slot 1. Bands are washes: charging green, Low Power Mode yellow, about 15 % opacity. Text stays in primary and secondary ink. Y axis 0, 50, 100 %; hairline grid.
- An AirPods group shades charging when any component charges (the buds charge only in the case).
- Accessibility: the chart has a summary label; the legend names every colour, so colour is never the only cue.

### Concurrency

`HistoryStore` is an actor; file I/O is small (≤ 40 KB) and runs on it. `HistoryRecordingSync` records after the base report returns, inside the reporter's own serial report, so "Remove all my data" (which stops and drains both reporters first) never races a recording.

## Edge cases and failure modes

- Clock change: R7. Samples out of order are inserted sorted; future ones dropped.
- Mac asleep or app quit: no samples, so a gap (R9).
- Accessory disconnected: its reports stop, so a gap; reconnect starts a new segment.
- Accessory record IDs are stable (UUIDv5, lead's call 2), so history survives reconnects and relaunches.
- File unreadable or newer format: treated as empty, replaced on next write.
- Disk full or write failure: logged; the in-memory copy keeps the sample and the next write retries.
- Reporting off (after "Remove all my data"): nothing is recorded.

## Acceptance criteria

- [ ] AC1 — Given 7 days and 1 hour of samples, when pruned, then only the last 7 days remain (unit test).
- [ ] AC2 — Given a gap of 2 hours with no samples, when charted, then the chart has two segments (unit test on segments).
- [ ] AC3 — Given a `.sleep` sample followed 30 min later by a `.wake` sample, when charted, then the line breaks after the sleep sample (unit test).
- [ ] AC4 — Given worst-case 1-minute samples for 7 days, then the encoded file is under 64 KB and decodes to the same samples (unit test).
- [ ] AC5 — Given an accepted report with this Mac and three AirPods components, then four device histories gain a sample; given a `.failed` report or reporting off, then none does (unit test).
- [ ] AC6 — Given two identical readings 5 min apart, then one sample is kept; 10 min apart, two (unit test). A Low Power Mode change is always kept.
- [ ] AC7 — Given history on disk, when "Remove all my data" runs, then the history folder is gone and the next read is empty (unit test on the store; manual on the Mac).
- [ ] AC8 — Given charging from 10:00 to 11:00, when charted, then one charging band spans 10:00–11:00 (unit test).
- [ ] AC9 — Given a sample 10 min in the future, then it is dropped (unit test).
- [ ] AC10 — Given the Mac reported for a day, when its row is selected in the device window, then a 24 h chart with charging bands appears; the 7-day option widens it (manual).

## Tests

AC1–AC9 are Swift Testing unit tests in `LevelsModelTests` and `LevelsUITests` (ADR-0018). AC10 and the look of the chart are checked by rendering fixtures (normal, charging, gaps, AirPods, empty) to PNG and on the Mac.

## Later: synced daily summary (not built)

When the paid team arrives and CloudKit sync ships (SYNC-001), other devices may get a **daily summary** per device, not the full history: lead's call 3 recommends it because every history save would push every device through the database subscription (ADR-0006; a separate zone doesn't help). Sketch, to be decided then:

- One `DeviceDaySummary` per device per day (min, max, time charging, time in Low Power Mode, sample count), saved once a day with the next throttled `DeviceBattery` write, so at most one extra push per device per day.
- The full history stays local on each device (this spec). An iPhone shows the Mac's week as daily bars, not a line.
- Option C of the earlier outline (one ring-buffer record per device) stays the fallback if the owner wants full synced history and accepts the extra pushes.
- "Remove all my data" deletes summaries with the zone (ADR-0019 §6).

## Open questions

- None for the Mac-first build. The synced summary's shape is decided when SYNC-001 starts.
