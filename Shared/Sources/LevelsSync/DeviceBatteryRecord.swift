import CloudKit
import Foundation
import LevelsModel
import os

/// Maps ``DeviceBattery`` to and from `DeviceBattery` CloudKit records (ADR-0005, SYNC-002).
public enum DeviceBatteryRecord {
    public static let recordType = "DeviceBattery"
    public static let zoneName = "Levels"

    /// Record field names (ADR-0005). `name` lives in `encryptedValues`.
    public enum Field {
        public static let schemaVersion = "schemaVersion"
        public static let deviceId = "deviceId"
        public static let type = "type"
        public static let parentDeviceId = "parentDeviceId"
        public static let accessoryKind = "accessoryKind"
        public static let accessoryGroupId = "accessoryGroupId"
        public static let component = "component"
        public static let level = "level"
        public static let isCharging = "isCharging"
        public static let isPluggedIn = "isPluggedIn"
        public static let isLowPowerMode = "isLowPowerMode"
        public static let updatedAt = "updatedAt"
        public static let name = "name"
    }

    private static let logger = Logger(subsystem: (Bundle.main.bundleIdentifier ?? "levels"), category: "sync")

    /// A fresh record named by the model's ID in `zoneID` (ADR-0008: no change tag).
    public static func record(for model: DeviceBattery, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: model.id.recordName, zoneID: zoneID))
        apply(model, to: record)
        return record
    }

    /// Writes every field of `model` into `record`, removing keys whose value is `nil`.
    /// Used for new records and for the accessory conflict retry on the server copy.
    public static func apply(_ model: DeviceBattery, to record: CKRecord) {
        record[Field.schemaVersion] = Int64(model.schemaVersion)
        record[Field.deviceId] = model.id.recordName
        record[Field.type] = model.kind.rawValue
        record[Field.parentDeviceId] = model.accessory?.parentDeviceID.recordName
        record[Field.accessoryKind] = model.accessory?.kind.rawValue
        record[Field.accessoryGroupId] = model.accessory?.groupID.uuidString.lowercased()
        record[Field.component] = model.accessory?.component.rawValue
        record[Field.level] = model.level.map { Int64($0) }
        record[Field.isCharging] = flag(model.isCharging)
        record[Field.isPluggedIn] = model.isPluggedIn.map(flag)
        record[Field.isLowPowerMode] = model.isLowPowerMode.map(flag)
        record[Field.updatedAt] = model.updatedAt
        record.encryptedValues[Field.name] = model.name
    }

    /// Decodes a record, or returns `nil` (and logs) when it must be skipped (SYNC-002 R5):
    /// wrong record type, a record name that isn't a UUID, a missing required field
    /// (`deviceId`, `type`, `isCharging`, `updatedAt`, `name`), or an accessory without a
    /// valid `parentDeviceId`. Unknown fields are ignored; unknown enum strings fall back (R4).
    public static func model(from record: CKRecord) -> DeviceBattery? {
        let recordName = record.recordID.recordName
        func skip(_ why: String) -> DeviceBattery? {
            logger.error("Skipping record \(recordName, privacy: .public): \(why, privacy: .public)")
            return nil
        }
        guard record.recordType == recordType else { return skip("record type \(record.recordType)") }
        guard let id = DeviceID(recordName: recordName) else { return skip("record name is not a UUID") }
        guard record[Field.deviceId] is String else { return skip("missing deviceId") }
        guard let type = record[Field.type] as? String else { return skip("missing type") }
        guard let isCharging = bool(record[Field.isCharging]) else { return skip("missing isCharging") }
        guard let updatedAt = record[Field.updatedAt] as? Date else { return skip("missing updatedAt") }
        guard let name = record.encryptedValues[Field.name] as? String else { return skip("missing name") }

        let kind = DeviceKind(parsing: type)
        var accessory: AccessoryInfo?
        if kind == .accessory {
            guard let parentName = record[Field.parentDeviceId] as? String,
                  let parent = DeviceID(recordName: parentName)
            else { return skip("accessory without parentDeviceId") }
            accessory = AccessoryInfo(
                parentDeviceID: parent,
                kind: (record[Field.accessoryKind] as? String).map(AccessoryKind.init(parsing:)) ?? .other,
                // A single-battery accessory may omit the group; it is then its own group.
                groupID: (record[Field.accessoryGroupId] as? String).flatMap(UUID.init(uuidString:)) ?? id.uuid,
                component: (record[Field.component] as? String).map(AccessoryComponent.init(parsing:)) ?? .main
            )
        }

        return DeviceBattery(
            id: id,
            schemaVersion: (record[Field.schemaVersion] as? NSNumber)?.intValue ?? 1,
            name: name,
            kind: kind,
            accessory: accessory,
            level: (record[Field.level] as? NSNumber).flatMap { DeviceBattery.clampedLevel($0.doubleValue) },
            isCharging: isCharging,
            isPluggedIn: bool(record[Field.isPluggedIn]),
            isLowPowerMode: bool(record[Field.isLowPowerMode]),
            updatedAt: updatedAt,
            serverModifiedAt: record.modificationDate
        )
    }

    /// Decodes a batch, skipping bad records without stopping the rest (SYNC-002 R5).
    public static func models(from records: [CKRecord]) -> [DeviceBattery] {
        records.compactMap(model(from:))
    }

    private static func flag(_ value: Bool) -> Int64 { value ? 1 : 0 }

    private static func bool(_ value: (any CKRecordValue)?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }
}
