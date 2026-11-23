import Foundation
import LevelsModel

/// When ``LocalOnlySyncService`` writes a reading into the snapshot cache: ADR-0008
/// adapted to a single device with no iCloud. Pure; times come from the caller.
///
/// Kept from ADR-0008, because they still protect the disk, the widget reload
/// budget (SYNC-001 R8a) and keep "updated" honest:
/// - **W1** no known last write for this record → write now.
/// - **W2/W3** `isCharging`, `isPluggedIn` or `isLowPowerMode` changed, or the reason is
///   `.chargerChange` → write after the 3 s debounce (a quick plug and unplug becomes one
///   write), ignoring the 60 s minimum gap.
/// - **W6** heartbeat: the last write is ≥ 30 min old → write now (moves `updatedAt`).
/// - **W9** urgent reasons (`ReportReason.isUrgent`) → write now even if unchanged, but
///   keep the 10 s floor (and the debounce for `.chargerChange`).
/// - **Floor**: no record is written twice within 10 s.
/// - **Coalescing** (in the service): one pending slot per record, latest reading wins.
///
/// Changed for local use: **W4/W5/W7/W8** collapse into one rule. Any change of
/// `level` or `name` is written once ≥ 60 s have passed since the last write, without the
/// 5-point step or the 20/10 crossings. Those exist to save the fleet's push budget
/// (ADR-0006), which a local cache doesn't have, and the Mac's own menu bar should not
/// lag its real level by up to 4 points. Unchanged, non-urgent readings are skipped.
public struct LocalWritePolicy: Sendable, Equatable {
    public struct Configuration: Sendable, Equatable {
        /// Minimum gap for level and name changes (W4, W8).
        public var minInterval: TimeInterval = 60
        /// Absolute floor between two writes of one record.
        public var floor: TimeInterval = 10
        /// Debounce for charger and Low Power Mode changes (W2, W3).
        public var debounce: TimeInterval = 3
        /// Heartbeat age (W6).
        public var heartbeat: TimeInterval = 30 * 60

        public static let `default` = Configuration()

        public init() {}
    }

    public enum Decision: Sendable, Equatable {
        case writeNow
        case writeAt(Date)
        case skip
    }

    public var configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// - Parameters:
    ///   - lastWritten: the value last written to the cache for this record by this process.
    ///   - lastWriteAt: when that write happened.
    public func decide(new: DeviceBattery, reason: ReportReason, lastWritten: DeviceBattery?, lastWriteAt: Date?, now: Date) -> Decision {
        guard let lastWritten, let lastWriteAt else { return .writeNow }  // W1
        let c = configuration
        let floorAt = lastWriteAt.addingTimeInterval(c.floor)
        let due: Date
        let flagsChanged = new.isCharging != lastWritten.isCharging
            || new.isPluggedIn != lastWritten.isPluggedIn
            || new.isLowPowerMode != lastWritten.isLowPowerMode
        if flagsChanged || reason == .chargerChange {
            due = max(now.addingTimeInterval(c.debounce), floorAt)  // W2, W3
        } else if reason.isUrgent {
            due = max(now, floorAt)  // W9
        } else if new.level != lastWritten.level || new.name != lastWritten.name {
            due = max(now, lastWriteAt.addingTimeInterval(c.minInterval), floorAt)  // W4, W5, W8 (local)
        } else if now.timeIntervalSince(lastWriteAt) >= c.heartbeat {
            due = max(now, floorAt)  // W6
        } else {
            return .skip  // W7
        }
        return due <= now ? .writeNow : .writeAt(due)
    }
}
