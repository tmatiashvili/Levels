import Foundation

/// Maps IOKit power-source descriptions to a ``BatteryReading`` (MAC-002 R1–R5, R10).
///
/// Pure and IOKit-free: it takes the dictionaries `IOPSGetPowerSourceDescription`
/// returns, keyed by the `kIOPS*` string values, so tests feed fixtures. The IOKit
/// calls themselves live in the Mac app target (`IOKitBatteryReader`, ADR-0010).
public enum MacPowerMapper {
    /// The `kIOPS*` keys and values from `IOKit/ps/IOPSKeys.h`.
    public enum Key {
        public static let type = "Type"                          // kIOPSTypeKey
        public static let isPresent = "Is Present"               // kIOPSIsPresentKey
        public static let currentCapacity = "Current Capacity"   // kIOPSCurrentCapacityKey
        public static let maxCapacity = "Max Capacity"           // kIOPSMaxCapacityKey
        public static let isCharging = "Is Charging"             // kIOPSIsChargingKey
        public static let isCharged = "Is Charged"               // kIOPSIsChargedKey
        public static let powerSourceState = "Power Source State" // kIOPSPowerSourceStateKey
    }

    public enum Value {
        public static let internalBattery = "InternalBattery"    // kIOPSInternalBatteryType
        public static let acPower = "AC Power"                   // kIOPSACPowerValue
        public static let batteryPower = "Battery Power"         // kIOPSBatteryPowerValue
    }

    /// - Parameter descriptions: one dictionary per power source, or `nil` when IOPS
    ///   answered nothing (read failure: level `nil`, `.unknown`, never offered, R10).
    public static func reading(from descriptions: [[String: Any]]?, lowPowerMode: Bool, now: Date) -> BatteryReading {
        guard let descriptions else {
            return BatteryReading(level: nil, powerState: .unknown, isLowPowerMode: lowPowerMode, readAt: now)
        }
        // R1: the first present internal battery; UPS and other sources are ignored.
        guard let battery = descriptions.first(where: {
            $0[Key.type] as? String == Value.internalBattery && bool($0[Key.isPresent]) == true
        }) else {
            // R5: no internal battery. On power, not charging, level unknown; still reported.
            return BatteryReading(level: nil, powerState: .pluggedIn, isLowPowerMode: lowPowerMode, readAt: now)
        }
        return BatteryReading(
            level: level(current: int(battery[Key.currentCapacity]), max: int(battery[Key.maxCapacity])),
            powerState: powerState(of: battery),
            isLowPowerMode: lowPowerMode,
            readAt: now
        )
    }

    /// R2: `round(current / max × 100)` clamped to 0...100; `current` as a percentage
    /// when `max` is missing or ≤ 0. `nil` when `current` is missing.
    static func level(current: Int?, max: Int?) -> Int? {
        guard let current else { return nil }
        guard let max, max > 0 else { return Swift.min(100, Swift.max(0, current)) }
        let percent = (Double(current) / Double(max) * 100).rounded()
        return Int(Swift.min(100, Swift.max(0, percent)))
    }

    /// R3: charging, else full on AC, else on AC, else unplugged.
    static func powerState(of battery: [String: Any]) -> BatteryReading.PowerState {
        let onAC = battery[Key.powerSourceState] as? String == Value.acPower
        if bool(battery[Key.isCharging]) == true { return .charging }
        if onAC && bool(battery[Key.isCharged]) == true { return .full }
        if onAC { return .pluggedIn }
        return .unplugged
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
