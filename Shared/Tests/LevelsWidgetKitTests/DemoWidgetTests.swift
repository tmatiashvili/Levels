import Foundation
import LevelsModel
import Testing
import WidgetKit
@testable import LevelsWidgetKit

@Suite("DEMO-001 demo widget")
struct DemoWidgetTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("AC7: flag on gives the sample snapshot; off gives nothing (the cache is used)")
    func ac7Flag() throws {
        let on = DemoModeSetting.inMemory(on: true)
        let snapshot = try #require(DevicesProvider.demoSnapshot(mode: on, now: t0))
        #expect(SampleDevices.isSample(snapshot))
        #expect(DevicesProvider.demoSnapshot(mode: .inMemory(on: false), now: t0) == nil)
    }

    @Test("AC7: one entry with the sample rows, reload in 30 min, footer flag set")
    func ac7Timeline() throws {
        let timeline = DemoWidgetPlan.timeline(snapshot: SampleDevices.snapshot(now: t0), now: t0, selection: nil)
        #expect(timeline.entries.count == 1)
        let entry = try #require(timeline.entries.first)
        #expect(entry.isSample)
        #expect(entry.rows.count == 5)
        #expect(entry.rows.first?.isThisDevice == true)
        #expect(entry.lowest?.id == SampleDevices.iPadID)  // the low iPad
        #expect(timeline.policy == .after(t0 + DemoWidgetPlan.reloadAfter))
    }

    @Test("A real snapshot is never marked as sample")
    func realIsNotSample() {
        let entry = DeviceEntry(date: t0, snapshot: SnapshotFile(ownDeviceID: DeviceID(UUID())), preferences: DisplayPreferences())
        #expect(!entry.isSample)
    }
}
