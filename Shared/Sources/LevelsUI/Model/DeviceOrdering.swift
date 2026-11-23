import Foundation
import LevelsModel

/// The one sort order every surface uses (UI-001 R1, ADR-0016 rule 5).
///
/// UI-001 Design places this in `LevelsModel`; it lives in `LevelsUI` for now (widgets
/// link `LevelsUI`, so they can still call it).
public enum DeviceOrdering {
    /// Hidden devices removed (R2); this device first; then level ascending with
    /// `level == nil` last; ties by name (localised, case-insensitive), then `deviceId`.
    /// Accessory records are sorted one by one here; ``DeviceRows`` groups them (R13).
    public static func sorted(_ devices: [DeviceBattery],
                              thisDeviceID: DeviceID?,
                              preferences: DisplayPreferences) -> [DeviceBattery] {
        devices
            .filter { !isHidden($0, in: preferences) }
            .sorted { precedes(SortKey($0, thisDeviceID: thisDeviceID), SortKey($1, thisDeviceID: thisDeviceID)) }
    }

    /// Hidden by its own ID, or by its accessory group's ID (a grouped row is hidden as one).
    public static func isHidden(_ d: DeviceBattery, in preferences: DisplayPreferences) -> Bool {
        if preferences.hidden.contains(d.id) { return true }
        if let group = d.accessory?.groupID { return preferences.hidden.contains(DeviceID(group)) }
        return false
    }

    struct SortKey {
        var isThisDevice: Bool
        var level: Int?
        var name: String
        var id: DeviceID

        init(isThisDevice: Bool, level: Int?, name: String, id: DeviceID) {
            self.isThisDevice = isThisDevice
            self.level = level
            self.name = name
            self.id = id
        }

        init(_ d: DeviceBattery, thisDeviceID: DeviceID?) {
            self.init(isThisDevice: d.id == thisDeviceID, level: d.level, name: d.name, id: d.id)
        }
    }

    static func precedes(_ a: SortKey, _ b: SortKey) -> Bool {
        if a.isThisDevice != b.isThisDevice { return a.isThisDevice }
        switch (a.level, b.level) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        switch a.name.localizedCaseInsensitiveCompare(b.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.id.recordName < b.id.recordName
        }
    }
}
