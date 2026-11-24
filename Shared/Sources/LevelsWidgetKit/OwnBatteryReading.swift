// The iPhone widget's own reading of this iPhone's battery. The app writes the iPhone's record
// only while it runs (foreground, or a rare BGAppRefreshTask), and a widget fetch from the Mac
// keeps the cached own record (`SnapshotFile.merge`, ownIDs). Without this the widget showed the
// iPhone's level from the app's last run, hours old. `UIDevice` battery reads work in the widget
// extension, so the provider reads it at each timeline load and lays it over the own record.
import Foundation
import LevelsModel

/// One `UIDevice` battery read, made by the widget extension. Pure value, no UIKit.
public struct OwnBatteryReading: Sendable, Equatable {
    /// `UIDevice.BatteryState`, one to one.
    public enum State: Sendable, Equatable { case unknown, unplugged, charging, full }

    /// 0...100; `nil` when `UIDevice` answered −1 (monitoring off, Simulator).
    public var level: Int?
    public var state: State
    public var isLowPowerMode: Bool
    public var readAt: Date

    public init(level: Int?, state: State, isLowPowerMode: Bool, readAt: Date) {
        self.level = level
        self.state = state
        self.isLowPowerMode = isLowPowerMode
        self.readAt = readAt
    }

    /// `UIDevice.batteryLevel` (0...1, or −1 when unknown) to a percentage, as the app's
    /// reader does (ADR-0010 rule 1).
    public static func level(fromFraction raw: Double) -> Int? {
        guard raw.isFinite, raw >= 0 else { return nil }
        return DeviceBattery.clampedLevel(Int((raw * 100).rounded()))
    }

    /// A read of the provider's choice; `nil` = no reader (Mac and Watch widgets).
    public typealias Read = @Sendable () async -> OwnBatteryReading?
}

extension SnapshotFile {
    /// This snapshot with the own record (`ownDeviceID`) updated from `reading`, when the reading
    /// has a level and is newer than the record. Charging flags follow the app's mapping
    /// (SYNC-002 R16): charging and full are on external power, unknown keeps the record's.
    /// Nothing else changes; the result is shown, never written to the cache.
    public func overlaying(own reading: OwnBatteryReading?) -> SnapshotFile {
        guard let reading, let level = reading.level, let ownDeviceID,
              let i = devices.firstIndex(where: { $0.id == ownDeviceID }),
              reading.readAt > devices[i].updatedAt else { return self }
        var file = self
        var record = file.devices[i]
        record.level = level
        switch reading.state {
        case .charging: record.isCharging = true; record.isPluggedIn = true
        case .full: record.isCharging = false; record.isPluggedIn = true
        case .unplugged: record.isCharging = false; record.isPluggedIn = false
        case .unknown: break
        }
        record.isLowPowerMode = reading.isLowPowerMode
        record.updatedAt = reading.readAt
        file.devices[i] = record
        return file
    }
}

extension SnapshotFile {
    /// The own record with `reading` laid over it (``overlaying(own:)``), for the widget to send
    /// to the Mac. `nil` when the reading has no level, is not newer than the cached record, or
    /// there is no own record yet (the app writes it on its first run).
    public func ownRecordToSend(_ reading: OwnBatteryReading?) -> DeviceBattery? {
        guard let reading, reading.level != nil, let ownDeviceID else { return nil }
        let record = overlaying(own: reading).devices.first { $0.id == ownDeviceID }
        return record?.updatedAt == reading.readAt ? record : nil
    }
}
