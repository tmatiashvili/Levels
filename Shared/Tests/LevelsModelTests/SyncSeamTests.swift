import Foundation
import Testing
@testable import LevelsModel

@Suite("Sync seam")
struct SyncSeamTests {
    @Test("isUrgent matches SYNC-001 R5a")
    func urgentReasons() {
        let urgent = Set(ReportReason.allCases.filter(\.isUrgent))
        #expect(urgent == [.launch, .appIntent, .sleep, .wake, .chargerChange, .userRefresh])
    }

    @Test("SyncStatus round-trips through JSON")
    func syncStatusCodable() throws {
        let values: [SyncStatus] = [.idle, .localOnly, .signedOut, .misconfigured(code: 7), .offline(lastFetchAt: now), .offline(lastFetchAt: nil)]
        let data = try JSONEncoder().encode(values)
        #expect(try JSONDecoder().decode([SyncStatus].self, from: data) == values)
    }

    @Test("BatterySyncing can be faked")
    func fake() async {
        struct Fake: BatterySyncing {
            func report(_ readings: [DeviceBattery], reason: ReportReason) async -> ReportOutcome {
                reason.isUrgent ? .uploaded : .held(until: now)
            }
            var status: SyncStatus { get async { .idle } }
            func refresh(_ reason: RefreshReason) async -> Bool { reason == .userPull }
        }
        let sync: any BatterySyncing = Fake()
        #expect(await sync.report([], reason: .launch) == .uploaded)
        #expect(await sync.report([], reason: .heartbeat) == .held(until: now))
        #expect(await sync.status == .idle)
        #expect(await sync.refresh(.userPull))
        #expect(await sync.refresh(.wake) == false)
    }

    @Test("FixedDeviceIdentity returns its value")
    func fixedIdentity() throws {
        let id = DeviceID(UUID())
        let identity: any DeviceIdentityProviding = FixedDeviceIdentity(id)
        #expect(try identity.currentDeviceID() == id)
        #expect(try FixedDeviceIdentity(nil).currentDeviceID() == nil)
    }
}
