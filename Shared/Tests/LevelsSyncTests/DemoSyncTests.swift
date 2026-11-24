import Foundation
import LevelsModel
import Synchronization
import Testing
@testable import LevelsSync

/// Records every call that reaches the "real" sync.
private final class RecordingSync: BatterySyncing {
    private let calls = Mutex<[String]>([])
    var log: [String] { calls.withLock { $0 } }

    func report(_ readings: [DeviceBattery], reason: ReportReason) async -> ReportOutcome {
        calls.withLock { $0.append("report") }
        return .uploaded
    }

    var status: SyncStatus {
        get async {
            calls.withLock { $0.append("status") }
            return .notPaired
        }
    }

    func refresh(_ reason: RefreshReason) async -> Bool {
        calls.withLock { $0.append("refresh") }
        return true
    }
}

private let phoneID = DeviceID(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!)

private func phone(level: Int, at: Date) -> DeviceBattery {
    DeviceBattery(id: phoneID, name: "iPhone", kind: .iphone, level: level, isCharging: false, updatedAt: at)
}

@Suite("DEMO-001 demo sync")
struct DemoSyncTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("levels-demo-\(UUID().uuidString)")
    var cache: SnapshotCache { SnapshotCache(directory: directory) }

    @Test("DemoSyncService drops reports, has nothing to fetch, says local only")
    func demoServiceIsInert() async {
        let demo = DemoSyncService()
        #expect(await demo.report([phone(level: 50, at: .now)], reason: .launch) == .skipped)
        #expect(await demo.refresh(.userPull))
        #expect(await demo.status == .localOnly)
        #expect(demo.droppedReports == 1)
    }

    @Test("AC3: while demo is on the real sync gets no call at all")
    func ac3RealSyncUntouched() async {
        let real = RecordingSync()
        let mode = DemoModeSetting.inMemory(on: true)
        let sync = DemoAwareSync(real: real, mode: mode)
        _ = await sync.report([phone(level: 50, at: .now)], reason: .userRefresh)
        _ = await sync.refresh(.foreground)
        #expect(await sync.status == .localOnly)
        #expect(real.log.isEmpty)
        #expect(sync.demo.droppedReports == 1)
    }

    @Test("AC4: after Exit the next call reaches the real sync")
    func ac4ExitRoutesToReal() async {
        let real = RecordingSync()
        let mode = DemoModeSetting.inMemory(on: true)
        let sync = DemoAwareSync(real: real, mode: mode)
        _ = await sync.report([phone(level: 50, at: .now)], reason: .launch)
        mode.setOn(false)
        _ = await sync.report([phone(level: 51, at: .now)], reason: .foreground)
        _ = await sync.refresh(.foreground)
        #expect(await sync.status == .notPaired)
        #expect(real.log == ["report", "refresh", "status"])
        #expect(sync.demo.droppedReports == 1)
    }

    @Test("AC3, AC4: demo never writes the real cache; after Exit reports write it again")
    func ac3ac4RealCache() async throws {
        let reloads = Mutex(0)
        let clock = ManualClock()
        let local = LocalOnlySyncService(cache: cache, widgetReloader: { reloads.withLock { $0 += 1 } },
                                         now: { clock.date }, clock: clock)
        let before = phone(level: 70, at: clock.date)
        _ = await local.report([before], reason: .launch)
        let original = try #require(try Data(contentsOf: cache.fileURL))

        let mode = DemoModeSetting.inMemory(on: true)
        let sync = DemoAwareSync(real: local, mode: mode)
        for (i, reason) in [ReportReason.userRefresh, .launch, .chargerChange].enumerated() {
            clock.advance(by: .seconds(120))
            _ = await sync.report([phone(level: 10 + i, at: clock.date)], reason: reason)
        }
        _ = await sync.refresh(.userPull)
        #expect(try Data(contentsOf: cache.fileURL) == original)  // byte for byte
        #expect(reloads.withLock { $0 } == 1)  // only the pre-demo write

        mode.setOn(false)
        clock.advance(by: .seconds(120))
        let after = phone(level: 33, at: clock.date)
        #expect(await sync.report([after], reason: .userRefresh) == .uploaded)
        #expect(cache.read()?.devices.first { $0.id == phoneID }?.level == 33)
    }
}
