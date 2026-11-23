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

/// The state a ring shows as a badge on its edge. A shape, not only a colour: in tinted and
/// clear (Liquid Glass) styles, StandBy and on the Lock Screen every colour turns white, so
/// "low" must still read as low (ADR-0016 rule 3, Liquid Glass review 2026-11-24).
enum RingBadge: Equatable {
    case charging
    case low

    static func of(_ row: DeviceRowModel, now: Date) -> RingBadge? {
        if row.showsChargingBolt(at: now) { return .charging }
        return row.hasBattery && row.isLow ? .low : nil
    }

    var symbolName: String {
        switch self {
        case .charging: "bolt.circle.fill"
        case .low: "exclamationmark.circle.fill"
        }
    }
}

/// Colours of one ring for the current rendering mode. Pure, unit-tested.
///
/// - `.fullColor` (default and dark Home Screen, Mac desktop in front): green when charging,
///   red when low, else primary, on a faint track.
/// - `.accented` (tinted and clear Home Screen, Mac desktop behind windows) and `.vibrant`
///   (Lock Screen, StandBy): the system draws everything in one colour and keeps only opacity,
///   so the fill is solid primary in the accent group and the track a fainter primary.
enum RingStyle: Equatable {
    case charging, low, normal

    static func of(_ row: DeviceRowModel, now: Date) -> RingStyle {
        if row.showsChargingBolt(at: now) { return .charging }
        return row.isLow ? .low : .normal
    }

    func fill(_ mode: WidgetRenderingMode) -> Color {
        guard mode == .fullColor else { return .primary }
        switch self {
        case .charging: return .green
        case .low: return .red
        case .normal: return .primary
        }
    }

    /// The track behind the fill. Stronger when the system removed the widget background
    /// (StandBy, clear glass) or drew the widget in one colour, where `.quaternary` vanishes.
    static func track(_ mode: WidgetRenderingMode, showsBackground: Bool) -> AnyShapeStyle {
        mode == .fullColor && showsBackground ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tertiary)
    }
}

/// A capacity ring with the device symbol inside and, while charging or low, a badge on the
/// ring. Tint per ADR-0016 rule 3 in full colour; one colour plus a badge shape in the tinted,
/// clear, StandBy and Lock Screen styles. Dimmed when stale.
struct DeviceRing: View {
    let row: DeviceRowModel
    let now: Date
    let metrics: RingMetrics
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.showsWidgetContainerBackground) private var showsBackground

    var body: some View {
        let stale = row.freshness(at: now) == .stale
        let badge = RingBadge.of(row, now: now)
        let fraction = CGFloat(min(max(row.level ?? 0, 0), 100)) / 100
        ZStack {
            Circle().stroke(RingStyle.track(renderingMode, showsBackground: showsBackground), lineWidth: metrics.stroke)
            if row.hasBattery {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(RingStyle.of(row, now: now).fill(renderingMode),
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
                .widgetAccentable()
        }
        .padding(metrics.stroke / 2)
        .frame(width: metrics.diameter, height: metrics.diameter)
        // The badge cuts the ring instead of sitting on a disc of the background: tinted and
        // clear styles have no background to paint, only transparency survives.
        .mask { RingMask(cut: badge != nil, badge: metrics.badge, gap: metrics.stroke * 0.45) }
        .overlay(alignment: .topTrailing) {
            if let badge {
                StateBadge(badge: badge, size: metrics.badge)
                    .offset(x: metrics.badge * 0.2, y: -metrics.badge * 0.2)
            }
        }
        .opacity(stale ? 0.45 : 1)
        .accessibilityHidden(true)
    }
}

/// Everything but a disc around the badge spot (top trailing).
private struct RingMask: View {
    let cut: Bool
    let badge: CGFloat
    let gap: CGFloat

    var body: some View {
        Rectangle()
            .overlay(alignment: .topTrailing) {
                if cut {
                    Circle()
                        .frame(width: badge + 2 * gap, height: badge + 2 * gap)
                        .offset(x: badge * 0.2 + gap, y: -badge * 0.2 - gap)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
    }
}

/// The charging or low badge: a symbol in a disc. In full colour a black bolt on green or a
/// white "!" on red; in the one-colour styles the glyph is a hole in a solid disc, so it stays
/// readable when the system paints every layer white.
struct StateBadge: View {
    let badge: RingBadge
    let size: CGFloat
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let image = Image(systemName: badge.symbolName).resizable().scaledToFit()
        Group {
            if renderingMode == .fullColor {
                switch badge {
                case .charging: image.symbolRenderingMode(.palette).foregroundStyle(.black, .green)
                case .low: image.symbolRenderingMode(.palette).foregroundStyle(.white, .red)
                }
            } else {
                image.symbolRenderingMode(.monochrome).foregroundStyle(.primary)
            }
        }
        .frame(width: size, height: size)
        .widgetAccentable()
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
            .widgetAccentable()
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

/// A tap target that opens one device (UI-003 R7). In the render harness, where
/// `ImageRenderer` can't draw a `Link`, just the content.
struct DeviceLink<Content: View>: View {
    let id: DeviceID
    @ViewBuilder let content: Content
    @Environment(\.isWidgetRenderHarness) private var isHarness

    var body: some View {
        if isHarness {
            content.foregroundStyle(.primary)
        } else {
            Link(destination: LevelsAppConfig.deviceURL(id)) {
                content.foregroundStyle(.primary)  // accented mode must not tint links blue
            }
        }
    }
}

extension EnvironmentValues {
    /// True only in previews and the snapshot harness (``GalleryCell``).
    @Entry var isWidgetRenderHarness = false
}
