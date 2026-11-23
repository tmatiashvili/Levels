import Foundation
import LevelsModel

/// One reading of this device's own battery (ADR-0010). Platform readers produce it;
/// ``BatteryReporter`` maps it to a ``DeviceBattery`` (SYNC-002).
public struct BatteryReading: Sendable, Equatable {
    /// Where the power comes from and what the battery is doing (ADR-0010).
    public enum PowerState: Sendable, Equatable, CaseIterable {
        case unknown, unplugged, charging, full
        /// On external power, neither charging nor full (Mac: held at a limit, paused, or no battery).
        case pluggedIn

        /// The model's charging flags (SYNC-002 R16, ADR-0010 rule 6):
        /// `.charging` and `.full` → `true, true`; `.pluggedIn` → `false, true`;
        /// `.unplugged` → `false, false`; `.unknown` → `false, nil`.
        public var chargingFlags: ChargingFlags {
            switch self {
            case .charging: ChargingFlags(charging: true, onExternalPower: true, full: false)
            case .full: ChargingFlags(charging: false, onExternalPower: true, full: true)
            case .pluggedIn: ChargingFlags(charging: false, onExternalPower: true, full: false)
            case .unplugged: ChargingFlags(charging: false, onExternalPower: false, full: false)
            case .unknown: ChargingFlags(charging: false, onExternalPower: nil, full: false)
            }
        }
    }

    /// 0...100; `nil` when unknown or when there is no internal battery.
    public var level: Int?
    public var powerState: PowerState
    public var isLowPowerMode: Bool
    public var readAt: Date

    /// `level` is clamped to 0...100.
    public init(level: Int?, powerState: PowerState, isLowPowerMode: Bool, readAt: Date) {
        self.level = level.map(DeviceBattery.clampedLevel)
        self.powerState = powerState
        self.isLowPowerMode = isLowPowerMode
        self.readAt = readAt
    }

    /// ADR-0010 rule 1: `Int((raw * 100).rounded())`, clamped to 0...100; a raw value
    /// below 0 (or not finite) gives `nil`. For the UIKit and WatchKit readers.
    public static func level(fromFraction raw: Double) -> Int? {
        guard raw.isFinite, raw >= 0 else { return nil }
        return DeviceBattery.clampedLevel(Int((raw * 100).rounded()))
    }

    /// The reading a reader returns when the platform answered nothing (MAC-002 R10,
    /// RPT-001 R3): level `nil` and state `.unknown`. It is never offered to sync.
    public var isReadFailure: Bool { level == nil && powerState == .unknown }

    /// True when `level`, `powerState` or `isLowPowerMode` differ (MAC-002 R7); `readAt` is ignored.
    public func differsInValues(from other: BatteryReading) -> Bool {
        level != other.level || powerState != other.powerState || isLowPowerMode != other.isLowPowerMode
    }
}

/// Reads this device's battery (ADR-0010). One implementation per platform, in the
/// app targets (`IOKitBatteryReader` in Levels-Mac); ``FixedBatteryReader`` for tests.
public protocol BatteryReader: Sendable {
    /// Current values. Never throws; unknown is a valid answer.
    func read() async -> BatteryReading
    /// Emits a new reading on every change the platform tells us about,
    /// only while this process runs. Platforms without change events emit nothing.
    func changes() -> AsyncStream<BatteryReading>
}
