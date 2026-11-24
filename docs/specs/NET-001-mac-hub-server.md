---
id: NET-001
title: Mac hub server on the home network
milestone: free-team   # owner decision M; outside the v0.x plan, see the specs README "Now"
status: Ready
depends_on: [SYNC-002, MAC-001, MAC-002]
adrs: [3, 8, 9, 13, 14, 17, 19, 20]
targets: [Shared, Levels-Mac]
---

# NET-001: Mac hub server on the home network

## Why

On the free team there is no iCloud, so the iPhone can't see the Mac and the Mac can't see the iPhone. Owner decision M makes the Mac a hub: it serves the levels it holds on the home Wi-Fi and takes in the iPhone's own reading (ADR-0020).

## Scope

- In: the `LevelsNet` module (wire types, HTTP subset, TLS-PSK options, the server core); the Mac's `HubServer`; Bonjour advertising; the four API routes; `LocalOnlySyncService.ingest`; listener start and stop rules; the Mac Settings "iPhone" section (status, toggle, paired list, firewall hint); Info.plist keys.
- Out (and where it goes instead): pairing itself and the pairing UI → NET-002. The iPhone client → NET-003. iPhone app and widget changes → NET-004. CloudKit → SYNC-001. Bluetooth → NRB-001.

## Behaviour

- **R1** The listener runs only while all hold: reporting is on (SYNC-001 R15a), Settings ▸ iPhone ▸ "Share with iPhone on this Wi-Fi" is on (default on), and at least one device is paired or the pairing window (NET-002) is open. Otherwise it is cancelled and the Bonjour record goes away.
- **R2** The listener uses TCP with TLS (R5), a system-picked port, and Bonjour type `_levels._tcp`. Instance name `Levels-<tag>`, where `<tag>` is the first 4 lowercase hex characters of the hub ID. TXT record `v=1`, `hub=<tag>`, and `pair=1` only while the pairing window is open. `includePeerToPeer = false`. The name and TXT record never contain a device or user name.
- **R3** The hub ID is a random UUID made on first use and kept in the Mac's App Group `UserDefaults` key `net.hubID`. It never changes, except "Remove all pairings" (R14) makes a new one.
- **R4** Routes (HTTP/1.1 subset, R6). All bodies are JSON (R7).

  | Route | Answer |
  |---|---|
  | `GET /v1/snapshot` | `200` + `HubSnapshot` + `ETag`; `304` (no body) if `If-None-Match` equals the current tag |
  | `GET /v1/snapshot?wait=N` | like above, but with a matching `If-None-Match` the Mac holds the request until the cache changes or `min(N, 25)` s pass, then answers `200` or `304` |
  | `POST /v1/readings` | body `[DeviceBattery]`; `204` + `ETag` when accepted (R9) |
  | `DELETE /v1/devices/me` | removes the caller's record from the cache; `204` |
  | `DELETE /v1/pairing` | forgets the caller (NET-002 R9); `204`; then the connection closes |

  Anything else: `404`, or `405` for a known path with a wrong method.
- **R5** Every connection is TLS 1.2 with a pre-shared key. The PSK identity is the caller's device ID (lowercase UUID string) and the key is that device's pairing key (NET-002). The identity `pair` is the pairing key of NET-002 R4 and is accepted only while the window is open, and only for `POST /v1/pair` and `POST /v1/pair/confirm` (NET-002 R5a, lead's call 30). Unknown identity or wrong key: the handshake fails and no HTTP is read.
- **R6** HTTP subset: request line, headers up to 8 KB, `Content-Length` bodies up to 64 KB, keep-alive. No chunked bodies, no compression, no pipelining (one request at a time per connection). A malformed request gets `400` and the connection closes. A body over 64 KB gets `413`. A connection never buffers more than 8 KB + 64 KB, also while a request is in flight (a held long-poll); more closes it (lead's call 30).
- **R7** JSON: `JSONEncoder` with `.millisecondsSince1970` dates and `.sortedKeys`. `HubSnapshot` = `{ "v": 1, "hubID", "hubDeviceID", "generatedAt", "devices": [DeviceBattery] }`. `devices` is everything in the Mac's cache, sorted as SYNC-002 sorts it: the Mac, its accessories, and every paired client's last reading. Unknown fields are ignored on decode.
- **R8** ETag = `"` + first 16 hex characters of SHA-256 over the R7 JSON of `devices` + `"`. Same devices, same tag, across relaunches.
- **R9** `POST /v1/readings` accepts only records whose `id` equals the `Levels-Device` header and whose `kind` is `iphone` or `ipad`, at most 1 record. The header must match a paired device; the connection must have passed R5. Other records or a missing header: `403`, nothing written. Each accepted record is checked: `hasConsistentAccessory`, name trimmed to 40 characters, `level` clamped (SYNC-002 R3). The Mac sets `serverModifiedAt` to its own receive time, then calls `LocalOnlySyncService.ingest([record], replacingAllExcept: nil)`.
- **R10** `ingest` merges by SYNC-002 R14 (newer `updatedAt` wins; on a tie the incoming one wins) and applies the SYNC-001 R8a widget reload rule (lead's call 17). It doesn't pass through `LocalWritePolicy`: the client already throttled (ADR-0008 on the iPhone). It writes nothing while reporting is off.
- **R11** A held long-poll ends early when the cache changes (the app's change relay, the same one the popover uses). If the client closes, the hold ends. At most one held request per connection.
- **R12** Limits (lead's call 31): at most 3 authenticated connections per paired device (the app's long-poll, a short POST, the widget's own fetch) plus 3 spare (the pairing session, a re-pair, a connection still closing after a network change), so 6 with one device and 15 with 4; a connection over the limit is cancelled at once; a connection idle for 60 s is closed; at most 10 requests per second per connection, more get `429`.
- **R12a** Handshakes (lead's call 30): a connection that hasn't finished the TLS handshake 10 s after it arrived is closed. Connections still in the handshake have their own budget of 3 and don't count toward R12's limit, so half-open connections can't take the slots of authenticated ones; a new connection over either limit is cancelled at once.
- **R13** While reporting is off (Remove all my data, SYNC-001 R15a) the listener stops (R1). "Remove all my data" on the Mac also removes every client's record from the cache (the cache reset does that). Pairings stay. A client that reports later adds itself back, as ADR-0019 §6 warns.
- **R14** Settings ▸ "iPhone" section: the toggle of R1; status line ("Sharing on this Wi-Fi", "Off", "Not sharing: no iPhone paired"); paired devices with name, kind, "last seen" age and Remove (NET-002 R9); "Pair iPhone…" (NET-002); "Remove all pairings" (confirmation; drops every key and makes a new hub ID).
- **R15** Firewall hint: if the listener is running, at least one device is paired, and no TLS handshake has succeeded for 24 h, the section shows "If your iPhone can't find this Mac, check System Settings ▸ Network ▸ Firewall ▸ Options and allow Levels." It hides after the next successful handshake.
- **R16** Logging (ADR-0019 rule 3): routes, status codes, device IDs and the hub tag may be logged public. Device names, bodies and keys are never logged.
- **R17** No new periodic timer (ADR-0014 rule 5). Only one-shot waits tied to a request or a connection (R4 wait, R12 idle, R12a handshake deadline) exist.

## Design

**Module `LevelsNet`** (new in `Shared/Package.swift`; depends on `LevelsModel`; imports Foundation, Network, CryptoKit, Security). No CloudKit, no `LevelsSync`. The Mac app, the iPhone app and (variant B, NET-004) the iPhone widget may link it.

```swift
public enum HubProtocol {
    public static let serviceType = "_levels._tcp"
    public static let version = 1
    public static let maxBody = 64 * 1024
    public static let maxWait: Duration = .seconds(25)
}

public struct HubSnapshot: Codable, Sendable, Equatable {
    public var v: Int
    public var hubID: UUID
    public var hubDeviceID: DeviceID
    public var generatedAt: Date
    public var devices: [DeviceBattery]
}

public enum HubWire {                       // R7, R8
    public static func encoder() -> JSONEncoder
    public static func decoder() -> JSONDecoder
    public static func etag(for devices: [DeviceBattery]) -> String
}

public struct HTTPRequest: Sendable, Equatable { public var method: String; public var path: String; public var query: [String: String]; public var headers: [String: String]; public var body: Data }
public struct HTTPResponse: Sendable, Equatable { public var status: Int; public var headers: [String: String]; public var body: Data }
public enum HTTPCodec {                     // R6; pure, unit-tested
    public static func parseRequest(_ buffer: inout Data) throws(HTTPError) -> HTTPRequest?   // nil = need more bytes
    public static func serialize(_ response: HTTPResponse) -> Data
    // + parseResponse / serialize(request) for the client (NET-003)
}

public enum HubTLS {                        // R5
    /// Client side: one identity and key.
    public static func clientOptions(identity: String, key: SymmetricKey) -> NWProtocolTLS.Options
    /// Server side: picks the key per identity; `nil` refuses the handshake.
    public static func serverOptions(keyFor: @escaping @Sendable (String) -> SymmetricKey?) -> NWProtocolTLS.Options
}

/// The routes of R4 with no Network code, so tests drive it with plain requests.
public protocol HubBackend: Sendable {
    func snapshot() async -> HubSnapshot?                       // nil while reporting is off
    func changes() -> AsyncStream<Void>                         // R11
    func ingest(_ record: DeviceBattery) async -> Bool          // R9, R10
    func removeRecord(_ id: DeviceID) async
    func forget(_ id: DeviceID) async                           // NET-002 R9
    func isPaired(_ id: DeviceID) -> Bool
}
public actor HubRouter {
    public init(backend: any HubBackend, now: @escaping @Sendable () -> Date, clock: any Clock<Duration>)
    public func handle(_ request: HTTPRequest) async -> HTTPResponse   // R4, R8, R9, R11 (pairing route added by NET-002)
}
```

**Mac target (`Levels-Mac`):** `HubServer` (`@MainActor`, owns the `NWListener`, connections and the R1 rule), `MacHubBackend: HubBackend` (reads `SnapshotCache`, calls `LocalOnlySyncService.ingest`, reads the pairing store of NET-002), `HubSettingsSection` (R14, R15). `MacAppModel` creates `HubServer` after `local.start()` and passes the existing `ChangeRelay` as `changes()`.

**`LocalOnlySyncService` additions** (in `LevelsSync`, used by NET-001 and NET-003):

```swift
/// Merges records written elsewhere (SYNC-002 R14) and applies the R8a widget reload rule.
/// `replacingAllExcept: nil` = partial (keep everything else). Non-nil = full: drop
/// entries the incoming set lacks, except the IDs given (the own device).
/// Does nothing while reporting is off. Returns whether `devices` changed.
@discardableResult
public func ingest(_ records: [DeviceBattery], replacingAllExcept keep: Set<DeviceID>?) async -> Bool

/// Removes one record from the cache (DELETE /v1/devices/me, NET-002 R9). R8a reload rule.
public func removeLocal(_ id: DeviceID) async
```

Both run under the existing serial gate, so they never interleave with a report or a held flush.

**Info.plist (`Levels-Mac`):** `NSBonjourServices = ["_levels._tcp"]`; `NSLocalNetworkUsageDescription = "Levels shares your Mac's battery and accessories with your iPhone on this Wi-Fi."` Entitlements: none new while the app is unsandboxed (lead's call 16). A future sandboxed build adds `com.apple.security.network.server`. The Mac widget gets nothing: it reads the cache, which now holds the iPhone (decision L).

**Concurrency:** `NWListener` and `NWConnection` callbacks run on one private serial `DispatchQueue`; each connection hops into the `HubRouter` actor per request. `HubServer` publishes status to the UI on the main actor.

**First build step (spike, about an hour):** before the rest, the builder checks the two TLS-PSK assumptions of ADR-0020 on the owner's Mac and iPhone: (1) `serverOptions` picks a key per identity with `sec_protocol_options_set_pre_shared_key_selection_block`; (2) a handshake with a wrong key fails on both sides. Result goes in this spec's AC1 note.
- **Fallback if (1) fails:** one hub-wide key shared by all paired clients, in place of per-device keys. Remove then means "make a new hub key; the other clients pair again". Pairing moves to a second listener (`_levels-pair._tcp`) that runs only while the window is open, with the code key as its only PSK.
- **Fallback if TLS-PSK fails entirely:** ADR-0020 Option S3 (plain TCP, CryptoKit-sealed bodies, HMAC with a counter). Needs a new lead's call before building.

**Builder's call:** the exact status line wording and the "last seen" format in R14.

## Edge cases and failure modes

- Port in use or listener fails (lead's call 31): retry after 5 s, 15 s, 1 min, then every 5 min (one-shot waits, R17), and at once when the network path becomes satisfied. The first failure still shows "Starting…"; from the second on, "Couldn't start sharing" with a Retry button. A running listener that waits for its network path is kept, not counted as a failure. `HubRetryPolicy` (LevelsNet) holds these rules.
- Mac sleeps: the listener stops answering; iPhones see "Away" (NET-003). On wake the listener resumes by itself (Network.framework); if it failed, R1 restarts it.
- Wi-Fi changes on the Mac: the listener follows; Bonjour re-registers.
- Two clients send at once: the router serialises per request; `ingest` serialises under the gate.
- A client clock far ahead: `serverModifiedAt` caps the reading date (SYNC-002 R8).
- Pairing removed while a client is connected: its connections close at once (R5 refuses the next handshake).
- Cache file unreadable: `snapshot()` returns the last good copy, or `503` if none.
- More connections than R12 allows (a buggy client loop): extra connections drop; logged once per minute.
- Firewall blocks: the Mac can't tell; R15 hints.
- The Mac joins another Wi-Fi (café, office): it advertises `Levels-<tag>` there too. Nothing can be read without a key. The tag is 4 hex characters of a random ID and names no one. The owner can turn sharing off (R1).

## Acceptance criteria

- [ ] AC1 — Spike: on real hardware, a client with the right identity and key completes a handshake; a wrong key fails on both sides; the server picks the key per identity. Result recorded here before the rest is built.
  - **Spike result (2026-11-24, macOS 26, loopback on the owner's Mac; iPhone run still to do):** per-device keys work, so the fallback is not needed. The server calls `sec_protocol_options_add_pre_shared_key` once per paired device and TLS picks the key the client's identity names. Right identity and key: handshake completes (`TLS_PSK_WITH_AES_128_GCM_SHA256`, suite 0x00A8). Wrong key: server fails with `-9846 bad MAC`, client with `-9820`. Unknown identity: `-9864 unknown PSK identity` on both sides. `sec_protocol_options_set_pre_shared_key_selection_block` runs on the server with the client's identity as its `psk_identity_hint` argument; completing with `nil` refuses the handshake, so a removed device or a closed window is refused at once, and its metadata object is the ready connection's, so the server learns the caller's identity. Two builder findings: (1) keys added to the options after the listener starts are not seen, so the Mac rebuilds the `NWListener` on the same port when the key set or TXT record changes (open connections survive; checked); (2) TLS session resumption skips the selection block, so resumption and tickets are off on both sides. Scripts: `Spike/TLSPSK-Mac/`; permanent checks: `LevelsNetTests` `TLSLoopbackTests` and `LevelsSyncTests` `HubLoopbackTests`.
- [ ] AC2 — Given the router and a fake backend with three devices, when `GET /v1/snapshot` arrives, then `200`, the body decodes to the same devices, and `ETag` equals `HubWire.etag(for:)` (R4, R7, R8).
- [ ] AC3 — Given a request with `If-None-Match` equal to the current tag and no `wait`, then `304` with an empty body (R4).
- [ ] AC4 — Given `wait=25` and a matching tag, when the backend fires a change after 3 s of clock time, then the answer is `200` at 3 s; with no change, `304` at 25 s; with `wait=99`, `304` at 25 s (R4, R11).
- [ ] AC5 — Given `POST /v1/readings` from paired device P with P's iPhone record, then `204`, `ingest` is called once, and the stored record has `serverModifiedAt` = the router's `now` (R9).
- [ ] AC6 — Given a POST whose record ID is not the `Levels-Device` header, or whose kind is `mac` or `accessory`, or with two records, then `403` and no `ingest` (R9).
- [ ] AC7 — Given `ingest` with an older `updatedAt` than the cached record, then the cache keeps the cached one and no widget reload is requested; given a newer level, then one reload is requested (R10, SYNC-001 R8a).
- [ ] AC8 — Given `ingest(…, replacingAllExcept: [own])` with a set lacking device X, then X is dropped and own is kept (full form, used by NET-003).
- [ ] AC9 — Given reporting is off, then `ingest` writes nothing and the listener is not running (R1, R10, R13).
- [ ] AC10 — Given malformed bytes, a header over 8 KB, or a 65 KB body, then `400`, `400` and `413` (R6).
- [ ] AC11 — Given zero paired devices and no pairing window, then no listener runs and no Bonjour record exists (R1); after pairing one device it runs.
- [ ] AC12 — Given the Bonjour record, then its name matches `Levels-[0-9a-f]{4}` and its TXT has only `v`, `hub` and (in the window) `pair` (R2).
- [ ] AC13 — Given the Mac idle for an hour with one paired iPhone not connected, then Activity Monitor's average Energy Impact for Levels stays under 1.0, as without the hub (R17, ADR-0014 rule 5).
- [ ] AC14 — Given a log capture during AC5, then no device name or body appears (R16).

## Tests

- Unit (Swift Testing, `LevelsNetTests`, new test target): `HTTPCodec` round trips and limits (AC10), `HubWire` ETag stability (AC2), `HubRouter` routes with a fake backend and a manual clock (AC2–AC6). `LevelsSyncTests`: `ingest` and `removeLocal` (AC7–AC9).
- Integration on the Mac (no iPhone): a test client in the test target connects to a real `NWListener` on loopback with TLS-PSK (AC1 partly, AC12). **Assumption:** loopback TLS-PSK works in `swift test`; otherwise it runs from an Xcode test plan on the Mac.
- Manual on real hardware: AC1 with the iPhone, AC11, AC13, AC14; firewall on and off (R15); Mac sleep with the iPhone app open. QA notes go in the NET-003 test section.

## Open questions

None. Builder-level choices are marked **Builder's call** above.
