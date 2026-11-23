import Foundation
import LevelsModel
import SwiftUI

/// Localised strings from this module's `Localizable.xcstrings`.
func loc(_ key: String.LocalizationValue, locale: Locale = .current) -> String {
    String(localized: key, bundle: .module, locale: locale)
}

/// Age text as a string (UI-001 R8), for accessibility labels and tests. The on-screen
/// ``AgeText`` shows the same string.
public enum AgeFormatting {
    /// The fields R8 allows.
    public static let allowedFields: Set<Date.RelativeFormatStyle.Field> = [.minute, .hour, .day]

    /// "now" when the reading is less than a minute old (future dates included, clock skew),
    /// else the `DateReference` phrase ("5 minutes ago", "3 hours ago").
    public static func text(readingDate: Date, now: Date, locale: Locale = .current) -> String {
        if now.timeIntervalSince(readingDate) < 60 { return loc("now", locale: locale) }
        let style = SystemFormatStyle.DateReference(to: readingDate, allowedFields: allowedFields).locale(locale)
        return String(style.format(now).characters)
    }
}

/// Labels and status lines for a row (R5–R9, R13).
public enum RowText {
    /// `level` as a percentage ("62%").
    public static func percent(_ level: Int, locale: Locale = .current) -> String {
        (Double(level) / 100).formatted(.percent.locale(locale))
    }

    /// "Plugged in · no battery" (R5a).
    public static func noBattery(locale: Locale = .current) -> String {
        loc("Plugged in · no battery", locale: locale)
    }

    /// "Low" (R7).
    public static func low(locale: Locale = .current) -> String { loc("Low", locale: locale) }

    /// Short component title shown beside its level ("L", "R", "Case").
    public static func componentTitle(_ c: AccessoryComponent, locale: Locale = .current) -> String {
        switch c {
        case .left: loc("L", locale: locale)
        case .right: loc("R", locale: locale)
        case .case: loc("Case", locale: locale)
        case .main: ""
        }
    }

    static func componentSpoken(_ c: AccessoryComponent, locale: Locale) -> String? {
        switch c {
        case .left: loc("left", locale: locale)
        case .right: loc("right", locale: locale)
        case .case: loc("case", locale: locale)
        case .main: nil
        }
    }

    /// The one accessibility label of a row (R9, R5a, R6):
    /// "<name>, <level> percent[, low][, charging][, low power mode], updated <age>[, out of date]".
    /// A stale row doesn't say "charging" (R6: we no longer know). A group names each component.
    public static func accessibilityLabel(for row: DeviceRowModel, now: Date, locale: Locale = .current) -> String {
        var parts = [row.name]
        if row.isGroup {
            for c in row.components {
                parts.append(contentsOf: readingParts(c, spokenComponent: c.accessory.flatMap { componentSpoken($0.component, locale: locale) },
                                                      lowPower: false, now: now, locale: locale))
            }
        } else {
            parts.append(contentsOf: readingParts(row.records[0], spokenComponent: nil,
                                                  lowPower: row.isLowPowerMode, now: now, locale: locale))
        }
        return parts.joined(separator: ", ")
    }

    private static func readingParts(_ d: DeviceBattery, spokenComponent: String?, lowPower: Bool,
                                     now: Date, locale: Locale) -> [String] {
        var parts: [String] = []
        let fresh = FreshnessRule.of(d, at: now) == .fresh
        if let level = d.level {
            let amount = loc("\(level) percent", locale: locale)
            parts.append(spokenComponent.map { "\($0) \(amount)" } ?? amount)
            if DeviceRowModel.isLow(level) { parts.append(loc("low", locale: locale)) }
            if d.isCharging && fresh { parts.append(loc("charging", locale: locale)) }
        } else {
            if let spokenComponent { parts.append(spokenComponent) }
            parts.append(loc("plugged in, no battery", locale: locale))
        }
        if lowPower { parts.append(loc("low power mode", locale: locale)) }
        let age = AgeFormatting.text(readingDate: d.readingDate(now: now), now: now, locale: locale)
        parts.append(loc("updated \(age)", locale: locale))
        if !fresh { parts.append(loc("out of date", locale: locale)) }
        return parts
    }
}
