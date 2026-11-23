# ADR-0008: Write own records only on meaningful change, at most once a minute, last writer wins

- **Status:** Proposed
- **Date:** 2026-11-23
- **Deciders:** project owner
- **Related:** ADR-0004, ADR-0005, ADR-0006, SYNC-001, SYNC-002

## Context

README says "overwrite your own record on change, saving at most about once a minute". We need an exact, testable rule. Every write fans out as a silent push to every other device (ADR-0006). Apple says not to send more than "two or three" background pushes per hour, and throttles beyond that. So each extra write wastes the push budget of the whole fleet.

Verified facts:
- CloudKit rejects excess traffic with `CKError.requestRateLimited`. Any CloudKit error may carry `CKErrorRetryAfterKey`, the number of seconds to wait. ([requestRateLimited](https://developer.apple.com/documentation/cloudkit/ckerror/code/requestratelimited))
- `savePolicy`: `.ifServerRecordUnchanged` (default) compares change tags and fails with `serverRecordChanged`. `.changedKeys` and `.allKeys` do **not** compare change tags. ([savePolicy](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/savepolicy))
- **Assumption:** Apple publishes no numeric per-user CloudKit request limits. A few writes per device per hour is far below any practical limit.
- **Assumption:** iOS `UIDevice.batteryLevel` changes in coarse steps (README says 5%), and macOS IOKit in 1% steps.

## Decision

A pure, testable `WritePolicy` decides, for each new reading of a record, whether to save. "Last written" means the last reading the server **accepted**. It is persisted in the App Group cache (ADR-0009), so the rules hold across processes and launches (app, push wake, App Intent).

| # | Trigger | Write? |
|---|---|---|
| W1 | No last-written reading is known for this record (first run, cache cleared, account changed), or the fetched server copy is missing (deleted, zone recreated) | Yes, now |
| W2 | `isCharging` or `isPluggedIn` changed | Yes, after a **3 s debounce** (so a quick plug and unplug becomes one write). Ignores the min interval. |
| W3 | `isLowPowerMode` changed | Yes, after the 3 s debounce. Ignores the min interval. |
| W4 | `level` differs from the last written level by **≥ 5 points** | Yes, if ≥ **60 s** since the last write; otherwise held |
| W5 | `level` crosses 20 or 10 (either direction) | Yes, if ≥ 60 s since the last write; otherwise held |
| W6 | Heartbeat: last accepted write is ≥ **30 min** old and the process is awake for any reason. Lead's call (2026-11-23): 30 min. | Yes (refreshes `updatedAt`) |
| W7 | Anything else (for example a 1–4 point change) | No. Kept as the pending reading. |
| W8 | `name` changed | Yes, if ≥ 60 s since the last write |
| W9 | **Urgent report** (`ReportReason.isUrgent` in SYNC-001: launch, App Intent, Mac sleep, Mac wake, charger event, user refresh (pull to refresh, refresh button, ⌘R; lead's call 2026-11-23)) | Yes, now, even with no change (refreshes `updatedAt`). Ignores the 60 s min interval; still obeys the 10 s floor; a charger event still waits for the W2 debounce. |

Coalescing:
- One **pending slot** per record. A new reading replaces the pending one (latest wins). A held write fires when its interval ends, and only with the latest reading.
- A Mac's own record and its accessory records go in **one** `modifyRecords` call. Accessory records follow the same rules, judged per record.
- Absolute floor: no record is written more than once per **10 s**, whatever the trigger.

Conflicts:
- **Own device record:** save a fresh `CKRecord` with `savePolicy = .allKeys`. There is only one writer, so last writer wins and `serverRecordChanged` cannot occur. **Assumption:** saving a new `CKRecord` instance with an existing ID under `.allKeys` overwrites the server record without needing its change tag. An integration test checks this (SYNC-001 AC).
- **Accessory records** (may have two writers): save with `.ifServerRecordUnchanged`, using the cached server record. On `serverRecordChanged`, compare `updatedAt`. If ours is newer, copy our fields onto `serverRecord` and retry once. If not, drop our write and keep theirs.

Errors (details in SYNC-001):
- Honour `CKErrorRetryAfterKey` for every error that carries it. Otherwise back off 30 s × 2ⁿ, capped at 15 min.
- A failed write stays in the pending slot. It is retried on the next trigger or wake; nothing is queued on disk. A newer reading simply replaces it.

## Options considered

### Option A — Change-threshold + min interval + heartbeat (chosen)
- Pros: State changes (plug, unplug, Low Power Mode) show up fast. Level drift costs about one write per 5 points. The heartbeat keeps "updated X ago" honest. Bounded fan-out: a Mac discharging 1% every ~5 min writes about every 25 min.
- Cons: Some tuning constants to own. Small level changes lag by up to 5 points.

### Option B — Fixed "once a minute while changed" (literal README)
- Pros: Simplest to state.
- Cons: A Mac's 1% steps would write every few minutes and flood the push budget of the other devices.

### Option C — Write every reading, rely on CloudKit throttling
- Pros: No policy code.
- Cons: Wastes the push budget, invites `requestRateLimited`, and gives no gain to readers.

### Option D — `.ifServerRecordUnchanged` with fetch-merge for own record too
- Pros: Detects any foreign writer.
- Cons: An extra round trip or stored change tags in short wake windows. No benefit, because only one device owns the record.

## Consequences

- Positive: Predictable write rate (typically ≤ 6 per device per hour). Fast plug and unplug updates. A simple conflict story.
- Negative / accepted risks: A dead-but-unlucky device whose last 4% drop was never written shows a slightly high level. Heartbeat writes on iOS happen only when the system wakes the app.
- Follow-ups: v0.4 alerts may change the W5 thresholds; ALR must update this ADR or supersede it. QA measures the real writes per hour.

## References

- [CKError.Code.requestRateLimited](https://developer.apple.com/documentation/cloudkit/ckerror/code/requestratelimited)
- [CKErrorRetryAfterKey](https://developer.apple.com/documentation/cloudkit/ckerrorretryafterkey)
- [CKModifyRecordsOperation.savePolicy](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/savepolicy)
- [CKError.Code.serverRecordChanged](https://developer.apple.com/documentation/cloudkit/ckerror/code/serverrecordchanged)
- [Pushing background updates to your app](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
