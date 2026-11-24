import Foundation
import LevelsModel

/// One row of the device list: a device, or one accessory shown as a group (UI-001 R13).
///
/// Freshness is not stored: views compute it at render time from ``freshness(at:)``
/// (UI-001 Design), so a row turns stale on screen without a store update.
public struct DeviceRowModel: Identifiable, Equatable, Sendable {
    /// The record ID, or for a grouped accessory `DeviceID(accessoryGroupId)`.
    public let id: DeviceID
    public let name: String
    public let kind: DeviceKind
    /// `nil` = no battery (R5a). For a group: its lowest component (R13).
    public let level: Int?
    public let isCharging: Bool
    public let isPluggedIn: Bool?
    public let isLowPowerMode: Bool
    /// Writer's clock of the reading (for a group: the newest component).
    public let updatedAt: Date
    public let isThisDevice: Bool
    /// The accessory family, for the symbol (ADR-0016 table); `nil` for devices.
    public let accessoryKind: AccessoryKind?
    /// The records behind this row: one, or a group's components in left, right, case order.
    public let records: [DeviceBattery]
    /// True when this row stands for several accessory components (R13).
    public let isGroup: Bool

    /// A row for one record.
    public init(record: DeviceBattery, isThisDevice: Bool) {
        id = record.id
        name = record.name
        kind = record.kind
        level = record.level
        isCharging = record.isCharging
        isPluggedIn = record.isPluggedIn
        isLowPowerMode = record.isLowPowerMode ?? false
        updatedAt = record.updatedAt
        self.isThisDevice = isThisDevice
        accessoryKind = record.accessory?.kind
        records = [record]
        isGroup = false
    }

    /// A grouped accessory row (R13). `components` share one `accessoryGroupId` and are not empty.
    /// The row's level and charging come from its lowest component; it is named after the headset.
    init(groupID: UUID, components: [DeviceBattery]) {
        precondition(!components.isEmpty, "DeviceRowModel: a group needs at least one component")
        let ordered = components.sorted { Self.componentRank($0) < Self.componentRank($1) }
        let lowest = ordered.min { a, b in
            switch (a.level, b.level) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            default: return false
            }
        }!
        id = DeviceID(groupID)
        name = Self.groupName(ordered)
        kind = .accessory
        level = lowest.level
        isCharging = lowest.isCharging
        isPluggedIn = lowest.isPluggedIn
        isLowPowerMode = false
        updatedAt = ordered.map(\.updatedAt).max()!
        isThisDevice = false
        accessoryKind = ordered.first?.accessory?.kind
        records = ordered
        isGroup = true
    }

    /// The IDs of the records behind the row (what Remove deletes).
    public var memberIDs: [DeviceID] { records.map(\.id) }

    /// Components shown side by side; empty for an ungrouped row.
    public var components: [DeviceBattery] { isGroup ? records : [] }

    /// False when `level == nil` (R5a).
    public var hasBattery: Bool { level != nil }

    /// Low = level ≤ 20 %, never for `level == nil` (R7). A group is low when its lowest component is.
    public var isLow: Bool { Self.isLow(level) }

    public static let lowThreshold = 20

    public static func isLow(_ level: Int?) -> Bool { level.map { $0 <= lowThreshold } ?? false }

    /// `FreshnessRule` per record (R4). A group is stale only when every component is;
    /// each component keeps its own staleness (R13).
    public func freshness(at now: Date) -> Freshness {
        records.contains { FreshnessRule.of($0, at: now) == .fresh } ? .fresh : .stale
    }

    /// `readingDate` (SYNC-002 R8) for the age text; for a group, the newest component.
    public func readingDate(now: Date) -> Date {
        records.map { $0.readingDate(now: now) }.max() ?? now
    }

    /// No reading for 30 days (R14). This device is never old; a group is old when all its components are.
    public func isRetired(at now: Date) -> Bool {
        !isThisDevice && records.allSatisfy { FreshnessRule.isRetired($0, at: now) }
    }

    /// The bolt shows only while charging and fresh (R5, R6).
    public func showsChargingBolt(at now: Date) -> Bool {
        isCharging && freshness(at: now) == .fresh
    }

    // MARK: Grouping helpers

    static func componentRank(_ d: DeviceBattery) -> Int {
        switch d.accessory?.component ?? .main {
        case .left: 0
        case .right: 1
        case .case: 2
        case .main: 3
        }
    }

    /// The headset name: the shortest component name (records may carry "AirPods Pro" or
    /// "AirPods Pro – Left"); ties by the first in component order.
    static func groupName(_ components: [DeviceBattery]) -> String {
        let names = components.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return names.min { $0.count < $1.count } ?? components[0].name
    }
}

/// Rows built from a snapshot: grouped (R13), hidden removed (R2), old devices split off (R14), sorted (R1).
/// Pure, so widgets (UI-003/004) can use it from a timeline provider.
public struct DeviceRows: Equatable, Sendable {
    public var rows: [DeviceRowModel]
    /// Devices with no reading for 30 days, same order as `rows` (R14).
    public var oldRows: [DeviceRowModel]
    /// Hidden devices, for the settings "Hidden devices" section only (R2).
    public var hiddenRows: [DeviceRowModel]

    public init(devices: [DeviceBattery], thisDeviceID: DeviceID?, preferences: DisplayPreferences, now: Date) {
        var groups: [UUID: [DeviceBattery]] = [:]
        var all: [DeviceRowModel] = []
        for d in devices {
            if let info = d.accessory, Self.isGroupedComponent(info.component) {
                groups[info.groupID, default: []].append(d)
            } else {
                all.append(DeviceRowModel(record: d, isThisDevice: d.id == thisDeviceID))
            }
        }
        for (groupID, members) in groups {
            all.append(DeviceRowModel(groupID: groupID, components: members))
        }
        all.sort { Self.precedes($0, $1) }

        var rows: [DeviceRowModel] = [], old: [DeviceRowModel] = [], hidden: [DeviceRowModel] = []
        for row in all {
            if Self.isHidden(row, in: preferences) { hidden.append(row) }
            else if row.isRetired(at: now) { old.append(row) }
            else { rows.append(row) }
        }
        self.rows = rows
        oldRows = old
        hiddenRows = hidden
    }

    /// A `main` component is a single-battery accessory (mouse, keyboard): an ordinary row.
    static func isGroupedComponent(_ c: AccessoryComponent) -> Bool { c != .main }

    static func isHidden(_ row: DeviceRowModel, in preferences: DisplayPreferences) -> Bool {
        preferences.hidden.contains(row.id) || row.records.contains { DeviceOrdering.isHidden($0, in: preferences) }
    }

    static func precedes(_ a: DeviceRowModel, _ b: DeviceRowModel) -> Bool {
        DeviceOrdering.precedes(
            .init(isThisDevice: a.isThisDevice, level: a.level, name: a.name, id: a.id),
            .init(isThisDevice: b.isThisDevice, level: b.level, name: b.name, id: b.id))
    }
}
