import Foundation

/// One point of a device's local 7-day history (HIS-001 R2): minute-precision time, level
/// and power flags. No name, kind or reason (ADR-0019 rule 3).
public struct HistorySample: Hashable, Sendable {
    /// Whole minutes since the reference date (2001-01-01 UTC).
    public var minute: Int
    /// 0...100.
    public var level: Int
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var isLowPowerMode: Bool
    /// The line stops after this sample (Mac went to sleep, R4).
    public var endsSegment: Bool

    public init(minute: Int, level: Int, isCharging: Bool, isPluggedIn: Bool = false,
                isLowPowerMode: Bool = false, endsSegment: Bool = false) {
        self.minute = minute
        self.level = DeviceBattery.clampedLevel(level)
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.isLowPowerMode = isLowPowerMode
        self.endsSegment = endsSegment
    }

    /// A sample at `date` (truncated to the minute).
    public init(date: Date, level: Int, isCharging: Bool, isPluggedIn: Bool = false,
                isLowPowerMode: Bool = false, endsSegment: Bool = false) {
        self.init(minute: Self.minute(of: date), level: level, isCharging: isCharging,
                  isPluggedIn: isPluggedIn, isLowPowerMode: isLowPowerMode, endsSegment: endsSegment)
    }

    /// The candidate sample of an accepted reading (R1); `nil` when it has no level or
    /// comes from a newer schema.
    public init?(reading: DeviceBattery, reason: ReportReason) {
        guard let level = reading.level, !reading.needsNewerApp else { return nil }
        self.init(date: reading.updatedAt, level: level, isCharging: reading.isCharging,
                  isPluggedIn: reading.isPluggedIn ?? false, isLowPowerMode: reading.isLowPowerMode ?? false,
                  endsSegment: reason == .sleep)
    }

    public var date: Date { Date(timeIntervalSinceReferenceDate: TimeInterval(minute) * 60) }

    public static func minute(of date: Date) -> Int {
        Int((date.timeIntervalSinceReferenceDate / 60).rounded(.down))
    }

    /// Level and the three power flags equal (R3); time and `endsSegment` are ignored.
    public func hasSameState(as other: HistorySample) -> Bool {
        level == other.level && isCharging == other.isCharging && isPluggedIn == other.isPluggedIn
            && isLowPowerMode == other.isLowPowerMode
    }
}
