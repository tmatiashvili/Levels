import Foundation

/// Whether a reading is recent enough to trust (ADR-0017).
public enum Freshness: Sendable, Equatable {
    case fresh, stale
}

/// Staleness thresholds per device type (ADR-0017 rule 4, SYNC-002 R10). Pure functions.
public enum FreshnessRule {
    /// iPhone, iPad, Watch and `other`.
    public static let handheldThreshold: TimeInterval = 2 * 60 * 60
    /// Mac (with or without a battery) and accessories: one missed 30-min heartbeat plus slack.
    public static let macThreshold: TimeInterval = 65 * 60
    /// Mac or accessory actively charging below 100 %.
    public static let chargingThreshold: TimeInterval = 30 * 60
    /// Age at which a device moves to "Old devices" (ADR-0005).
    public static let retiredAge: TimeInterval = 30 * 24 * 60 * 60

    /// How old a reading may be and still count as fresh.
    public static func threshold(for d: DeviceBattery) -> TimeInterval {
        switch d.kind {
        case .iphone, .ipad, .watch, .other:
            return handheldThreshold
        case .mac, .accessory:
            // An unknown level is not "below 100", so it keeps the type's threshold.
            if d.isCharging, let level = d.level, level < 100 { return chargingThreshold }
            return macThreshold
        }
    }

    /// `.fresh` when `age(now:) <= threshold`; exactly at the threshold is fresh.
    public static func of(_ d: DeviceBattery, at now: Date) -> Freshness {
        d.age(now: now) <= threshold(for: d) ? .fresh : .stale
    }

    /// The moment the reading turns stale: `readingDate + threshold`.
    /// Uses `min(updatedAt, serverModifiedAt)` as the reading date (no `now` cap),
    /// so the result is stable for widget timelines.
    public static func staleDate(for d: DeviceBattery) -> Date {
        min(d.updatedAt, d.serverModifiedAt ?? d.updatedAt).addingTimeInterval(threshold(for: d))
    }

    /// True when the reading is 30 days old or more (ADR-0005 "Old devices").
    public static func isRetired(_ d: DeviceBattery, at now: Date) -> Bool {
        d.age(now: now) >= retiredAge
    }
}
