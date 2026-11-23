import Foundation
import LevelsModel
import Testing
import WidgetKit
@testable import LevelsWidgetKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func id(_ n: Int) -> DeviceID { DeviceID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }
private func d(_ n: Int, _ kind: DeviceKind, _ name: String, _ level: Int?, age: TimeInterval = 300, charging: Bool = false) -> DeviceBattery {
    DeviceBattery(id: id(n), name: name, kind: kind, level: level, isCharging: charging, updatedAt: now - age)
}

@Suite("UI-004 widgets")
struct LevelsWidgetKitTests {
    func entry(_ devices: [DeviceBattery], own: DeviceID? = id(1)) -> DeviceEntry {
        DeviceEntry(date: now, snapshot: SnapshotFile(ownDeviceID: own, devices: devices), preferences: DisplayPreferences())
    }

    @Test func AC7_smallDefaultIsLowestOtherDevice() {
        let e = entry([d(1, .mac, "Mac", 10), d(2, .iphone, "iPhone", 40), d(3, .watch, "Watch", 30)])
        #expect(e.lowest(excludingThisDevice: true)?.name == "Watch")
        #expect(e.lowest(excludingThisDevice: false)?.name == "Mac")
    }

    @Test func smallFallsBackToThisMacWhenAlone() {
        #expect(entry([d(1, .mac, "Mac", 66)]).lowest(excludingThisDevice: true)?.name == "Mac")
    }

    @Test func noCacheGivesEmptyEntry() {
        let e = DeviceEntry(date: now, snapshot: nil, preferences: DisplayPreferences())
        #expect(e.rows.isEmpty && e.snapshot == nil)
    }

    @Test func hiddenDevicesAreLeftOut() {
        let e = DeviceEntry(date: now, snapshot: SnapshotFile(ownDeviceID: id(1), devices: [d(1, .mac, "Mac", 66), d(2, .iphone, "iPhone", 40)]),
                            preferences: DisplayPreferences(hidden: [id(2)]))
        #expect(e.rows.map(\.name) == ["Mac"])
    }

    @Test func ADR0017_entryPerStaleMomentMergedWithin5Minutes() {
        // Mac 5 min old: stale at +60 min. iPhone 5 min old: stale at +115 min. Another Mac 7 min old: +58 min (merged).
        let rows = entry([d(1, .mac, "Mac", 66), d(2, .iphone, "iPhone", 40), d(3, .mac, "Other", 50, age: 420)]).rows
        let dates = DevicesTimeline.entryDates(rows: rows, now: now)
        #expect(dates == [now, now + 58 * 60, now + 115 * 60])
        #expect(DevicesTimeline.policy(entryCount: dates.count, now: now) == .atEnd)
    }

    @Test func ADR0017_noFutureStaleMomentReloadsAfter6Hours() {
        let rows = entry([d(1, .mac, "Mac", 66, age: 5 * 3600)]).rows
        #expect(DevicesTimeline.entryDates(rows: rows, now: now) == [now])
        #expect(DevicesTimeline.policy(entryCount: 1, now: now) == .after(now + 6 * 3600))
    }

    @Test func entriesShareTheSnapshot() {
        let entries = DevicesTimeline.entries(snapshot: SnapshotFile(ownDeviceID: id(1), devices: [d(1, .mac, "Mac", 66)]),
                                              preferences: DisplayPreferences(), now: now)
        #expect(entries.map(\.date) == [now, now + 60 * 60])
        #expect(entries.allSatisfy { $0.rows.count == 1 })
    }

    @Test func deviceURL() {
        #expect(LevelsAppConfig.deviceURL(id(2)).absoluteString == "levels://device/00000000-0000-0000-0000-000000000002")
    }
}
