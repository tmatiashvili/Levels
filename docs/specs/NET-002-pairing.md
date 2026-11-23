---
id: NET-002
title: Pairing an iPhone with the Mac hub
milestone: free-team   # owner decision M
status: Ready
depends_on: [NET-001]
adrs: [7, 19, 20]
targets: [Shared, Levels-Mac, Levels-iOS]
---

# NET-002: Pairing an iPhone with the Mac hub

## Why

The home network is not trusted (ADR-0020). Only the owner's iPhone may read the Mac's levels or write its own. A one-time code shown on the Mac and typed on the iPhone gives both sides a shared key, and every later request is authenticated and encrypted with it.

## Scope

- In: the pairing window on the Mac, the code, the pairing exchange, key derivation, Keychain storage on both sides, Remove and Forget, the iPhone pairing screens' behaviour.
- Out (and where it goes instead): the iPhone screen layout and onboarding copy → NET-004. Using the key for requests → NET-001 R5, NET-003. QR-code pairing → follow-up in ADR-0020.

## Behaviour

- **R1** Mac Settings ▸ iPhone ▸ "Pair iPhone…" opens a sheet with a 6-digit code (shown as `123 456`), the hub tag ("This Mac shows as Levels-ab12"), a 2-minute countdown and Cancel. Opening the sheet opens the **pairing window**: the listener starts if needed (NET-001 R1) and the TXT record gets `pair=1`.
- **R2** The code comes from `SystemRandomNumberGenerator`, uniform over 000000–999999. It is valid for 2 minutes and for one successful pairing. Closing the sheet, a success, the timeout or 5 failed attempts end the window. After 5 failures the sheet says "Too many tries. Get a new code." with a button for a new code.
- **R3** iPhone: "Connect to your Mac" (NET-004) browses `_levels._tcp` and lists hubs whose TXT has `pair=1` and `v=1`, as "Levels-ab12". One hub is pre-selected. The owner types the 6 digits.
- **R4** The iPhone opens a TLS-PSK connection with identity `pair` and key `codeKey = HKDF<SHA256>(inputKey: code as UTF-8, salt: "levels-hub-" + hub tag as UTF-8, info: "levels-pair-v1", outputByteCount: 32)`. The tag is the 4-character TXT `hub` value; the full hub ID is sent only inside the session (R5). A failed handshake counts as one failed attempt on the Mac (R2). The iPhone shows "That code didn't work. Check the code on your Mac." and keeps the field.
- **R5** Inside the session the iPhone sends `POST /v1/pair` with `{ "deviceID", "name", "kind", "publicKey" }` (a fresh `Curve25519.KeyAgreement.PrivateKey`'s raw public key, base64). The Mac answers `200` with `{ "hubID", "hubDeviceID", "hubName", "publicKey" }` (its own fresh key pair). `kind` must be `iphone` or `ipad`; otherwise `403`.
- **R6** Both sides compute `pairingKey = HKDF<SHA256>(inputKey: X25519 shared secret, salt: codeKey, info: "levels-key-v1" + hubID + deviceID (lowercase strings), outputByteCount: 32)`. The ephemeral private keys are dropped right after.
- **R7** Then the iPhone opens a normal connection with identity = its device ID and the new key and calls `GET /v1/snapshot`. Only when that succeeds does the iPhone save the pairing, and only then does the Mac mark it **confirmed**. An unconfirmed entry on the Mac is dropped when the window ends. The Mac's sheet then says "Paired with <name>" and closes after 3 s.
- **R8** Storage. Mac: one Keychain generic-password item per client, service `<rdns>.levels.hub.client`, account = device ID, data = `{ key, name, kind, pairedAt, lastSeenAt }`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable. iPhone: one item, service `<rdns>.levels.hub`, account = hub ID, data = `{ key, hubName, hubDeviceID, pairedAt }`, same accessibility, in the shared keychain access group `$(AppIdentifierPrefix)<rdns>.levels.shared` (so a variant B widget can read it, NET-004).
- **R9** Remove and Forget.
  - Mac Settings ▸ paired device ▸ Remove (confirmation: "<name> will stop seeing this Mac's levels until you pair it again."): deletes the Keychain item, closes that client's connections, and keeps its last record in the cache (it ages and moves to "Old devices" by the usual rule; the owner can remove it there).
  - iPhone Settings ▸ Mac ▸ "Forget this Mac": calls `DELETE /v1/pairing` if the Mac is reachable (best effort), then deletes the iPhone's item and sets status `.notPaired`. Records from the Mac stay in the iPhone cache until "Remove all my data" or the next pairing's full fetch.
- **R10** Re-pairing a device that is already paired replaces its key on both sides. An iPhone holds at most one hub (lead's call 26): pairing with a different Mac replaces the old pairing, after a confirmation ("Replace <old Mac name>?").
- **R11** The Mac allows at most 4 paired devices. A 5th pairing gets `409` and the iPhone shows "This Mac already has 4 devices. Remove one on the Mac first."
- **R12** Nothing about pairing is logged except outcomes and device IDs (ADR-0019 rule 3). The code and keys are never logged.

## Design

**`LevelsNet` additions:**

```swift
public enum PairingCrypto {
    public static func codeKey(code: String, hubTag: String) -> SymmetricKey                      // R4
    public static func pairingKey(shared: SharedSecret, codeKey: SymmetricKey,
                                  hubID: UUID, deviceID: DeviceID) -> SymmetricKey                 // R6
    public static func newCode<G: RandomNumberGenerator>(using g: inout G) -> String              // R2, 6 digits
}

public struct PairRequest: Codable, Sendable { public var deviceID: DeviceID; public var name: String; public var kind: DeviceKind; public var publicKey: Data }
public struct PairResponse: Codable, Sendable { public var hubID: UUID; public var hubDeviceID: DeviceID; public var hubName: String; public var publicKey: Data }

/// Keychain-backed; tests use the in-memory fake.
public protocol HubPairingStore: Sendable {          // Mac side
    func key(for id: DeviceID) -> SymmetricKey?
    func all() -> [PairedClient]
    func save(_ client: PairedClient) throws
    func remove(_ id: DeviceID) throws
    func touch(_ id: DeviceID, at: Date)             // lastSeenAt, written at most once per 10 min
}
public protocol ClientPairingStore: Sendable {       // iPhone side
    func current() -> HubPairing?
    func save(_ pairing: HubPairing) throws
    func remove() throws
}

/// Mac: the window state machine (R1, R2, R7). Pure, driven by a clock.
public actor PairingWindow {
    public enum State: Sendable, Equatable { case closed, open(code: String, endsAt: Date, failures: Int), locked, paired(name: String) }
    public func open() -> String
    public func handshakeFailed()
    public func accept(_ request: PairRequest) throws(PairError) -> PairResponse   // R5, R11
    public func confirm(_ id: DeviceID)                                              // R7
}

/// iPhone: runs R4–R7 end to end.
public struct PairingClient: Sendable {
    public func pair(with endpoint: NWEndpoint, hubTag: String, code: String,
                     me: PairRequestIdentity) async throws(PairError) -> HubPairing
}
public enum PairError: Error, Equatable { case wrongCode, tooManyTries, hubFull, notReachable, refused, timedOut }
```

- `HubTLS.serverOptions(keyFor:)` (NET-001) returns `codeKey` for identity `pair` only while `PairingWindow` is open, and the stored key for a paired device ID.
- Every pairing step has a 10 s timeout. The whole flow ends within 30 s.
- The `hubName` sent in R5 is the Mac's display name from SYNC-002 R17 (shown only inside the encrypted session, never in Bonjour).
- **Builder's call:** the countdown style and whether the code field auto-submits at 6 digits.

## Edge cases and failure modes

- Code typed after it expired: handshake fails (no `pair` key any more); the iPhone shows the wrong-code message; the Mac's sheet already says it expired.
- Two iPhones pair in the same window: the first success ends the window; the second gets a failed handshake.
- The iPhone is killed between R6 and R7: the Mac drops the unconfirmed entry when the window ends; the iPhone saved nothing. Pair again.
- The Mac's Keychain item exists but the iPhone lost its own (app deleted): the old entry stays until the owner re-pairs (R10 replaces it) or removes it.
- The 7-day free install expiry: reinstalling over the top keeps Keychain items, so pairing survives. **Assumption:** true for a Personal Team re-install with the same bundle ID; QA checks it.
- Local Network permission denied on the iPhone: browsing fails before any code is asked (NET-004 shows the fix).
- An attacker on the network during the window (ADR-0020 Decision 3, accepted risk): the Mac shows the attacker's pairing by name in R7 and the list; the owner removes it.

## Acceptance criteria

- [ ] AC1 — Given a seeded generator, then `newCode` always gives 6 digits, and over 100,000 draws every first digit 0–9 appears (R2).
- [ ] AC2 — Given the same code, tag, shared secret, hub ID and device ID, then both sides' `pairingKey` are equal; changing any input changes the key (R4, R6; test vectors checked in).
- [ ] AC3 — Given an open window, when 5 handshakes fail, then the state is `.locked` and identity `pair` gets no key (R2).
- [ ] AC4 — Given an open window and the clock moves 2 min, then the state is `.closed` and an unconfirmed entry is gone (R2, R7).
- [ ] AC5 — Given `accept` then `confirm` for device D, then the store holds D's key, the state is `.paired(name:)`, and `pair` gets no key any more (R7).
- [ ] AC6 — Given `accept` for kind `mac`, then `.refused`; given 4 paired devices, then `.hubFull` (R5, R11).
- [ ] AC7 — Given a paired device is removed on the Mac, then its next handshake fails and the iPhone shows "This Mac no longer knows this iPhone" (R9, NET-003).
- [ ] AC8 — Given the iPhone pairs with a second Mac and confirms, then only the new pairing is stored (R10).
- [ ] AC9 — On real hardware: the Mac shows a code, the iPhone pairs with it in under 30 s, and the iPhone then shows the Mac's levels (R1–R7).
- [ ] AC10 — On real hardware: a wrong code shows the wrong-code message and the Mac's failure count goes up by one (R4).
- [ ] AC11 — Given a log capture during AC9, then neither the code nor any key appears (R12).

## Tests

- Unit (Swift Testing, `LevelsNetTests`): AC1–AC6, AC8 with fake stores and a manual clock.
- Real hardware (Mac + iPhone on the same Wi-Fi): AC7, AC9, AC10, AC11; reinstall the iPhone app over the top and check the pairing survives.

## Open questions

None.
