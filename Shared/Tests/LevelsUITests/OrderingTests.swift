import Foundation
import LevelsModel
import Testing
@testable import LevelsUI

@Suite("UI-001 ordering, grouping, hiding, old devices")
struct OrderingTests {
    let iPhone = device(id(1), .iphone, "iPhone", level: 62)
    let mac = device(id(2), .mac, "Mac", level: 18)
    let watch = device(id(3), .watch, "Watch", level: 81)
    let iPad = device(id(4), .ipad, "Alpha", level: 18)

    @Test func AC1_thisDeviceFirstThenLevelThenName() {
        let sorted = DeviceOrdering.sorted([watch, mac, iPad, iPhone], thisDeviceID: iPhone.id,
                                           preferences: DisplayPreferences())
        #expect(sorted.map(\.name) == ["iPhone", "Alpha", "Mac", "Watch"])
        #expect(rows([watch, mac, iPad, iPhone], this: iPhone.id).rows.map(\.name) == ["iPhone", "Alpha", "Mac", "Watch"])
    }

    @Test func AC1_nameTieIsCaseInsensitiveThenDeviceID() {
        let a = device(id(9), .iphone, "iphone", level: 50)
        let b = device(id(8), .iphone, "iPhone", level: 50)
        let c = device(id(7), .iphone, "Banana", level: 50)
        #expect(rows([a, b, c]).rows.map(\.id) == [c.id, b.id, a.id])
    }

    @Test func unknownOwnDeviceID_noRowPinnedFirst() {
        #expect(rows([iPhone, mac]).rows.map(\.id) == [mac.id, iPhone.id])
    }

    @Test func AC4_hiddenDeviceIsNotInRows() {
        let built = rows([iPhone, mac, watch], this: iPhone.id, preferences: DisplayPreferences(hidden: [mac.id]))
        #expect(!built.rows.contains { $0.id == mac.id })
        #expect(built.hiddenRows.map(\.id) == [mac.id])
        #expect(!DeviceOrdering.sorted([iPhone, mac], thisDeviceID: nil,
                                       preferences: DisplayPreferences(hidden: [mac.id])).contains(mac))
    }

    @Test func AC4_staleHiddenEntryForRemovedDeviceIsIgnored() {
        let built = rows([iPhone], this: iPhone.id, preferences: DisplayPreferences(hidden: [id(99)]))
        #expect(built.rows.map(\.id) == [iPhone.id])
    }

    @Test func AC13_noBatterySortsAfterDevicesWithALevel() {
        let iMac = device(id(5), .mac, "Aardvark iMac", level: nil)
        #expect(rows([iMac, watch, mac]).rows.map(\.name) == ["Mac", "Watch", "Aardvark iMac"])
    }

    @Test func AC14_airPodsGroupIsOneRowSortedByLowestComponent() {
        let pods = [airPod(.case, level: 80), airPod(.left, level: 40), airPod(.right, level: 35)]
        let mid = device(id(6), .iphone, "Phone", level: 36)
        let low = device(id(7), .ipad, "Pad", level: 34)
        let built = rows([mid, low] + pods)
        #expect(built.rows.count == 3)
        #expect(built.rows.map(\.name) == ["Pad", "AirPods Pro", "Phone"])
        let row = built.rows[1]
        #expect(row.isGroup)
        #expect(row.id == DeviceID(airPodsGroup))
        #expect(row.level == 35)
        #expect(row.components.map { $0.accessory!.component } == [.left, .right, .case])
        #expect(row.components.map(\.level) == [40, 35, 80])
    }

    @Test func AC14_missingComponentIsLeftOut() {
        let built = rows([airPod(.left, level: 40), airPod(.case, level: 90)])
        #expect(built.rows.count == 1)
        #expect(built.rows[0].components.map { $0.accessory!.component } == [.left, .case])
    }

    @Test func groupIsNamedAfterTheHeadset() {
        let built = rows([airPod(.left, level: 40, name: "AirPods Pro Left"), airPod(.case, level: 90)])
        #expect(built.rows[0].name == "AirPods Pro")
    }

    @Test func singleBatteryAccessoryIsAPlainRow() {
        let mouse = DeviceBattery(id: .accessory(key: "M", component: .main), name: "Magic Mouse", kind: .accessory,
                                  accessory: AccessoryInfo(parentDeviceID: id(2), kind: .mouse, groupID: UUID(), component: .main),
                                  level: 50, isCharging: false, updatedAt: now)
        let row = rows([mouse]).rows[0]
        #expect(!row.isGroup)
        #expect(row.id == mouse.id)
    }

    @Test func hidingAGroupHidesAllComponents() {
        let pods = [airPod(.left, level: 40), airPod(.right, level: 35)]
        let built = rows(pods, preferences: DisplayPreferences(hidden: [DeviceID(airPodsGroup)]))
        #expect(built.rows.isEmpty)
        #expect(built.hiddenRows.count == 1)
    }

    @Test(arguments: [(31.0, true), (30.0, true), (29.0, false)])
    func AC15_oldDevicesMoveToOldRows(days: Double, old: Bool) {
        let gone = device(id(2), .mac, "Old Mac", level: 50, age: days * day)
        let built = rows([iPhone, gone], this: iPhone.id)
        #expect(built.oldRows.contains { $0.id == gone.id } == old)
        #expect(built.rows.contains { $0.id == gone.id } == !old)
    }

    @Test func AC15_thisDeviceIsNeverOldAndOldRowsKeepOrder() {
        let me = device(id(1), .iphone, "iPhone", level: 50, age: 60 * day)
        let a = device(id(2), .mac, "A", level: 70, age: 40 * day)
        let b = device(id(3), .mac, "B", level: 20, age: 40 * day)
        let built = rows([me, a, b], this: me.id)
        #expect(built.rows.map(\.id) == [me.id])
        #expect(built.oldRows.map(\.name) == ["B", "A"])
    }

    @Test func groupIsOldOnlyWhenAllComponentsAre() {
        let built = rows([airPod(.left, level: 40, age: 40 * day), airPod(.case, level: 90, age: 1 * day)])
        #expect(built.rows.count == 1)
        #expect(rows([airPod(.left, level: 40, age: 40 * day)]).oldRows.count == 1)
    }
}

@Suite("UI-001 freshness (R4, ADR-0017)")
struct FreshnessTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var kind: DeviceKind
        var level: Int?
        var charging: Bool
        var age: TimeInterval
        var expected: Freshness
        var testDescription: String { "\(kind) \(level.map(String.init) ?? "nil")% charging=\(charging) \(Int(age / 60)) min → \(expected)" }
    }

    @Test(arguments: [
        // AC2
        Case(kind: .mac, level: 50, charging: false, age: 66 * minute, expected: .stale),
        Case(kind: .mac, level: 50, charging: false, age: 65 * minute, expected: .fresh),
        // AC3
        Case(kind: .mac, level: 60, charging: true, age: 40 * minute, expected: .stale),
        Case(kind: .mac, level: 60, charging: false, age: 40 * minute, expected: .fresh),
        Case(kind: .mac, level: 100, charging: true, age: 40 * minute, expected: .fresh),
        Case(kind: .iphone, level: 60, charging: true, age: 90 * minute, expected: .fresh),
        // rest of the table
        Case(kind: .mac, level: 60, charging: true, age: 30 * minute, expected: .fresh),
        Case(kind: .iphone, level: 60, charging: false, age: 2 * hour, expected: .fresh),
        Case(kind: .iphone, level: 60, charging: false, age: 2 * hour + 1, expected: .stale),
        Case(kind: .ipad, level: 60, charging: true, age: 2 * hour + 1, expected: .stale),
        Case(kind: .watch, level: 60, charging: false, age: 119 * minute, expected: .fresh),
        Case(kind: .mac, level: nil, charging: false, age: 66 * minute, expected: .stale),
    ])
    func AC2_AC3_freshnessTable(_ c: Case) {
        let row = DeviceRowModel(record: device(id(1), c.kind, "D", level: c.level, charging: c.charging, age: c.age),
                                 isThisDevice: false)
        #expect(row.freshness(at: now) == c.expected)
    }

    @Test func AC12_futureUpdatedAtShowsNowAndIsFresh() {
        let d = device(id(2), .mac, "Mac", level: 50, age: -2 * minute)
        let row = DeviceRowModel(record: d, isThisDevice: false)
        #expect(row.freshness(at: now) == .fresh)
        #expect(row.readingDate(now: now) == now)
        #expect(AgeFormatting.text(readingDate: row.readingDate(now: now), now: now, locale: en) == "now")
    }

    @Test func AC14_eachComponentKeepsItsOwnStaleness() {
        let row = rows([airPod(.left, level: 40, age: 70 * minute), airPod(.right, level: 35, age: 5 * minute)]).rows[0]
        #expect(row.components.map { FreshnessRule.of($0, at: now) } == [.stale, .fresh])
        #expect(row.freshness(at: now) == .fresh)
    }

    @Test func staleChargingDeviceHidesBolt() {
        let stale = DeviceRowModel(record: device(id(2), .mac, "Mac", level: 50, charging: true, age: 40 * minute),
                                   isThisDevice: false)
        let fresh = DeviceRowModel(record: device(id(2), .mac, "Mac", level: 50, charging: true, age: 10 * minute),
                                   isThisDevice: false)
        #expect(!stale.showsChargingBolt(at: now))
        #expect(fresh.showsChargingBolt(at: now))
    }
}
