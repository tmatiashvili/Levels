import Foundation
import LevelsModel
import Synchronization
import Testing
@testable import LevelsUI

/// A clock the test moves.
private final class TestClock: Sendable {
    private let value = Mutex(now)
    var date: Date { value.withLock { $0 } }
    func advance(_ s: TimeInterval) { value.withLock { $0 += s } }
}

@Suite("DEMO-001 demo list")
@MainActor
struct DemoSnapshotSourceTests {
    @Test("The demo store lists the R2 devices, AirPods as one row, no hub banner")
    func listsSampleDevices() async {
        let store = DeviceListStore(source: DemoSnapshotSource(now: { now }), preferences: InMemoryDisplayPreferencesStore(),
                                    now: { now }, isHubMode: true)
        await store.reload()
        #expect(store.state == .loaded)
        #expect(store.thisDeviceID == SampleDevices.iPhoneID)
        #expect(store.rows.count == 5)
        #expect(store.rows.first?.isThisDevice == true)
        let pods = store.rows.first { $0.isGroup }
        #expect(pods?.name == "AirPods Pro")
        #expect(pods?.memberIDs.count == 3)
        #expect(store.oldRows.isEmpty)
    }

    @Test("R2: every read measures ages from now")
    func agesStayLive() async throws {
        let clock = TestClock()
        let source = DemoSnapshotSource(now: { clock.date })
        let first = try await source.current()
        clock.advance(6 * 3600)
        let later = try await source.current()
        let mac = { (f: SnapshotFile) in f.devices.first { $0.id == SampleDevices.macID }! }
        #expect(clock.date.timeIntervalSince(mac(later).updatedAt) == now.timeIntervalSince(mac(first).updatedAt))
    }

    @Test("R4: rename and hide stay in memory; the real preferences are untouched")
    func renameAndHideInMemory() async throws {
        let suite = "levels-demo-ui-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let real = UserDefaultsDisplayPreferencesStore(suiteName: suite)
        let before = real.load()

        let source = DemoSnapshotSource(now: { now })
        let store = DeviceListStore(source: source, preferences: InMemoryDisplayPreferencesStore(), now: { now },
                                    isHubMode: true)
        await store.reload()
        #expect(store.canRename(try #require(store.rows.first)))
        await store.renameThisDevice(to: "Test phone")
        #expect(store.rows.first?.name == "Test phone")
        store.setHidden(SampleDevices.watchID, true)
        #expect(store.hiddenRows.map(\.id) == [SampleDevices.watchID])
        #expect(real.load() == before)
    }

    @Test("R5: Remove and Remove all my data refuse and change nothing")
    func removeRefuses() async throws {
        let store = DeviceListStore(source: DemoSnapshotSource(now: { now }), preferences: InMemoryDisplayPreferencesStore(),
                                    now: { now }, isHubMode: true)
        await store.reload()
        await #expect(throws: DemoSnapshotSource.DemoError.notInDemo) { try await store.removeAllData() }
        await #expect(throws: DemoSnapshotSource.DemoError.notInDemo) { try await store.remove(SampleDevices.iPadID) }
        #expect(!store.isReportingOff)
        #expect(store.rows.count == 5)
    }
}
