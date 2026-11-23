// UI-003 R1, UI-004 R12: the widget configuration. "Lowest battery" (default) or one known,
// non-hidden device. Only single-device families use it; list families ignore it.
import AppIntents
import Foundation
import LevelsModel
import LevelsUI
import WidgetKit

/// The device a single-device widget shows (UI-003 Design, ADR-0003: the device `AppEntity`
/// lives in `LevelsWidgetKit`). `id` is `"lowest"` or a device's record name.
public struct DeviceChoice: AppEntity, Hashable, Sendable {
    public static let lowestID = "lowest"

    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// "Lowest battery", the default (UI-003 R1).
    public static var lowest: DeviceChoice { DeviceChoice(id: lowestID, name: String(localized: "Lowest battery")) }

    /// `nil` for "Lowest battery".
    public var deviceID: DeviceID? { id == Self.lowestID ? nil : DeviceID(recordName: id) }

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Device"
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    public static let defaultQuery = DeviceChoiceQuery()
}

/// Suggestions come from the App Group cache, never from the network (UI-003 Design).
/// This device is offered too (UI-004 R12); hidden and old devices are not (UI-003 AC9).
public struct DeviceChoiceQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [DeviceChoice.ID]) async throws -> [DeviceChoice] {
        let all = Self.choices(rows: Self.cachedRows())
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    public func suggestedEntities() async throws -> [DeviceChoice] {
        Self.choices(rows: Self.cachedRows())
    }

    public func defaultResult() async -> DeviceChoice? { .lowest }

    /// "Lowest battery" first, then the rows in UI-001 order. Pure, unit-tested.
    public static func choices(rows: [DeviceRowModel]) -> [DeviceChoice] {
        [.lowest] + rows.map { DeviceChoice(id: $0.id.recordName, name: $0.name) }
    }

    static func cachedRows(now: Date = .now) -> [DeviceRowModel] {
        DevicesProvider.load(now: now).first?.rows ?? []
    }
}

/// The widget's configuration intent (UI-003 R1).
public struct SelectDeviceIntent: WidgetConfigurationIntent {
    public static let title: LocalizedStringResource = "Choose Device"
    public static let description = IntentDescription("Pick the device a small widget shows.")

    /// `nil` = "Lowest battery".
    @Parameter(title: "Device")
    public var device: DeviceChoice?

    public init() {}

    public init(device: DeviceChoice?) {
        self.device = device
    }
}
