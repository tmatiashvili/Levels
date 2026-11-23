import Foundation
import LevelsModel

/// Fixture devices for SwiftUI previews and demos (the ASCII sketch in UI-001).
public enum PreviewFixtures {
    public static let now = Date()
    public static let iPhoneID = DeviceID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    public static let macID = DeviceID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    public static let watchID = DeviceID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    public static let iMacID = DeviceID(UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
    public static let oldIPadID = DeviceID(UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
    public static let airPodsGroup = UUID(uuidString: "00000000-0000-0000-0000-0000000000A0")!

    public static let iPhone = DeviceBattery(id: iPhoneID, name: "iPhone", kind: .iphone, level: 62, isCharging: true,
                                             isPluggedIn: true, isLowPowerMode: false, updatedAt: now - 2 * 60)
    public static let macBook = DeviceBattery(id: macID, name: "MacBook Pro", kind: .mac, level: 18, isCharging: false,
                                              isPluggedIn: false, updatedAt: now - 12 * 60)
    /// Stale: 3 hours old.
    public static let watch = DeviceBattery(id: watchID, name: "Apple Watch", kind: .watch, level: 81, isCharging: false,
                                            isLowPowerMode: true, updatedAt: now - 3 * 3600)
    /// No battery (R5a).
    public static let iMac = DeviceBattery(id: iMacID, name: "iMac", kind: .mac, level: nil, isCharging: false,
                                           isPluggedIn: true, updatedAt: now - 5 * 60)
    /// Old: 40 days (R14).
    public static let oldIPad = DeviceBattery(id: oldIPadID, name: "Old iPad", kind: .ipad, level: 44, isCharging: false,
                                              updatedAt: now - 40 * 86_400)

    public static func airPods(parent: DeviceID = macID) -> [DeviceBattery] {
        [(AccessoryComponent.left, 40), (.right, 35), (.case, 80)].map { component, level in
            DeviceBattery(id: .accessory(key: "AA:BB:CC:DD:EE:FF", component: component), name: "AirPods Pro",
                          kind: .accessory,
                          accessory: AccessoryInfo(parentDeviceID: parent, kind: .airpods, groupID: airPodsGroup,
                                                   component: component),
                          level: level, isCharging: component == .case, updatedAt: now - 7 * 60)
        }
    }

    /// The full sketch: this iPhone, a low Mac, a stale Watch, a desktop Mac, AirPods and an old iPad.
    public static var loaded: SnapshotFile {
        SnapshotFile(ownDeviceID: iPhoneID, syncStatus: .idle,
                     devices: [iPhone, macBook, watch, iMac, oldIPad] + airPods())
    }
    public static var empty: SnapshotFile { SnapshotFile(syncStatus: .idle) }
    public static var onlyThisDevice: SnapshotFile { SnapshotFile(ownDeviceID: iPhoneID, syncStatus: .idle, devices: [iPhone]) }
    public static var noICloud: SnapshotFile {
        SnapshotFile(ownDeviceID: iPhoneID, syncStatus: .signedOut, devices: [iPhone, macBook])
    }
    public static var syncError: SnapshotFile {
        SnapshotFile(ownDeviceID: iPhoneID, syncStatus: .offline(lastFetchAt: now - 600), devices: [iPhone, macBook, watch])
    }
    /// Local-only Mac build: no sync status at all.
    public static var localMac: SnapshotFile {
        let mac = DeviceBattery(id: macID, name: "MacBook Pro", kind: .mac, level: 45, isCharging: true,
                                isPluggedIn: true, updatedAt: now - 5 * 60)
        return SnapshotFile(ownDeviceID: macID, devices: [mac] + airPods())
    }

    /// A store over `snapshot`; call `start()` (the previews do it in `.task`).
    @MainActor public static func store(_ snapshot: SnapshotFile) -> DeviceListStore {
        DeviceListStore(source: InMemorySnapshotSource(snapshot), preferences: InMemoryDisplayPreferencesStore())
    }
}
