import Foundation
import Synchronization

/// DEMO-001 R7: whether the iPhone shows sample devices ("Try with sample devices").
///
/// Lives in App Group `UserDefaults` under ``key`` (default off), so it survives relaunch and
/// the widget reads the same value (R10). Same shape as ``ReportingSetting``.
public final class DemoModeSetting: Sendable {
    public static let key = "demoMode.isOn"

    /// `nil` keeps the value in ``memory`` only.
    private let suite: Suite?
    private let memory: Mutex<Bool>

    private struct Suite: Sendable { var name: String? }

    /// - Parameter suiteName: the App Group ID; `nil` uses `UserDefaults.standard`.
    public init(suiteName: String?) {
        suite = Suite(name: suiteName)
        memory = Mutex(false)
    }

    private init(on: Bool) {
        suite = nil
        memory = Mutex(on)
    }

    /// A setting kept in memory only (tests, previews).
    public static func inMemory(on: Bool = false) -> DemoModeSetting { DemoModeSetting(on: on) }

    public var isOn: Bool {
        guard let suite else { return memory.withLock { $0 } }
        return defaults(suite.name)?.bool(forKey: Self.key) ?? false
    }

    public func setOn(_ on: Bool) {
        guard let suite else {
            memory.withLock { $0 = on }
            return
        }
        if on {
            defaults(suite.name)?.set(true, forKey: Self.key)
        } else {
            defaults(suite.name)?.removeObject(forKey: Self.key)
        }
    }

    private func defaults(_ suiteName: String?) -> UserDefaults? {
        guard let suiteName else { return .standard }
        return UserDefaults(suiteName: suiteName)
    }
}

/// DEMO-001 R2: the fixed sample devices. Generic names only; ages are measured from `now`
/// on every call, so the list always looks live. Pure.
public enum SampleDevices {
    public static let iPhoneID = DeviceID(UUID(uuidString: "5A3B1E00-0000-4000-8000-000000000001")!)
    public static let macID = DeviceID(UUID(uuidString: "5A3B1E00-0000-4000-8000-000000000002")!)
    public static let watchID = DeviceID(UUID(uuidString: "5A3B1E00-0000-4000-8000-000000000003")!)
    public static let iPadID = DeviceID(UUID(uuidString: "5A3B1E00-0000-4000-8000-000000000004")!)
    public static let airPodsGroup = UUID(uuidString: "5A3B1E00-0000-4000-8000-0000000000A0")!
    /// Never a real Bluetooth address: only hashed into the accessory IDs.
    static let airPodsKey = "sample-airpods-pro"

    /// Reading ages (R2).
    public enum Age {
        public static let iPhone: TimeInterval = 60
        public static let mac: TimeInterval = 2 * 60
        public static let airPods: TimeInterval = 4 * 60
        public static let watch: TimeInterval = 3 * 3600  // stale (handheld threshold is 2 h)
        public static let iPad: TimeInterval = 9 * 60
    }

    /// The sample AirPods' record IDs: left, right, case.
    public static func airPodsID(_ component: AccessoryComponent) -> DeviceID {
        .accessory(key: airPodsKey, component: component)
    }

    /// The sample snapshot at `now`: this iPhone, a MacBook Pro with AirPods Pro, a stale
    /// Apple Watch and a low iPad. `syncStatus` is `.localOnly`, so no hub banner shows.
    public static func snapshot(now: Date) -> SnapshotFile {
        let devices = [
            DeviceBattery(id: iPhoneID, name: "iPhone", kind: .iphone, level: 62, isCharging: true, isPluggedIn: true,
                          isLowPowerMode: false, updatedAt: now - Age.iPhone),
            DeviceBattery(id: macID, name: "MacBook Pro", kind: .mac, level: 54, isCharging: false, isPluggedIn: false,
                          isLowPowerMode: false, updatedAt: now - Age.mac),
            DeviceBattery(id: watchID, name: "Apple Watch", kind: .watch, level: 71, isCharging: false,
                          isLowPowerMode: true, updatedAt: now - Age.watch),
            DeviceBattery(id: iPadID, name: "iPad", kind: .ipad, level: 12, isCharging: false, isPluggedIn: false,
                          isLowPowerMode: false, updatedAt: now - Age.iPad),
        ] + [(AccessoryComponent.left, 40), (.right, 35), (.case, 80)].map { component, level in
            DeviceBattery(id: airPodsID(component), name: "AirPods Pro", kind: .accessory,
                          accessory: AccessoryInfo(parentDeviceID: macID, kind: .airpods, groupID: airPodsGroup,
                                                   component: component),
                          level: level, isCharging: component == .case, updatedAt: now - Age.airPods)
        }
        return SnapshotFile(ownDeviceID: iPhoneID, syncStatus: .localOnly, lastFetchAt: now, lastFetchOutcome: .success,
                            devices: devices)
    }

    /// True for a snapshot made by ``snapshot(now:)`` (widget footer, R10).
    public static func isSample(_ file: SnapshotFile?) -> Bool { file?.ownDeviceID == iPhoneID }
}
