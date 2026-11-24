import Foundation
import Testing
@testable import LevelsModel

private let phoneID = DeviceID(UUID(uuidString: "BBBBBBBB-0000-0000-0000-0000000000B1")!)
private let macID = DeviceID(UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000A1")!)
private let otherMacID = DeviceID(UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000A2")!)
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func phone(_ level: Int = 50, charging: Bool = false, at: Date = t0) -> DeviceBattery {
    DeviceBattery(id: phoneID, name: "iPhone", kind: .iphone, level: level, isCharging: charging, updatedAt: at)
}

private func mac(_ level: Int = 80, id: DeviceID = macID, plugged: Bool = false, at: Date = t0) -> DeviceBattery {
    DeviceBattery(id: id, name: "MacBook", kind: .mac, level: level, isCharging: false, isPluggedIn: plugged, updatedAt: at)
}

private func pod(_ component: AccessoryComponent, _ level: Int?, charging: Bool = false, key: String = "AA:BB",
                 parent: DeviceID = macID, at: Date = t0) -> DeviceBattery {
    DeviceBattery(id: .accessory(key: key, component: component), name: "AirPods Pro", kind: .accessory,
                  accessory: AccessoryInfo(parentDeviceID: parent, kind: .airpods, groupID: DeviceID.accessoryGroup(key: key),
                                           component: component),
                  level: level, isCharging: charging, updatedAt: at)
}

private func state(_ devices: [LiveLevelsState.Device]) -> LiveLevelsState { LiveLevelsState(devices: devices) }
private func dev(_ role: LiveLevelsState.Role, _ level: Int?, charging: Bool = false, at: Int64 = 1_800_000_000) -> LiveLevelsState.Device {
    .init(role: role, level: level, charging: charging, updatedAt: at)
}

@Suite("LIVE-001 content-state: building and encoding (R10, R11)")
struct LiveLevelsStateTests {
    @Test func picksThisIPhoneThePairedMacAndTheLowerBud() {
        let s = LiveLevels.state(from: [mac(60, id: otherMacID, at: t0 + 100), mac(80), phone(50),
                                        pod(.left, 40), pod(.right, 30, charging: true), pod(.case, 90)],
                                 iphoneID: phoneID, macID: macID)
        #expect(s.devices.map(\.role) == [.iphone, .mac, .airpods])
        #expect(s.device(.iphone)?.level == 50)
        #expect(s.device(.mac)?.level == 80)  // the paired one, not the newer other Mac
        #expect(s.device(.airpods)?.level == 30)
        #expect(s.device(.airpods)?.charging == true)
    }

    @Test func unknownMacFallsBackToTheNewestMac() {
        let s = LiveLevels.state(from: [mac(80, at: t0), mac(60, id: otherMacID, at: t0 + 100)], iphoneID: phoneID, macID: nil)
        #expect(s.device(.mac)?.level == 60)
        #expect(s.device(.iphone) == nil)
    }

    @Test func caseOnlyWhenNoBudHasALevel() {
        let s = LiveLevels.state(from: [pod(.left, nil), pod(.right, nil), pod(.case, 70)], iphoneID: nil, macID: macID)
        #expect(s.device(.airpods)?.level == 70)
    }

    @Test func prefersTheAirPodsOfThePairedMac() {
        let s = LiveLevels.state(from: [pod(.left, 40, key: "11", parent: otherMacID, at: t0 + 500), pod(.left, 90, key: "22")],
                                 iphoneID: nil, macID: macID)
        #expect(s.device(.airpods)?.level == 90)
    }

    @Test func pluggedInCountsAsCharging() {
        let s = LiveLevels.state(from: [mac(100, plugged: true)], iphoneID: nil, macID: macID)
        #expect(s.device(.mac)?.charging == true)
    }

    @Test func newestKeepsANewerPushedReadingPerRole() {
        let pushed = state([dev(.iphone, 40, at: 100), dev(.mac, 70, at: 300)])
        let local = state([dev(.iphone, 45, at: 200), dev(.mac, 80, at: 250), dev(.airpods, 30, at: 50)])
        let merged = LiveLevels.newest(pushed, local)
        #expect(merged.device(.iphone)?.level == 45)  // local is newer
        #expect(merged.device(.mac)?.level == 70)  // the push is newer
        #expect(merged.device(.airpods)?.level == 30)
        #expect(LiveLevels.newest(pushed, state([dev(.iphone, 45, at: 200)])).device(.mac) == nil)
        #expect(LiveLevels.newest(nil, local) == local)
    }

    @Test func emptyListGivesEmptyState() {
        #expect(LiveLevels.state(from: [], iphoneID: phoneID, macID: macID).devices.isEmpty)
    }

    @Test func initKeepsRoleOrderAndOnePerRole() {
        let s = state([dev(.airpods, 1), dev(.iphone, 2), dev(.iphone, 3), dev(.mac, 4)])
        #expect(s.devices.map(\.role) == [.iphone, .mac, .airpods])
        #expect(s.device(.iphone)?.level == 2)
    }

    @Test func levelsAreClamped() {
        #expect(dev(.mac, 140).level == 100)
        #expect(dev(.mac, -3).level == 0)
    }

    /// Apple decodes pushed content with the default JSON strategies: plain keys, Unix seconds
    /// as integers, nothing else.
    @Test func encodesWithDefaultStrategiesAndPlainKeys() throws {
        let s = state([dev(.iphone, 64), dev(.mac, nil, charging: true)])
        let json = try #require(String(data: try s.encoded(), encoding: .utf8))
        #expect(json == #"{"devices":[{"charging":false,"level":64,"role":"iphone","updatedAt":1800000000},{"charging":true,"role":"mac","updatedAt":1800000000}]}"#)
        let back = try JSONDecoder().decode(LiveLevelsState.self, from: Data(json.utf8))  // default decoder
        #expect(back == s)
    }

    /// R11: the largest possible state fits the APNs 4 KB limit with plenty of room for `aps`.
    @Test func largestStateIsFarUnderFourKilobytes() throws {
        let big = state([dev(.iphone, 100, charging: true, at: 99_999_999_999), dev(.mac, 100, charging: true, at: 99_999_999_999),
                         dev(.airpods, 100, charging: true, at: 99_999_999_999)])
        let bytes = try big.encoded().count
        #expect(bytes < 512)
        let aps = #"{"aps":{"timestamp":99999999999,"event":"update","stale-date":99999999999,"content-state":"# + String(decoding: try big.encoded(), as: UTF8.self) + "}}"
        #expect(aps.utf8.count < 4096)
    }
}

@Suite("LIVE-001 update and start/stop rules (R3, R7, R8, R20–R25)")
struct LiveLevelsPolicyTests {
    let base = LiveLevelsState(devices: [.init(role: .iphone, level: 50, charging: false, updatedAt: 1),
                                         .init(role: .mac, level: 80, charging: false, updatedAt: 1)])

    @Test func onlyVisibleChangesCount() {
        var newer = base
        newer.devices[0].updatedAt = 999
        #expect(!LiveLevelsPolicy.isVisibleChange(from: base, to: newer))
        var level = base
        level.devices[1].level = 79
        #expect(LiveLevelsPolicy.isVisibleChange(from: base, to: level))
        var charging = base
        charging.devices[0].charging = true
        #expect(LiveLevelsPolicy.isVisibleChange(from: base, to: charging))
        #expect(LiveLevelsPolicy.isVisibleChange(from: base, to: LiveLevelsState(devices: [base.devices[0]])))
        #expect(LiveLevelsPolicy.isVisibleChange(from: nil, to: base))
    }

    @Test func urgentIsPlugUnplugFullAndThreshold() {
        var plug = base; plug.devices[1].charging = true
        #expect(LiveLevelsPolicy.isUrgent(from: base, to: plug, threshold: 20))
        #expect(LiveLevelsPolicy.isUrgent(from: plug, to: base, threshold: 20))  // unplug
        var low = base; low.devices[0].level = 20
        #expect(LiveLevelsPolicy.isUrgent(from: base, to: low, threshold: 20))
        var lower = low; lower.devices[0].level = 19
        #expect(!LiveLevelsPolicy.isUrgent(from: low, to: lower, threshold: 20))
        var almost = plug; almost.devices[1].level = 99
        var full = almost; full.devices[1].level = 100
        #expect(LiveLevelsPolicy.isUrgent(from: almost, to: full, threshold: 20))
        var step = base; step.devices[1].level = 79
        #expect(!LiveLevelsPolicy.isUrgent(from: base, to: step, threshold: 20))
        #expect(!LiveLevelsPolicy.isUrgent(from: nil, to: base, threshold: 20))
    }

    @Test func startBlockers() {
        #expect(LiveLevelsPolicy.startBlocker(isAllowed: true, activitiesEnabled: true, isPaired: true, isDemo: false) == nil)
        #expect(LiveLevelsPolicy.startBlocker(isAllowed: false, activitiesEnabled: true, isPaired: true, isDemo: false) == .notAllowed)
        #expect(LiveLevelsPolicy.startBlocker(isAllowed: true, activitiesEnabled: false, isPaired: true, isDemo: false) == .disabledInSettings)
        #expect(LiveLevelsPolicy.startBlocker(isAllowed: true, activitiesEnabled: true, isPaired: false, isDemo: false) == .notPaired)
        #expect(LiveLevelsPolicy.startBlocker(isAllowed: true, activitiesEnabled: true, isPaired: true, isDemo: true) == .demo)
    }

    @Test func endsAfterEightHoursOrWhenUnpaired() {
        let start = t0
        #expect(LiveLevelsPolicy.endReason(startedAt: start, now: start + 8 * 3600 - 1, isPaired: true) == nil)
        #expect(LiveLevelsPolicy.endReason(startedAt: start, now: start + 8 * 3600, isPaired: true) == .expired)
        #expect(LiveLevelsPolicy.endReason(startedAt: start, now: start + 60, isPaired: false) == .unpaired)
    }

    @Test func localUpdateOnChangeOrNewerDataAfterAMinute() {
        var newer = base
        newer.devices[0].updatedAt = 999
        #expect(LiveLevelsPolicy.shouldUpdate(shown: nil, shownAt: nil, new: base, now: t0))
        #expect(!LiveLevelsPolicy.shouldUpdate(shown: base, shownAt: t0, new: base, now: t0 + 3600))
        #expect(!LiveLevelsPolicy.shouldUpdate(shown: base, shownAt: t0, new: newer, now: t0 + 59))
        #expect(LiveLevelsPolicy.shouldUpdate(shown: base, shownAt: t0, new: newer, now: t0 + 60))
        var level = base; level.devices[0].level = 49
        #expect(LiveLevelsPolicy.shouldUpdate(shown: base, shownAt: t0, new: level, now: t0 + 1))
    }
}
