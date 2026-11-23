import Foundation

/// The name a device writes into its own record (SYNC-002 R17, ADR-0007 rule 8).
public enum DefaultDeviceName {
    /// The default name for this device when the user has not renamed it:
    /// the model name, or on a Mac its computer name (else "Mac").
    public static func current(kind: DeviceKind) -> String {
        defaultName(kind: kind, computerName: kind == .mac ? macComputerName() : nil)
    }

    /// The name to report: the in-app rename (`DisplayPreferences.thisDeviceName`)
    /// when it is set and not blank, else ``current(kind:)``.
    public static func resolved(kind: DeviceKind, thisDeviceName: String?) -> String {
        resolved(kind: kind, thisDeviceName: thisDeviceName, computerName: kind == .mac ? macComputerName() : nil)
    }

    static func resolved(kind: DeviceKind, thisDeviceName: String?, computerName: String?) -> String {
        if let rename = thisDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines), !rename.isEmpty {
            return rename
        }
        return defaultName(kind: kind, computerName: computerName)
    }

    static func defaultName(kind: DeviceKind, computerName: String?) -> String {
        switch kind {
        case .iphone: return "iPhone"
        case .ipad: return "iPad"
        case .watch: return "Apple Watch"
        case .mac:
            if let name = computerName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return name
            }
            return "Mac"
        case .accessory: return "Accessory"  // real names come from MAC-003
        case .other: return "Device"
        }
    }

    private static func macComputerName() -> String? {
        #if os(macOS)
        return Host.current().localizedName
        #else
        return nil
        #endif
    }
}
