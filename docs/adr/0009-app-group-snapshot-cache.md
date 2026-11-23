# ADR-0009: Cache the latest snapshot as one atomically replaced JSON file in the App Group container

- **Status:** Proposed
- **Date:** 2026-11-23
- **Deciders:** project owner
- **Related:** ADR-0004, ADR-0006, ADR-0007, ADR-0008, ADR-0013, SYNC-001, SYNC-002

## Context

Widgets and complications must render instantly, without the network. Several processes on one device read and write the same data: the app (or Mac agent), widget extensions, App Intents and push-wake handlers. Each device has its own cache. App Groups do not span devices, so the iPhone and Watch caches are separate.

Verified facts:
- `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` returns the shared container. On iOS it returns `nil` for an invalid group. On macOS it always returns a URL, so we must check that the directory is accessible. The system creates the directory on first use. ([doc](https://developer.apple.com/documentation/foundation/filemanager/containerurl(forsecurityapplicationgroupidentifier:)))
- Group ID format: iOS/watchOS use `group.<name>`. macOS accepts `group.<name>` (needs a provisioning profile) or `<TeamID>.<name>`. Since macOS 15, access to a group container prompts the user unless the app is from the Mac App Store or TestFlight (15.1+), the ID is Team ID–prefixed, or an embedded provisioning profile authorises the group. Since February 2025, Mac profiles (Developer ID included) can authorise `group.` IDs, and Apple recommends `group.` IDs for new code ([Accessing app group containers](https://developer.apple.com/documentation/xcode/accessing-app-group-containers); [forum 721701](https://developer.apple.com/forums/thread/721701)). **Assumption:** this still holds on macOS 26.
- Widget reload budget: about 40–70 per day for a widget viewed often. ([Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date))

## Decision

**Format:** a single file `Levels/snapshot.json` in the App Group container, holding a versioned `SnapshotFile` (schema in SYNC-002):
`formatVersion`, `ownDeviceID`, `accountFingerprint`, `bootstrappedFingerprint`, `lastFetchAt`, `lastFetchOutcome`, `syncStatus`, `devices: [DeviceBattery]`, and `lastWritten: [DeviceID: DeviceBattery]` (the last accepted upload per own record, used by ADR-0008).

**Writes:**
1. Writers: `BatterySyncService` in the app or Mac agent, and App Intents. Widgets only read (ADR-0006). All of them use the one `SnapshotCache` type, which lives in the `LevelsModel` module (Foundation only, ADR-0003) so widget extensions can read it without linking `LevelsSync`.
2. Read-modify-write runs inside an `NSFileCoordinator` write on the file URL. This serializes writers across processes.
3. The new content is written to a temporary file in the same directory, then swapped in with an atomic rename (`Data.write(to:options: .atomic)`). Readers see the old file or the new one, never a partial file.
4. Merge rule: per `deviceId`, keep the entry with the newer `updatedAt`. After a **successful full fetch**, drop entries the server no longer has, except the own device entry while its upload is pending.
5. The own reading is written to the cache **before** the upload starts, and the writer requests a widget reload, so the own widget shows it at once, even offline. Lead's call (2026-11-23): any write that changes `devices` in any field (including `updatedAt` and the device's own writes) requests a reload, coalesced to at most once per 60 s (ADR-0017 rule 1, SYNC-001 R8a). A write that changes nothing requests none.

**Reads:** widgets and complications decode the file in `getTimeline`/`getSnapshot` without coordination. An atomic rename makes that safe. If the file is missing, unreadable or has an unknown `formatVersion`, they render an "Open Levels" placeholder. They never crash.

**Staleness:** the cache stores raw times. The UI computes "updated X ago" per device from `readingDate` (SYNC-002), and "last synced" from `lastFetchAt`. Widgets never fetch, whatever the cache age (ADR-0006).

**Group IDs** (placeholders `<rdns>` and `<TEAMID>` as in ADR-0003; lead's call 2026-11-23):
- iOS, iPadOS and watchOS apps and their widget extensions: `group.<rdns>.levels`
- macOS app and Mac widget extension: `<TEAMID>.<rdns>.levels` (works for App Store and Developer ID with no registration and no prompt; a profile-authorised `group.` ID would also avoid the prompt. Team ID form kept by the lead's call).

**Account change:** if `accountFingerprint` (a hash of the CloudKit user record ID) changes, delete the file and start fresh (SYNC-001).

## Options considered

### Option A — One JSON file, coordinated writes, atomic replace (chosen)
- Pros: Atomic snapshot of all devices. Easy to inspect and test. `Codable` end to end. No database to migrate. Tiny (a few KB).
- Cons: Needs `NSFileCoordinator` for read-modify-write. The whole file is rewritten on every change (trivial at this size).

### Option B — `UserDefaults(suiteName:)`
- Pros: Very simple API. Commonly used with widgets.
- Cons: Cross-process change visibility relies on `cfprefsd` caching, so the timing between processes is not specified. No atomic multi-key update (devices plus `lastFetchAt`). It still needs its own encoding for an array of structs. Apple's docs don't promise when another process sees a write. **Assumption:** widely reported staleness of suite defaults across processes still exists on OS 26.

### Option C — SwiftData store in the App Group
- Pros: Queries, and a natural fit for v0.5 history.
- Cons: A heavy dependency for about 20 rows. Concurrent writers in several processes need care, and schema migrations add risk. Widget extensions have tight memory limits. Better to decide this in the HIS spec for history only.

### Option D — No cache, widgets fetch from CloudKit every time
- Pros: No shared state.
- Cons: Slow and fails offline. Burns network on every reload. Widgets with no network show nothing.

## Consequences

- Positive: Instant widgets, offline display, one source of truth per device, simple tests (write file, read file).
- Negative / accepted risks: Each device's cache is only as fresh as its last fetch. The UI must show the age.
- Follow-ups: the macOS group ID form is settled (lead's call 2026-11-23, Team ID–prefixed; ADR-0013 Accepted Developer ID). v0.5 history may add a separate store (HIS). It must not grow `snapshot.json` beyond about 64 KB.

## References

- [FileManager.containerURL(forSecurityApplicationGroupIdentifier:)](https://developer.apple.com/documentation/foundation/filemanager/containerurl(forsecurityapplicationgroupidentifier:))
- [Accessing app group containers](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)
- [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator)
- [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
- [Developer forums: Sequoia group container prompt (DTS)](https://developer.apple.com/forums/thread/758358)
