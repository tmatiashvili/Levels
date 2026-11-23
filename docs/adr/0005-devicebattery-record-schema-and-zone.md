# ADR-0005: One `DeviceBattery` record per battery in a custom `Levels` zone, named by its stable ID

- **Status:** Accepted (owner decision J, 2026-11-23)
- **Date:** 2026-11-23
- **Deciders:** project owner
- **Related:** ADR-0004, ADR-0006, ADR-0007, ADR-0008, SYNC-001, SYNC-002

## Context

README sketches a `DeviceBattery` record type with `deviceId`, `name`, `type`, `parentDeviceId`, `level`, `isCharging`, `isLowPowerMode` and `updatedAt`. We must fix the zone, the record name, the field types, versioning and what happens to devices that disappear.

Verified facts:

- The private database has one default zone, and you can create custom zones there. Custom zones allow atomic multi-record saves. ([CKRecordZone](https://developer.apple.com/documentation/cloudkit/ckrecordzone))
- The default zone does not support change fetching. It does not take part in database subscriptions. ([CKRecordZone.default()](https://developer.apple.com/documentation/cloudkit/ckrecordzone/default()), [CKDatabaseSubscription](https://developer.apple.com/documentation/cloudkit/ckdatabasesubscription))
- Field types are String, Number (Int64/Double), Data, Date, Array, Location, Asset and Reference. A record holds at most 1 MB. `encryptedValues` stores fields encrypted. ([CKRecord](https://developer.apple.com/documentation/cloudkit/ckrecord))
- Schemas are additive only once promoted to production. In production, saving unknown keys or record types fails. ([CKRecord](https://developer.apple.com/documentation/cloudkit/ckrecord), [SwiftData sync](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices))
- The `com.apple.developer.icloud-container-environment` entitlement selects `Development` or `Production`. ([entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-container-environment))

## Decision

**Zone:** one custom zone named `Levels` in the private database. Every device creates it if it is missing (the save is idempotent).

**Record type:** `DeviceBattery`. **Record name:** the battery's stable ID as a lowercase UUID string.
- Own device: the `deviceId` from the Keychain (ADR-0007).
- Accessory: `UUIDv5(LevelsNamespace, "accessory:" + accessoryKey + ":" + component)`. Here `accessoryKey` is a stable hardware key the Mac reader provides (for example the Bluetooth address), and `component` is `main`, `left`, `right` or `case`. So the same AirPods seen by two Macs map to the **same** records, and there are no duplicates.
  - Lead's call (2026-11-23): this UUIDv5 scheme is the only accessory ID scheme; ADR-0015 and MAC-003 use it. `accessoryKey` is the accessory's Bluetooth address (uppercase, colon-separated). UUIDv5 hashes namespace + name with SHA-1, so the record name is a one-way derivation and the raw address is never stored or synced.
  - Lead's call (2026-11-23): the same AirPods seen by two Macs are one record per component; the newest `updatedAt` wins (ADR-0008 accessory conflict rule).

**One record per battery.** AirPods give three records (left, right, case) that share `accessoryGroupId`. Owner decision (2026-11-23): three records, grouped under one AirPods row in the UI (UI-001 R13).

| Field | CK type | Req. | Meaning |
|---|---|---|---|
| `schemaVersion` | Int64 | yes | Version of the writer's schema. Starts at `1`. |
| `deviceId` | String | yes | Same as the record name. Kept as a field for debugging in the CloudKit Console. |
| `type` | String | yes | `iphone`, `ipad`, `mac`, `watch`, `accessory`. Unknown values are shown as "other". |
| `parentDeviceId` | String | accessories | The `deviceId` of the host that wrote it last. |
| `accessoryKind` | String | no | `airpods`, `mouse`, `keyboard`, `trackpad`, `other`. |
| `accessoryGroupId` | String | no | Groups components (left, right, case) of one accessory. |
| `component` | String | no | `main`, `left`, `right`, `case`. |
| `level` | Int64 | no | 0–100. **Absent** (`nil` in the model) means the device has no internal battery: a desktop Mac (Mac mini, iMac, Mac Studio, Mac Pro) still publishes its own record (ADR-0015, MAC-002 R5), and the UI shows it as "plugged in, no battery". |
| `isCharging` | Int64 (0/1) | yes | Charging, or on external power and full: `isCharging = charging \|\| (onExternalPower && full)` (SYNC-002 R16). False for a battery held below full on the charger (for example Optimized Charging at 80 %). |
| `isPluggedIn` | Int64 (0/1) | no | On external power (charging, full, held at a limit, or a desktop Mac). Absent when unknown. |
| `isLowPowerMode` | Int64 (0/1) | no | Low Power Mode on. Absent on accessories. |
| `updatedAt` | Date | yes | Writer's clock at the moment of **reading** the battery. |
| `name` | String (**encrypted**, `encryptedValues`) | yes | Display name. |

Readers also use the system field `modificationDate` (server time) to correct clock skew (SYNC-002).

**Versioning rules:**
1. Only add fields. Never rename a field, change its type or change its meaning.
2. Readers ignore unknown fields and tolerate missing optional fields.
3. Bump `schemaVersion` only for a change that old readers would misread. A reader that sees a higher major version still shows `level` and `updatedAt`, and labels the device "update Levels on this device".
4. Deploy the schema from Development to Production in the CloudKit Console before any build that uses Production. A CI or manual check lists the fields above.
5. **Every build used day to day, including Xcode debug builds, sets `com.apple.developer.icloud-container-environment = Production`** in the target's entitlements file. Otherwise a debug iPhone build (Development) and a release Mac build (Production) would never see each other. Owner decision (2026-11-23): this applies to every daily build, debug included. Experiments that must not touch the owner's data use a separate container or test setup (ADR-0018 §6).

**Removed and retired devices:**
- No automatic deletion. A device that stops reporting shows its last reading with "updated X ago" (UI owns the wording).
- Records not updated for **30 days** are grouped under "Old devices" in the UI. Lead's call (2026-11-23): retired devices move to "Old devices" after 30 days; removal is manual only (UI-002 R11, UI-004 R9).
- Any device can **Remove** a record (and accessory records whose `parentDeviceId` points at it). A removed device that is still alive recreates its record on its next report. That is correct, so Remove is only for retired devices.
- Duplicate records after a restore or migration are handled the same way (ADR-0007).

## Options considered

### Option A — Custom zone, record per battery, name = stable ID (chosen)
- Pros: Works with `CKDatabaseSubscription` and zone change fetches. Atomic multi-record save for a Mac and its accessories. Deterministic names make saves idempotent (no lookup, no duplicates). Accessory IDs shared across Macs.
- Cons: The zone must be bootstrapped on every device, and `zoneNotFound`/`userDeletedZone` must be handled. AirPods take three records.

### Option B — Default zone, query by record type
- Pros: No bootstrap. Works with `CKQuerySubscription`.
- Cons: No change fetch, no database subscription, no atomic batches. It would rule out the CKSyncEngine path later.

### Option C — One record per device, accessories as an embedded array or JSON field
- Pros: Fewer records and fewer pushes.
- Cons: Two Macs would each embed the same AirPods, giving duplicates and conflicts. Every accessory change rewrites the host record. Type safety is lost in a JSON blob.

### Option D — Auto-delete records not seen for N days
- Pros: The list stays tidy without effort.
- Cons: Deletes a laptop left in a drawer, which then reappears. A delete from one device races with the owner's own record. It adds a destructive background job for little gain.

## Consequences

- Positive: The schema is simple, additive and readable in the Console. No duplicate accessories. It is ready for `CKSyncEngine` (custom zone, database subscription) if we migrate.
- Negative / accepted risks: Retired devices stay until removed by hand. The production schema can never shed fields.
- Follow-ups: `accessoryKey` is the Bluetooth address (lead's call above; MAC-003 R3). **Assumption:** the Bluetooth address of AirPods and Magic peripherals is readable on macOS and is stable. UI-002 owns the 30-day "Old devices" section and the Remove action.

## References

- [CKRecordZone](https://developer.apple.com/documentation/cloudkit/ckrecordzone)
- [CKRecordZone.default()](https://developer.apple.com/documentation/cloudkit/ckrecordzone/default())
- [CKRecord](https://developer.apple.com/documentation/cloudkit/ckrecord)
- [Encrypting user data](https://developer.apple.com/documentation/cloudkit/encrypting-user-data)
- [com.apple.developer.icloud-container-environment](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-container-environment)
- [Deploying an iCloud container's schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)
