import Foundation

/// What kind of thing a battery belongs to (record field `type`, ADR-0005).
public enum DeviceKind: String, Codable, Sendable, CaseIterable {
    case iphone, ipad, mac, watch, accessory, other

    /// Unknown strings map to `.other` (SYNC-002 R4).
    public init(parsing raw: String) { self = DeviceKind(rawValue: raw) ?? .other }

    public init(from decoder: any Decoder) throws {
        self.init(parsing: try decoder.singleValueContainer().decode(String.self))
    }
}

/// Accessory family (record field `accessoryKind`).
public enum AccessoryKind: String, Codable, Sendable, CaseIterable {
    case airpods, mouse, keyboard, trackpad, other

    /// Unknown strings map to `.other` (SYNC-002 R4).
    public init(parsing raw: String) { self = AccessoryKind(rawValue: raw) ?? .other }

    public init(from decoder: any Decoder) throws {
        self.init(parsing: try decoder.singleValueContainer().decode(String.self))
    }
}

/// Which battery of an accessory a record describes (record field `component`).
public enum AccessoryComponent: String, Codable, Sendable, CaseIterable {
    case main, left, right, `case`

    /// Unknown strings map to `.main` (SYNC-002 R4).
    public init(parsing raw: String) { self = AccessoryComponent(rawValue: raw) ?? .main }

    public init(from decoder: any Decoder) throws {
        self.init(parsing: try decoder.singleValueContainer().decode(String.self))
    }
}

/// Accessory-only fields of a ``DeviceBattery``.
public struct AccessoryInfo: Hashable, Codable, Sendable {
    /// The Mac that reported this accessory last.
    public var parentDeviceID: DeviceID
    public var kind: AccessoryKind
    /// Same for the left, right and case records of one accessory.
    public var groupID: UUID
    public var component: AccessoryComponent

    public init(parentDeviceID: DeviceID, kind: AccessoryKind, groupID: UUID, component: AccessoryComponent) {
        self.parentDeviceID = parentDeviceID
        self.kind = kind
        self.groupID = groupID
        self.component = component
    }
}

/// The latest reading of one battery, as synced (ADR-0005) and cached (ADR-0009).
public struct DeviceBattery: Identifiable, Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var id: DeviceID
    public var schemaVersion: Int
    /// Display name (personal data; encrypted in CloudKit).
    public var name: String
    public var kind: DeviceKind
    /// Non-nil iff `kind == .accessory`.
    public var accessory: AccessoryInfo?
    /// 0...100; `nil` means no internal battery or unknown.
    public var level: Int?
    public var isCharging: Bool
    public var isPluggedIn: Bool?
    public var isLowPowerMode: Bool?
    /// Writer's clock when the battery was read.
    public var updatedAt: Date
    /// `CKRecord.modificationDate`; `nil` for values not yet seen by the server.
    public var serverModifiedAt: Date?

    /// True when a newer app wrote this record (SYNC-002 R6).
    public var needsNewerApp: Bool { schemaVersion > Self.currentSchemaVersion }

    /// Creates a value. `level` is clamped to 0...100 (SYNC-002 R3).
    public init(
        id: DeviceID,
        schemaVersion: Int = DeviceBattery.currentSchemaVersion,
        name: String,
        kind: DeviceKind,
        accessory: AccessoryInfo? = nil,
        level: Int?,
        isCharging: Bool,
        isPluggedIn: Bool? = nil,
        isLowPowerMode: Bool? = nil,
        updatedAt: Date,
        serverModifiedAt: Date? = nil
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.name = name
        self.kind = kind
        self.accessory = accessory
        self.level = level.map(Self.clampedLevel)
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.isLowPowerMode = isLowPowerMode
        self.updatedAt = updatedAt
        self.serverModifiedAt = serverModifiedAt
    }

    /// Clamps to 0...100 (SYNC-002 R3).
    public static func clampedLevel(_ level: Int) -> Int { min(100, max(0, level)) }

    /// Rounds and clamps a raw stored value to 0...100 (SYNC-002 R3). Non-finite gives `nil`.
    public static func clampedLevel(_ raw: Double) -> Int? {
        guard raw.isFinite else { return nil }
        return Int(min(100, max(0, raw.rounded())))
    }

    /// `min(updatedAt, serverModifiedAt ?? updatedAt, now)`: caps a writer clock
    /// that runs ahead, and future dates (SYNC-002 R8).
    public func readingDate(now: Date) -> Date {
        min(updatedAt, serverModifiedAt ?? updatedAt, now)
    }

    /// `now − readingDate`, never negative (SYNC-002 R9).
    public func age(now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(readingDate(now: now)))
    }
}

/// The one charging-flags rule every reporter uses (SYNC-002 R16, ADR-0010 rule 6).
public struct ChargingFlags: Hashable, Sendable {
    public var isCharging: Bool
    public var isPluggedIn: Bool?

    /// `isCharging = charging || (onExternalPower && full)`, `isPluggedIn = onExternalPower`.
    /// Pass `onExternalPower: nil` when the power source is unknown.
    public init(charging: Bool, onExternalPower: Bool?, full: Bool) {
        isCharging = charging || (onExternalPower == true && full)
        isPluggedIn = onExternalPower
    }
}
