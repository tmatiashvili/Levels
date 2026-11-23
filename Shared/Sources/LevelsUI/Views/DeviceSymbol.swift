import LevelsModel
import SwiftUI

/// The SF Symbol for a device (ADR-0016 rule 4 table).
public struct DeviceSymbol: View {
    let name: String

    public init(kind: DeviceKind, accessoryKind: AccessoryKind? = nil, hasBattery: Bool = true) {
        name = Self.symbolName(kind: kind, accessoryKind: accessoryKind, hasBattery: hasBattery)
    }

    public init(row: DeviceRowModel) {
        self.init(kind: row.kind, accessoryKind: row.accessoryKind, hasBattery: row.hasBattery)
    }

    public var body: some View {
        Image(systemName: name)
            .symbolRenderingMode(.hierarchical)
            .accessibilityHidden(true)
    }

    /// A Mac with no battery is a desktop (`desktopcomputer`, R5a). AirPods have no Pro/Max
    /// subtype in the record yet, so all show `airpods`.
    nonisolated public static func symbolName(kind: DeviceKind, accessoryKind: AccessoryKind?, hasBattery: Bool) -> String {
        switch kind {
        case .iphone: return "iphone"
        case .ipad: return "ipad"
        case .mac: return hasBattery ? "laptopcomputer" : "desktopcomputer"
        case .watch: return "applewatch"
        case .accessory:
            switch accessoryKind {
            case .airpods?: return "airpods"
            case .mouse?: return "magicmouse"
            case .keyboard?: return "keyboard"
            case .trackpad?: return "rectangle.and.hand.point.up.left"
            case .other?: return "battery.100percent"
            case nil: return "headphones"
            }
        case .other: return "battery.100percent"
        }
    }
}
