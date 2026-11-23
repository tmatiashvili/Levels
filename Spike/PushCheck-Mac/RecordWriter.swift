// SPIKE-001 throwaway code. Not kept after the spike.
//
// Writes (overwrites) one DeviceBattery record in zone `Levels` of the container
// named in the entitlements (Production, ADR-0005 rule 5). Fields follow ADR-0005 /
// SYNC-002. Every field is set, so a Development run also creates the full schema
// for "Deploy Schema Changes" (README step 4).

import CloudKit
import Foundation
import Observation

@MainActor
@Observable
final class RecordWriter {
    /// Newest first.
    private(set) var lines: [String] = []
    private(set) var isBusy = false
    private(set) var writeCount = 0

    @ObservationIgnored private let container = CKContainer(identifier: SpikeConfig.containerID)
    @ObservationIgnored private var zoneReady = false
    @ObservationIgnored private let formatter: DateFormatter

    private var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: SpikeConfig.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    private var recordID: CKRecord.ID {
        CKRecord.ID(recordName: SpikeConfig.testRecordName, zoneID: zoneID)
    }

    init() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS xxx"
        self.formatter = formatter
    }

    var text: String {
        lines.reversed().joined(separator: "\n")
    }

    func write() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let database = container.privateCloudDatabase
        do {
            try await ensureReady(database)

            let now = Date()
            let record = makeRecord(updatedAt: now)
            let (saveResults, _) = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .allKeys,   // fresh CKRecord, overwrite (SYNC-001 R6)
                atomically: true
            )
            guard let result = saveResults[recordID] else {
                add("ERROR", "no save result for the test record")
                return
            }
            switch result {
            case .success(let saved):
                writeCount += 1
                let server = saved.modificationDate.map { formatter.string(from: $0) } ?? "nil"
                let level = (saved["level"] as? Int64).map(String.init) ?? "?"
                add("WRITE", "#\(writeCount) saved, level=\(level), updatedAt=\(formatter.string(from: now)), server modificationDate=\(server)")
            case .failure(let error):
                add("ERROR", "save failed: \(Self.describe(error))")
            }
        } catch {
            add("ERROR", "write failed: \(Self.describe(error))")
        }
    }

    func deleteTestRecord() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            _ = try await container.privateCloudDatabase.deleteRecord(withID: recordID)
            add("DELETE", "test record \(SpikeConfig.testRecordName) deleted")
        } catch let error as CKError where error.code == .unknownItem {
            add("DELETE", "test record was already gone")
        } catch {
            add("ERROR", "delete failed: \(Self.describe(error))")
        }
    }

    private func ensureReady(_ database: CKDatabase) async throws {
        if zoneReady { return }
        let status = try await container.accountStatus()
        add("SETUP", "account status: \(status == .available ? "available" : "not available (\(status.rawValue))")")
        guard status == .available else {
            throw CKError(.notAuthenticated)
        }
        // Saving an existing zone is success (ADR-0005).
        let zone = try await database.save(CKRecordZone(zoneID: zoneID))
        add("SETUP", "zone \(zone.zoneID.zoneName) ready")
        zoneReady = true
    }

    private func makeRecord(updatedAt: Date) -> CKRecord {
        let record = CKRecord(recordType: SpikeConfig.recordType, recordID: recordID)
        // ADR-0005 field table. Dummy values; the record is deleted after the spike.
        record["schemaVersion"] = Int64(1)
        record["deviceId"] = SpikeConfig.testRecordName
        record["type"] = "mac"
        record["parentDeviceId"] = SpikeConfig.testRecordName
        record["accessoryKind"] = "other"
        record["accessoryGroupId"] = "spike-001"
        record["component"] = "main"
        record["level"] = Int64.random(in: 1...100)
        record["isCharging"] = Int64(0)
        record["isPluggedIn"] = Int64(1)
        record["isLowPowerMode"] = Int64(0)
        record["updatedAt"] = updatedAt
        record.encryptedValues["name"] = "SPIKE-001 test record"
        return record
    }

    private func add(_ kind: String, _ message: String) {
        lines.insert("\(formatter.string(from: Date())) | \(kind) | \(message)", at: 0)
    }

    private static func describe(_ error: any Error) -> String {
        if let ck = error as? CKError {
            return "CKError \(ck.code.rawValue) (\(ck.code)): \(ck.localizedDescription)"
        }
        return error.localizedDescription
    }
}
