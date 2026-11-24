// Widgets-iOS entry point (ADR-0003, UI-003, NET-004 variants A + B, lead's call 29). Widget
// extensions link LevelsModel, LevelsUI, LevelsWidgetKit and LevelsNet: never LevelsSync or
// LevelsReaders (ADR-0003 §3, SYNC-001 R14). The widget reads the App Group snapshot cache the
// app writes (A) and, when that is older than 15 minutes, fetches from the paired Mac (B,
// WidgetHubFetch).
//
// Every family reuses LevelsWidgetKit's views, from the same `DeviceEntry`.
import LevelsModel
import LevelsUI
import LevelsWidgetKit
import SwiftUI
import UIKit
import WidgetKit

@main
struct LevelsWidgets: WidgetBundle {
    var body: some Widget {
        PhoneDevicesWidget()
        LevelsLiveActivity()  // LIVE-001: Lock Screen, StandBy, Dynamic Island
    }
}

/// UI-003 R1, R3: one widget kind, `LevelsDevicesWidget.kind`, with every iPhone family.
struct PhoneDevicesWidget: Widget {
    static let families: [WidgetFamily] = [
        .systemSmall, .systemMedium, .systemLarge,
        .accessoryCircular, .accessoryRectangular, .accessoryInline,
    ]

    var body: some WidgetConfiguration {
        #if LEVELS_PUSH
        configuration.pushHandler(LevelsWidgetPushHandler.self)  // WidgetPush.swift
        #else
        configuration
        #endif
    }

    private var configuration: some WidgetConfiguration {
        AppIntentConfiguration(kind: LevelsDevicesWidget.kind, intent: SelectDeviceIntent.self,
                               provider: DevicesProvider(fetch: WidgetHubFetch.make(),
                                                         readOwn: WidgetOwnBattery.read,
                                                         freshFor: WidgetPushState.freshFor)) { entry in
            PhoneWidgetView(entry: entry)
        }
        .configurationDisplayName(Text("Battery Levels"))
        .description(Text("See the battery of all your devices."))
        .supportedFamilies(Self.families)
    }
}

struct PhoneWidgetView: View {
    let entry: DeviceEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            AccessoryCircularView(entry: entry)
                .containerBackground(.clear, for: .widget)
        case .accessoryRectangular:
            AccessoryRectangularView(entry: entry)
                .containerBackground(.clear, for: .widget)
        case .accessoryInline:
            AccessoryInlineView(entry: entry)
                .containerBackground(.clear, for: .widget)
        default:
            DevicesWidgetView(entry: entry)  // small, medium, large and their empty state
                .containerBackground(.fill.tertiary, for: .widget)  // UI-003 R10
        }
    }
}

/// This iPhone's battery, read by the widget itself at each timeline load: the app writes its
/// own record only while it runs, so without this the iPhone row kept the app's last reading.
enum WidgetOwnBattery {
    @Sendable static func read() async -> OwnBatteryReading? {
        await MainActor.run {
            let device = UIDevice.current
            if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
            let state: OwnBatteryReading.State = switch device.batteryState {
            case .unplugged: .unplugged
            case .charging: .charging
            case .full: .full
            case .unknown: .unknown
            @unknown default: .unknown
            }
            let reading = OwnBatteryReading(level: OwnBatteryReading.level(fromFraction: Double(device.batteryLevel)),
                                            state: state, isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                            readAt: Date())
            if let level = reading.level {
                WidgetHubFetch.logger.notice("Widget: own battery \(level, privacy: .public) %")
            } else {
                // UIDevice answered −1 (monitoring refused in this extension, or the Simulator):
                // `overlaying(own:)` then keeps the app's last cached reading of this iPhone.
                WidgetHubFetch.logger.notice("Widget: own battery unknown (UIDevice −1, monitoring \(device.isBatteryMonitoringEnabled ? "on" : "off", privacy: .public)); showing the app's last reading")
            }
            return reading
        }
    }
}

// The Lock Screen family views (AccessoryCircularView, AccessoryRectangularView,
// AccessoryInlineView) live in LevelsWidgetKit, so the render harness can draw them too.

// MARK: - Previews (UI-003 Tests)

private let previewEntry = DevicesProvider.sample(now: .now)
private let emptyEntry = DeviceEntry(date: .now, snapshot: nil, preferences: DisplayPreferences())

#Preview("Small", as: .systemSmall) { PhoneDevicesWidget() } timeline: { previewEntry; emptyEntry }
#Preview("Medium", as: .systemMedium) { PhoneDevicesWidget() } timeline: { previewEntry; emptyEntry }
#Preview("Large", as: .systemLarge) { PhoneDevicesWidget() } timeline: { previewEntry; emptyEntry }
#Preview("Circular", as: .accessoryCircular) { PhoneDevicesWidget() } timeline: { previewEntry; emptyEntry }
#Preview("Rectangular", as: .accessoryRectangular) { PhoneDevicesWidget() } timeline: { previewEntry; emptyEntry }
#Preview("Inline", as: .accessoryInline) { PhoneDevicesWidget() } timeline: { previewEntry; emptyEntry }
