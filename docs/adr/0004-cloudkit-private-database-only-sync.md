# ADR-0004: Sync only through the CloudKit private database, with our own thin client on raw CKDatabase APIs

- **Status:** Proposed
- **Date:** 2026-11-23
- **Deciders:** project owner
- **Related:** ADR-0005, ADR-0006, ADR-0007, ADR-0008, ADR-0009, ADR-0013, SYNC-001, SYNC-002

## Context

Every device must publish its latest reading (its own battery, plus accessories on the Mac) and read everyone else's. The owner decided: no backend, no analytics, data stays in the user's private iCloud database, latest OS only (iOS/iPadOS/macOS/watchOS 26).

The shape of the data matters more than anything else here:

- About 4–20 records in total. Each one is a few hundred bytes.
- Each record has exactly one writer: the device it describes. Accessory records are the only exception (two Macs may see the same AirPods). See ADR-0005.
- Readers always want *all* records. There are no partial queries.
- Writes happen in short, uncertain windows: a 30-second silent-push wake, a `BGAppRefreshTask`, an App Intent run by a Shortcuts automation, a widget timeline reload. The Mac agent is the only long-running writer.
- Several processes touch the data on one device: the app, widget extensions, App Intents, and (on watchOS) complications.

Verified platform facts:

- `CKSyncEngine` exists on iOS 17+, macOS 14+, watchOS 10+, so on all target OSes. It finds or creates a `CKDatabaseSubscription`, schedules syncs through a system scheduler, listens for pushes itself, retries `networkFailure`, `requestRateLimited`, `zoneBusy` and similar errors, and reports account sign-in, sign-out and switch as events. The app must persist an opaque state serialization and must handle `serverRecordChanged` itself. It needs the CloudKit and remote-notification entitlements. ([CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5), [WWDC23 10188](https://developer.apple.com/videos/play/wwdc2023/10188/))
- Apple's guidance in that session: use `NSPersistentCloudKitContainer` for a full stack, `CKSyncEngine` if you bring your own persistence, and `CKDatabase` operations "if you still think you need more fine-grained control".
- SwiftData sync mirrors to the private database, does not sync immediately, offers no timing control, does not support `unique`, and needs a schema that is additive only after promotion to production. ([Syncing model data](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices))
- `NSUbiquitousKeyValueStore`: 1 MB, 1024 keys, no stated sync timing; it posts `didChangeExternallyNotification` only to a running app. The documentation says it requires App Store / Mac App Store distribution. ([NSUbiquitousKeyValueStore](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore))
- The default zone does not support change fetching or database subscriptions, so anything beyond a plain query needs a custom zone. ([CKDatabaseSubscription](https://developer.apple.com/documentation/cloudkit/ckdatabasesubscription), [CKRecordZone.default()](https://developer.apple.com/documentation/cloudkit/ckrecordzone/default()))

## Decision

Use the **CloudKit private database as the only sync channel**. Build a small `BatterySyncService` actor in the Shared package on the async `CKDatabase` APIs: `modifyRecords`, `recordZoneChanges`, `modifyRecordZones` and `modifySubscriptions`. Do **not** use `CKSyncEngine`, SwiftData+CloudKit or the key-value store in v0.1–v0.2.

Specifics:

1. One custom zone and one record per battery (ADR-0005).
2. Upload: save only our own records, with `savePolicy = .allKeys` (ADR-0008). Each send runs at once and is awaited, so it fits a 30-second wake or an App Intent run.
3. Download: always fetch the **whole zone** (`recordZoneChanges(inZoneWith:since: nil)`). No change tokens are stored. With 20 records or fewer this is one small request. A missing record means it was deleted.
4. Wake-ups come from one `CKDatabaseSubscription` (ADR-0006), plus fallback fetches.
5. The same stateless "fetch all" call is safe from any process (app, App Intent, push wake), because it keeps no sync state. Widgets don't fetch (ADR-0006).
6. A `CloudDatabase` protocol hides `CKDatabase`, so tests use an in-memory fake.

Revisit (with a new ADR) if history (v0.5) or family sharing (later) puts many records or the shared database into sync. At that point `CKSyncEngine` becomes the better fit.

## Options considered

### Option A — Raw CKDatabase async APIs, full-zone fetch, no tokens (chosen)
- Pros: Fully deterministic. A send happens now, not when a scheduler decides, which matters inside short background windows. No persisted sync state, so many processes can read safely and there is no state to corrupt. Easy to fake in Swift Testing. Very little code, because the data is tiny and each record has one writer.
- Cons: We write the subscription bootstrap, push handling (three app-delegate entry points), account-change handling and retry ourselves. This duplicates what `CKSyncEngine` gives for free. It goes against Apple's stated default recommendation. A full fetch costs more than a delta fetch, but the cost is trivial at this size.

### Option B — CKSyncEngine
- Pros: Apple's recommended path. Built-in subscription, push listening, retry with retry-after, account events, batching and pending-change persistence. Works on all target OSes. Apple's sample project exists.
- Cons: Sends and fetches are scheduled by the system and "may be delayed" when power is low or the network is busy. We can force them with `sendChanges()`/`fetchChanges()`, but then we bypass most of what the engine adds. It needs persisted state per process. The app and an App Intents or widget extension would each need their own engine and state, or must never sync outside the app. Conflict handling (`serverRecordChanged`) is still ours. Its strengths (deltas, large batches, offline edit queues) solve problems this app does not have. **Assumption:** how the engine delivers fetched changes when the system wakes the app in the background (and so when we could reload widgets) is not documented clearly enough to rely on without testing.

### Option C — SwiftData with CloudKit mirroring
- Pros: Least code. Local persistence and sync in one.
- Cons: No control over when sync happens ("doesn't immediately synchronize"), which directly hurts freshness. Schema is hidden behind Core Data mirroring names. Sharing one CloudKit-mirrored store between the app and widget processes is risky. No `unique`, so duplicate device rows must be cleaned up by hand. Hard to reason about wake-up and widget reload timing.

### Option D — NSUbiquitousKeyValueStore
- Pros: Trivial API. The size fits (one key per device).
- Cons: No timing guarantee and no background wake-up to receive changes. Only a running app gets the change notification, so widgets and a suspended iPhone app never learn about changes. The docs tie it to App Store distribution, which may conflict with a Developer ID Mac build (ADR-0013).

### Option E — iCloud Drive file per device
- Pros: Simple files.
- Cons: Document sync has no push to a suspended app, uses slow, opaque scheduling, and needs file coordination across devices. No advantage over CloudKit.

## Consequences

- Positive: Predictable timing, small code, easy tests, no sync state to migrate or corrupt.
- Negative / accepted risks: We own retry, account and push plumbing (specified in SYNC-001). If the data grows, we will migrate to `CKSyncEngine`. The schema and zone from ADR-0005 are compatible with that move.
- Follow-ups: The Mac's CloudKit and push entitlements depend on the distribution channel (ADR-0013). Both App Store and Developer ID builds can carry iCloud entitlements through a provisioning profile. **Assumption:** CloudKit works the same for a Developer ID–signed Mac app with a profile; check this once ADR-0013 is decided. All builds the owner uses daily must point at the same CloudKit environment (ADR-0005).

## References

- [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5)
- [WWDC23: Sync to iCloud with CKSyncEngine](https://developer.apple.com/videos/play/wwdc2023/10188/)
- [Sample: sample-cloudkit-sync-engine](https://github.com/apple/sample-cloudkit-sync-engine)
- [Syncing model data across a person's devices (SwiftData)](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)
- [NSUbiquitousKeyValueStore](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore)
- [CKDatabaseSubscription](https://developer.apple.com/documentation/cloudkit/ckdatabasesubscription)
- [CKRecordZone.default()](https://developer.apple.com/documentation/cloudkit/ckrecordzone/default())
- [CKFetchRecordZoneChangesOperation](https://developer.apple.com/documentation/cloudkit/ckfetchrecordzonechangesoperation)
