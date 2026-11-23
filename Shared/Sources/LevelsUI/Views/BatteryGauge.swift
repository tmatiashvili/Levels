import LevelsModel
import SwiftUI
import WidgetKit  // widgetAccentable()

/// Gauge tint (ADR-0016 rule 3): green when charging, red when low, else primary.
func batteryTint(isCharging: Bool, isLow: Bool) -> Color {
    if isCharging { return .green }
    if isLow { return .red }
    return .primary
}

/// Ring gauge: `Gauge` with `.accessoryCircularCapacity` (ADR-0016 rule 3).
public struct BatteryRing: View {
    let level: Int
    let isCharging: Bool
    let isLow: Bool

    public init(level: Int, isCharging: Bool, isLow: Bool) {
        self.level = DeviceBattery.clampedLevel(level)
        self.isCharging = isCharging
        self.isLow = isLow
    }

    public var body: some View {
        Gauge(value: Double(level), in: 0...100) {
            EmptyView()
        } currentValueLabel: {
            Text(level, format: .number)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(batteryTint(isCharging: isCharging, isLow: isLow))
        .widgetAccentable()
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
            .tint(batteryTint(isCharging: isCharging, isLow: isLow))
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
