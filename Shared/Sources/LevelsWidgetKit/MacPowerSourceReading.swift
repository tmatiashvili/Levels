// The Mac widget's own reading of this Mac's battery. The app writes the Mac's record at most
// once a minute (LocalWritePolicy) and only while it runs; it was down for 2.5 h and 1 h on
// 2026-11-24 (Bluetooth crash), and the widget kept the last cached level. IOKit power-source
// reads work in the sandboxed widget extension, so the provider reads them at each timeline load
// and lays the reading over the own record, as the iPhone widget does with `UIDevice`.
// The IOKit call lives in Widgets-Mac; this mapping is pure so `swift test` covers it. It
// follows `MacPowerMapper` (LevelsReaders), which widget extensions may not link (ADR-0003).
import Foundation
import LevelsModel

extension OwnBatteryReading {
    /// The `kIOPS*` keys and values from `IOKit/ps/IOPSKeys.h`.
    enum PowerSourceKey {
        static let type = "Type"
        static let isPresent = "Is Present"
        static let currentCapacity = "Current Capacity"
        static let maxCapacity = "Max Capacity"
        static let isCharging = "Is Charging"
        static let powerSourceState = "Power Source State"
        static let internalBattery = "InternalBattery"
        static let acPower = "AC Power"
    }

    /// Maps `IOPSGetPowerSourceDescription` dictionaries to a reading: the first present internal
    /// battery, `round(current / max × 100)`. Charging → `.charging`; on AC and not charging
    /// (full, or held by optimized charging) → `.full`, which the overlay shows as plugged in and
    /// not charging, like the app's `.pluggedIn`; else `.unplugged`. `nil` when IOPS answered
    /// nothing or there is no internal battery (the cached record is shown as it is).
    public static func macPowerSources(_ descriptions: [[String: Any]]?, isLowPowerMode: Bool,
                                       readAt: Date) -> OwnBatteryReading? {
        typealias K = PowerSourceKey
        guard let battery = descriptions?.first(where: {
            $0[K.type] as? String == K.internalBattery && bool($0[K.isPresent]) == true
        }), let current = int(battery[K.currentCapacity]) else { return nil }
        let level: Int
        if let max = int(battery[K.maxCapacity]), max > 0 {
            level = DeviceBattery.clampedLevel(Int((Double(current) / Double(max) * 100).rounded()))
        } else {
            level = DeviceBattery.clampedLevel(current)
        }
        let state: State = if bool(battery[K.isCharging]) == true {
            .charging
        } else if battery[K.powerSourceState] as? String == K.acPower {
            .full
        } else {
            .unplugged
        }
        return OwnBatteryReading(level: level, state: state, isLowPowerMode: isLowPowerMode, readAt: readAt)
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: n
        case let n as NSNumber: n.intValue
        default: nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool: b
        case let n as NSNumber: n.boolValue
        default: nil
        }
    }
}
