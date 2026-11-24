import Foundation
import LevelsModel

/// "Menu bar shows" setting (UI-004 R4), stored in App Group `UserDefaults` key ``key``.
public enum MenuBarMode: String, CaseIterable, Sendable {
    case lowest, iconOnly
    public static let key = "menuBarMode"
}

/// What the menu-bar label shows (UI-004 R1–R5). Monochrome: a template symbol plus text.
public struct MenuBarLabelContent: Equatable, Sendable {
    public var symbol: String
    /// `nil` = symbol only.
    public var text: String?
    /// "Levels: iPhone, 18 percent" (R5).
    public var accessibilityLabel: String
}

/// Pure label logic (UI-004 Design), unit-tested.
public enum MenuBarLabelModel {
    /// The app symbol (R3).
    public static let appSymbol = "battery.100percent"

    /// - R1: the lowest **other** device (UI-003 R2: among fresh ones, else among all;
    ///   `level == nil` never chosen), as its symbol and "18%".
    /// - R2: stale → "(18%)".
    /// - R3: no other device → app symbol only. This device's level is never shown: macOS
    ///   already shows its own battery item. Holds in the local-only build too (decision K).
    /// - R4: `.iconOnly` → app symbol whatever the data.
    public static func content(rows: [DeviceRowModel], mode: MenuBarMode, now: Date,
                               locale: Locale = .current) -> MenuBarLabelContent {
        let iconOnly = MenuBarLabelContent(symbol: appSymbol, text: nil, accessibilityLabel: "Levels")
        guard mode == .lowest else { return iconOnly }
        let others = rows.filter { !$0.isThisDevice && $0.level != nil }
        if let pick = lowest(others, now: now) {
            return content(for: pick, symbol: DeviceSymbol.symbolName(kind: pick.kind, accessoryKind: pick.accessoryKind,
                                                                      hasBattery: true),
                           now: now, locale: locale)
        }
        return iconOnly
    }

    /// UI-003 R2 "Lowest battery": lowest level among fresh rows, else among all; `nil` levels skipped.
    public static func lowest(_ rows: [DeviceRowModel], now: Date) -> DeviceRowModel? {
        let withLevel = rows.filter { $0.level != nil }
        let fresh = withLevel.filter { $0.freshness(at: now) == .fresh }
        let pool = fresh.isEmpty ? withLevel : fresh
        return pool.min { a, b in
            if a.level! != b.level! { return a.level! < b.level! }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private static func content(for row: DeviceRowModel, symbol: String, now: Date, locale: Locale) -> MenuBarLabelContent {
        let level = row.level ?? 0
        let percent = RowText.percent(level, locale: locale)
        let stale = row.freshness(at: now) == .stale
        return MenuBarLabelContent(
            symbol: symbol,
            text: stale ? "(\(percent))" : percent,
            accessibilityLabel: "Levels: \(row.name), \(loc("\(level) percent", locale: locale))")
    }
}
