// Previews and the render harness's content: every family in every widget rendering mode
// (Liquid Glass review 2026-11-24). Xcode previews and `ImageRenderer` don't draw the widget
// host, so the gallery sets `widgetRenderingMode` itself; the snapshot test in
// LevelsWidgetKitTests also imitates what the host then does to the pixels.
// Debug only (release readiness 2026-11-24): sample data and the gallery are for previews and
// the snapshot test (`swift test` builds Debug); they are not compiled into Release widgets.
#if DEBUG
import Foundation
import LevelsModel
import LevelsUI
import SwiftUI
import WidgetKit

/// Sample entries for previews and snapshots: every state a ring can show.
enum WidgetSamples {
    /// Now, so live "x min ago" texts read like on a device.
    static let now = Date()

    private static func id(_ n: Int) -> DeviceID {
        DeviceID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!)
    }

    /// Mac charging, iPhone low, Watch stale, AirPods with no battery data.
    static var devices: DeviceEntry {
        let mac = id(1)
        let airpods = AccessoryInfo(parentDeviceID: mac, kind: .airpods, groupID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
                                    component: .main)
        let devices = [
            DeviceBattery(id: mac, name: "Tornike’s MacBook Pro", kind: .mac, level: 76, isCharging: true, isPluggedIn: true,
                          updatedAt: now - 120),
            DeviceBattery(id: id(2), name: "Tornike’s iPhone", kind: .iphone, level: 14, isCharging: false, updatedAt: now - 540),
            DeviceBattery(id: id(3), name: "Apple Watch", kind: .watch, level: 63, isCharging: false, updatedAt: now - 3 * 3600),
            DeviceBattery(id: id(4), name: "AirPods Pro", kind: .accessory, accessory: airpods, level: 92, isCharging: false,
                          updatedAt: now - 600),
        ]
        return DeviceEntry(date: now, snapshot: SnapshotFile(ownDeviceID: mac, devices: devices), preferences: DisplayPreferences())
    }

    /// The small widget showing the low device ("Lowest battery").
    static var lowSingle: DeviceEntry { devices }

    /// The small widget showing the charging Mac.
    static var chargingSingle: DeviceEntry {
        let e = devices
        return DeviceEntry(date: now, snapshot: e.snapshot, preferences: DisplayPreferences(), selection: id(1))
    }

    static var empty: DeviceEntry { DeviceEntry(date: now, snapshot: nil, preferences: DisplayPreferences()) }
}

/// The families the harness draws, with their point sizes (iPhone 6.1", Lock Screen).
enum GalleryFamily: String, CaseIterable, Identifiable {
    case smallLow = "small-low"
    case smallCharging = "small-charging"
    case medium
    case large
    case circular
    case rectangular
    case inline

    var id: String { rawValue }

    var size: CGSize {
        switch self {
        case .smallLow, .smallCharging: CGSize(width: 170, height: 170)
        case .medium: CGSize(width: 364, height: 170)
        case .large: CGSize(width: 364, height: 382)
        case .circular: CGSize(width: 72, height: 72)
        case .rectangular: CGSize(width: 172, height: 76)
        case .inline: CGSize(width: 240, height: 24)
        }
    }

    var isAccessory: Bool { [.circular, .rectangular, .inline].contains(self) }

    /// The system's content margins around Home Screen widgets.
    var padding: CGFloat { isAccessory ? 0 : 16 }

    @ViewBuilder func view(entry: DeviceEntry? = nil) -> some View {
        switch self {
        case .smallLow: SmallDeviceView(entry: entry ?? WidgetSamples.lowSingle)
        case .smallCharging: SmallDeviceView(entry: entry ?? WidgetSamples.chargingSingle)
        case .medium: MediumDevicesView(entry: entry ?? WidgetSamples.devices)
        case .large: LargeDevicesView(entry: entry ?? WidgetSamples.devices)
        case .circular: AccessoryCircularView(entry: entry ?? WidgetSamples.lowSingle)
        case .rectangular: AccessoryRectangularView(entry: entry ?? WidgetSamples.devices)
        case .inline: AccessoryInlineView(entry: entry ?? WidgetSamples.chargingSingle)
        }
    }
}

/// One family in one rendering mode, at its widget size, without the host's background.
struct GalleryCell: View {
    let family: GalleryFamily
    let mode: WidgetRenderingMode

    var body: some View {
        family.view()
            .padding(family.padding)
            .frame(width: family.size.width, height: family.size.height)
            .environment(\.widgetRenderingMode, mode)
            .environment(\.isWidgetRenderHarness, true)
    }
}

/// Every family in one rendering mode, on a background like the host's.
struct WidgetModeGallery: View {
    let mode: WidgetRenderingMode
    var families: [GalleryFamily] = GalleryFamily.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: mode.description).font(.headline)
            ForEach(families) { family in
                GalleryCell(family: family, mode: mode)
                    .background(
                        RoundedRectangle(cornerRadius: family.isAccessory ? 12 : 22, style: .continuous)
                            .fill(mode == .fullColor ? AnyShapeStyle(.background.secondary) : AnyShapeStyle(.ultraThinMaterial))
                    )
            }
        }
        .padding()
    }
}

#Preview("Full colour") { ScrollView { WidgetModeGallery(mode: .fullColor) } }
#Preview("Accented (tinted, clear)") { ScrollView { WidgetModeGallery(mode: .accented) }.preferredColorScheme(.dark) }
#Preview("Vibrant (Lock Screen, StandBy)") { ScrollView { WidgetModeGallery(mode: .vibrant) }.preferredColorScheme(.dark) }
#endif
