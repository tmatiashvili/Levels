---
id: NRB-001
title: BLE nearby mode (Mac to iPhone without the cloud)
milestone: later
status: Outline
depends_on: [SYNC-001, MAC-001, RPT-001]
adrs: [4, 7, 9, 14, 17, 18, 19]
targets: [Shared, Levels-Mac, Levels-iOS]
---

# NRB-001: BLE nearby mode (Mac to iPhone without the cloud)

> **Note (2026-11-24):** owner decision M picked the home-network hub (ADR-0020) over BLE for the free team. This spec stays parked under lead's call 6e.

## Why

CloudKit plus silent push takes minutes, and needs internet on both devices. When the Mac is in a bag next to the iPhone (on a plane, on a train with poor signal), Bluetooth LE could carry the Mac's level directly in seconds. This spec decides whether that's worth building.

## Scope

- In: Mac advertises its own battery over BLE; iPhone reads it when nearby; nearby readings feed the same local cache and UI as CloudKit readings (newest wins by timestamp).
- Out: iPhone → Mac direction (the Mac gets iPhone data from CloudKit; can be added later the same way), iPad as central (same code, later), Watch (watchOS Core Bluetooth background limits not studied), accessories over BLE.

## Behaviour

- R1 — When the iPhone app is in the foreground and the Mac is within range, the Mac's level shown is at most about 10 s old.
- R2 — In the background, the iPhone updates the cache when the Mac's level changes, if iOS wakes it (best effort; no promise).
- R3 — Only the owner's devices can read the value (see Security).
- R4 — Nearby readings never overwrite a newer CloudKit reading; both carry `updatedAt`.
- R5 — Nearby mode can be turned off in settings on either device.

## Design

### Facts (verified)

- `scanForPeripherals(withServices:options:)`: to scan in the background the app needs the `bluetooth-central` background mode and "must explicitly scan for one or more services by specifying them in the `serviceUUIDs` parameter". ([scanForPeripherals](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/scanforperipherals(withservices:options:)))
- In the background, `CBCentralManagerScanOptionAllowDuplicatesKey` is ignored and discoveries are coalesced; the scan interval grows, so discovery can take longer. A woken app has "around 10 seconds" to finish. ([Core Bluetooth background processing](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html))
- State preservation and restoration only covers managers created with a restoration identifier; the system relaunches the app into the background and calls `centralManager(_:willRestoreState:)` first; restored state includes connected peripherals and their notification states. (same page; [CBCentralManagerRestoredStatePeripheralsKey](https://developer.apple.com/documentation/corebluetooth/cbcentralmanagerrestoredstateperipheralskey))

### Assumptions

- **Assumption:** iOS does not relaunch an app the user force-quit for Bluetooth events.
- **Assumption:** a pending `connect(_:)` to a known peripheral doesn't time out, so the iPhone can "wait" for the Mac in the background and get woken when it comes in range.
- **Assumption:** a macOS app (sandboxed, with `com.apple.security.device.bluetooth` and `NSBluetoothAlwaysUsageDescription`) can advertise with `CBPeripheralManager` while running as a menu-bar agent, with no background limits.
- **Assumption:** WidgetKit's reload budget still applies to reloads requested from a BLE wake, so nearby mode makes the *app* faster but not necessarily the *widget*.

### Outline

- Mac (`Levels-Mac`): `CBPeripheralManager` publishes one custom service (fixed 128-bit UUID) with one characteristic, readable and notifying. Value: small encrypted payload (below). Notifies subscribers on every battery change.
- iPhone (`Levels-iOS`): `CBCentralManager` with a restoration identifier; scans for the service UUID; connects, subscribes to notifications, keeps a pending connection when out of range. On a value: decrypt, check `deviceId` and timestamp, write to the App Group cache (ADR-0009), reload widgets (ADR-0017 rules).
- Shared: payload encode/decode and crypto in `Shared`, unit-tested with Swift Testing (ADR-0018).

### Security

A plain characteristic would let anyone nearby read the Mac's battery, and a fixed service UUID tells scanners "a Levels Mac is here".

- **Option S1 — Bluetooth pairing** (`readEncryptionRequired` permission): OS-level pairing dialog. Pros: no crypto code. Cons: user pairing step; pairing iPhone↔Mac over a custom app service may confuse; doesn't prove the reader is the *same Apple ID*.
- **Option S2 — App-level encryption with a key from the private CloudKit DB (recommended):** on first enable, a device creates a random 256-bit key and saves it in a `NearbyKey` record in the private database (only the owner's devices can read it). The Mac encrypts each payload (`deviceId`, `level`, `isCharging`, `updatedAt`, counter) with AES-GCM (CryptoKit); the iPhone decrypts. A wrong key fails authentication, so other people's apps learn nothing but ciphertext. Rotate the key from settings. Store the local copy in the Keychain.
- Presence leak from the fixed service UUID is accepted (low risk; nothing identifies the owner). **Assumption:** acceptable for a personal tool; revisit before App Store.
- Privacy (ADR-0019): no data leaves the owner's devices; the new key record is deleted with the zone.

### Is it worth it? (honest view)

- Gain: fast in-app reading and offline operation when the devices are together.
- Limits: background wake-ups are best effort; force-quit stops it; widgets stay budget-bound; a second transport doubles the testing; Bluetooth permission prompt on both devices.
- **Recommendation:** don't build until real-device QA (QA-001 latency numbers) shows that CloudKit delay, not the widget budget, is what the owner actually notices. If built, start foreground-only (R1) and add background (R2) after measuring.

## Edge cases and failure modes

- Bluetooth off or permission denied: nearby mode silently off; CloudKit still works.
- Two Macs: each has its own `deviceId` in the payload; iPhone keeps a connection per Mac.
- Clock skew between Mac and iPhone: compare with ADR-0017 rules; prefer the newer by sender clock, flag big skew.
- Key rotated on one device while the other is offline: decryption fails until the new key syncs; show nothing rather than wrong data.
- Replay of an old payload: counter and timestamp must increase; older ones are ignored.

## Acceptance criteria

- [ ] AC1 — Given the iPhone app open within 5 m of the Mac, when the Mac is plugged in, then the iPhone shows charging within 10 s with no network.
- [ ] AC2 — Given a payload encrypted with a different key, when received, then it is rejected (unit test).
- [ ] AC3 — Given a nearby reading older than the cached CloudKit one, then the cache keeps the CloudKit value (unit test).
- [ ] AC4 — Given the iPhone app in the background, when the Mac level changes, then record whether and when the cache updated (measurement, not pass/fail).

## Tests

AC2, AC3 and payload round trips are Swift Testing unit tests. AC1 and AC4 are manual real-device tests (Bluetooth doesn't work in the Simulator in a useful way — **Assumption**).

## Open questions

- Closed. Lead's call (2026-11-23): nearby mode is not built until measured CloudKit delay (QA-001/QA-002 latency numbers) justifies it.
- If built, is the fixed-UUID presence leak acceptable? Recommended: yes for personal use; re-check before App Store.
