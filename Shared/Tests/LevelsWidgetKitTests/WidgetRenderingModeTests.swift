import Foundation
import LevelsModel
import LevelsUI
import SwiftUI
import Testing
import WidgetKit
@testable import LevelsWidgetKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func row(_ kind: DeviceKind, _ level: Int?, charging: Bool = false, age: TimeInterval = 300) -> DeviceRowModel {
    let d = DeviceBattery(id: DeviceID(UUID()), name: "X", kind: kind, level: level, isCharging: charging, updatedAt: now - age)
    let e = DeviceEntry(date: now, snapshot: SnapshotFile(ownDeviceID: nil, devices: [d]), preferences: DisplayPreferences())
    return e.rows[0]
}

/// Liquid Glass review 2026-11-24: state is a shape, not only a colour.
@Suite("Widget rendering modes")
struct WidgetRenderingModeTests {
    @Test func lowAndChargingGetABadge() {
        #expect(RingBadge.of(row(.iphone, 14), now: now) == .low)
        #expect(RingBadge.of(row(.mac, 14, charging: true), now: now) == .charging)
        #expect(RingBadge.of(row(.iphone, 80), now: now) == nil)
        #expect(RingBadge.of(row(.iphone, nil), now: now) == nil)
    }

    @Test func fillIsColouredOnlyInFullColour() {
        #expect(RingStyle.low.fill(.fullColor) == .red)
        #expect(RingStyle.charging.fill(.fullColor) == .green)
        for mode in [WidgetRenderingMode.accented, .vibrant] {
            #expect(RingStyle.low.fill(mode) == .primary)
            #expect(RingStyle.charging.fill(mode) == .primary)
        }
    }
}
