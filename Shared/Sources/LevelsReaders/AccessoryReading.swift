import Foundation
import LevelsModel
import Synchronization

/// One battery of one accessory connected to this Mac (MAC-003). Readers in the Mac app
/// produce it from parsed source output; ``AccessoryReporter`` maps it to a ``DeviceBattery``.
///
/// `key` is the uppercase, colon-separated Bluetooth address. It lives in memory only:
/// the record keeps nothing but its one-way UUIDv5 (MAC-003 R3, ADR-0019).
public struct AccessoryReading: Sendable, Equatable {
    public var key: String
    /// The device name as the user set it ("TPods"); the same for every component.
    public var name: String
    public var kind: AccessoryKind
    public var component: AccessoryComponent
    /// 0...100.
    public var level: Int
    public var readAt: Date

    public init(key: String, name: String, kind: AccessoryKind, component: AccessoryComponent, level: Int, readAt: Date) {
        self.key = key
        self.name = name
        self.kind = kind
        self.component = component
        self.level = DeviceBattery.clampedLevel(level)
        self.readAt = readAt
    }

    /// The record ID: `UUIDv5("accessory:<key>:<component>")` (SYNC-002 R2, MAC-003 R3).
    public var id: DeviceID { DeviceID.accessory(key: key, component: component) }

    /// The synced value: `type = accessory`, `parentDeviceId` = this Mac, one shared
    /// `accessoryGroupId` per accessory (R3a). Neither source exposes charging, so
    /// `isCharging = false` and `isPluggedIn`/`isLowPowerMode` are absent (ADR-0015).
    public func deviceBattery(parent: DeviceID) -> DeviceBattery {
        DeviceBattery(
            id: id,
            name: name,
            kind: .accessory,
            accessory: AccessoryInfo(parentDeviceID: parent, kind: kind,
                                     groupID: DeviceID.accessoryGroup(key: key), component: component),
            level: level,
            isCharging: false,
            isPluggedIn: nil,
            isLowPowerMode: nil,
            updatedAt: readAt
        )
    }
}

/// What one look at the accessory sources found.
public struct AccessoryScan: Sendable, Equatable {
    /// Connected components with a valid level, at most one per record ID.
    public var readings: [AccessoryReading]
    /// R5: stable, address-free descriptions of what could not be parsed. Logged once per run.
    public var problems: Set<String>
    /// AirPods or other headphones are connected (ADR-0014 rule 5 poll interval), even
    /// when they reported no level this time.
    public var headphonesConnected: Bool

    public init(readings: [AccessoryReading] = [], problems: Set<String> = [], headphonesConnected: Bool = false) {
        self.readings = readings
        self.problems = problems
        self.headphonesConnected = headphonesConnected
    }

    public static let empty = AccessoryScan()

    /// Joins scans from several sources. The first reading for a record ID wins, so pass
    /// the IOKit scan (1 % steps) before `system_profiler` (5 % steps).
    public static func merged(_ scans: [AccessoryScan]) -> AccessoryScan {
        var seen = Set<DeviceID>()
        var out = AccessoryScan()
        for scan in scans {
            for r in scan.readings where seen.insert(r.id).inserted { out.readings.append(r) }
            out.problems.formUnion(scan.problems)
            out.headphonesConnected = out.headphonesConnected || scan.headphonesConnected
        }
        return out
    }
}

/// Reads the accessories connected to this Mac (MAC-003, ADR-0015). The Mac app's
/// `MacAccessoryReader` is the real one (IOKit + `system_profiler`, ADR-0010: platform
/// calls stay in the app target); ``FixedAccessoryReader`` is the test double.
public protocol AccessoryBatteryReader: Sendable {
    /// Scans every source now. Never throws; a source that fails adds a problem.
    func read() async -> AccessoryScan
    /// One element per connect or disconnect the platform reports (IOKit HID match and
    /// termination). Platforms without such events emit nothing.
    func changes() -> AsyncStream<Void>
}

/// Normalises Bluetooth addresses to the `accessoryKey` form (MAC-003 R3).
public enum BluetoothAddress {
    /// `"aa-bb-cc-dd-ee-ff"`, `"AA:BB:CC:DD:EE:FF"` → `"AA:BB:CC:DD:EE:FF"`; anything that is
    /// not six two-digit hex groups gives `nil`.
    public static func normalized(_ raw: String) -> String? {
        let parts = raw.trimmingCharacters(in: .whitespaces)
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return parts.map { $0.uppercased() }.joined(separator: ":")
    }

    /// Six raw bytes (IOKit may hand `DeviceAddress` over as data).
    public static func normalized(_ bytes: Data) -> String? {
        guard bytes.count == 6 else { return nil }
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

/// Scripted ``AccessoryBatteryReader`` for unit tests and previews.
public final class FixedAccessoryReader: AccessoryBatteryReader {
    private let state: Mutex<(scan: AccessoryScan, reads: Int)>
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    public init(_ scan: AccessoryScan = .empty) {
        state = Mutex((scan, 0))
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    public func read() async -> AccessoryScan {
        state.withLock { s in
            s.reads += 1
            return s.scan
        }
    }

    public func changes() -> AsyncStream<Void> { stream }

    /// What `read()` returns from now on.
    public func set(_ scan: AccessoryScan) { state.withLock { $0.scan = scan } }

    /// Sets `scan` and emits a connect/disconnect event.
    public func emit(_ scan: AccessoryScan) {
        set(scan)
        continuation.yield()
    }

    public var readCount: Int { state.withLock { $0.reads } }
}
