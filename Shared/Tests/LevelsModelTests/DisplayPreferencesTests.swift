import Foundation
import Testing
@testable import LevelsModel

@Suite("UI-001 DisplayPreferences and DeviceOrdering (LevelsModel)")
struct DisplayPreferencesTests {
    func d(_ n: Int, _ kind: DeviceKind, _ name: String, _ level: Int?) -> DeviceBattery {
        DeviceBattery(id: DeviceID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!),
                      name: name, kind: kind, level: level, isCharging: false, updatedAt: now)
    }

    @Test("UserDefaults store round-trips; missing data gives defaults")
    func store() {
        let suite = "levels.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = UserDefaultsDisplayPreferencesStore(suiteName: suite)
        #expect(store.load() == DisplayPreferences())
        let p = DisplayPreferences(hidden: [DeviceID(UUID())], thisDeviceName: "Work Mac")
        store.save(p)
        #expect(UserDefaultsDisplayPreferencesStore(suiteName: suite).load() == p)
    }

    @Test("Partial JSON decodes with defaults")
    func partial() throws {
        let p = try JSONDecoder().decode(DisplayPreferences.self, from: Data(#"{"thisDeviceName":"X"}"#.utf8))
        #expect(p == DisplayPreferences(thisDeviceName: "X"))
    }

    @Test("UI-001 AC1 order: this device first, level ascending, ties by name, nil last")
    func ordering() {
        let iPhone = d(1, .iphone, "iPhone", 62), mac = d(2, .mac, "Mac", 18)
        let watch = d(3, .watch, "Watch", 81), iPad = d(4, .ipad, "Alpha", 18), desk = d(5, .mac, "Desk", nil)
        let sorted = DeviceOrdering.sorted([desk, watch, mac, iPad, iPhone], thisDeviceID: iPhone.id, preferences: DisplayPreferences())
        #expect(sorted.map(\.name) == ["iPhone", "Alpha", "Mac", "Watch", "Desk"])
        #expect(DeviceOrdering.sorted([mac, watch], thisDeviceID: nil, preferences: DisplayPreferences(hidden: [mac.id])) == [watch])
    }
}
