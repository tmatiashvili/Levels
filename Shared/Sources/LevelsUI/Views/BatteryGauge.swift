import LevelsModel
import SwiftUI
import WidgetKit  // widgetAccentable(), widgetRenderingMode

/// Capacity ring for the app (ADR-0016 rule 3), coloured by ``RingStyle`` like the widget
/// rings: green when charging, red when low, else primary, on a faint track.
///
/// Drawn by hand rather than with `Gauge(.accessoryCircularCapacity)`: in the apps that style
/// came out plain grey and white, ignoring `.tint`. No value label inside: the caller shows the
/// percentage (and "Low") next to it, and dims the ring when stale (UI-001 R6).
public struct BatteryRing: View {
    let level: Int
    let isCharging: Bool
    let isLow: Bool
    let size: CGFloat
    @Environment(\.widgetRenderingMode) private var renderingMode

    /// `isCharging` must already be false for a stale reading (`showsChargingBolt(at:)`).
    public init(level: Int, isCharging: Bool, isLow: Bool, size: CGFloat = 58) {
        self.level = DeviceBattery.clampedLevel(level)
        self.isCharging = isCharging
        self.isLow = isLow
        self.size = size
    }

    /// Stroke width for a ring of `size`: about the widget rings' proportion, never a hairline.
    static func stroke(for size: CGFloat) -> CGFloat { max(2.5, size * 0.11) }

    public var body: some View {
        let stroke = Self.stroke(for: size)
        ZStack {
            Circle().stroke(RingStyle.track(renderingMode), lineWidth: stroke)
            Circle()
                .trim(from: 0, to: CGFloat(level) / 100)
                .stroke(RingStyle.of(isCharging: isCharging, isLow: isLow).fill(renderingMode),
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
        }
        .padding(stroke / 2)
        .frame(width: size, height: size)
        .accessibilityHidden(true)  // the row carries the label (R9)
    }
}

/// Bar gauge: `.linearCapacity` in apps, `.accessoryLinearCapacity` in accessory widget families.
public struct BatteryBar: View {
    public enum Style: Sendable { case app, accessory }

    let level: Int
    let isCharging: Bool
    let isLow: Bool
    let style: Style

    public init(level: Int, isCharging: Bool, isLow: Bool, style: Style = .app) {
        self.level = DeviceBattery.clampedLevel(level)
        self.isCharging = isCharging
        self.isLow = isLow
        self.style = style
    }

    public var body: some View {
        let gauge = Gauge(value: Double(level), in: 0...100) { EmptyView() }
            .tint(RingStyle.of(isCharging: isCharging, isLow: isLow).fill())
        Group {
            switch style {
            case .app: gauge.gaugeStyle(.linearCapacity)
            case .accessory: gauge.gaugeStyle(.accessoryLinearCapacity)
            }
        }
        .widgetAccentable()
        .accessibilityHidden(true)
    }
}
