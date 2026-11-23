---
id: SYNC-001
title: CloudKit sync service
milestone: v0.1
status: Draft
depends_on: [SYNC-002]
adrs: [3, 4, 5, 6, 7, 8, 9]
targets: [Shared, Levels-iOS, Levels-Mac, Levels-Watch, Widgets-iOS, Widgets-Mac, Widgets-Watch]
---

# SYNC-001: CloudKit sync service

## Why

Each device must publish its own battery and see everyone else's, using only the owner's private iCloud database. Sync must work inside short background windows (push wake, background refresh, a Shortcuts-run App Intent) and fail visibly, never silently or by corrupting data.

## Scope

- In: `BatterySyncService` actor; account status handling; zone and subscription bootstrap; upload of own records with `WritePolicy` (ADR-0008); full-zone fetch; cache update and widget reload; push entry points per platform; error and retry policy; Remove device; Remove all my data; entitlements.
- Out: reading batteries and scheduling `BGAppRefreshTask` or App Intents (RPT); Mac accessory discovery (MAC); UI wording and screens (UI); model and cache formats (SYNC-002); alerts (ALR, v0.4).

## Behaviour

Account
- **R1** On `start()` and on every `CKAccountChanged` notification, read `CKContainer.accountStatus()`.
  - `.available`: continue.
  - `.noAccount`: status `.signedOut`.
  - `.restricted`: status `.restricted`.
  - `.temporarilyUnavailable` / `.couldNotDetermine`: status `.waitingForAccount`, retry on the next trigger.
  - In every non-available state: no network calls, keep showing the cache, and keep recording own readings in the cache.
- **R2** When available, fetch the user record ID and compute `accountFingerprint` (SHA-256 of its record name). If it differs from the cache's value, call `SnapshotCache.reset()`, clear the bootstrap flag, and continue as a first run. Data from another Apple ID must never be shown.

Bootstrap
- **R3** If the bootstrap flag for this fingerprint is not set: save zone `Levels` (an existing zone is success), then save `CKDatabaseSubscription(subscriptionID: "levels-private-db")` with `notificationInfo.shouldSendContentAvailable = true` and nothing else. Then set the flag (`SnapshotFile.bootstrappedFingerprint`, SYNC-002). Saving the same subscription ID again is harmless.
- **R4** On `zoneNotFound` or `userDeletedZone` from any call, clear the flag, run R3 once, then retry the failed call once. Own records are re-uploaded (W1 in ADR-0008).

Upload
- **R5** `report(_:reason:)` first writes the reading into the cache's `devices` and, if that changed `devices`, requests a widget reload (R8a), so the own widget is current at once. Then it asks `WritePolicy` (ADR-0008, W1–W9). If a write is due, it uploads now. If held, it keeps the reading in the pending slot and arms a timer for when the interval ends (only while the process lives).
- **R5a** **Urgent reports.** When `reason.isUrgent` is true (`.launch`, `.appIntent`, `.sleep`, `.wake`, `.chargerChange`, `.userRefresh`), `WritePolicy` treats the reading as due now (ADR-0008 W9): it skips the 60 s minimum gap and writes even if nothing changed, but still obeys the 10 s floor (a write inside the floor is held until the floor ends) and, for `.chargerChange`, the 3 s debounce (W2). All other reasons follow W1–W8 unchanged. There is no separate urgent API: urgency comes from the reason. Lead's call (2026-11-23): `.userRefresh` is the reason for a refresh the user asked for (pull to refresh, a refresh button, ⌘R; UI-002 R2, UI-004 R7, UI-005 R4). It writes even if nothing changed, so the device's "updated" age moves, and it respects the 10 s floor. Foreground and popover-open refreshes use `.foreground` (not urgent).
- **R6** Own device record: a fresh `CKRecord`, `savePolicy = .allKeys`. Accessory records: `.ifServerRecordUnchanged` with the last fetched server record. On `serverRecordChanged`, the newer `updatedAt` wins; if ours wins, apply our fields to `serverRecord` and retry once. The own record and its accessories go in one `modifyRecords` call (non-atomic, per-record results).
- **R7** On success, store each accepted model in `lastWritten` and clear the pending slot. The upload itself doesn't request another reload: the reading reached the cache, and its reload, in R5.

Fetch
- **R8** `refresh(_:)` fetches the whole `Levels` zone (`recordZoneChanges(inZoneWith:since: nil)`, following `moreComing`). It maps records with SYNC-002, merges them with `isFullFetch: true`, and sets `lastFetchAt` and `lastFetchOutcome`. Then it requests a widget reload (R8a) **only if** `devices` changed.
- **R8a** **Widget reloads.** Lead's call (2026-11-23): whenever a write changes the cache's `devices` in any field (level, charging, low power, name, `updatedAt` or `readingDate`, an added or removed entry), including the device's own readings (R5), the service requests a reload (ADR-0017 rule 1). `updatedAt` counts because it moves each device's stale moment in the widget timeline. Requests are coalesced to at most one `widgetReloader()` call per 60 s: the first request in a quiet period reloads at once; requests inside the window mark one trailing reload at the window's end (only while the process lives; otherwise the next write or foreground reload covers it). A write that leaves `devices` equal requests nothing. Remove (R15, R15a) uses the same path.
- **R9** Concurrent `refresh` calls in one process share one in-flight fetch.
- **R10** After a successful fetch, if a server record for the own device is missing, or its `updatedAt` is older than `lastWritten`'s, trigger W1 (re-upload).

Push and wake entry points
- **R11** At launch, every app target calls `registerForRemoteNotifications()`. No user permission prompt is needed for silent pushes.
- **R12** `handleRemoteNotification(_:)` returns `.notOurs` unless `CKNotification(fromRemoteNotificationDictionary:)?.subscriptionID == "levels-private-db"`. For ours, it runs `refresh(.push)` and nothing else: it takes no own reading. Lead's call (2026-11-23): the platform's reporter reports its own battery itself, after this returns, with `report(_:reason: .pushWake)` (RPT-001 R8, RPT-004 R7, MAC-001 R9). It must finish within **25 s** (an internal deadline), and returns `.newData`, `.noData` or `.failed`.
- **R13** Fallback triggers (ADR-0006) call `refresh`: app launch (`.launch`), return to foreground (`.foreground`), background refresh (`.backgroundRefresh`), Mac wake (`.wake`), network reachable (`.networkReachable`), and the Mac 15-min fallback timer (`.timer`), which runs only while pushes appear missing (MAC-001 R11). A user refresh (pull to refresh, refresh button, ⌘R) calls `refresh(.userPull)` alongside the reporter's `.userRefresh` report (UI-002 R2).
- **R14** Parked. Lead's call (2026-11-23): v0.1 widgets and complications read the App Group cache only and never fetch from iCloud (ADR-0006). There is no `fetchForExtension`; widget extensions don't link `LevelsSync` and carry no iCloud entitlement. Fetches happen only through R13 (R13's triggers, including network reachable and user refresh) and pushes (R12).

Remove
- **R15** `removeDevice(_:)` deletes the record and every accessory record whose `parentDeviceID` matches, then removes them from the cache. Removing the own device is refused (`.cannotRemoveSelf`). UI-002 R11 calls it from "Old devices".
- **R15a** `removeAllData()` follows ADR-0019 §6: delete the `Levels` zone, delete this device's subscription, reset the cache, reload widgets, then set `reportingEnabled = false` (App Group `UserDefaults` key `reportingEnabled`, default true) so `report` stops uploading. Offline or signed out: throw, change nothing. `resumeReporting()` sets it back to true, clears the bootstrap flag, runs R3 and uploads only this device's own records (W1).

Errors and retry
- **R16** Transient (`networkUnavailable`, `networkFailure`, `serviceUnavailable`, `requestRateLimited`, `zoneBusy`, `accountTemporarilyUnavailable`, `notAuthenticated` while status is available): keep the pending slot. Wait `CKErrorRetryAfterKey` if present, else 30 s × 2ⁿ (n = consecutive failures, cap 15 min), but only while the process lives. Otherwise retry on the next trigger.
- **R17** `partialFailure`: handle each per-record error with R6 and R16. Records that succeeded count as accepted.
- **R18** `quotaExceeded`: status `.iCloudFull`. Stop uploads until the next launch or account change; fetches continue.
- **R19** Configuration errors (`badContainer`, `missingEntitlement`, `permissionFailure`, `invalidArguments`, `serverRejectedRequest`): status `.misconfigured(code)`, logged at fault level, no retry loop.
- **R20** All CloudKit calls use `CKOperation.Configuration` with `timeoutIntervalForRequest = 20 s`. Background-originated calls use `qualityOfService = .utility`; user-initiated ones use `.userInitiated`.
- **R21** Every state change is published on `statusUpdates()`, written to `SnapshotFile.syncStatus` (so widgets can show "iCloud off", ADR-0017), and logged with `Logger(subsystem: "<bundle-prefix>.levels", category: "sync")`. Record names may be logged; device names may not.

## Design

Module `LevelsSync` in the Shared package, depending on `LevelsModel` (SYNC-002). The Foundation-only seam (`SyncStatus`, `ReportReason`, `ReportOutcome`, `BatterySyncing`) lives in `LevelsModel`, so `LevelsReaders` (RPT) and `LevelsUI` can use it without linking CloudKit (ADR-0003).

```swift
public struct SyncConfiguration: Sendable {
    public var containerID: String            // "iCloud.<bundle-prefix>.levels" (placeholder)
    public var appGroupID: String             // per platform, ADR-0009
    public var zoneName = "Levels"
    public var subscriptionID = "levels-private-db"
    public var policy = WritePolicy.Configuration.default   // ADR-0008 constants
}

// LevelsModel
public enum SyncStatus: Sendable, Equatable, Codable {
    case idle, syncing, signedOut, restricted, waitingForAccount, iCloudFull
    case misconfigured(code: Int)
    case offline(lastFetchAt: Date?)
}

public enum ReportReason: String, Sendable, CaseIterable, Codable {
    case launch, foreground, batteryChange, chargerChange, backgroundRefresh, pushWake, appIntent, sleep, wake, heartbeat, userRefresh
    /// R5a, ADR-0008 W9: skip the 60 s minimum gap, keep the 10 s floor. `.userRefresh` = pull to refresh / refresh button / ⌘R.
    public var isUrgent: Bool { [.launch, .appIntent, .sleep, .wake, .chargerChange, .userRefresh].contains(self) }
}
public enum ReportOutcome: Sendable, Equatable { case uploaded, held(until: Date), skipped, failed(retryAt: Date?) }

/// What reporters (RPT-001, RPT-004, MAC-002) depend on; BatterySyncService conforms. Tests fake it.
public protocol BatterySyncing: Sendable {
    func report(_ readings: [DeviceBattery], reason: ReportReason) async -> ReportOutcome
    var status: SyncStatus { get async }
}

// LevelsSync
public enum RefreshReason: Sendable { case launch, foreground, push, backgroundRefresh, wake, networkReachable, timer, userPull }
public enum RemoteNotificationResult: Sendable { case newData, noData, failed, notOurs }

/// Thin seam over CKDatabase/CKContainer so tests use an in-memory fake.
public protocol CloudDatabase: Sendable {
    func accountStatus() async throws -> CKAccountStatus
    func userRecordName() async throws -> String
    func saveZone(named: String) async throws
    func saveDatabaseSubscription(id: String) async throws
    func fetchAll(zone: String) async throws -> [CKRecord]
    func save(_ records: [CKRecord], policy: CKModifyRecordsOperation.RecordSavePolicy) async throws -> [CKRecord.ID: Result<CKRecord, Error>]
    func delete(_ ids: [CKRecord.ID]) async throws
}
public struct CKCloudDatabase: CloudDatabase { public init(containerID: String) }

public struct WritePolicy: Sendable {      // pure; ADR-0008
    public struct Configuration: Sendable { public var minInterval = 60.0, floor = 10.0, debounce = 3.0, levelStep = 5, thresholds = [20, 10], heartbeat = 1800.0; public static let `default` = Configuration() }
    public func decide(new: DeviceBattery, reason: ReportReason, lastWritten: DeviceBattery?, lastWriteAt: Date?, now: Date) -> Decision
    public enum Decision: Sendable, Equatable { case writeNow, writeAt(Date), skip }
}

public actor BatterySyncService: BatterySyncing {
    public init(configuration: SyncConfiguration,
                database: any CloudDatabase,
                cache: SnapshotCache,
                identity: any DeviceIdentityProviding,   // ADR-0007; RPT or Shared implements it
                widgetReloader: @escaping @Sendable () -> Void = { WidgetCenter.shared.reloadAllTimelines() },
                clock: any Clock<Duration> = ContinuousClock(),
                now: @escaping @Sendable () -> Date = Date.init)
    public func start() async                                  // R1–R3, then refresh(.launch)
    public func report(_ readings: [DeviceBattery], reason: ReportReason) async -> ReportOutcome  // own + accessories
    @discardableResult public func refresh(_ reason: RefreshReason) async -> Bool                // R8–R10
    public func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> RemoteNotificationResult  // R12; no own reading, the reporter reports .pushWake after
    public func removeDevice(_ id: DeviceID) async throws(RemoveError)                          // R15
    public func removeAllData() async throws(RemoveError)                                       // R15a, ADR-0019
    public func resumeReporting() async                                                         // R15a
    public var status: SyncStatus { get }
    public nonisolated func statusUpdates() -> AsyncStream<SyncStatus>
}

public protocol DeviceIdentityProviding: Sendable {
    /// Returns nil when the Keychain is not readable yet (before first unlock); the caller skips reporting.
    func currentDeviceID() throws -> DeviceID?
}
```

`userInfo` is not `Sendable`. Each entry point parses it into a `CKNotification` (or just the subscription ID) on the calling actor, before crossing into the service. The signature above is illustrative. **Builder's call:** pass a `String?` subscription ID instead.

Per-platform wiring (in the app targets, not Shared):

| Platform | Push entry | Registration |
|---|---|---|
| iOS / iPadOS | `UIApplicationDelegate.application(_:didReceiveRemoteNotification:) async -> UIBackgroundFetchResult` via `@UIApplicationDelegateAdaptor` | `UIApplication.shared.registerForRemoteNotifications()` |
| macOS | `NSApplicationDelegate.application(_:didReceiveRemoteNotification:)` via `@NSApplicationDelegateAdaptor` | `NSApplication.shared.registerForRemoteNotifications()` |
| watchOS | `WKApplicationDelegate.didReceiveRemoteNotification(_:) async -> WKBackgroundFetchResult` via `@WKApplicationDelegateAdaptor` | `WKApplication.shared().registerForRemoteNotifications()` |

One `BatterySyncService` per app process, created at launch and held by the app (it is not a global singleton, so it can be injected in tests). Widgets and complications use only `SnapshotCache` (read only, R14). App Intents running in the app process use the app's instance. **Builder's call:** if they run in an extension, create a short-lived instance.

Entitlements and Info.plist (placeholders `<bundle-prefix>` = ADR-0003's `<rdns>`, `<TeamID>` = `<TEAMID>`):

| Key | App iOS / iPadOS | App watchOS | Mac agent | Widget / complication ext. |
|---|---|---|---|---|
| `com.apple.developer.icloud-services` = `[CloudKit]` | ✓ | ✓ | ✓ | – (R14: widgets don't fetch) |
| `com.apple.developer.icloud-container-identifiers` = `[iCloud.<bundle-prefix>.levels]` | ✓ | ✓ | ✓ | – |
| `com.apple.developer.icloud-container-environment` = `Production` in every configuration, Debug included (ADR-0005 rule 5; owner decision 2026-11-23) | ✓ | ✓ | ✓ | – |
| `aps-environment` (iOS/watchOS) / `com.apple.developer.aps-environment` (macOS): Debug = `development`; Release, TestFlight and Developer ID = `production` (owner decision 2026-11-23; a development profile only allows `development`) | ✓ | ✓ | ✓ | – |
| `UIBackgroundModes` = `[remote-notification]` | ✓ | ✓ (**Assumption:** a single-target watch app declares it in `UIBackgroundModes` / WKBackgroundModes as Xcode's Background Modes capability writes it) | – (not needed on macOS) | – |
| `com.apple.security.application-groups` (ADR-0003, ADR-0009; lead's call 2026-11-23) | `group.<bundle-prefix>.levels` | same | `<TeamID>.<bundle-prefix>.levels` | same as host (iOS/watch widgets `group.…`, Mac widget `<TeamID>.…`) |
| `keychain-access-groups` (ADR-0007) | `$(AppIdentifierPrefix)<bundle-prefix>.levels.shared` | same | same | same |
| `com.apple.security.app-sandbox` + `com.apple.security.network.client` | – | – | depends on ADR-0013 | macOS widget: required (extensions are sandboxed) |

Widget extensions get no iCloud rows (R14). Experiments that must not touch the owner's data use a separate container or test setup, not the daily container (ADR-0018 §6).

**Assumption:** a Debug build (`aps-environment = development`) still receives the database-subscription silent push for the Production CloudKit container environment. [SPIKE-001](SPIKE-001-debug-build-push-check.md) checks this on a real iPhone before any other v0.1 work. Pass: Xcode debug builds stay the owner's daily builds. Fail: the owner's daily iPhone build comes from TestFlight (ADR-0018 §5); Debug keeps `development`, because a development profile can't carry `production`.

Concurrency: `BatterySyncService` is an actor. `SnapshotCache.update` blocks, so the actor calls it in a detached utility task and awaits it. The widget reloader closure is `@Sendable`. No `@unchecked Sendable` except in `CKCloudDatabase` if CloudKit types require it; any such use needs a comment explaining why.

## Edge cases and failure modes

- **No iCloud account / restricted:** R1. Own readings still show locally. The UI shows a banner (UI spec).
- **Account switched:** R2 wipes the cache and re-bootstraps. The old account's records are untouched on the server.
- **iCloud Drive off but iCloud signed in:** **Assumption:** CloudKit works with the iCloud Drive toggle off but needs the app's iCloud switch on. If it is off, we expect `.noAccount` or `notAuthenticated`, which maps to `.signedOut`.
- **Offline:** uploads stay pending. The cache serves the UI. `.offline(lastFetchAt)` is shown.
- **Push dropped or throttled:** covered by fallback fetches (R13). Freshness comes from `readingDate`, never from push arrival.
- **Force-quit iOS app:** no pushes until relaunch. Widgets keep showing the cache with honest ages (R14) until the app runs again.
- **Background launch before first unlock:** `currentDeviceID()` returns nil. Skip upload, still fetch (the cache file is readable if its protection class allows). **Builder's call:** write the cache with `.completeUntilFirstUserAuthentication` protection.
- **Zone deleted by the user ("Manage Storage → Delete data"):** R4 recreates it. Every device re-uploads on its next sync.
- **Rate limited:** R16 honours retry-after.
- **Two devices with the same ID** (should not happen, ADR-0007): last writer wins; visible as flapping. Out of scope to detect.
- **Clock skew:** handled in SYNC-002 R8.
- **Low Power Mode:** fewer background wakes. No special code; the policy still applies.
- **Mac asleep:** no writes or fetches. On wake: refresh, then report (MAC spec triggers both).

## Acceptance criteria

- [ ] AC1 — Given a fake database with status `.noAccount`, when `start()` runs, then status is `.signedOut`, no zone, subscription, save or fetch call is made, and `report` still updates the cache's own entry (R1, R5).
- [ ] AC2 — Given a cache with fingerprint F1 and devices, when the account's fingerprint is F2, then the cache is reset, bootstrap runs, and no F1 device appears in the cache after refresh (R2).
- [ ] AC3 — Given a fresh install, when `start()` runs twice, then the zone and subscription are each saved once in total (the flag is honoured), and the subscription has `shouldSendContentAvailable == true` and no alert body (R3).
- [ ] AC4 — Given the fake returns `zoneNotFound` on save, when `report` runs, then the zone and subscription are re-saved once and the save is retried once and succeeds (R4).
- [ ] AC5 — Given the last write was 20 s ago at level 80, when a reading of 74 arrives, then the outcome is `.held(until: last+60 s)`, and after the clock advances 40 s exactly one save with level 74 happens (R5, ADR-0008 W4).
- [ ] AC6 — Given charging flips true then false within 2 s, when both readings are reported, then exactly one save happens, with the final state (W2 debounce).
- [ ] AC6a — Given the last write was 20 s ago with the same reading, when a report with reason `.wake` arrives, then it is saved at once; given the last write was 4 s ago, then it is held until 10 s after that write; given reason `.foreground` and the same reading, then nothing is saved; given reason `.userRefresh` and the same reading 20 s after the last write, then it is saved at once (R5a, ADR-0008 W9).
- [ ] AC7 — Given own and two accessory readings, when uploaded, then one save call carries 3 records, the own record with `.allKeys` and the accessories with `.ifServerRecordUnchanged` (R6).
- [ ] AC8 — Given an accessory save fails with `serverRecordChanged` whose server `updatedAt` is newer, then no retry happens and the cache keeps the server version. If ours is newer, one retry carries our fields on the server record (R6).
- [ ] AC9 — Given the zone holds 3 records and the cache holds 4 (one deleted remotely), when `refresh` runs, then the cache holds 3, the widget reloader is called once, and a second identical refresh does not call it (R8).
- [ ] AC9a — Given a refresh that changes only one device's `updatedAt`, then the widget reloader is called once. Given an own `report` that changes the cache 10 s later, then no reload happens at once and exactly one trailing reload happens 60 s after the first; given an own `report` with an unchanged reading, then no reload is requested (R5, R8a).
- [ ] AC10 — Given two concurrent `refresh` calls, then the fake sees one fetch (R9).
- [ ] AC11 — Given a remote notification for another subscription ID, then the result is `.notOurs` and no fetch happens. Given ours, then a fetch happens and the result is `.newData` or `.noData` (R12).
- [ ] AC12 — Given the fake fetch hangs, when `handleRemoteNotification` runs, then it returns `.failed` within 25 s of clock time (R12, R20).
- [ ] AC13 — Given `requestRateLimited` with retry-after 42 s, then the next attempt is not before 42 s, and the pending reading is kept (R16).
- [ ] AC14 — Given `quotaExceeded`, then status is `.iCloudFull`, later `report` calls do not upload, and `refresh` still fetches (R18).
- [ ] AC15 — Given `missingEntitlement`, then status is `.misconfigured` and no retry is scheduled (R19).
- [ ] AC16 — Given `removeDevice(mac)` with two accessories whose parent is the Mac, then three deletes are sent and the cache drops all three. `removeDevice(own)` throws `.cannotRemoveSelf` (R15).
- [ ] AC16a — Given `removeAllData()` succeeds, then the zone delete and subscription delete are sent, the cache is empty, and a later `report` uploads nothing; after `resumeReporting()`, the zone and subscription are saved again and only own records are uploaded. Given the fake is offline, then `removeAllData()` throws and nothing is deleted (R15a).
- [ ] AC17 — Given the widget extension targets, then none links `LevelsSync` or has an iCloud entitlement (build-setting check, R14).
- [ ] AC18 — Integration, **real iCloud account, separate test container (not the daily Production data, ADR-0018 §6), on a Mac or simulator signed in:** saving a fresh `CKRecord` with an existing record name under `.allKeys` overwrites it without error (verifies the ADR-0008 assumption).
- [ ] AC19 — **Real hardware:** with the Mac agent and an iPhone (app in background, not force-quit), when the Mac is unplugged, then within 2 minutes the iPhone's cache shows the Mac `isCharging == false` in most of 10 trials (record the hit rate; push is best effort).
- [ ] AC20 — **Real hardware:** with the iPhone in Airplane Mode, when the app reports, then the own widget shows the new level at once, and after reconnecting and foregrounding the Mac shows it within 2 minutes.
- [ ] AC21 — **Real hardware:** sign out of iCloud on the iPhone, then sign in with a different Apple ID, then open the app: no device from the first account is visible (R2).
- [ ] AC22 — **Real hardware, Production schema:** a TestFlight or release build on two devices syncs with no `unknownItem` or schema errors (ADR-0005 deploy rule).

## Tests

- AC1–AC16 (including AC6a, AC9a, AC16a): Swift Testing unit tests against an in-memory `CloudDatabase` fake and a test clock. They run in `swift test` with no iCloud. AC17 is a build-setting check.
- AC18: an integration test target that runs only when `LEVELS_CLOUDKIT_IT=1` and a signed-in account are present. It needs a signed build with the iCloud entitlement.
- AC19–AC22: manual checks on the owner's devices, recorded in the QA checklist. Simulators cannot reliably receive CloudKit silent pushes or emulate battery state. **Assumption:** recent simulators get CloudKit pushes sometimes; don't rely on them.

## Open questions

- None that block v0.1. The Mac sandbox row follows ADR-0013 (Accepted): sandbox on for v0.1–v0.2, off from v0.3.
