import Foundation
import LevelsModel
import Testing
@testable import LevelsUI

private func row(_ level: Int?, charging: Bool = false, age: TimeInterval = 300) -> DeviceRowModel {
    DeviceRowModel(record: DeviceBattery(id: DeviceID(UUID()), name: "X", kind: .iphone, level: level,
                                         isCharging: charging, updatedAt: now - age),
                   isThisDevice: false)
}

/// The app rows and the widgets share one colour rule (ADR-0016 rule 3).
@Suite("Ring style")
struct RingStyleTests {
    @Test func chargingBeatsLowAndLowBeatsNormal() {
        #expect(RingStyle.of(isCharging: true, isLow: true) == .charging)
        #expect(RingStyle.of(isCharging: false, isLow: true) == .low)
        #expect(RingStyle.of(isCharging: false, isLow: false) == .normal)
    }

    @Test func lowUsesTheSharedThreshold() {
        #expect(RingStyle.of(row(DeviceRowModel.lowThreshold), now: now) == .low)
        #expect(RingStyle.of(row(DeviceRowModel.lowThreshold + 1), now: now) == .normal)
        #expect(RingStyle.of(row(nil), now: now) == .normal)
    }

    @Test func aStaleDeviceIsNotCharging() {
        #expect(RingStyle.of(row(50, charging: true), now: now) == .charging)
        #expect(RingStyle.of(row(50, charging: true, age: 3 * 86_400), now: now) == .normal)
        #expect(RingStyle.of(row(10, charging: true, age: 3 * 86_400), now: now) == .low)
    }

    @Test func appColours() {
        #expect(RingStyle.charging.fill() == .green)
        #expect(RingStyle.low.fill() == .red)
        #expect(RingStyle.normal.fill() == .primary)
    }
}
