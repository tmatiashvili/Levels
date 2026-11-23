import Foundation
import LevelsModel
import Synchronization

/// Per-device display choices (UI-001 R2, R3). Local to the device where they were made;
/// never synced.
///
/// UI-001 Design places this type in `LevelsModel`; it lives in `LevelsUI` until
/// `LevelsModel` adopts it (reporters need `thisDeviceName`, SYNC-002 R17).
public struct DisplayPreferences: Codable, Sendable, Equatable {
    /// Devices (or accessory groups, by group ID) hidden on this device (R2).
    public var hidden: Set<DeviceID>
    /// In-app rename of this device; `nil` = default name (SYNC-002 R17).
    public var thisDeviceName: String?

    public init(hidden: Set<DeviceID> = [], thisDeviceName: String? = nil) {
        self.hidden = hidden
        self.thisDeviceName = thisDeviceName
    }

    private enum CodingKeys: String, CodingKey { case hidden, thisDeviceName }

    /// Missing keys decode as defaults, so older or partial JSON still loads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hidden = try c.decodeIfPresent(Set<DeviceID>.self, forKey: .hidden) ?? []
        thisDeviceName = try c.decodeIfPresent(String.self, forKey: .thisDeviceName)
    }
}

/// Where ``DisplayPreferences`` are kept.
public protocol DisplayPreferencesStore: Sendable {
    func load() -> DisplayPreferences
    func save(_ p: DisplayPreferences)
}

/// Default store: JSON in (App Group) `UserDefaults` under key `"displayPreferences"`.
public struct UserDefaultsDisplayPreferencesStore: DisplayPreferencesStore {
    public static let key = "displayPreferences"
    /// The App Group ID, or `nil` for `UserDefaults.standard`.
    public let suiteName: String?

    public init(suiteName: String?) { self.suiteName = suiteName }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    /// Missing or unreadable data gives empty preferences; never throws.
    public func load() -> DisplayPreferences {
        guard let data = defaults.data(forKey: Self.key),
              let p = try? JSONDecoder().decode(DisplayPreferences.self, from: data)
        else { return DisplayPreferences() }
        return p
    }

    public func save(_ p: DisplayPreferences) {
        guard let data = try? JSONEncoder().encode(p) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// In-memory store for previews, tests and builds without an App Group.
public final class InMemoryDisplayPreferencesStore: DisplayPreferencesStore {
    private let value: Mutex<DisplayPreferences>

    public init(_ initial: DisplayPreferences = DisplayPreferences()) { value = Mutex(initial) }

    public func load() -> DisplayPreferences { value.withLock { $0 } }
    public func save(_ p: DisplayPreferences) { value.withLock { $0 = p } }
}
