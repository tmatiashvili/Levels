// Lock Screen (accessory) family views (UI-003 R3, R8, R9), shared so the render harness and
// previews can draw them on the Mac too. The iPhone widget uses them for `accessoryCircular`,
// `accessoryRectangular` and `accessoryInline`.
//
// The Lock Screen draws accessory widgets in the vibrant rendering mode (and the Watch in
// accented): colours are dropped and only luminance and opacity survive (R9). So state is a
// symbol, the gauges are plain shapes in primary with a fainter track, and the fill is in the
// accent group. The gauges are our own shapes, not `Gauge` with an accessory style, so they
// draw the same in every host, including `ImageRenderer` on the Mac (which drew the system
// accessory gauge as a placeholder).
import Foundation
import LevelsModel
import LevelsUI
import SwiftUI
import WidgetKit

/// `accessoryCircular`: one device as a capacity ring with the device symbol inside and the
/// level under it ("⚡85" while charging, "!18" when low, a clock when stale).
public struct AccessoryCircularView: View {
    let entry: DeviceEntry

    public init(entry: DeviceEntry) { self.entry = entry }

    public var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let row = entry.singleDevice, let level = row.level {
                let stale = row.freshness(at: entry.date) == .stale
                ZStack {
                    AccessoryRing(fraction: Double(level) / 100, lineWidth: 4.5)
                        .padding(3)
                    VStack(spacing: 0) {
                        AccessoryGlyph(row: row, size: 17)
                        Group {
                            if row.showsChargingBolt(at: entry.date) {
                                Text("\(Image(systemName: "bolt.fill"))\(level)")
                            } else if stale {
                                Text("\(Image(systemName: "clock"))\(level)")
                            } else if row.isLow {
                                Text("\(Image(systemName: "exclamationmark"))\(level)")
                            } else {
                                Text(verbatim: "\(level)")
                            }
                        }
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .widgetAccentable()
                    }
                    .padding(.top, 2)
                }
                .opacity(stale ? 0.6 : 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(RowText.accessibilityLabel(for: row, now: entry.date))
                .widgetURL(LevelsAppConfig.deviceURL(row.id))  // UI-003 R7
            } else if let row = entry.singleDevice {  // no battery (UI-001 R5a)
                AccessoryGlyph(row: row, size: 22)
                    .accessibilityLabel(RowText.accessibilityLabel(for: row, now: entry.date))
                    .widgetURL(LevelsAppConfig.deviceURL(row.id))
            } else {
                AccessoryNoDataView()
            }
        }
    }
}

/// A capacity ring for accessory widgets: a faint full track and the level in the accent group.
struct AccessoryRing: View {
    let fraction: Double
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(.tertiary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
        }
    }
}

/// A capacity bar for accessory widgets: a faint full capsule and the level in the accent group.
struct AccessoryBar: View {
    let fraction: Double
    var height: CGFloat = 5

    var body: some View {
        let f = min(max(fraction, 0), 1)
        Capsule()
            .fill(.tertiary)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(.primary)
                        .frame(width: max(height, geo.size.width * f))
                        .widgetAccentable()
                }
            }
            .frame(height: height)
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
public struct AccessoryRectangularView: View {
    let entry: DeviceEntry

    public init(entry: DeviceEntry) { self.entry = entry }

    public var body: some View {
        let rows = Array(entry.rows.prefix(3))
        if rows.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "battery.0percent")
                    .widgetAccentable()
                Text(Self.emptyText(entry))
                    .font(.caption)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(LevelsAppConfig.listURL)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(rows) { row in
                    AccessoryRectangularRow(row: row, now: entry.date)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(LevelsAppConfig.listURL)  // UI-003 R7: accessory list opens the list
        }
    }

    static func emptyText(_ entry: DeviceEntry) -> String {
        if entry.isNotPaired { return String(localized: "Open Levels to connect your Mac") }  // NET-004 R12
        return entry.snapshot == nil ? String(localized: "Open Levels to start") : String(localized: "No devices")
    }
}

/// One `accessoryRectangular` line.
struct AccessoryRectangularRow: View {
    let row: DeviceRowModel
    let now: Date

    var body: some View {
        let stale = row.freshness(at: now) == .stale
        HStack(spacing: 5) {
            AccessoryGlyph(row: row, size: 15)
                .widgetAccentable()
            if let level = row.level {
                Text(verbatim: WidgetText.percent(level))
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: 36, alignment: .leading)
                    .widgetAccentable()
                AccessoryBar(fraction: Double(level) / 100)
                // R9: colours turn white on the Lock Screen, so state is a symbol.
                Group {
                    if stale {
                        Image(systemName: "clock")
                    } else if row.showsChargingBolt(at: now) {
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
                Spacer(minLength: 0)
            }
        }
        .opacity(stale ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RowText.accessibilityLabel(for: row, now: now))
    }
}

/// `accessoryInline`: "[symbol] MacBook Pro 62% · 5 min" (short name + % + short age). The
/// system draws inline widgets as plain text and one symbol: no shapes, no colour.
public struct AccessoryInlineView: View {
    let entry: DeviceEntry

    public init(entry: DeviceEntry) { self.entry = entry }

    public var body: some View {
        if let row = entry.singleDevice {
            let symbol = DeviceSymbol.symbolName(kind: row.kind, accessoryKind: row.accessoryKind, hasBattery: row.hasBattery)
            let name = WidgetText.compactName(row.name)
            let level = row.level.map(WidgetText.percent) ?? "—"
            let age = Text(.currentDate, format: .reference(to: row.readingDate(now: entry.date),
                                                            allowedFields: [.minute, .hour, .day], maxFieldCount: 1))
            Label {
                Text("\(name) \(level) · \(age)")
            } icon: {
                Image(systemName: row.showsChargingBolt(at: entry.date) ? "bolt.fill" : symbol)
            }
            .widgetURL(LevelsAppConfig.deviceURL(row.id))
        } else {
            Label("—", systemImage: "battery.0percent")
                .widgetURL(LevelsAppConfig.listURL)
        }
    }
}

/// UI-003 R8: accessory families with no data show `battery.0percent` and "—".
struct AccessoryNoDataView: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "battery.0percent")
                .widgetAccentable()
            Text("—")
        }
        .accessibilityLabel(Text("Open Levels to start"))
        .widgetURL(LevelsAppConfig.listURL)
    }
}
