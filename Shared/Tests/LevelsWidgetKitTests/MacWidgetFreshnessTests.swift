// Regression: "the Mac widget shows older battery info than reality" (2026-11-24). The Mac widget
// showed only the cache, which the app writes at most once a minute and not at all while it is
// down (2.5 h and 1 h that day). It now reads this Mac's battery through IOKit at each load.
import Foundation
import LevelsModel
import Testing
import WidgetKit
@testable import LevelsWidgetKit

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let macID = DeviceID(UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!)
private let phoneID = DeviceID(UUID(uuidString: "00000000-0000-0000-0000-0000000000C4")!)

private func battery(current: Int = 58, max: Int = 100, charging: Bool = false, state: String = "AC Power",
                     type: String = "InternalBattery", present: Bool = true) -> [String: Any] {
    ["Type": type, "Is Present": present, "Current Capacity": current, "Max Capacity": max,
     "Is Charging": charging, "Power Source State": state]
}

@Suite("Mac widget: live own battery")
struct MacWidgetFreshnessTests {
    private func read(_ descriptions: [[String: Any]]?) -> OwnBatteryReading? {
        OwnBatteryReading.macPowerSources(descriptions, isLowPowerMode: false, readAt: t0)
    }

    @Test func mapsChargingOnACAndBattery() {
        #expect(read([battery(charging: true)]) == OwnBatteryReading(level: 58, state: .charging, isLowPowerMode: false, readAt: t0))
        #expect(read([battery()])?.state == .full)  // on AC, not charging (full or held at 80 %)
        #expect(read([battery(state: "Battery Power")])?.state == .unplugged)
    }

    @Test func levelIsCurrentOverMaxRoundedAndClamped() {
        #expect(read([battery(current: 2, max: 3)])?.level == 67)
        #expect(read([battery(current: 120, max: 100)])?.level == 100)
        #expect(read([battery(current: 44, max: 0)])?.level == 44)  // no max: current is a percentage
    }

    @Test func noReadingWithoutAPresentInternalBattery() {
        #expect(read(nil) == nil)
        #expect(read([]) == nil)
        #expect(read([battery(type: "UPS")]) == nil)
        #expect(read([battery(present: false)]) == nil)
        #expect(read([["Type": "InternalBattery", "Is Present": true]]) == nil)  // no capacity
        #expect(read([battery(current: 10, type: "UPS"), battery(current: 77)])?.level == 77)
    }

    @Test func timelineShowsTheLiveLevelNotTheCachedOne() {
        // The app wrote 50 % ten minutes ago (or crashed then); the Mac is at 58 % and charging now.
        let cached = SnapshotFile(ownDeviceID: macID, devices: [
            DeviceBattery(id: macID, name: "MacBook", kind: .mac, level: 50, isCharging: false, isPluggedIn: false,
                          updatedAt: t0 - 600),
            DeviceBattery(id: phoneID, name: "iPhone", kind: .iphone, level: 70, isCharging: false, updatedAt: t0 - 3600),
        ])
        let own = OwnBatteryReading(level: 58, state: .charging, isLowPowerMode: false, readAt: t0)
        let t = DevicesProvider.liveOwnTimeline(cached: cached, preferences: DisplayPreferences(), now: t0,
                                                selection: nil, own: own)
        let mac = t.entries.first?.rows.flatMap(\.records).first { $0.id == macID }
        #expect(mac?.level == 58)
        #expect(mac?.isCharging == true)
        #expect(mac?.updatedAt == t0)
        #expect(t.policy == .after(t0 + DevicesTimeline.liveOwnRefresh))
        // Stale entries stay (the live Mac at 30 min, the iPhone at 1 h), so a late reload still shows them.
        #expect(t.entries.map(\.date) == [t0, t0 + 1800, t0 + 3600])
    }

    @Test func noReadingKeepsTheCacheAndStillReloadsIn15Minutes() {
        let cached = SnapshotFile(ownDeviceID: macID, devices: [
            DeviceBattery(id: macID, name: "Mac mini", kind: .mac, level: nil, isCharging: false, updatedAt: t0 - 60),
        ])
        let t = DevicesProvider.liveOwnTimeline(cached: cached, preferences: DisplayPreferences(), now: t0,
                                                selection: nil, own: nil)
        #expect(t.entries.first?.snapshot == cached)
        #expect(t.policy == .after(t0 + 15 * 60))
    }
}
