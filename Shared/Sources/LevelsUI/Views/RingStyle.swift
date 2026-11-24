import SwiftUI
import WidgetKit  // WidgetRenderingMode

/// Colours of a battery ring or bar (ADR-0016 rule 3). One rule for the app rows and the
/// widgets. Pure, unit-tested.
///
/// - `.fullColor` (the app, default and dark Home Screen, Mac desktop in front): green when
///   charging, red when low, else primary, on a faint track.
/// - `.accented` (tinted and clear Home Screen, Mac desktop behind windows) and `.vibrant`
///   (Lock Screen, StandBy): the system draws everything in one colour and keeps only opacity,
///   so the fill is solid primary in the accent group and the track a fainter primary.
///
/// Stale readings keep their colour but the caller dims the ring (UI-001 R6); a stale device
/// never counts as charging (``DeviceRowModel/showsChargingBolt(at:)``).
public enum RingStyle: Equatable, Sendable {
    case charging, low, normal

    public static func of(_ row: DeviceRowModel, now: Date) -> RingStyle {
        of(isCharging: row.showsChargingBolt(at: now), isLow: row.isLow)
    }

    /// `isCharging` must already be false for a stale reading.
    public static func of(isCharging: Bool, isLow: Bool) -> RingStyle {
        if isCharging { return .charging }
        return isLow ? .low : .normal
    }

    public func fill(_ mode: WidgetRenderingMode = .fullColor) -> Color {
        guard mode == .fullColor else { return .primary }
        switch self {
        case .charging: return .green
        case .low: return .red
        case .normal: return .primary
        }
    }

    /// The track behind the fill. Stronger when the system removed the widget background
    /// (StandBy, clear glass) or drew the widget in one colour, where `.quaternary` vanishes.
    public static func track(_ mode: WidgetRenderingMode = .fullColor, showsBackground: Bool = true) -> AnyShapeStyle {
        mode == .fullColor && showsBackground ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tertiary)
    }
}

/// The state a widget ring shows as a badge on its edge. A shape, not only a colour: in tinted
/// and clear (Liquid Glass) styles, StandBy and on the Lock Screen every colour turns white, so
/// "low" must still read as low (ADR-0016 rule 3, Liquid Glass review 2026-11-24). The app rows
/// say "Low" in words next to the ring instead, and in their accessibility label.
public enum RingBadge: Equatable, Sendable {
    case charging
    case low

    public static func of(_ row: DeviceRowModel, now: Date) -> RingBadge? {
        if row.showsChargingBolt(at: now) { return .charging }
        return row.hasBattery && row.isLow ? .low : nil
    }

    public var symbolName: String {
        switch self {
        case .charging: "bolt.circle.fill"
        case .low: "exclamationmark.circle.fill"
        }
    }
}
