import Foundation
import Testing
@testable import LevelsModel

@Suite("Freshness rule")
struct FreshnessRuleTests {
    private func freshness(_ kind: DeviceKind, level: Int? = 60, charging: Bool = false, age: TimeInterval) -> Freshness {
        FreshnessRule.of(battery(kind: kind, level: level, isCharging: charging, updatedAt: now - age), at: now)
    }

    @Test("AC10: thresholds per type and charging state")
    func ac10() {
        let results = [
            freshness(.iphone, age: hour + 59 * minute),
            freshness(.iphone, age: 2 * hour + minute),
            freshness(.mac, age: 65 * minute),
            freshness(.mac, age: 66 * minute),
            freshness(.iphone, charging: true, age: 31 * minute),
            freshness(.iphone, charging: true, age: 2 * hour + minute),
            freshness(.mac, charging: true, age: 30 * minute),
            freshness(.mac, charging: true, age: 31 * minute),
            freshness(.accessory, charging: true, age: 31 * minute),
            freshness(.mac, level: 100, charging: true, age: 40 * minute),
        ]
        #expect(results == [.fresh, .stale, .fresh, .stale, .fresh, .stale, .fresh, .stale, .stale, .fresh])
    }

    @Test("AC10: retired at 30 days")
    func ac10Retired() {
        #expect(FreshnessRule.isRetired(battery(updatedAt: now - 31 * 24 * hour), at: now))
        #expect(FreshnessRule.isRetired(battery(updatedAt: now - 30 * 24 * hour), at: now))
        #expect(!FreshnessRule.isRetired(battery(updatedAt: now - 29 * 24 * hour), at: now))
    }

    @Test("R10: other types and Mac without a battery")
    func otherThresholds() {
        #expect(freshness(.ipad, age: 2 * hour) == .fresh)
        #expect(freshness(.watch, charging: true, age: 2 * hour) == .fresh)
        #expect(freshness(.other, age: 2 * hour + 1) == .stale)
        #expect(freshness(.mac, level: nil, age: 65 * minute) == .fresh)
        #expect(freshness(.accessory, age: 65 * minute) == .fresh)
        #expect(freshness(.accessory, level: 100, charging: true, age: 40 * minute) == .fresh)
    }

    @Test("R10: staleDate is readingDate plus threshold")
    func staleDate() {
        #expect(FreshnessRule.staleDate(for: battery(kind: .iphone, updatedAt: now)) == now + 2 * hour)
        #expect(FreshnessRule.staleDate(for: battery(kind: .mac, isCharging: true, updatedAt: now)) == now + 30 * minute)
        let skewed = battery(kind: .mac, updatedAt: now + 10 * minute, serverModifiedAt: now)
        #expect(FreshnessRule.staleDate(for: skewed) == now + 65 * minute)
    }
}
