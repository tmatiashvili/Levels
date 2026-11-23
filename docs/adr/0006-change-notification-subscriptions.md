# ADR-0006: Use one silent CKDatabaseSubscription, and never trust push alone

- **Status:** Proposed
- **Date:** 2026-11-23
- **Deciders:** project owner
- **Related:** ADR-0004, ADR-0005, ADR-0008, ADR-0009, SYNC-001

## Context

README says "a `CKQuerySubscription` on `DeviceBattery` sends a silent push". Before we commit, we must check which subscription types work where, and how reliable silent pushes are.

Verified facts:

| Subscription | Databases | Notes |
|---|---|---|
| `CKQuerySubscription` | public and private | Can be scoped to one zone with `zoneID`. ([doc](https://developer.apple.com/documentation/cloudkit/ckquerysubscription)) |
| `CKRecordZoneSubscription` | **private only** | Fires on any change in the zone you name. ([doc](https://developer.apple.com/documentation/cloudkit/ckrecordzonesubscription)) |
| `CKDatabaseSubscription` | private and shared (not public) | Fires on changes in **custom** zones. The private default zone does not take part. ([doc](https://developer.apple.com/documentation/cloudkit/ckdatabasesubscription)) |

All three exist on watchOS 6+, iOS 10+ and macOS 10.12+.

Silent ("background") pushes ([Pushing background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)):
- `aps` contains only `content-available`. The push type is `background` with priority 5. CloudKit sets these when `notificationInfo.shouldSendContentAvailable = true`. **Assumption:** CloudKit uses exactly these headers; we can't set them.
- "The system treats background notifications as low priority … doesn't guarantee their delivery … may throttle … don't try to send more than two or three per hour."
- The system holds only the **newest** pending background notification. If the app was force-quit, the held notification is discarded.
- The app gets about 30 seconds to handle it.
- The app needs the Background Modes "Remote notifications" capability. watchOS delivers to the watch app's delegate.

Other facts:
- Widget reloads have a daily budget of roughly 40–70 for a widget that is viewed often. Reloads while the containing app is in the foreground don't count. ([Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date))
- **Assumption:** CloudKit does not push to the device that made the change.
- **Assumption:** One `modifyRecords` call (for example a Mac and its accessories) produces at most one push per other device.
- **Assumption:** On macOS a running app (the menu-bar agent) receives silent pushes reliably while the Mac is awake. On watchOS, background delivery is sparser than on iPhone. Apple publishes no numbers for either.

## Decision

1. Each device saves **one `CKDatabaseSubscription`** in the private database, with the fixed ID `levels-private-db` and `notificationInfo.shouldSendContentAvailable = true`. It has no alert, badge or sound, so no notification permission is needed.
2. On any push whose `CKNotification.subscriptionID == "levels-private-db"`: fetch the whole `Levels` zone, write the App Group cache (ADR-0009), then call `WidgetCenter.shared.reloadAllTimelines()` if the data changed (rule 4). The push handler in sync takes no own reading; the device's reporter then reports its own battery with reason `.pushWake`, and ADR-0008 decides whether it is written (lead's call 2026-11-23, SYNC-001 R12). Finish within 25 s.
3. **Push is a hint, not a guarantee.** Fallback fetches:
   - Every app launch and every move to the foreground.
   - Each `BGAppRefreshTask` run (iOS/iPadOS/watchOS background refresh; the RPT spec schedules it).
   - Mac agent: on wake from sleep, on network becoming reachable, and every 15 minutes while awake **only while pushes appear missing** (push registration failed, or no push for 15 minutes; MAC-001 R11, ADR-0014 rule 5).
   - Widgets and complications do **not** fetch. Lead's call (2026-11-23): v0.1 widgets read the App Group cache only and never fetch from iCloud. They don't link `LevelsSync` and have no iCloud entitlement (ADR-0003, UI-003, UI-004). A widget fallback fetch (if `lastFetchAt` is older than 15 min, one stateless 10 s fetch) is parked; reopening it needs a new ADR.
4. Never call `reloadAllTimelines()` when the fetched data is the same as the cache. This saves the widget budget. Any changed field, `updatedAt` included, does reload, coalesced to at most once per 60 s (ADR-0017 rule 1, SYNC-001 R8a).

## Options considered

### Option A — CKDatabaseSubscription (chosen)
- Pros: One subscription covers every custom zone we add later (for example history). The same type works in the shared database for family sharing. It is what `CKSyncEngine` uses, which keeps a migration path open. No predicate to keep in step with the schema.
- Cons: The push carries no record ID, so we always fetch. That is fine, because we fetch the whole zone anyway (ADR-0004). It needs a custom zone (we have one).

### Option B — CKRecordZoneSubscription on `Levels`
- Pros: Private-only and precise. Equivalent for one zone.
- Cons: Needs one subscription per zone. It is not usable in the shared database later.

### Option C — CKQuerySubscription on `DeviceBattery` (README sketch)
- Pros: Works in the private database (verified). Can fire on create, update and delete separately. The payload can carry the record ID.
- Cons: The predicate and fire options are one more thing to get right. It is not usable in the shared database. Per-record notifications add nothing, because we fetch everything anyway. It does not cover future record types.

### Option D — No subscription, polling only
- Pros: Simplest. No push entitlement.
- Cons: A suspended iPhone app or a watch never learns of changes between refreshes. Widgets go stale for hours.

## Consequences

- Positive: One subscription, one handler path, and an honest fallback, so a dropped push costs freshness, not correctness.
- Negative / accepted risks: Silent push throttling ("two or three per hour" guidance) means non-Mac devices often see changes only when opened, on background refresh or when a push gets through. Widgets show only what the app last cached. Every write fans out to N-1 devices, so ADR-0008 must keep writes rare. A force-quit iOS app gets no pushes until it is relaunched.
- Follow-ups: Measure real push delivery per platform on the owner's devices (QA spec). The UI must always show "updated X ago" (README).

## References

- [CKQuerySubscription](https://developer.apple.com/documentation/cloudkit/ckquerysubscription)
- [CKRecordZoneSubscription](https://developer.apple.com/documentation/cloudkit/ckrecordzonesubscription)
- [CKDatabaseSubscription](https://developer.apple.com/documentation/cloudkit/ckdatabasesubscription)
- [CKSubscription.NotificationInfo.shouldSendContentAvailable](https://developer.apple.com/documentation/cloudkit/cksubscription/notificationinfo/shouldsendcontentavailable)
- [Pushing background updates to your app](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
- [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
