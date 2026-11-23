// Widgets-iOS entry point (ADR-0003, UI-003, NET-004 variants A + B, lead's call 29). Widget
// extensions link LevelsModel, LevelsUI, LevelsWidgetKit and LevelsNet: never LevelsSync or
// LevelsReaders (ADR-0003 §3, SYNC-001 R14). The widget reads the App Group snapshot cache the
// app writes (A) and, when that is older than 15 minutes, fetches from the paired Mac (B,
// WidgetHubFetch).
//
// Home Screen families reuse LevelsWidgetKit's views; the Lock Screen (accessory) families
// are drawn here, from the same `DeviceEntry`.
import LevelsModel
import LevelsUI
import LevelsWidgetKit
import SwiftUI
import WidgetKit

@main
struct LevelsWidgets: WidgetBundle {
    var body: some Widget {
        PhoneDevicesWidget()
    }
}

/// UI-003 R1, R3: one widget kind, `LevelsDevicesWidget.kind`, with every iPhone family.
struct PhoneDevicesWidget: Widget {
    static let families: [WidgetFamily] = [
        .systemSmall, .systemMedium, .systemLarge,
        .accessoryCircular, .accessoryRectangular, .accessoryInline,
    ]

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: LevelsDevicesWidget.kind, intent: SelectDeviceIntent.self,
                               provider: DevicesProvider(fetch: WidgetHubFetch.make())) { entry in
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
            CircularDeviceView(entry: entry)
                .containerBackground(.clear, for: .widget)
        case .accessoryRectangular:
            RectangularDevicesView(entry: entry)
                .containerBackground(.clear, for: .widget)
        case .accessoryInline:
            InlineDeviceView(entry: entry)
                .containerBackground(.clear, for: .widget)
        default:
            DevicesWidgetView(entry: entry)  // small, medium, large and their empty state
                .containerBackground(.fill.tertiary, for: .widget)  // UI-003 R10
        }
    }
}

// MARK: - Lock Screen families (UI-003 R3, R8, R9)

/// `accessoryCircular`: one device as a capacity gauge, device symbol as label, % as value.
struct CircularDeviceView: View {
    let entry: DeviceEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let row = entry.singleDevice, let level = row.level {
                Gauge(value: Double(level), in: 0...100) {
                    DeviceSymbol(row: row)
                } currentValueLabel: {
                    Text("\(level)").monospacedDigit()
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .widgetAccentable()
                .opacity(row.freshness(at: entry.date) == .stale ? 0.5 : 1)
                .accessibilityLabel(RowText.accessibilityLabel(for: row, now: entry.date))
                .widgetURL(LevelsAppConfig.deviceURL(row.id))  // UI-003 R7
            } else if let row = entry.singleDevice {  // no battery (UI-001 R5a)
                DeviceSymbol(row: row)
                    .accessibilityLabel(RowText.accessibilityLabel(for: row, now: entry.date))
                    .widgetURL(LevelsAppConfig.deviceURL(row.id))
            } else {
                NoDataView()
            }
        }
    }
}

/// `accessoryRectangular`: up to 3 devices in UI-001 order, symbol, % and a mini bar.
struct RectangularDevicesView: View {
    let entry: DeviceEntry

    var body: some View {
        let rows = Array(entry.rows.prefix(3))
        if rows.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "battery.0percent")
                Text(Self.emptyText(entry))
                    .font(.caption)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(LevelsAppConfig.listURL)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in
                    let stale = row.freshness(at: entry.date) == .stale
                    HStack(spacing: 4) {
                        DeviceSymbol(row: row)
                            .widgetAccentable()
                            .frame(width: 16)
                        if let level = row.level {
                            Text(RowText.percent(level))
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .frame(minWidth: 36, alignment: .leading)
                            Gauge(value: Double(level), in: 0...100) { EmptyView() }
                                .gaugeStyle(.accessoryLinearCapacity)
                                .widgetAccentable()
                            // R9: colours turn white on the Lock Screen, so state is a symbol.
                            if stale {
                                Image(systemName: "clock").font(.caption2)
                            } else if row.showsChargingBolt(at: entry.date) {
                                Image(systemName: "bolt.fill").font(.caption2)
                            } else if row.isLow {
                                Image(systemName: "exclamationmark").font(.caption2.bold())
                            }
                        } else {
                            Text(RowText.noBattery()).font(.caption2)
                        }
                    }
                    .opacity(stale ? 0.6 : 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(RowText.accessibilityLabel(for: row, now: entry.date))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(LevelsAppConfig.listURL)  // UI-003 R7: accessory list opens the list
        }
    }

    static func emptyText(_ entry: DeviceEntry) -> String {
        if entry.isNotPaired { return String(localized: "Open Levels to connect your Mac") }  // NET-004 R12
        return entry.snapshot == nil ? String(localized: "Open Levels to start") : String(localized: "No devices")
    }
}

/// `accessoryInline`: "[symbol] iPhone 62% · 5 min" (symbol + name + % + short age).
struct InlineDeviceView: View {
    let entry: DeviceEntry

    var body: some View {
        if let row = entry.singleDevice {
            let symbol = DeviceSymbol.symbolName(kind: row.kind, accessoryKind: row.accessoryKind, hasBattery: row.hasBattery)
            let level = row.level.map { RowText.percent($0) } ?? "—"
            let age = Text(.currentDate, format: .reference(to: row.readingDate(now: entry.date),
                                                            allowedFields: [.minute, .hour, .day]))
            Label {
                Text("\(row.name) \(level) · \(age)")
            } icon: {
                Image(systemName: symbol)
            }
            .widgetURL(LevelsAppConfig.deviceURL(row.id))
        } else {
            Label("—", systemImage: "battery.0percent")
                .widgetURL(LevelsAppConfig.listURL)
        }
    }
}

/// UI-003 R8: accessory families with no data show `battery.0percent` and "—".
struct NoDataView: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "battery.0percent")
            Text("—")
        }
        .accessibilityLabel(Text("Open Levels to start"))
        .widgetURL(LevelsAppConfig.listURL)
    }
}

// MARK: - Previews (UI-003 Tests)

private let previewEntry = DevicesProvider.sample(now: .now)
private let emptyEntry = DeviceEntry(date: .now, snapshot: nil, preferences: DisplayPreferences())

#Preview("Small", as: .systemSmall) { PhoneDevicesWidget() } timeline: { previewEntry; emptyEntry }
#Preview("Medium", as: .systemMedium) { PhoneDevicesWidget() } timeline: { previewEntry; emptyEntry }
#Preview("Large", as: .systemLarge) { PhoneDevicesWidget() } timeline: { previewEntry; emptyEntry }
#Preview("Circular", as: .accessoryCircular) { PhoneDevicesWidget() } timeline: { previewEntry; emptyEntry }
#Preview("Rectangular", as: .accessoryRectangular) { PhoneDevicesWidget() } timeline: { previewEntry; emptyEntry }
#Preview("Inline", as: .accessoryInline) { PhoneDevicesWidget() } timeline: { previewEntry; emptyEntry }
