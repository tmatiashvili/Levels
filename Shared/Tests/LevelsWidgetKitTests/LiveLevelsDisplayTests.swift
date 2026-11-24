import Foundation
import LevelsModel
import LevelsUI
import Testing
@testable import LevelsWidgetKit

@Suite("LIVE-001 Live Activity display rules (R12–R16)")
struct LiveLevelsDisplayTests {
    func dev(_ role: LiveLevelsState.Role, _ level: Int?, charging: Bool = false) -> LiveLevelsState.Device {
        .init(role: role, level: level, charging: charging, updatedAt: 1_800_000_000)
    }

    @Test func compactShowsTheMacAndAirPodsBeforeTheIPhone() {
        let all = LiveLevelsState(devices: [dev(.iphone, 50), dev(.mac, 80), dev(.airpods, 30)])
        let c = LiveLevelsDisplay.compact(all)
        #expect(c.leading?.role == .mac)
        #expect(c.trailing?.role == .airpods)
        let noPods = LiveLevelsDisplay.compact(LiveLevelsState(devices: [dev(.iphone, 50), dev(.mac, 80)]))
        #expect(noPods.leading?.role == .mac)
        #expect(noPods.trailing?.role == .iphone)
        let empty = LiveLevelsDisplay.compact(LiveLevelsState(devices: []))
        #expect(empty.leading == nil && empty.trailing == nil)
    }

    @Test func minimalIsTheLowestNotCharging() {
        let s = LiveLevelsState(devices: [dev(.iphone, 50), dev(.mac, 10, charging: true), dev(.airpods, 30)])
        #expect(LiveLevelsDisplay.minimal(s)?.role == .airpods)
        let allCharging = LiveLevelsState(devices: [dev(.iphone, 50, charging: true), dev(.mac, 10, charging: true)])
        #expect(LiveLevelsDisplay.minimal(allCharging)?.role == .mac)
    }

    @Test func coloursFollowRingStyle() {
        #expect(LiveLevelsDisplay.style(dev(.mac, 80, charging: true), isStale: false) == .charging)
        #expect(LiveLevelsDisplay.style(dev(.mac, 80, charging: true), isStale: true) == .normal)  // stale never charges
        #expect(LiveLevelsDisplay.style(dev(.mac, 20), isStale: false) == .low)
        #expect(LiveLevelsDisplay.style(dev(.mac, 21), isStale: false) == .normal)
        #expect(LiveLevelsDisplay.style(dev(.mac, nil), isStale: false) == .normal)
    }

    @Test func namesFallBackToTheKind() {
        let names = LiveLevelsNames(iphone: "  ", mac: "Tornike’s MacBook Air", airpods: nil)
        #expect(names.name(.iphone) == "iPhone")
        #expect(names.name(.mac) == "MacBook Air")
        #expect(names.name(.airpods) == "AirPods")
        #expect(LiveLevelsDisplay.percent(dev(.mac, 7)) == "7%")
        #expect(LiveLevelsDisplay.percent(dev(.mac, nil)) == "–")
    }
}
