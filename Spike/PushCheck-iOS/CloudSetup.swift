// SPIKE-001 throwaway code. Not kept after the spike.
//
// Account check, zone bootstrap and the database subscription, as in SYNC-001 R3:
// save zone `Levels` (an existing zone is success), then save
// CKDatabaseSubscription("levels-private-db") with shouldSendContentAvailable = true
// and nothing else. Saving the same subscription ID again is harmless.

import CloudKit
import Foundation

@MainActor
enum CloudSetup {
    static func run(log: PushLog) async {
        let container = CKContainer(identifier: SpikeConfig.containerID)
        let database = container.privateCloudDatabase
        log.add("SETUP", "start, container \(SpikeConfig.containerID)")

        // 1. iCloud account
        do {
            let status = try await container.accountStatus()
            log.add("SETUP", "account status: \(describe(status))")
            guard status == .available else {
                log.add("ERROR", "iCloud account not available; sign in to iCloud and tap Run setup again")
                return
            }
        } catch {
            log.add("ERROR", "account status failed: \(describe(error))")
            return
        }

        // 2. Zone `Levels`
        do {
            let zone = CKRecordZone(zoneName: SpikeConfig.zoneName)
            let saved = try await database.save(zone)
            log.add("SETUP", "zone saved: \(saved.zoneID.zoneName)")
        } catch {
            log.add("ERROR", "zone save failed: \(describe(error))")
            return
        }

        // 3. Database subscription, silent push only (no alert, badge or sound)
        do {
            let subscription = CKDatabaseSubscription(subscriptionID: SpikeConfig.subscriptionID)
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            let saved = try await database.save(subscription)
            log.add("SETUP", "subscription saved: \(saved.subscriptionID)")
        } catch {
            log.add("ERROR", "subscription save failed: \(describe(error))")
            return
        }

        // 4. Show what the server now holds, as a cross-check.
        do {
            let all = try await database.allSubscriptions()
            let ids = all.map(\.subscriptionID).joined(separator: ", ")
            log.add("SETUP", "server subscriptions: [\(ids)]")
        } catch {
            log.add("ERROR", "list subscriptions failed: \(describe(error))")
        }

        log.add("SETUP", "done, ready for the test")
    }

    static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: "available"
        case .noAccount: "noAccount"
        case .restricted: "restricted"
        case .couldNotDetermine: "couldNotDetermine"
        case .temporarilyUnavailable: "temporarilyUnavailable"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }

    static func describe(_ error: any Error) -> String {
        if let ck = error as? CKError {
            return "CKError \(ck.code.rawValue) (\(ck.code)): \(ck.localizedDescription)"
        }
        return error.localizedDescription
    }
}
