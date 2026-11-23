import SwiftUI

/// "5 minutes ago" that updates itself (R8, ADR-0017 rule 2); "now" under a minute.
/// Pass the reading date (`DeviceBattery.readingDate(now:)`, SYNC-002 R8), not raw `updatedAt`.
/// `now` is the render time (the list's `TimelineView` date, or a widget entry's date).
public struct AgeText: View {
    let updatedAt: Date
    let now: Date

    public init(updatedAt: Date, now: Date = .now) {
        self.updatedAt = min(updatedAt, now)  // future dates read as "now"
        self.now = now
    }

    public var body: some View {
        if now.timeIntervalSince(updatedAt) < 60 {
            Text("now", bundle: .module)
        } else {
            Text(.currentDate, format: .reference(to: updatedAt, allowedFields: AgeFormatting.allowedFields))
        }
    }
}
