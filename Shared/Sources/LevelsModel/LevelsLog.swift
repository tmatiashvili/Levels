import Foundation

/// The one `Logger` subsystem every Levels target uses (SYNC-001 R21: `<bundle-prefix>.levels`).
public enum LevelsLog {
    /// `<bundle-prefix>.levels`, derived from the running bundle's identifier by cutting it
    /// after its first `levels` component (ADR-0003 §5: every target's ID starts with
    /// `<rdns>.levels`). Falls back to `"levels"` when the bundle ID has no such component.
    public static let subsystem = subsystem(forBundleID: Bundle.main.bundleIdentifier)

    /// Category for sync logs (SYNC-001 R21).
    public static let syncCategory = "sync"

    static func subsystem(forBundleID bundleID: String?) -> String {
        guard let bundleID else { return "levels" }
        let parts = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        guard let index = parts.firstIndex(of: "levels") else { return "levels" }
        return parts[...index].joined(separator: ".")
    }
}
