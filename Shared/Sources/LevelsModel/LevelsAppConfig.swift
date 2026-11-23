import Foundation

/// IDs every Levels target reads from its own Info.plist, so the Team ID and prefix stay in
/// `Config/Levels.xcconfig` only (ADR-0003 §6). Keys are filled in at build time.
public enum LevelsAppConfig {
    /// `<TEAMID>.<rdns>.levels` on macOS (ADR-0009, lead's call 2026-11-23).
    public static let appGroupKey = "LevelsAppGroupID"
    /// `<TEAMID>.<rdns>.levels.shared` (ADR-0007).
    public static let keychainGroupKey = "LevelsKeychainGroup"
    /// `<rdns>.levels.device-identity` (ADR-0007).
    public static let keychainServiceKey = "LevelsKeychainService"

    public static var appGroupID: String? { value(appGroupKey) }
    public static var keychainAccessGroup: String? { value(keychainGroupKey) }
    public static var keychainService: String { value(keychainServiceKey) ?? "levels.device-identity" }
    /// iPhone's Mac pairing item, `<rdns>.levels.hub` (NET-002 R8), in the shared access group.
    public static var hubPairingService: String {
        keychainService.replacingOccurrences(of: ".device-identity", with: "") + ".hub"
    }

    /// `levels://device/<uuid>` (UI-003 R7, UI-004 R14).
    public static func deviceURL(_ id: DeviceID) -> URL { URL(string: "levels://device/\(id.recordName)")! }
    /// `levels://` (list widgets, accessory families).
    public static let listURL = URL(string: "levels://")!
    /// `levels://settings` (MAC-001 R5 fallback).
    public static let settingsURL = URL(string: "levels://settings")!

    /// What a `levels://` URL asks for.
    public enum Route: Equatable, Sendable { case list, device(DeviceID), settings }

    /// Parses a `levels://` URL; an unknown or malformed device id opens the list (UI-004 R14).
    public static func route(_ url: URL) -> Route? {
        guard url.scheme?.lowercased() == "levels" else { return nil }
        switch url.host()?.lowercased() {
        case "device":
            let raw = url.pathComponents.first { $0 != "/" } ?? ""
            return DeviceID(recordName: raw).map(Route.device) ?? .list
        case "settings": return .settings
        default: return .list
        }
    }

    private static func value(_ key: String) -> String? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: key) as? String, !s.isEmpty, !s.contains("$(") else { return nil }
        return s
    }
}
