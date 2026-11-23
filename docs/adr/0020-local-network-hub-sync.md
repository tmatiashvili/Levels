# ADR-0020: Local network hub sync (free team)

- **Status:** Proposed
- **Date:** 2026-11-24
- **Deciders:** project owner
- **Related:** ADR-0003, ADR-0004, ADR-0007, ADR-0008, ADR-0009, ADR-0011, ADR-0013, ADR-0014, ADR-0017, ADR-0019, NRB-001, SYNC-001, SYNC-002, RPT-001, UI-002, UI-003, NET-001, NET-002, NET-003, NET-004

## Context

Owner decision K keeps Levels on the free Personal Team: no iCloud and no push. The Mac app works local-only through `LocalOnlySyncService` behind `BatterySyncing`. The iPhone has nothing to sync with.

Owner decision M (2026-11-24): stay on the free team. To get the iPhone working now, the **Mac acts as a hub on the home Wi-Fi**. The Mac app serves the levels it holds (its own battery and its accessories) on the local network. The iPhone app and widget read them. The iPhone also reports its own battery to the Mac, so the Mac shows it. This works only on the same network. The free iPhone install expires every 7 days. iCloud (SYNC-001) stays the long-term plan and replaces or complements the hub when the owner pays.

Forces:

- The home network is not trusted. Guests, smart TVs and other gadgets share it. Device names are personal data (ADR-0019), and charging patterns show when someone is home.
- The Mac is the always-on side. It is an `LSUIElement` agent with strict energy rules (ADR-0014 rule 5: no new periodic timers without a decision).
- The iPhone app runs only in short bursts (ADR-0011). Widgets run in an extension with a small time and memory budget (ADR-0017).
- The existing seam is `BatterySyncing` (`LevelsModel/SyncSeam.swift`). Reporters and the UI must not change when the transport changes.
- The free team limits are not fully known. Another agent is running a free-team probe (`feature/ios-free-probe`) on App Groups and widget networking.

### Facts (from Apple documentation and samples; not re-checked on OS 26 hardware)

- `NWListener` can advertise a Bonjour service (`NWListener.Service(type:)`), and `NWBrowser` finds it. `NWConnection` can connect straight to the found service endpoint. ([NWListener](https://developer.apple.com/documentation/network/nwlistener), [NWBrowser](https://developer.apple.com/documentation/network/nwbrowser))
- Network.framework supports TLS with a pre-shared key: `sec_protocol_options_add_pre_shared_key` on both sides, with a PSK cipher suite such as `TLS_PSK_WITH_AES_128_GCM_SHA256`. Apple's sample "Building a custom peer-to-peer protocol" uses exactly this, with the key derived from a code the user types. ([sample](https://developer.apple.com/documentation/network/building-a-custom-peer-to-peer-protocol), [sec_protocol_options_add_pre_shared_key](https://developer.apple.com/documentation/security/sec_protocol_options_add_pre_shared_key(_:_:_:)))
- `URLSession` has no PSK option. A client that needs TLS-PSK must use `NWConnection`.
- iOS local network privacy: an app that browses Bonjour or connects to a local address needs `NSLocalNetworkUsageDescription` and must list its service types in `NSBonjourServices`. The system asks once. There is no API to read the answer; a denied browse fails with a policy-denied error (`kDNSServiceErr_PolicyDenied`). ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy), [NSLocalNetworkUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription), [NSBonjourServices](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbonjourservices))
- macOS 15 and later also have local network privacy (TN3179).
- When the macOS Application Firewall is on, an app that listens for incoming connections can trigger the "accept incoming network connections?" dialog. ([Firewall settings on Mac](https://support.apple.com/guide/mac-help/mh34041/mac))
- Multipeer Connectivity finds nearby peers over Wi-Fi, peer-to-peer Wi-Fi and Bluetooth and can encrypt sessions. TN3151 steers new peer-to-peer code to Network.framework. ([Multipeer Connectivity](https://developer.apple.com/documentation/multipeerconnectivity), [TN3151](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api))

### Assumptions (checked by the builder's first step, NET-001 AC1, or by the free-team probe)

- **Assumption:** on macOS, accepting incoming connections and advertising a Bonjour service do not need the local network permission; only outgoing local connections do (TN3179). The Mac app adds the usage string anyway.
- **Assumption:** the server side of Network.framework TLS-PSK can pick a key per client with `sec_protocol_options_set_pre_shared_key_selection_block`. Fallback in NET-001 Design.
- **Assumption:** the free Personal Team allows Bonjour, local network access and background app refresh on iOS. Pending: App Groups and widget networking (the free-team probe).
- **Assumption:** a sleeping Mac's Bonjour record can stay visible through a Bonjour Sleep Proxy, and a connection may wake the Mac ("Wake for network access"). QA measures it.
- **Assumption:** the firewall remembers its answer for the app as long as the code signature stays the same (same Apple Development certificate across rebuilds).

## Decision

**The Mac runs a small HTTP/JSON server on the home network with Network.framework. iPhones find it by Bonjour, pair once with a code, and then talk to it over TLS with a pre-shared key. The iPhone uses a new `LocalNetworkSyncService` behind `BatterySyncing`. The Mac's `LocalOnlySyncService` takes in the iPhone's readings.**

1. **Discovery.** The Mac advertises `_levels._tcp` with an `NWListener` on a port the system picks. The instance name is `Levels-<tag>`, where `<tag>` is the first 4 hex characters of a random hub ID. It never contains the Mac's or the owner's name (ADR-0019 rule 3). TXT record: `v=1` (protocol version), `hub=<tag>`, and `pair=1` only while the pairing window is open. Infrastructure Wi-Fi only: `includePeerToPeer = false`. The iPhone browses with `NWBrowser` and connects to the service endpoint. It never stores an IP address.
2. **Transport.** A minimal HTTP/1.1 subset (request line, `Content-Length`, a few headers, keep-alive; no chunking, no compression) over `NWConnection` on both sides, inside TLS. Bodies are JSON. The code lives in a new Shared module `LevelsNet` (Foundation, Network, CryptoKit, `LevelsModel`; no CloudKit, no `LevelsSync`). Lead's call 20.
3. **Pairing** (NET-002, lead's calls 21 and 30). The owner opens "Pair iPhone" on the Mac. The Mac shows a 6-digit code from a secure random source, valid 2 minutes, single use. The owner types it on the iPhone.
   - The pairing connection is TLS-PSK with PSK identity `pair` and key `HKDF-SHA256(code, salt: "levels-hub-" + hub tag, info: "levels-pair-v1")`. A wrong code fails the TLS handshake. After 5 failed handshakes the code is dead and the Mac asks for a new one. The code only gates who may try: it has 20 bits, so someone who records the handshake can find it offline in milliseconds (security review, call 30). Nothing below relies on its secrecy.
   - Inside that session the iPhone sends a hash **commitment** to a fresh X25519 public key, the Mac answers with its own fresh public key, and the iPhone then reveals its key, which the Mac checks against the commitment. The long-term **pairing key** is `HKDF-SHA256(X25519 shared secret, salt: SHA-256 of the transcript, info: "levels-key-v2")`, 32 bytes; the transcript holds both public keys, the hub tag, hub ID, hub device ID and name, and the device's ID, name and kind. A passive listener who cracked the code sees the whole exchange but not the shared secret, so it can't get the key.
   - **Confirmation number** (call 30). Both screens show a 6-digit number, `HKDF-SHA256(shared secret, salt: transcript digest, info: "levels-sas-v2")` mod 10⁶. A man in the middle runs two separate key agreements, so the two numbers differ; the commitment stops it from choosing its keys after seeing the others' to make them equal (1 in 10⁶ chance per try, and each try spends the code). The Mac gives the device its key only after the owner taps **They match**; Cancel ends the window. This is the numeric-comparison model of Bluetooth Secure Simple Pairing and ZRTP, built from CryptoKit's X25519, SHA-256 and HKDF; no PAKE.
   - Each side stores the key in its Keychain, this-device-only, readable after first unlock. The Mac keeps one entry per paired device (device ID, name, kind, key, paired at). The iPhone keeps one entry (hub ID, Mac name, key).
   - Residual risk (call 30 replaces call 21's accepted one): an attacker on the network can still race the iPhone during the window and send its own request first, but the Mac then shows the attacker's number (and name) while the iPhone shows none, so an owner who compares refuses it. The protection depends on the owner comparing the numbers; the sheet says so. The Mac still lists every paired device with Remove. QR-code pairing stays a follow-up.
4. **Requests are authenticated and encrypted.** Every hub request runs over TLS-PSK with identity = the client's device ID and key = its pairing key. The Mac picks the key by identity. A handshake with an unknown identity or a wrong key fails; nothing reaches the HTTP layer. Payloads are encrypted by TLS. Why encrypt and not only authenticate: the payload holds device names and charging times, which ADR-0019 treats as personal, and TLS-PSK gives encryption and authentication with no certificates and no custom crypto on the wire. A pinned self-signed certificate would need certificate creation code and a separate client token (Options S2).
   - The client also sends `Levels-Device: <device ID>`. The Mac trusts it only from a connection that passed TLS-PSK. Every paired device is the owner's, so one paired device could claim to be another. That is accepted.
   - TLS 1.2 PSK suites have no forward secrecy for the long-term key. Accepted: the key never leaves the two Keychains, and the payload is low value. If the probe shows an ECDHE-PSK suite works, the builder uses it.
5. **API shape** (NET-001).
   - `GET /v1/snapshot` returns `HubSnapshot` (protocol version, hub ID, the Mac's device ID, the Mac's clock time, and `devices: [DeviceBattery]`: everything the Mac's cache holds) with an `ETag`. `If-None-Match` with the current tag returns `304`.
   - `GET /v1/snapshot?wait=25` is a long-poll: with a matching `If-None-Match`, the Mac holds the request until the cache changes or 25 s pass, then answers `200` or `304`. The iPhone app runs it in a loop only while it is in the foreground (lead's call 22).
   - `POST /v1/readings` carries the client's own reading. The Mac accepts only a record whose ID is the client's device ID and whose kind is `iphone` or `ipad`. Other records give `403`.
   - `DELETE /v1/devices/me` removes the client's record from the Mac ("Remove all my data" on the iPhone). `DELETE /v1/pairing` forgets the client ("Forget this Mac").
   - ETag = the first 16 hex characters of SHA-256 over the canonical JSON of `devices`. It needs no stored state and survives relaunch.
6. **The `BatterySyncing` seam.**
   - iPhone: `LocalNetworkSyncService` (in `LevelsSync`, uses `LevelsNet`) conforms to `BatterySyncing`. It wraps a `LocalOnlySyncService` for the own cache write, ADR-0008 throttling and the widget reload rule (SYNC-001 R8a). Every own write that reaches the cache is then sent to the Mac. `refresh(_:)` fetches the snapshot and merges it into the cache. RPT-001's reporter and UI-001's store don't change.
   - Mac: `LocalOnlySyncService` gains `ingest(_:replacingAllExcept:)`, which merges records from elsewhere into the cache by SYNC-002's newest-`updatedAt` rule and then applies the same widget reload rule. The hub server calls it for incoming iPhone readings, with `serverModifiedAt` set to the Mac's receive time (caps an iPhone clock that runs ahead, SYNC-002 R8). The iPhone uses the same method for fetched snapshots (full fetch: keep only what the Mac has, plus the own record).
   - `SyncStatus` gains `.notPaired` and `.awayFromHub(lastContactAt: Date?)`. `SnapshotFile.lastFetchAt` means the last good contact with the Mac (lead's call 24).
7. **Widget data (pending the free-team probe, lead's call 23).** Two variants:
   - **Variant A, App Group cache (default).** The iPhone app writes the App Group cache (ADR-0009). The widget reads it only. It updates when the app runs: foreground, background refresh, the "Report Battery" intent, live updates.
   - **Variant B, the widget fetches from the Mac.** `getTimeline` reads the pairing key from the shared Keychain group, fetches `GET /v1/snapshot` with a 4 s limit, writes the result to the cache (when there is one) and builds the timeline. Reload policy `.after(now + 15 min)` after a good fetch, `.after(now + 60 min)` when away, plus ADR-0017's planned stale entries. The widget links `LevelsNet`, never `LevelsSync` (ADR-0003 rule kept).
   - **Rule for choosing.** Use B only if the probe shows all of: (1) a widget extension can connect to the Mac without its own prompt and without the app open; (2) it can read a Keychain item from the shared access group; (3) the fetch finishes inside `getTimeline` in under 4 s. Use A if the App Group works and B fails. If neither works, the free-team iPhone has no widget; the app still works. B also writes the cache when the App Group works, so A's paths keep working alongside it.
   - B is a periodic reload, which ADR-0017 Option B rejected for CloudKit. It is allowed here because nothing else can reload an iPhone widget with Mac data on the free team. It stays inside the 40–70 a day budget (at most 96 asks a day, and WidgetKit drops some).
8. **Away from home.** ADR-0017 still applies unchanged. Rows keep their last level and turn stale on time (Mac and accessories after 65 min). When the iPhone can't reach the Mac (no Bonjour result within 5 s, or the connection fails), status becomes `.awayFromHub` and the app shows "Away from your Mac" with the last contact age. Readings taken while away wait in one slot (latest wins) and go to the Mac on the next contact. No queue, no history.
9. **Energy on the Mac** (lead's call 25). The listener runs only while all of these hold: reporting is on (SYNC-001 R15a), "Share with iPhone" is on, and at least one device is paired or the pairing window is open. An idle `NWListener` costs no CPU; `mDNSResponder` handles the Bonjour record. No new periodic timer (ADR-0014 rule 5 keeps its count). Waits are one-shot and tied to a request or a window: the 25 s long-poll deadline, a 10 s TLS handshake deadline and a 60 s idle timeout per connection, the 2-minute pairing window. At most 4 authenticated connections, plus at most 3 still in the TLS handshake (a separate budget, so half-open connections can't take the authenticated slots; call 30). Each connection buffers at most 8 KB + 64 KB, also while a request is in flight. ADR-0014's energy target (under 1.0 average Energy Impact) still holds and QA measures it with the iPhone app open.
10. **macOS firewall and permissions.** The first listener start may show the firewall dialog. The Mac app can't read the firewall state, so Settings shows a hint when no iPhone has connected for a while: "If your iPhone can't find this Mac, check System Settings ▸ Network ▸ Firewall ▸ Options and allow Levels." The Mac app's Info.plist gets `NSLocalNetworkUsageDescription` and `NSBonjourServices`. The Mac app is unsandboxed (lead's call 16); for a future sandboxed build it also gets `com.apple.security.network.server`.
11. **iOS Local Network permission.** Info.plist: `NSBonjourServices = ["_levels._tcp"]` and `NSLocalNetworkUsageDescription = "Levels connects to your Mac on this Wi-Fi to show its battery and your accessories, and to send this iPhone's battery to the Mac."` The app starts browsing only after the owner taps "Connect to your Mac", so the system prompt has context. Denied: the app explains and opens Settings.
12. **When the owner pays** (lead's call 27). `BatterySyncService` (SYNC-001) replaces `LocalNetworkSyncService` on the iPhone and `LocalOnlySyncService` on the Mac. Device IDs stay the same (Keychain, ADR-0007), so records match and no data migration is needed: CloudKit's first run uploads own records (ADR-0008 W1) and the full fetch merges the rest. The hub code stays, switched off by default. It comes back as a "Fast updates on home Wi-Fi" option only if measured CloudKit delay justifies it, the same rule as lead's call 6e for NRB-001. If it does, both paths feed the one cache and the newest `updatedAt` wins. The Mac never uploads an iPhone's record to CloudKit.

## Options considered

### Transport

#### Option A — Bonjour + HTTP/JSON over Network.framework `NWListener`, TLS-PSK (chosen)
- Pros: Apple frameworks only (ADR-0019 rule 2). Request and response are easy to test with fakes. ETag and long-poll give fast updates while the app is open and nothing when it isn't. The widget can use the same client. `openssl s_client -psk` can debug it.
- Cons: we write a small HTTP subset ourselves, on both sides, because `URLSession` can't do TLS-PSK. Same network only.

#### Option B — WebSocket push (`NWProtocolWebSocket`)
- Pros: the Mac pushes each change at once over one open connection.
- Cons: a long-lived connection and its reconnect logic. We still need a plain fetch for background refresh and the widget. Long-poll gives nearly the same speed for an app that is open for seconds. Kept as a later upgrade on the same listener.

#### Option C — BLE nearby (NRB-001)
- Pros: no Wi-Fi needed; works in a bag or on a train.
- Cons: Bluetooth permission on both sides, best-effort background wakes, small payloads, and only the Mac-to-iPhone direction is outlined. Lead's call 6e parks it until latency justifies it. Doesn't answer decision M, which is about the home network.

#### Option D — Multipeer Connectivity
- Pros: discovery and encryption built in; works without a shared network when devices are close (peer-to-peer Wi-Fi).
- Cons: the peer display name is broadcast (a name leak). Encryption without certificates doesn't prove who the peer is, so we would still need our own pairing. Sessions drop when the iOS app goes to the background, and a widget can't use it. TN3151 points new code to Network.framework.

### Payload security

#### Option S1 — TLS-PSK with a per-device key from pairing (chosen)
- Pros: encryption and mutual authentication in one, from the platform. No certificates. Apple's own peer-to-peer sample uses it.
- Cons: TLS 1.2 PSK suites; picking the key per client needs the selection block (Assumption above).

#### Option S2 — TLS with a pinned self-signed certificate plus a bearer token
- Pros: TLS 1.3, forward secrecy.
- Cons: no first-party API makes a self-signed certificate on iOS or macOS; we would add certificate code (for example Apple's `swift-certificates`). The client still needs a token. More parts for one user.

#### Option S3 — Plain TCP, HMAC-signed requests, bodies sealed with CryptoKit
- Pros: fully testable in unit tests; works with any transport.
- Cons: our own replay protection and framing; easy to get subtly wrong. Kept as the fallback if TLS-PSK fails the builder's first check.

#### Option S4 — Authentication only, plain payloads
- Cons: device names and charging times readable by anything on the network. Rejected (ADR-0019).

### Widget data

Variants A and B are in Decision 7. A third option, Live Activities or push to the widget, needs push, which the free team lacks.

## Consequences

- Positive: the iPhone works now, at no cost, with the same reporters, store and views. The Mac shows the iPhone. All data stays on the owner's devices and home network. The switch to iCloud is a change of `BatterySyncing` implementation, not a rewrite.
- Negative / accepted risks:
  - Away from home the iPhone shows only what it last got from the Mac, aging honestly. The Mac shows the iPhone as stale after 2 h unless Shortcuts automations (RPT-002) run on home Wi-Fi.
  - The iPhone install expires every 7 days; the owner re-runs it from Xcode. Keychain and App Group data survive a reinstall over the top, so pairing usually survives. Deleting the app may lose it; then the owner pairs again.
  - The residual pairing risk in Decision 3 (the owner must compare the numbers).
  - A firewall dialog or a VPN on the iPhone can block the hub, and the app can only guess why.
  - A connection to a sleeping Mac may wake it (Assumption above).
  - New code to own: an HTTP subset, a TLS-PSK setup, pairing crypto.
- Follow-ups:
  - The free-team probe result picks the widget variant (Decision 7).
  - NET-001 AC1 checks the TLS-PSK assumptions first.
  - QR-code pairing (the Mac shows the key; no code to race) if the owner wants it.
  - NRB-001 and WebSocket push stay parked.
  - ADR-0019 Decision 1 gains the home network as a place data travels (note added there).

## References

- [NWListener](https://developer.apple.com/documentation/network/nwlistener), [NWBrowser](https://developer.apple.com/documentation/network/nwbrowser), [NWConnection](https://developer.apple.com/documentation/network/nwconnection)
- [Building a custom peer-to-peer protocol](https://developer.apple.com/documentation/network/building-a-custom-peer-to-peer-protocol) (TLS-PSK from a typed code)
- [sec_protocol_options_add_pre_shared_key](https://developer.apple.com/documentation/security/sec_protocol_options_add_pre_shared_key(_:_:_:))
- [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [TN3151: Choosing the right networking API](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)
- [NSLocalNetworkUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription), [NSBonjourServices](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbonjourservices)
- [CryptoKit](https://developer.apple.com/documentation/cryptokit) (`Curve25519.KeyAgreement`, `HKDF`)
- [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
- [Change Firewall settings on Mac](https://support.apple.com/guide/mac-help/mh34041/mac)
