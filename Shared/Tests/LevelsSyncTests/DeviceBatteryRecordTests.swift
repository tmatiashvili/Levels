import CloudKit
import Foundation
import LevelsModel
import Testing
@testable import LevelsSync

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let zone = CKRecordZone.ID(zoneName: DeviceBatteryRecord.zoneName, ownerName: CKCurrentUserDefaultName)

private func fullAccessory() -> DeviceBattery {
    DeviceBattery(
        id: .accessory(key: "AA:BB:CC:DD:EE:FF", component: .left),
        name: "Tamar's AirPods",
        kind: .accessory,
        accessory: AccessoryInfo(parentDeviceID: DeviceID(UUID()), kind: .airpods, groupID: UUID(), component: .left),
        level: 42,
        isCharging: true,
        isPluggedIn: true,
        isLowPowerMode: false,
        updatedAt: now,
        serverModifiedAt: now + 5
    )
}

private func validRecord(name: String = UUID().uuidString.lowercased()) -> CKRecord {
    let model = DeviceBattery(id: DeviceID(recordName: name) ?? DeviceID(UUID()), name: "Phone", kind: .iphone,
                              level: 50, isCharging: false, updatedAt: now)
    let record = CKRecord(recordType: DeviceBatteryRecord.recordType, recordID: CKRecord.ID(recordName: name, zoneID: zone))
    DeviceBatteryRecord.apply(model, to: record)
    return record
}

@Suite("DeviceBattery record mapping")
struct DeviceBatteryRecordTests {
    @Test("AC1: model to record and back is lossless except serverModifiedAt")
    func ac1RoundTrip() throws {
        let original = fullAccessory()
        let record = DeviceBatteryRecord.record(for: original, zoneID: zone)
        #expect(record.recordID.recordName == original.id.recordName)
        #expect(record.recordID.zoneID.zoneName == "Levels")
        var expected = original
        expected.serverModifiedAt = nil
        #expect(DeviceBatteryRecord.model(from: record) == expected)

        let phone = DeviceBattery(id: DeviceID(UUID()), name: "iPhone", kind: .iphone, level: 0,
                                  isCharging: false, isPluggedIn: false, isLowPowerMode: true, updatedAt: now)
        #expect(DeviceBatteryRecord.model(from: DeviceBatteryRecord.record(for: phone, zoneID: zone)) == phone)
    }

    @Test("AC1: field types follow ADR-0005")
    func fieldTypes() {
        let record = DeviceBatteryRecord.record(for: fullAccessory(), zoneID: zone)
        #expect(record["schemaVersion"] as? Int64 == 1)
        #expect(record["level"] as? Int64 == 42)
        #expect(record["isCharging"] as? Int64 == 1)
        #expect(record["isLowPowerMode"] as? Int64 == 0)
        #expect(record["type"] as? String == "accessory")
        #expect(record["component"] as? String == "left")
        #expect(record["updatedAt"] as? Date == now)
    }

    @Test("AC2: nil level and isLowPowerMode leave the keys absent")
    func ac2AbsentKeys() {
        let model = DeviceBattery(id: DeviceID(UUID()), name: "Mac mini", kind: .mac, level: nil,
                                  isCharging: false, isPluggedIn: true, isLowPowerMode: nil, updatedAt: now)
        let record = DeviceBatteryRecord.record(for: model, zoneID: zone)
        #expect(!record.allKeys().contains("level"))
        #expect(!record.allKeys().contains("isLowPowerMode"))
        #expect(!record.allKeys().contains("parentDeviceId"))
        // apply() also clears keys on an existing (server) record.
        let existing = DeviceBatteryRecord.record(for: fullAccessory(), zoneID: zone)
        DeviceBatteryRecord.apply(model, to: existing)
        #expect(!existing.allKeys().contains("level"))
        #expect(!existing.allKeys().contains("accessoryKind"))
    }

    @Test("AC3: out-of-range levels are clamped, fractions rounded")
    func ac3Clamp() {
        let record = validRecord()
        record["level"] = Int64(140)
        #expect(DeviceBatteryRecord.model(from: record)?.level == 100)
        record["level"] = Int64(-3)
        #expect(DeviceBatteryRecord.model(from: record)?.level == 0)
        record["level"] = 55.6
        #expect(DeviceBatteryRecord.model(from: record)?.level == 56)
    }

    @Test("AC4: unknown type decodes as other; unknown accessory fields fall back; unknown fields ignored")
    func ac4Unknown() {
        let record = validRecord()
        record["type"] = "vision"
        record["futureField"] = "x"
        #expect(DeviceBatteryRecord.model(from: record)?.kind == .other)

        let acc = DeviceBatteryRecord.record(for: fullAccessory(), zoneID: zone)
        acc["accessoryKind"] = "pencil"
        acc["component"] = "stem"
        let model = DeviceBatteryRecord.model(from: acc)
        #expect(model?.accessory?.kind == .other)
        #expect(model?.accessory?.component == .main)
    }

    @Test("AC5: bad records are skipped, the rest decode", arguments: ["missingUpdatedAt", "badName"])
    func ac5Skip(_ defect: String) {
        let bad: CKRecord
        if defect == "badName" {
            bad = validRecord(name: "abc")
        } else {
            bad = validRecord()
            bad["updatedAt"] = nil
        }
        let models = DeviceBatteryRecord.models(from: [validRecord(), bad, validRecord()])
        #expect(models.count == 2)
    }

    @Test("R5: each required field is required")
    func r5Required() {
        for key in ["deviceId", "type", "isCharging", "updatedAt"] {
            let record = validRecord()
            record[key] = nil
            #expect(DeviceBatteryRecord.model(from: record) == nil, "missing \(key)")
        }
        let noName = validRecord()
        noName.encryptedValues["name"] = nil
        #expect(DeviceBatteryRecord.model(from: noName) == nil)

        let wrongType = CKRecord(recordType: "Other", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zone))
        #expect(DeviceBatteryRecord.model(from: wrongType) == nil)

        let orphan = DeviceBatteryRecord.record(for: fullAccessory(), zoneID: zone)
        orphan["parentDeviceId"] = nil
        #expect(DeviceBatteryRecord.model(from: orphan) == nil)
    }

    @Test("AC6: newer schemaVersion decodes and flags needsNewerApp")
    func ac6NewerSchema() {
        let record = validRecord()
        record["schemaVersion"] = Int64(2)
        let model = DeviceBatteryRecord.model(from: record)
        #expect(model?.needsNewerApp == true)
        #expect(model?.level == 50)
    }

    @Test("AC7: name is encrypted, not a plain field")
    func ac7EncryptedName() {
        let record = DeviceBatteryRecord.record(for: fullAccessory(), zoneID: zone)
        #expect(record.encryptedValues["name"] as? String == "Tamar's AirPods")
        // The plain subscript must not see it. (`allKeys()` lists encrypted keys too, so it can't be used here.)
        #expect(record["name"] == nil)
        #expect(record.object(forKey: "name") == nil)
    }

    @Test("R1: upper-case record names decode")
    func upperCaseRecordName() {
        let name = UUID().uuidString  // upper case
        let model = DeviceBatteryRecord.model(from: validRecord(name: name))
        #expect(model?.id.recordName == name.lowercased())
    }
}
