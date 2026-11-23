// Shared widget building blocks (UI-003 Design, owner's widget review 2026-11-24): one device
// as a ring with its symbol inside, a compact percentage, a short one-line name and a status
// line that appears only when it says something. Used by every Home Screen family on the
// iPhone and the Mac, and by the iPhone Lock Screen families.
import Foundation
import LevelsModel
import LevelsUI
import SwiftUI
import WidgetKit

/// Text rules for widgets. Pure, unit-tested.
public enum WidgetText {
    /// "85%": digits and the sign with no space, in every locale. Widgets are tight, and a
    /// locale space ("85 %") pushed the text into the ring (owner's widget review).
    public static func percent(_ level: Int) -> String { "\(level)%" }

    /// Names to try, longest first, each on one line: the full name, without the owner
    /// ("Tornike’s "), without a trailing copy number (" (2)"), then the kind ("MacBook").
    /// The view shows the first one that fits.
    public static func nameCandidates(name: String, kind: DeviceKind, accessoryKind: AccessoryKind?,
                                      hasBattery: Bool) -> [String] {
        var out: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !out.contains(t) { out.append(t) }
        }
        add(name)
        let unowned = withoutOwner(name)
        add(unowned)
        add(withoutCopyNumber(unowned))
        add(kindName(kind: kind, accessoryKind: accessoryKind, hasBattery: hasBattery, name: name))
        return out
    }

    /// The name without the owner and copy number: "Tornike’s MacBook Pro (2)" → "MacBook Pro".
    public static func compactName(_ name: String) -> String {
        let s = withoutCopyNumber(withoutOwner(name)).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? name : s
    }

    /// "Tornike’s MacBook Pro" → "MacBook Pro" (straight or curly apostrophe).
    static func withoutOwner(_ name: String) -> String {
        guard let r = name.range(of: #"^\S.*?['’]s\s+"#, options: .regularExpression) else { return name }
        let rest = name[r.upperBound...]
        return rest.isEmpty ? name : String(rest)
    }

    /// "MacBook Pro (2)" → "MacBook Pro".
    static func withoutCopyNumber(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
    }

    /// The shortest fallback: what the device is.
    static func kindName(kind: DeviceKind, accessoryKind: AccessoryKind?, hasBattery: Bool, name: String) -> String {
        switch kind {
        case .iphone: "iPhone"
        case .ipad: "iPad"
        case .mac: hasBattery ? (name.localizedCaseInsensitiveContains("MacBook") ? "MacBook" : "Mac") : "Mac"
        case .watch: "Watch"
        case .accessory:
            switch accessoryKind {
            case .airpods?: "AirPods"
            case .mouse?: "Mouse"
            case .keyboard?: "Keyboard"
            case .trackpad?: "Trackpad"
            default: withoutOwner(name).split(separator: " ").first.map(String.init) ?? name
            }
        case .other: withoutOwner(name).split(separator: " ").first.map(String.init) ?? name
        }
    }
}

/// What a widget says under a device, if anything (owner's widget review: say why a device is
/// grey). `nil` = nothing to say: a fresh reading needs no age.
public enum WidgetStatus: Equatable, Sendable {
    /// A stale accessory: the Mac no longer sees it.
    case notConnected
    /// A stale device: when it last reported (shown as a live age).
    case lastSeen(Date)
    /// No internal battery (UI-001 R5a).
    case noBattery

    public static func of(_ row: DeviceRowModel, now: Date) -> WidgetStatus? {
        guard row.hasBattery else { return .noBattery }
        guard row.freshness(at: now) == .stale else { return nil }
        return row.kind == .accessory ? .notConnected : .lastSeen(row.readingDate(now: now))
    }
}

/// Sizes of one ring. Fixed points, like the system battery widgets: the glyph box is the same
/// for every device, so a wide laptop and a tall phone sit on the same centre line.
struct RingMetrics {
    let diameter: CGFloat
    let stroke: CGFloat
    let glyph: CGFloat
    let badge: CGFloat

    static let small = RingMetrics(diameter: 78, stroke: 7, glyph: 32, badge: 22)
    static let medium = RingMetrics(diameter: 54, stroke: 5, glyph: 22, badge: 18)
    static let large = RingMetrics(diameter: 34, stroke: 3.5, glyph: 15, badge: 14)
}

/// A capacity ring with the device symbol inside and, while charging, a bolt badge on the ring.
/// Tint per ADR-0016 rule 3: green when charging, red when low, else primary. Dimmed when stale.
struct DeviceRing: View {
    let row: DeviceRowModel
    let now: Date
    let metrics: RingMetrics

    var body: some View {
        let stale = row.freshness(at: now) == .stale
        let charging = row.showsChargingBolt(at: now)
        let fraction = CGFloat(min(max(row.level ?? 0, 0), 100)) / 100
        ZStack {
            Circle().stroke(.quaternary, lineWidth: metrics.stroke)
            if row.hasBattery {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(charging ? Color.green : row.isLow ? Color.red : Color.primary,
                            style: StrokeStyle(lineWidth: metrics.stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()
            }
            Image(systemName: DeviceSymbol.symbolName(kind: row.kind, accessoryKind: row.accessoryKind,
                                                      hasBattery: row.hasBattery))
                .resizable()
                .symbolRenderingMode(.hierarchical)
                .scaledToFit()
                .frame(width: metrics.glyph, height: metrics.glyph)
        }
        .padding(metrics.stroke / 2)
        .frame(width: metrics.diameter, height: metrics.diameter)
        .opacity(stale ? 0.45 : 1)
        .overlay(alignment: .topTrailing) {
            if charging { BoltBadge(size: metrics.badge).offset(x: metrics.badge * 0.2, y: -metrics.badge * 0.2) }
        }
        .accessibilityHidden(true)
    }
}

/// The charging badge: a green bolt in a disc of the widget's own background, so it cuts the
/// ring instead of sitting on it.
struct BoltBadge: View {
    let size: CGFloat
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        ZStack {
            // Tinted and clear modes draw every non-accent layer in one colour: no cut-out disc there.
            if renderingMode == .fullColor { Circle().fill(.background) }
            Circle().fill(Color.green).padding(size * 0.12).widgetAccentable()
            Image(systemName: "bolt.fill")
                .resizable().scaledToFit()
                .frame(width: size * 0.42, height: size * 0.42)
                .foregroundStyle(.black)
        }
        .frame(width: size, height: size)
    }
}

/// One line with the first name candidate that fits (``WidgetText/nameCandidates``).
struct ShortName: View {
    let row: DeviceRowModel
    let font: Font

    var body: some View {
        let names = WidgetText.nameCandidates(name: row.name, kind: row.kind, accessoryKind: row.accessoryKind,
                                              hasBattery: row.hasBattery)
        ViewThatFits(in: .horizontal) {
            ForEach(names, id: \.self) { Text(verbatim: $0).fixedSize() }
            Text(verbatim: names.last ?? row.name).truncationMode(.tail)
        }
        .font(font)
        .lineLimit(1)
    }
}

/// The compact percentage ("85%"), or a dash for no battery.
struct PercentText: View {
    let row: DeviceRowModel
    let now: Date
    let font: Font

    var body: some View {
        let stale = row.freshness(at: now) == .stale
        Text(verbatim: row.level.map(WidgetText.percent) ?? "–")
            .font(font)
            .monospacedDigit()
            .foregroundStyle(stale || !row.hasBattery ? .secondary : .primary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// The status line (``WidgetStatus``). With `reserve`, an empty line still takes its height,
/// so columns stay level.
struct StatusLine: View {
    let status: WidgetStatus?
    var reserve = false
    var alignment: TextAlignment = .center

    var body: some View {
        if status != nil || reserve {
            Group {
                switch status {
                case .notConnected?: Text("Not connected")
                case .noBattery?: Text("No battery")
                case .lastSeen(let date)?:
                    // Live date text reserves its widest width; keep it aligned in that width.
                    Text(.currentDate, format: .reference(to: date, allowedFields: [.minute, .hour, .day], maxFieldCount: 1))
                case nil: Text(verbatim: " ").accessibilityHidden(true)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(alignment)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }
}

/// One device as a column: ring with symbol, percentage, name, status (medium and small).
struct DeviceColumn: View {
    let row: DeviceRowModel
    let now: Date
    let metrics: RingMetrics
    let percentFont: Font
    let nameFont: Font
    /// Keep the status line's height even when empty (columns of one widget stay level).
    let reserveStatus: Bool

    var body: some View {
        VStack(spacing: 3) {
            DeviceRing(row: row, now: now, metrics: metrics)
                .padding(.bottom, 3)
            PercentText(row: row, now: now, font: percentFont)
            ShortName(row: row, font: nameFont)
                .foregroundStyle(.secondary)
            StatusLine(status: WidgetStatus.of(row, now: now), reserve: reserveStatus)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RowText.accessibilityLabel(for: row, now: now))
    }
}
