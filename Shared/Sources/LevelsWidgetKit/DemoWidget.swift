// DEMO-001 R10: the widget while demo mode is on. It shows the sample devices instead of the
// App Group cache and never fetches from the Mac. Levels Pro gating applies as for real data.
import Foundation
import LevelsModel
import SwiftUI
import WidgetKit

/// The demo timeline. Pure, unit-tested.
public enum DemoWidgetPlan {
    /// Ages are measured from the entry's date, so one entry with a reload after this keeps
    /// them looking live without spending the reload budget.
    public static let reloadAfter: TimeInterval = 30 * 60

    public static func timeline(snapshot: SnapshotFile, now: Date, selection: DeviceID?) -> Timeline<DeviceEntry> {
        let entry = DeviceEntry(date: now, snapshot: snapshot, preferences: DisplayPreferences(), selection: selection)
        return Timeline(entries: [entry], policy: .after(now.addingTimeInterval(reloadAfter)))
    }
}

extension DevicesProvider {
    /// The sample snapshot when the App Group flag is on, else `nil`.
    static func demoSnapshot(appGroupID: String?, now: Date) -> SnapshotFile? {
        demoSnapshot(mode: DemoModeSetting(suiteName: appGroupID), now: now)
    }

    static func demoSnapshot(mode: DemoModeSetting, now: Date) -> SnapshotFile? {
        mode.isOn ? SampleDevices.snapshot(now: now) : nil
    }
}

extension DeviceEntry {
    /// True when the entry shows the sample devices (footer, R10).
    public var isSample: Bool { SampleDevices.isSample(snapshot) }
}

/// "Sample devices", medium and large only.
struct SampleDevicesFooter: View {
    var body: some View {
        Label(String(localized: "Sample devices"), systemImage: "sparkles")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}
