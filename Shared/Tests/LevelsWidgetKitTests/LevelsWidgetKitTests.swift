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

    // MARK: systemLarge (UI-003 R3, R4, AC3; UI-004 R11)

    @Test func AC3_tenDevicesShowEightRowsAndTwoMoreInListOrder() {
        let devices = (1...10).map { d($0, $0 == 1 ? .mac : .iphone, "D\($0)", 100 - $0 * 5) }
        let e = entry(devices)
        let list = e.largeList(excludingThisDevice: false)
        #expect(list.shown.count == 8)
        #expect(list.moreCount == 2)
        #expect(list.shown.map(\.id) == Array(e.rows.prefix(8)).map(\.id))
        #expect(list.shown.first?.isThisDevice == true)  // UI-001 order: this device first
    }

    @Test func macLargeAndMediumLeaveThisMacOut() {
        let devices = (1...10).map { d($0, $0 == 1 ? .mac : .iphone, "D\($0)", 100 - $0 * 5) }
        let e = entry(devices)
        let large = e.largeList(excludingThisDevice: true)
        #expect(large.shown.count == 8 && large.moreCount == 1)
        #expect(!large.shown.contains { $0.isThisDevice })
        #expect(large.shown.map(\.id) == Array(e.rows.filter { !$0.isThisDevice }.prefix(8)).map(\.id))
        let medium = e.mediumRows(excludingThisDevice: true)
        #expect(medium.count == 4 && !medium.contains { $0.isThisDevice })
        #expect(e.mediumRows(excludingThisDevice: false).first?.isThisDevice == true)
    }

    @Test func macListKeepsThisMacWhenAlone() {
        let e = entry([d(1, .mac, "Mac", 66)])
        #expect(e.largeList(excludingThisDevice: true).shown.map(\.name) == ["Mac"])
        #expect(e.mediumRows(excludingThisDevice: true).map(\.name) == ["Mac"])
    }

    @Test func largeShowsAllWhenEightOrFewer() {
        let e = entry((1...8).map { d($0, .iphone, "D\($0)", 50) })
        #expect(e.largeList(excludingThisDevice: false).shown.count == 8 && e.largeList(excludingThisDevice: false).moreCount == 0)
        let one = entry([d(1, .mac, "Mac", 66)])
        #expect(one.largeList(excludingThisDevice: false).shown.count == 1 && one.largeList(excludingThisDevice: false).moreCount == 0)
        #expect(one.isOnlyThisDevice)
    }

    @Test func largeKeepsStaleAndNoBatteryRowsAndDropsHidden() {
        let e = DeviceEntry(date: now, snapshot: SnapshotFile(ownDeviceID: id(1), devices: [
            d(1, .mac, "Mac", nil), d(2, .iphone, "iPhone", 40, age: 5 * 3600), d(3, .watch, "Watch", 30)]),
            preferences: DisplayPreferences(hidden: [id(3)]))
        let shown = e.largeList(excludingThisDevice: false).shown
        #expect(shown.map(\.name) == ["Mac", "iPhone"])
        #expect(shown[1].freshness(at: now) == .stale)
        #expect(!e.isOnlyThisDevice)
    }

    @Test func largeListEmptyWithoutCache() {
        let e = DeviceEntry(date: now, snapshot: nil, preferences: DisplayPreferences())
        #expect(e.largeList(excludingThisDevice: true) == LargeList(rows: []))
        #expect(e.largeList(excludingThisDevice: false).moreCount == 0)
    }

    @Test func macOffersLargeFamily() {
        #expect(LevelsDevicesWidget.families == [.systemSmall, .systemMedium, .systemLarge])
    }

    // MARK: Configuration (UI-003 R1, AC2, AC9; UI-004 R12)

    @Test func AC2_configuredDeviceWinsOverLowest() {
        let e = DeviceEntry(date: now, snapshot: SnapshotFile(ownDeviceID: id(1), devices: [
            d(1, .mac, "Mac", 10), d(2, .iphone, "iPhone", 40), d(3, .watch, "Watch", 90)]),
            preferences: DisplayPreferences(), selection: id(3))
        #expect(e.singleDevice(excludingThisDevice: true)?.name == "Watch")
    }

    @Test func configuredThisMacIsShown() {
        let e = DeviceEntry(date: now, snapshot: SnapshotFile(ownDeviceID: id(1), devices: [
            d(1, .mac, "Mac", 90), d(2, .iphone, "iPhone", 40)]), preferences: DisplayPreferences(), selection: id(1))
        #expect(e.singleDevice(excludingThisDevice: true)?.name == "Mac")
    }

    @Test func hiddenOrDeletedSelectionFallsBackToLowest() {
        let devices = [d(1, .mac, "Mac", 10), d(2, .iphone, "iPhone", 40), d(3, .watch, "Watch", 30)]
        let hidden = DeviceEntry(date: now, snapshot: SnapshotFile(ownDeviceID: id(1), devices: devices),
                                 preferences: DisplayPreferences(hidden: [id(2)]), selection: id(2))
        #expect(hidden.singleDevice(excludingThisDevice: true)?.name == "Watch")
        let gone = DeviceEntry(date: now, snapshot: SnapshotFile(ownDeviceID: id(1), devices: devices),
                               preferences: DisplayPreferences(), selection: id(9))
        #expect(gone.singleDevice(excludingThisDevice: true)?.name == "Watch")
    }

    @Test func AC9_choicesAreLowestThenShownRowsIncludingThisMac() {
        let e = DeviceEntry(date: now, snapshot: SnapshotFile(ownDeviceID: id(1), devices: [
            d(1, .mac, "Mac", 66), d(2, .iphone, "iPhone", 40), d(3, .watch, "Watch", 30)]),
            preferences: DisplayPreferences(hidden: [id(2)]))
        let choices = DeviceChoiceQuery.choices(rows: e.rows)
        #expect(choices.map(\.id) == [DeviceChoice.lowestID, id(1).recordName, id(3).recordName])
        #expect(choices[0].deviceID == nil)
        #expect(choices[1].deviceID == id(1))
    }

    @Test func timelineEntriesCarryTheSelection() {
        let entries = DevicesTimeline.entries(snapshot: SnapshotFile(ownDeviceID: id(1), devices: [d(1, .mac, "Mac", 66)]),
                                              preferences: DisplayPreferences(), now: now, selection: id(1))
        #expect(entries.allSatisfy { $0.selection == id(1) })
    }

    @Test func deviceURL() {
        #expect(LevelsAppConfig.deviceURL(id(2)).absoluteString == "levels://device/00000000-0000-0000-0000-000000000002")
    }
}
