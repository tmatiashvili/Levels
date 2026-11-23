---
id: HIS-001
title: 7-day history, charts and low-power-mode tracking
milestone: v0.5
status: Outline
depends_on: [SYNC-001, SYNC-002, RPT-001, UI-001]
adrs: [4, 5, 8, 9, 17, 18, 19]
targets: [Shared, Levels-iOS, Levels-Mac, Levels-Watch]
---

# HIS-001: 7-day history, charts and low-power-mode tracking

## Why

A single number says where a device is now. A week of levels says how fast it drains, when it is usually charged, and whether the Mac quietly drained overnight. That helps answer "will it last the day?" and spot a battery going bad.

## Scope

- In: per-device level samples for the last 7 days, synced so every device can see every device's history; a chart per device (level over time, charging periods, low-power periods); Low Power Mode on/off tracking.
- Out: predictions ("lasts until 18:00"), battery health/cycle count, history longer than 7 days, export. Accessory history (v0.3 accessories) can reuse the same format later.

## Behaviour

- R1 — Each reporting device records a sample when level, charging or low-power state changes, and at least every 30 min while awake.
- R2 — Samples older than 7 days are dropped. Lead's call (2026-11-23): 7 days.
- R3 — Device detail screen shows a chart of the last 24 h, with a 7-day option. Charging periods and Low Power Mode periods are shaded.
- R4 — Gaps (Mac asleep, iPhone not reporting) show as gaps, not as straight lines.
- R5 — History syncs no more often than the current-level record (ADR-0008); seeing history up to about 30 min late is fine.

## Design

### Facts (verified)

- A CloudKit record's data "must not exceed 1 MB. Assets don't count toward this limit". ([CKRecord](https://developer.apple.com/documentation/cloudkit/ckrecord))
- ADR-0006 uses one `CKDatabaseSubscription`, which fires on a change in any custom zone of the private database, whatever the record type. ([CKDatabaseSubscription](https://developer.apple.com/documentation/cloudkit/ckdatabasesubscription)) So every `DeviceHistory` save also sends a silent sync push to every other device. A separate zone does not avoid this: the database subscription covers every custom zone. Lead's call (2026-11-23): this is an open question (below), with local-only history plus a synced daily summary recommended.

### Size estimate

A sample packed as 4 bytes: minutes since a base time (UInt16 covers 7 days = 10,080 min), level (UInt8), flags (UInt8: charging, low power, gap). Worst case one sample a minute for 7 days = 10,080 × 4 ≈ 40 KB. A realistic 100–300 samples a day ≈ 1–8 KB. Far below 1 MB.

### Storage options

**Option A — One CloudKit record per sample**
- Pros: append-only, no read-modify-write; simple queries by date; history from any device.
- Cons: hundreds to thousands of records per device per week; every sample is a save (adds write load on top of ADR-0008); cleanup means many deletes; fetching a week means paging through many records. **Assumption:** this pushes against CloudKit request rate limits on a busy Mac.

**Option B — Local-only history on each device**
- Pros: no sync cost; best privacy.
- Cons: the iPhone can't see the Mac's history, which is the main use. Rejected for the main feature; fine as the device's own buffer before upload.

**Option C — Ring buffer in one record per device (recommended)**
- New record type `DeviceHistory` (added by ADR-0005), one per device, record name `history-<deviceId>`, written only by that device (single writer, so no conflicts). Fields: `deviceId`, `baseTime` (date), `samples` (bytes, packed as above), `sampleCount`, `updatedAt`.
- The device keeps its buffer in the App Group (ADR-0009), appends samples locally, drops ones older than 7 days, and uploads the whole blob at most every 30 min, or together with a throttled `DeviceBattery` save.
- Other devices fetch `DeviceHistory` when the user opens a detail screen (not in widgets, not on every push).
- Pros: one record per device; a few KB per save; one fetch per device to draw a week; cleanup is just trimming the buffer.
- Cons: whole blob rewritten each upload; a packed format to version (put a version byte first); a lost upload loses only up to 30 min of shared history (the local buffer still has it).

**Option D — Store the buffer as a `CKAsset` on the device record**
- Pros: no 1 MB worry.
- Cons: assets are extra round-trips and storage objects; unnecessary at this size.

**Recommendation:** Option C if full history must sync; use an asset (Option D) only if the format grows past about 500 KB. This depends on the push question under Open questions; if local-only history + daily summary is chosen, Option B becomes the main store and the summary is the only synced part.

### Low-power-mode tracking

- Read `ProcessInfo.processInfo.isLowPowerModeEnabled` and observe `NSProcessInfoPowerStateDidChange`; record a sample on change. **Assumption:** available and accurate on iOS, iPadOS, macOS and watchOS 26 (verify per platform before build-ready).
- The current flag already lives in `DeviceBattery.isLowPowerMode` (README); history adds when it was on.

### Charts

- Swift Charts on all platforms: `LineMark` for level (x: date, y: 0–100), `RectangleMark` bands for charging and low-power spans, break the line at gaps (separate series per continuous segment).
- Pure transforms in `Shared` (decode blob → segments → chart data), unit-tested with Swift Testing (ADR-0018).
- Watch: 24 h only, compact chart.

## Edge cases and failure modes

- Clock change on the reporting device: samples out of order; sort on decode and drop future samples beyond a small tolerance (ADR-0017 clock rules).
- Device reinstalled with a new device ID: the old history record stays until the old device is removed (ADR-0007).
- Format change: version byte; readers skip unknown versions and show "update Levels".
- "Remove all my data" (ADR-0019) deletes history with the zone.
- Privacy: history shows daily routines (when you sleep, when you're at your desk). It stays in the private DB (ADR-0019) and must be called out in any family-sharing consent (FAM-001).

## Acceptance criteria

- [ ] AC1 — Given 7 days and 1 hour of samples, when the buffer is trimmed, then only the last 7 days remain (unit test).
- [ ] AC2 — Given a gap of 2 hours with no samples, when charted, then the chart shows a gap (unit test on segments).
- [ ] AC3 — Given the Mac reported for a day, when the iPhone opens the Mac's detail screen, then a 24 h chart with charging bands appears.
- [ ] AC4 — Given worst-case 1-minute samples for 7 days, then the encoded `samples` field is under 64 KB (unit test).

## Tests

AC1, AC2, AC4 and encode/decode round trips are Swift Testing unit tests. AC3 and low-power tracking need a manual real-device check in a v0.5 QA spec.

## Open questions

- Closed. Lead's call (2026-11-23): 7 days everywhere.
- **History saves push every device.** Each synced history save fires ADR-0006's database subscription on every other device, and a separate zone doesn't help (the subscription covers all zones). Either (a) keep full history local-only on each device and sync only a small daily summary per device (one extra push per device per day), or (b) sync full history (Option C) and accept the extra pushes. Recommended: (a).
- Should widgets show a sparkline? Recommended: not in v0.5; it adds reload cost for little value.
