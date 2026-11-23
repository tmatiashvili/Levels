---
id: SYNC-002
title: Device battery model, CloudKit mapping and App Group cache
milestone: v0.1
status: Draft
depends_on: []
adrs: [3, 4, 5, 7, 8, 9, 10, 15, 17]
targets: [Shared, Levels-iOS, Levels-Mac, Levels-Watch, Widgets-iOS, Widgets-Mac, Widgets-Watch]
---

# SYNC-002: Device battery model, CloudKit mapping and App Group cache

## Why

Every target (apps, widgets, complications, intents) must agree on what a "device battery" is, how it looks in CloudKit, and how it sits in the local cache. If they don't, widgets show wrong or stale values, or devices disagree. This spec fixes the value types and their encoding so sync (SYNC-001), reporting (RPT) and UI can be built in parallel.

## Scope

- In: `DeviceID`, `DeviceBattery` and related enums; accessory IDs; the charging flags rule; the default device name; `CKRecord` mapping both ways; staleness (`readingDate`, `age`, `FreshnessRule` per ADR-0017); `SnapshotFile` and `SnapshotCache` (App Group JSON file); validation.
- Out: CloudKit network calls, account handling and push (SYNC-001); reading batteries (RPT, MAC); "updated X ago" wording and thresholds shown to the user (UI); history storage (HIS, v0.5).

## Behaviour

- **R1** `DeviceID` wraps a `UUID`. Its CloudKit record name is the lowercase `uuidString`. Parsing a record name accepts either case.
- **R2** An accessory's `DeviceID` is `UUIDv5(namespace: LevelsAccessoryNamespace, name: "accessory:\(accessoryKey):\(component.rawValue)")` (RFC 9562 §5.5, SHA-1). `LevelsAccessoryNamespace = 3F6A1C52-8E0B-4D8F-9B67-2C4E1A7D90B3`. This value is fixed forever. The same `accessoryKey` and component give the same ID on every Mac.
- **R3** `level` is `nil` (no internal battery or unknown) or in `0...100`. When mapping from a record, values outside 0–100 are clamped. A non-integer value is rounded.
- **R4** Unknown `type` strings decode as `.other`. Unknown `accessoryKind` decodes as `.other`. Unknown `component` decodes as `.main`. Unknown fields are ignored.
- **R5** A record that lacks any required field (`deviceId`, `type`, `isCharging`, `updatedAt`, `name`), or whose record name is not a UUID, is **skipped** (and logged). It never crashes and never stops the other records from decoding.
- **R6** `schemaVersion` greater than `DeviceBattery.currentSchemaVersion` (1) decodes normally and sets `needsNewerApp = true`.
- **R7** `name` is written to and read from `record.encryptedValues["name"]`. All other fields are plain.
- **R8** `readingDate = min(updatedAt, serverModifiedAt ?? updatedAt, now)`. This guards against a writer clock that is ahead, and against future dates.
- **R9** `age(now:) = now − readingDate`, never negative.
- **R10** `FreshnessRule.of(_:at:)` returns `.fresh` or `.stale` using the ADR-0017 table on `age(now:)`: iPhone, iPad, Watch and `other` 2 h; Mac (with or without a battery) and accessories 65 min; a Mac or accessory actively charging (`isCharging && level < 100`) 30 min. Lead's call (2026-11-23): the charging rule applies only to Macs and accessories; an iPhone, iPad, Watch or `other` device keeps its normal threshold while charging. A Mac or accessory full on the charger (`isCharging && level == 100`) uses its type's threshold. Exactly at the threshold counts as fresh. `FreshnessRule.staleDate(for:)` returns `readingDate + threshold`. `FreshnessRule.isRetired(_:at:)` is true when age ≥ 30 days (ADR-0005 "Old devices").
- **R11** The cache file is `<group container>/Levels/snapshot.json`, UTF-8 JSON, `formatVersion = 1`, dates as seconds since 1970 (Double), sorted keys.
- **R12** `SnapshotCache.read()` returns `nil` if the file is missing, unreadable, not valid JSON, or has an unknown `formatVersion`. It never throws to widget code.
- **R13** `SnapshotCache.update(_:)` runs read, transform and write inside one `NSFileCoordinator` write. It writes atomically (temporary file, then rename). Concurrent updates from two processes both persist; neither is lost.
- **R14** `SnapshotFile.merge(fetched:isFullFetch:pendingOwnIDs:)`: per ID, keep the entry with the newer `updatedAt`. If `isFullFetch`, remove entries the fetch did not return, unless their ID is in `pendingOwnIDs`.
- **R15** Mapping is lossless for valid values: `model → record → model` gives an equal value (except `serverModifiedAt`, which only the server sets).
- **R16** **Charging flags** (the one definition every reporter uses): `isCharging = charging || (onExternalPower && full)`; `isPluggedIn = onExternalPower` (`nil` when unknown). A battery held below full on the charger (Optimized Charging, paused) is `isCharging = false, isPluggedIn = true`. A Mac with no battery is `level = nil, isCharging = false, isPluggedIn = true`. ADR-0010 rule 6 gives the mapping from `BatteryReading.PowerState`.
- **R17** **Device name.** `name` is this device's display name, written by the device itself. Default: the model name ("iPhone", "iPad", "Apple Watch"); since iOS 16 `UIDevice.name` returns only a generic name without the user-assigned-device-name entitlement, which Levels does not request. A Mac uses its computer name (`Host.current().localizedName`), else "Mac" (**Assumption:** available inside the App Sandbox; verify on hardware). If the user renamed this device in the app (`DisplayPreferences.thisDeviceName`, UI-001), that name wins. The reporter writes it on every save, so a rename reaches every device (ADR-0008 W8). Accessory names come from MAC-003.

## Design

Everything except `DeviceBatteryRecord` lives in the `LevelsModel` module (Foundation only, ADR-0003), so widget extensions can read the cache without linking CloudKit. `DeviceBatteryRecord` imports CloudKit and lives in `LevelsSync`. Every type is a `Sendable` value type with no global mutable state.

```swift
public struct DeviceID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let uuid: UUID
    public init(_ uuid: UUID)
    public init?(recordName: String)
    public var recordName: String            // lowercase uuidString
    public static func accessory(key: String, component: AccessoryComponent) -> DeviceID  // R2
}

public enum DeviceKind: String, Codable, Sendable, CaseIterable {
    case iphone, ipad, mac, watch, accessory, other
}
public enum AccessoryKind: String, Codable, Sendable { case airpods, mouse, keyboard, trackpad, other }
public enum AccessoryComponent: String, Codable, Sendable { case main, left, right, `case` }

public struct AccessoryInfo: Hashable, Codable, Sendable {
    public var parentDeviceID: DeviceID
    public var kind: AccessoryKind
    public var groupID: UUID          // same for left/right/case of one accessory
    public var component: AccessoryComponent
}

public struct DeviceBattery: Identifiable, Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1
    public var id: DeviceID
    public var schemaVersion: Int
    public var name: String
    public var kind: DeviceKind
    public var accessory: AccessoryInfo?      // non-nil iff kind == .accessory
    public var level: Int?                    // 0...100, nil = no battery
    public var isCharging: Bool
    public var isPluggedIn: Bool?
    public var isLowPowerMode: Bool?
    public var updatedAt: Date                // writer clock at reading time
    public var serverModifiedAt: Date?        // CKRecord.modificationDate; nil locally
    public var needsNewerApp: Bool { schemaVersion > Self.currentSchemaVersion }

    public func readingDate(now: Date) -> Date                     // R8
    public func age(now: Date) -> TimeInterval                     // R9
}

public enum Freshness: Sendable, Equatable { case fresh, stale }
public enum FreshnessRule {                                       // R10, ADR-0017
    public static func threshold(for d: DeviceBattery) -> TimeInterval
    public static func of(_ d: DeviceBattery, at now: Date) -> Freshness
    public static func staleDate(for d: DeviceBattery) -> Date
    public static func isRetired(_ d: DeviceBattery, at now: Date) -> Bool
}

public enum DefaultDeviceName {                                   // R17
    public static func current(kind: DeviceKind) -> String
}

// LevelsSync (imports CloudKit)
public enum DeviceBatteryRecord {
    public static let recordType = "DeviceBattery"
    public static let zoneName = "Levels"
    public static func record(for model: DeviceBattery, zoneID: CKRecordZone.ID) -> CKRecord   // fresh instance (ADR-0008)
    public static func apply(_ model: DeviceBattery, to record: CKRecord)                     // for accessory conflict retry
    public static func model(from record: CKRecord) -> DeviceBattery?                         // nil = skipped (R5)
}

public struct SnapshotFile: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1
    public var formatVersion: Int
    public var ownDeviceID: DeviceID?
    public var accountFingerprint: String?           // SHA-256 hex of CKRecord.ID(userRecord).recordName
    public var bootstrappedFingerprint: String?      // zone + subscription saved for this account (SYNC-001 R3)
    public var syncStatus: SyncStatus?               // last status from BatterySyncService (SYNC-001), for widgets (ADR-0017 §6)
    public var lastFetchAt: Date?
    public var lastFetchOutcome: FetchOutcome?       // .success | .failed(reason: String)
    public var devices: [DeviceBattery]              // sorted by kind, then name
    public var lastWritten: [DeviceID: DeviceBattery] // last accepted upload per own record (ADR-0008)
    public mutating func merge(fetched: [DeviceBattery], isFullFetch: Bool, pendingOwnIDs: Set<DeviceID>)  // R14
}

public struct SnapshotCache: Sendable {
    public init?(appGroupID: String)                 // nil if container is inaccessible (checks the directory on macOS)
    public init(directory: URL)                      // tests
    public func read() -> SnapshotFile?              // R12, no coordination
    public func update(_ body: (inout SnapshotFile) -> Void) throws  // R13, blocking: call off the main actor
    public func reset() throws                       // delete file (account change)
}
```

CloudKit field mapping (ADR-0005): `schemaVersion` Int64, `deviceId` String, `type` String, `parentDeviceId` String, `accessoryKind` String, `accessoryGroupId` String, `component` String, `level` Int64 (field absent when `nil`), `isCharging`/`isPluggedIn`/`isLowPowerMode` Int64 0/1 (absent when `nil`), `updatedAt` Date, `encryptedValues["name"]` String.

`SyncStatus` is declared in SYNC-001 but lives in `LevelsModel` next to these types; build it together with this spec (it is a plain enum), so SYNC-002 still has no build dependency on SYNC-001.

`[DeviceID: DeviceBattery]` encodes as a JSON object keyed by `recordName`. **Builder's call:** a custom `Codable` or a `[String: DeviceBattery]` storage property.

**Builder's call:** implement UUIDv5 with `CryptoKit.Insecure.SHA1`; Foundation has no v5 initializer.

Concurrency: the model types are plain `Sendable` structs. `SnapshotCache` holds only a URL. Coordination happens inside `update` and blocks, so callers (`BatterySyncService`, intents, widget providers) call it from a non-main context.

## Edge cases and failure modes

- **Clock skew:** a writer clock that is ahead is capped by `serverModifiedAt` and `now` (R8). A clock that is behind makes a device look older. That is the safe direction.
- **Offline writer:** the reading is uploaded later. `serverModifiedAt` is later than `updatedAt`, and `readingDate` stays at `updatedAt`. The age is correct.
- **Mac mini / desktop:** own record with `level = nil`. The UI shows it as a host for accessories, not as a battery.
- **AirPods with one bud:** only the components reported get records. A missing component keeps its last record and ages out naturally.
- **Corrupt cache:** `read()` gives `nil`, the widget shows its placeholder, and the next successful `update` rewrites the file from the fetched data.
- **Unknown future schema:** shown with `needsNewerApp` (R6). Old fields keep working.
- **Device name:** on iOS 16+ `UIDevice.name` returns a generic model name unless the app has the user-assigned-device-name entitlement ([doc](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.device-information.user-assigned-device-name)). R17 defines the default and the in-app rename. Two devices of the same model both show "iPhone" until one is renamed.
- **Deleted record still in the cache:** removed by the next full fetch (R14), unless it is our own pending one.

## Acceptance criteria

- [ ] AC1 — Given a `DeviceBattery` with every field set, when mapped to a `CKRecord` and back, then the result equals the original except `serverModifiedAt` (R15).
- [ ] AC2 — Given a model with `level = nil` and `isLowPowerMode = nil`, when mapped to a record, then the `level` and `isLowPowerMode` keys are absent (R3).
- [ ] AC3 — Given a record with `level = 140`, when decoded, then `level == 100`. Given `-3`, then `0` (R3).
- [ ] AC4 — Given a record with `type = "vision"`, when decoded, then `kind == .other` (R4).
- [ ] AC5 — Given a record missing `updatedAt`, or with record name `"abc"`, when a batch of 3 records is decoded, then the other 2 decode and 1 is skipped (R5).
- [ ] AC6 — Given `schemaVersion = 2`, when decoded, then `needsNewerApp == true` and `level` is readable (R6).
- [ ] AC7 — Given a model, when mapped, then `name` is in `encryptedValues` and not in the plain fields (R7).
- [ ] AC8 — Given `accessoryKey = "AA:BB:CC:DD:EE:FF"` and `.left`, when `DeviceID.accessory` is called twice (and on another machine), then both IDs are equal, and they differ from the `.right` ID (R2). A golden test pins one known output UUID.
- [ ] AC9 — Given `updatedAt = now + 10 min` and `serverModifiedAt = now − 1 min`, then `readingDate == now − 1 min`. Given `updatedAt = now + 5 min` and no `serverModifiedAt`, then `readingDate == now` (R8, R9).
- [ ] AC10 — Given an iPhone at 1 h 59 min and 2 h 1 min, a Mac at 65 min and 66 min, an iPhone charging at 60 % at 31 min and at 2 h 1 min, a Mac charging at 60 % at 30 min and 31 min, an accessory charging at 60 % at 31 min, and a Mac at 100 % with `isCharging` at 40 min, then freshness is fresh, stale, fresh, stale, fresh, stale, fresh, stale, stale, fresh. Given an age of 31 days, then `isRetired` is true (R10).
- [ ] AC16 — Given power states charging, full, pluggedIn, unplugged and unknown, when mapped (R16), then (`isCharging`, `isPluggedIn`) are (true, true), (true, true), (false, true), (false, false), (false, nil).
- [ ] AC17 — Given no rename, then the default name is "iPhone" for `.iphone` and "Apple Watch" for `.watch`; given `thisDeviceName = "Work Phone"`, then the reported name is "Work Phone" (R17).
- [ ] AC11 — Given no file, a file with `formatVersion = 99`, or garbage bytes, when `read()` is called, then it returns `nil` and does not throw (R12).
- [ ] AC12 — Given two processes (simulated by two threads with separate `NSFileCoordinator`s) each calling `update` 100 times to set a distinct device, then the final file contains all 200 entries (R13).
- [ ] AC13 — Given a cache with devices A, B and own O (O pending), when merging a full fetch that returns only A (newer), then the cache holds A (new) and O, and not B (R14).
- [ ] AC14 — Given a cache entry A with `updatedAt` T2, when merging fetched A with `updatedAt` T1 < T2, then the cached A is kept (R14).
- [ ] AC15 — Given an App Group ID without the entitlement, when `SnapshotCache(appGroupID:)` is created, then it returns `nil` on iOS and on macOS. **Needs a signed build on a device or Mac.**

## Tests

- AC1–AC14, AC16, AC17: Swift Testing unit tests in the Shared package. `CKRecord` can be created offline; no account is needed. AC12 uses a temp directory.
- AC15: a manual check on a signed build per platform (entitlements are not applied in plain `swift test`).
- Widget rendering from the cache is covered in the UI specs.

## Open questions

- None for the owner.
