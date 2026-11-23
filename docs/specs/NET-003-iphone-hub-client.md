---
id: NET-003
title: iPhone hub client and reporting to the Mac
milestone: free-team   # owner decision M
status: Ready
depends_on: [NET-001, NET-002, SYNC-002, UI-001]
adrs: [3, 6, 8, 9, 11, 17, 19, 20]
targets: [Shared, Levels-iOS]
---

# NET-003: iPhone hub client and reporting to the Mac

## Why

The iPhone must show the Mac's battery and accessories, and the Mac must show the iPhone's, with no iCloud. This spec is the iPhone half of ADR-0020: a `LocalNetworkSyncService` behind `BatterySyncing`, so RPT-001's reporter and UI-001's store work unchanged.

## Scope

- In: `HubClient` (find, connect, fetch, post, long-poll) in `LevelsNet`; `LocalNetworkSyncService` in `LevelsSync`; the triggers that call it; the away state; the iPhone app's composition root for the free-team build; Info.plist keys.
- Out (and where it goes instead): pairing → NET-002. Screens, banners and widget behaviour → NET-004. The reporter itself and its triggers → RPT-001 (unchanged). The "Report Battery" intent → RPT-002 (unchanged, it calls the same sync).

## Behaviour

- **R1** The free-team iPhone app wires `BatteryReporter` (RPT-001) → `LocalNetworkSyncService` → App Group `SnapshotCache` (or the app container if the App Group is missing, as `MacAppModel` does). `BatterySyncService` (SYNC-001) is not built into this app.
- **R2** `report(_:reason:)` hands the readings to the inner `LocalOnlySyncService` first (own cache write, ADR-0008 throttling, SYNC-001 R8a widget reload). Every own value that reaches the cache, now or from a held flush, goes into one **outbox** slot (latest wins). The service then sends the outbox (R4) if the hub is reachable. `report` returns the inner outcome; the send never blocks it for more than 5 s.
- **R3** `refresh(_:)` fetches `GET /v1/snapshot` with the last ETag. On `200` it calls `ingest(devices, replacingAllExcept: [ownID])` (NET-001 Design), stores the new ETag, and sets `lastFetchAt` = now and `syncStatus = .localOnly`. On `304` it sets `lastFetchAt` and the status only. It also sends the outbox if it holds anything. Returns whether the cache is usable.
- **R4** Sending: `POST /v1/readings` with the outbox value and the `Levels-Device` header. `204` clears the slot if it still holds the same value. Any failure keeps it. No retry timer: the next trigger (R6) tries again.
- **R5** Finding the Mac: an `NWBrowser` for `_levels._tcp` looks for the paired hub's tag. Found within 5 s: connect to that service endpoint. Not found, or the connection doesn't become ready within 5 s: status `.awayFromHub(lastContactAt: lastFetchAt)`, written to the cache (NET-004 shows it). The browser is cancelled when the call ends, except during live updates (R7).
- **R6** Triggers (RPT-001 and SYNC-001 R13, unchanged in name): launch, foreground, pull to refresh (`.userPull`), background refresh, the "Report Battery" intent, and network reachable (`NWPathMonitor` sees Wi-Fi become satisfied while the app runs). Each calls `report` and/or `refresh` as today. Push triggers don't exist (no push on the free team).
- **R7** **Live updates** (lead's call 22). While the scene is `.active` and the iPhone is paired, one task loops `GET /v1/snapshot?wait=25` with `If-None-Match`, over one kept-alive connection. Each `200` is handled as in R3. On an error it waits 5 s, then 15 s, then 60 s (cap), and retries while still active. It stops when the scene leaves `.active`.
- **R8** Background refresh (RPT-001 R6, R7): the task reports, then refreshes, with a total limit of 20 s, then completes. The Local Network permission covers background runs. **Assumption:** checked on hardware (AC10).
- **R9** Errors and status:

  | What happened | Status | Kept |
  |---|---|---|
  | No pairing stored | `.notPaired` | cache as is |
  | Hub not found / not ready in 5 s | `.awayFromHub(lastContactAt:)` | cache, outbox |
  | TLS handshake fails with a stored key | `.misconfigured(code: 401)`; NET-004 shows "This Mac no longer knows this iPhone. Pair again." | cache |
  | Local Network permission denied (browse fails with policy denied) | `.restricted`; NET-004 shows the Settings fix | cache, outbox |
  | Protocol version in TXT or body differs | `.misconfigured(code: 426)`; "Update Levels on your Mac and iPhone." | cache |
  | `403` on POST | logged at fault level; slot dropped | cache |

  Each status is written to `SnapshotFile.syncStatus` (SYNC-001 R21) so widgets can read it.
- **R10** `removeAllData()` (UI-002 R12 in hub mode, lead's call 28): needs the Mac. It calls `DELETE /v1/devices/me`. Only after `204` does it reset the cache, clear the outbox, reload widgets and turn reporting off. Not reachable: throws `.notReachable`, nothing changes. `resumeReporting()` turns reporting on; the next report writes and sends at once.
- **R11** Own-record rules: the iPhone never sends any record but its own (NET-001 R9). After a full ingest the own record always stays (R3 keep set). If the snapshot's copy of the own record is newer than the cache's (should not happen), the newer one wins by SYNC-002 R14 anyway.
- **R12** Logging (ADR-0019 rule 3): status changes, routes, codes, the hub tag and device IDs may be public. Names, bodies and keys are never logged.

## Design

**`LevelsNet`:**

```swift
public struct HubPairing: Codable, Sendable, Equatable {
    public var hubID: UUID; public var hubTag: String; public var hubDeviceID: DeviceID
    public var hubName: String; public var key: Data; public var pairedAt: Date
}

public protocol HubTransport: Sendable {            // fake in tests; real one uses NWBrowser + NWConnection
    func send(_ request: HTTPRequest, to pairing: HubPairing, me: DeviceID,
              timeout: Duration) async throws(HubError) -> HTTPResponse
}
public enum HubError: Error, Equatable { case notFound, notReady, handshakeRefused, localNetworkDenied, versionMismatch, timedOut, badResponse(Int) }

public actor HubClient {
    public init(transport: any HubTransport, pairing: any ClientPairingStore, me: DeviceID)
    public func snapshot(ifNoneMatch: String?, wait: Duration?) async throws(HubError) -> HubFetch   // .changed(HubSnapshot, etag) | .notModified(etag)
    public func post(_ record: DeviceBattery) async throws(HubError)
    public func deleteMe() async throws(HubError)
    public func forget() async throws(HubError)
}
```

**`LevelsSync`:**

```swift
public actor LocalNetworkSyncService: BatterySyncing {
    public init(local: LocalOnlySyncService, client: HubClient?, pairing: any ClientPairingStore,
                now: @escaping @Sendable () -> Date = Date.init, clock: some Clock<Duration> = ContinuousClock())
    public var status: SyncStatus { get }                                          // R9
    public func report(_ readings: [DeviceBattery], reason: ReportReason) async -> ReportOutcome   // R2
    @discardableResult public func refresh(_ reason: RefreshReason) async -> Bool  // R3, R5
    public func startLiveUpdates() async                                           // R7
    public func stopLiveUpdates() async
    public func removeAllData() async throws(HubError)                             // R10
    public func resumeReporting() async
    public func statusUpdates() -> AsyncStream<SyncStatus>
}
```

- `LocalOnlySyncService` gets one more init parameter, `onOwnWrite: @Sendable ([DeviceBattery]) -> Void = { _ in }`, called after each successful own write (direct or held flush). `LocalNetworkSyncService` uses it to fill the outbox (R2). The Mac passes nothing.
- `SyncStatus` gains `.notPaired` and `.awayFromHub(lastContactAt: Date?)` (lead's call 24). App and widget ship together, so an older widget never reads a newer cache. `DeviceListStore.State` maps them in NET-004.
- The ETag is kept in memory and in App Group `UserDefaults` key `net.etag`.
- `LevelsNet` never imports `LevelsSync`; `LevelsSync` imports `LevelsNet`. Widgets may link `LevelsNet` only (NET-004 variant B; ADR-0003 rule kept).
- **Info.plist (`Levels-iOS`):** `NSBonjourServices = ["_levels._tcp"]`; `NSLocalNetworkUsageDescription = "Levels connects to your Mac on this Wi-Fi to show its battery and your accessories, and to send this iPhone's battery to the Mac."`; `UIBackgroundModes = ["fetch"]` and `BGTaskSchedulerPermittedIdentifiers` as in RPT-001.
- **Entitlements for the free-team iPhone build:** App Group (if the probe allows it) and the keychain access group. No iCloud, no `aps-environment`. The current `Levels-iOS.entitlements` holds both; the free-team configuration drops them, the way `Config/Levels-Mac.xcconfig` does for the Mac. **Builder's call:** a separate xcconfig or an entitlements file per configuration.
- Concurrency: `LocalNetworkSyncService` is an actor; network waits run in child tasks with deadlines from the injected clock. The `NWBrowser` and `NWConnection` callbacks run on one private queue inside the real `HubTransport`.

## Edge cases and failure modes

- Home Wi-Fi but the Mac asleep: not found, or found through a sleep proxy and the connection times out. Either way `.awayFromHub`. **Assumption:** a connection attempt may wake the Mac ("Wake for network access"); QA records it.
- iPhone on cellular at home (Wi-Fi off): away.
- VPN on the iPhone that captures local traffic: looks like away. NET-004's away text mentions VPN once.
- The Mac's IP changes: nothing stored, Bonjour finds it again.
- Two Macs on the network: only the paired tag is used.
- A held long-poll when the app goes to the background: cancelled (R7); no background connection is kept.
- Outbox holds a reading from 3 hours ago when the Mac is found: it is sent; the Mac shows it with its true age (it is the newest the iPhone has).
- Clock skew: the Mac caps the iPhone reading with its receive time (NET-001 R9); the iPhone's age texts use `readingDate` (SYNC-002 R8).
- The 7-day install expiry: the app doesn't launch; nothing is sent; the Mac shows the iPhone going stale after 2 h. After reinstall the next launch report sends at once.

## Acceptance criteria

- [ ] AC1 — Given a fake transport and a paired store, when `report` writes the own reading, then one `POST /v1/readings` with that reading and the `Levels-Device` header is sent (R2, R4).
- [ ] AC2 — Given the transport fails, then the outbox keeps the reading; given a later `refresh` succeeds, then the outbox is sent then and cleared on `204` (R3, R4).
- [ ] AC3 — Given two reports while away, then only the latest is sent on the next contact (R2).
- [ ] AC4 — Given a snapshot with the Mac and two accessories, then after `refresh` the cache holds them plus the own record, `lastFetchAt` = now, and a device the snapshot dropped is gone (R3, R11).
- [ ] AC5 — Given `304`, then the cache's `devices` are unchanged, no widget reload is requested, and `lastFetchAt` moves (R3).
- [ ] AC6 — Given the hub is not found in 5 s of clock time, then status is `.awayFromHub(lastContactAt:)` with the previous `lastFetchAt`, written to the cache (R5, R9).
- [ ] AC7 — Given the handshake is refused with a stored key, then status is `.misconfigured(code: 401)`; given policy denied, then `.restricted`; given no pairing, then `.notPaired` and no network call (R9).
- [ ] AC8 — Given live updates and a fake that answers `200` after 3 s, then the cache updates within that call and the next long-poll starts with the new ETag; after `stopLiveUpdates`, no further request starts (R7).
- [ ] AC9 — Given `removeAllData` with the hub reachable, then `DELETE /v1/devices/me` is sent before the cache reset, and later reports write nothing; with the hub not reachable, it throws and the cache is unchanged (R10).
- [ ] AC10 — On real hardware: with the app in the background, a background refresh task (forced from Xcode's debugger) posts the iPhone's reading and fetches the Mac's (R8).
- [ ] AC11 — On real hardware, iPhone app open on home Wi-Fi: plug in the Mac; the iPhone shows it charging within 10 s (R7). Unplug the iPhone; the Mac's popover shows it within 10 s (R2, NET-001).
- [ ] AC12 — On real hardware: turn Wi-Fi off on the iPhone, open the app; within 6 s the away state shows and the rows keep their last levels with honest ages (R5, ADR-0017).
- [ ] AC13 — On real hardware: run the "Report Battery" Shortcut on home Wi-Fi with the app closed; the Mac shows the new reading (R6, RPT-002).

## Tests

- Unit (Swift Testing): `LevelsNetTests` for `HubClient` over a fake transport; `LevelsSyncTests` for `LocalNetworkSyncService` with a fake client, a temp-directory cache and a manual clock (AC1–AC9).
- Real hardware (owner's Mac and iPhone on the home Wi-Fi; free-team builds of both): AC10–AC13. Also record: whether a connection to a sleeping Mac wakes it; Mac Energy Impact with the iPhone app open for 10 minutes (NET-001 AC13); pairing survives an over-the-top reinstall (NET-002).

## Open questions

None.
