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

/// `accessoryCircular`: one device as a capacity gauge with the device symbol inside and the
/// level under it ("⚡85" while charging). Colours turn white on the Lock Screen (R9), so the
/// state is a symbol.
struct CircularDeviceView: View {
    let entry: DeviceEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let row = entry.singleDevice, let level = row.level {
                let stale = row.freshness(at: entry.date) == .stale
                Gauge(value: Double(level), in: 0...100) {
                    EmptyView()
                } currentValueLabel: {
                    VStack(spacing: 0) {
                        AccessoryGlyph(row: row, size: 17)
                        Group {
                            if row.showsChargingBolt(at: entry.date) {
                                Text("\(Image(systemName: "bolt.fill"))\(level)")
                            } else if stale {
                                Text("\(Image(systemName: "clock"))\(level)")
                            } else {
                                Text(verbatim: "\(level)")
                            }
                        }
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    }
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .widgetAccentable()
                .opacity(stale ? 0.6 : 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(RowText.accessibilityLabel(for: row, now: entry.date))
                .widgetURL(LevelsAppConfig.deviceURL(row.id))  // UI-003 R7
            } else if let row = entry.singleDevice {  // no battery (UI-001 R5a)
                AccessoryGlyph(row: row, size: 22)
                    .accessibilityLabel(RowText.accessibilityLabel(for: row, now: entry.date))
                    .widgetURL(LevelsAppConfig.deviceURL(row.id))
            } else {
                NoDataView()
            }
        }
    }
}

/// The device symbol in a fixed square box, so every device sits on the same line.
struct AccessoryGlyph: View {
    let row: DeviceRowModel
    let size: CGFloat

    var body: some View {
        Image(systemName: DeviceSymbol.symbolName(kind: row.kind, accessoryKind: row.accessoryKind,
                                                  hasBattery: row.hasBattery))
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// `accessoryRectangular`: up to 3 devices in UI-001 order: symbol, "85%", a mini bar and a
/// state symbol (bolt, clock when stale, ! when low).
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
                    HStack(spacing: 5) {
                        AccessoryGlyph(row: row, size: 15)
                            .widgetAccentable()
                        if let level = row.level {
                            Text(verbatim: WidgetText.percent(level))
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                                .frame(width: 34, alignment: .leading)
                            Gauge(value: Double(level), in: 0...100) { EmptyView() }
                                .gaugeStyle(.accessoryLinearCapacity)
                                .widgetAccentable()
                            // R9: colours turn white on the Lock Screen, so state is a symbol.
                            Group {
                                if stale {
                                    Image(systemName: "clock")
                                } else if row.showsChargingBolt(at: entry.date) {
                                    Image(systemName: "bolt.fill")
                                } else if row.isLow {
                                    Image(systemName: "exclamationmark")
                                } else {
                                    Image(systemName: "bolt.fill").hidden()
                                }
                            }
                            .font(.caption2.bold())
                            .frame(width: 10)
                        } else {
                            Text(RowText.noBattery()).font(.caption2).lineLimit(1)
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

/// `accessoryInline`: "[symbol] MacBook Pro 62% · 5 min" (short name + % + short age).
struct InlineDeviceView: View {
    let entry: DeviceEntry

    var body: some View {
        if let row = entry.singleDevice {
            let symbol = DeviceSymbol.symbolName(kind: row.kind, accessoryKind: row.accessoryKind, hasBattery: row.hasBattery)
            let name = WidgetText.compactName(row.name)
            let level = row.level.map(WidgetText.percent) ?? "—"
            let age = Text(.currentDate, format: .reference(to: row.readingDate(now: entry.date),
                                                            allowedFields: [.minute, .hour, .day], maxFieldCount: 1))
            Label {
                Text("\(name) \(level) · \(age)")
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
