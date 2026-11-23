import SwiftUI

/// "5 minutes ago" (R8); "now" under a minute. Pass the reading date
/// (`DeviceBattery.readingDate(now:)`, SYNC-002 R8), not raw `updatedAt`. `now` is the render
/// time: the containers re-render every minute (`DeviceList`'s `TimelineView(.everyMinute)`).
///
/// Plain text on purpose. The self-updating `Text(.currentDate, format: .reference(...))`
/// inside a `List` row sent iOS 26 into an endless update and layout loop once a row was a
/// minute old: the main thread spun at 100 %, back and Cancel stopped responding and the
/// watchdog killed the app (iPhone 0x8BADF00D reports, 2026-11-24). Widgets keep their own
/// live text; they don't use this view.
public struct AgeText: View {
    let updatedAt: Date
    let now: Date

    public init(updatedAt: Date, now: Date = .now) {
        self.updatedAt = min(updatedAt, now)  // future dates read as "now"
        self.now = now
    }

    public var body: some View {
        Text(AgeFormatting.text(readingDate: updatedAt, now: now))
    }
}
