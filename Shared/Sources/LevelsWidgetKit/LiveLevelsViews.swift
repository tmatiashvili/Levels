// LIVE-001 R12–R16: the "Live levels" Live Activity views. Plain SwiftUI with no ActivityKit,
// so the render gallery and tests can draw them; Widgets-iOS puts them in an
// `ActivityConfiguration` (Lock Screen, StandBy, Dynamic Island compact, minimal, expanded).
// Colours follow RingStyle (ADR-0016 rule 3): green charging, red low, primary otherwise.
import Foundation
import LevelsModel
import LevelsUI
import SwiftUI

/// The names the activity shows, set by the app at start (static attributes, never pushed).
public struct LiveLevelsNames: Codable, Hashable, Sendable {
    public var iphone: String?
    public var mac: String?
    public var airpods: String?

    public init(iphone: String? = nil, mac: String? = nil, airpods: String? = nil) {
        self.iphone = iphone
        self.mac = mac
        self.airpods = airpods
    }

    public func name(_ role: LiveLevelsState.Role) -> String {
        let raw: String? = switch role {
        case .iphone: iphone
        case .mac: mac
        case .airpods: airpods
        }
        if let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty { return WidgetText.compactName(raw) }
        return LiveLevelsDisplay.kindName(role)
    }
}

/// Display rules. Pure, unit-tested.
public enum LiveLevelsDisplay {
    public static func symbolName(_ role: LiveLevelsState.Role) -> String {
        switch role {
        case .iphone: DeviceSymbol.symbolName(kind: .iphone, accessoryKind: nil, hasBattery: true)
        case .mac: DeviceSymbol.symbolName(kind: .mac, accessoryKind: nil, hasBattery: true)
        case .airpods: DeviceSymbol.symbolName(kind: .accessory, accessoryKind: .airpods, hasBattery: true)
        }
    }

    public static func kindName(_ role: LiveLevelsState.Role) -> String {
        switch role {
        case .iphone: "iPhone"
        case .mac: "Mac"
        case .airpods: "AirPods"
        }
    }

    public static func isLow(_ d: LiveLevelsState.Device, threshold: Int = AlertSettings.defaultThreshold) -> Bool {
        (d.level ?? 100) <= threshold
    }

    public static func style(_ d: LiveLevelsState.Device, isStale: Bool) -> RingStyle {
        RingStyle.of(isCharging: d.charging && !isStale, isLow: isLow(d))
    }

    public static func percent(_ d: LiveLevelsState.Device) -> String { d.level.map(WidgetText.percent) ?? "–" }

    /// Dynamic Island compact: two devices, the Mac and the AirPods first (the iPhone shows
    /// its own battery in the status bar).
    public static func compact(_ s: LiveLevelsState) -> (leading: LiveLevelsState.Device?, trailing: LiveLevelsState.Device?) {
        let order: [LiveLevelsState.Role] = [.mac, .airpods, .iphone]
        let shown = order.compactMap(s.device)
        return (shown.first, shown.dropFirst().first)
    }

    /// Dynamic Island minimal: the one device that matters most: the lowest that isn't
    /// charging, else the lowest.
    public static func minimal(_ s: LiveLevelsState) -> LiveLevelsState.Device? {
        let byLevel = s.devices.sorted { ($0.level ?? 101) < ($1.level ?? 101) }
        return byLevel.first { !$0.charging } ?? byLevel.first
    }

    /// VoiceOver: "Mac 80 percent, charging".
    public static func accessibilityLabel(_ d: LiveLevelsState.Device, names: LiveLevelsNames) -> String {
        let name = names.name(d.role)
        let level = d.level.map { String(localized: "\($0) percent") } ?? String(localized: "level unknown")
        return d.charging ? "\(name) \(level), \(String(localized: "charging"))" : "\(name) \(level)"
    }
}

/// A ring with the device symbol inside and a bolt while charging.
public struct LiveLevelRing: View {
    let device: LiveLevelsState.Device
    let isStale: Bool
    let size: CGFloat

    public init(device: LiveLevelsState.Device, isStale: Bool, size: CGFloat = 36) {
        self.device = device
        self.isStale = isStale
        self.size = size
    }

    public var body: some View {
        let stroke = max(2.5, size * 0.1)
        let fraction = CGFloat(device.level ?? 0) / 100
        ZStack {
            Circle().stroke(.quaternary, lineWidth: stroke)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(LiveLevelsDisplay.style(device, isStale: isStale).fill(),
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: LiveLevelsDisplay.symbolName(device.role))
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.45, height: size * 0.45)
        }
        .padding(stroke / 2)
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if device.charging, !isStale {
                Image(systemName: "bolt.circle.fill")
                    .resizable()
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.black, .green)
                    .frame(width: size * 0.38, height: size * 0.38)
                    .offset(x: size * 0.08, y: -size * 0.08)
            }
        }
        .opacity(isStale ? 0.5 : 1)
        .accessibilityHidden(true)
    }
}

/// One device: ring, percentage, name.
public struct LiveLevelColumn: View {
    let device: LiveLevelsState.Device
    let names: LiveLevelsNames
    let isStale: Bool

    public init(device: LiveLevelsState.Device, names: LiveLevelsNames, isStale: Bool) {
        self.device = device
        self.names = names
        self.isStale = isStale
    }

    public var body: some View {
        VStack(spacing: 4) {
            LiveLevelRing(device: device, isStale: isStale)
            Text(verbatim: LiveLevelsDisplay.percent(device))
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(isStale ? .secondary : .primary)
            Text(verbatim: names.name(device.role))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LiveLevelsDisplay.accessibilityLabel(device, names: names))
    }
}

/// The footer line: "Updated 14:05", or "Not updated since 14:05" once stale.
public struct LiveLevelsFooter: View {
    let state: LiveLevelsState
    let isStale: Bool

    public init(state: LiveLevelsState, isStale: Bool) {
        self.state = state
        self.isStale = isStale
    }

    public var body: some View {
        if let date = state.newestUpdate {
            Group {
                if isStale {
                    Text("Not updated since \(date, style: .time)")
                } else {
                    Text("Updated \(date, style: .time)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

/// Lock Screen and StandBy (R12): every device in a row, then the footer.
public struct LiveLevelsLockScreenView: View {
    let state: LiveLevelsState
    let names: LiveLevelsNames
    let isStale: Bool

    public init(state: LiveLevelsState, names: LiveLevelsNames, isStale: Bool) {
        self.state = state
        self.names = names
        self.isStale = isStale
    }

    public var body: some View {
        VStack(spacing: 8) {
            if state.devices.isEmpty {
                Text("No devices yet. Open Levels on the same Wi-Fi as your Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(state.devices, id: \.role) { LiveLevelColumn(device: $0, names: names, isStale: isStale) }
                }
            }
            LiveLevelsFooter(state: state, isStale: isStale)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Dynamic Island compact side (R13): symbol and percentage.
public struct LiveLevelsCompactView: View {
    let device: LiveLevelsState.Device?
    let isStale: Bool

    public init(device: LiveLevelsState.Device?, isStale: Bool) {
        self.device = device
        self.isStale = isStale
    }

    public var body: some View {
        if let device {
            HStack(spacing: 3) {
                Image(systemName: LiveLevelsDisplay.symbolName(device.role))
                Text(verbatim: LiveLevelsDisplay.percent(device))
                    .monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(LiveLevelsDisplay.style(device, isStale: false).fill()))
        } else {
            Image(systemName: "battery.100percent")
        }
    }
}

/// Dynamic Island minimal (R14): one small ring.
public struct LiveLevelsMinimalView: View {
    let state: LiveLevelsState
    let isStale: Bool

    public init(state: LiveLevelsState, isStale: Bool) {
        self.state = state
        self.isStale = isStale
    }

    public var body: some View {
        if let device = LiveLevelsDisplay.minimal(state) {
            LiveLevelRing(device: device, isStale: isStale, size: 22)
        } else {
            Image(systemName: "battery.100percent")
        }
    }
}
