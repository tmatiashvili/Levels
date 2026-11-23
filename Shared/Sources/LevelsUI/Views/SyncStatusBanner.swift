import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The banner above the list (R11): iCloud off, couldn't update, or reporting off (UI-002 R12).
/// Shows nothing for other states.
public struct SyncStatusBanner: View {
    let state: DeviceListStore.State
    let isReportingOff: Bool
    let onDismiss: () -> Void
    let onResumeReporting: () -> Void

    public init(state: DeviceListStore.State, isReportingOff: Bool = false,
                onDismiss: @escaping () -> Void = {}, onResumeReporting: @escaping () -> Void = {}) {
        self.state = state
        self.isReportingOff = isReportingOff
        self.onDismiss = onDismiss
        self.onResumeReporting = onResumeReporting
    }

    /// True when the banner has something to show.
    nonisolated public static func isVisible(state: DeviceListStore.State, isReportingOff: Bool) -> Bool {
        if isReportingOff { return true }
        switch state {
        case .noICloud, .syncError: return true
        default: return false
        }
    }

    public var body: some View {
        if isReportingOff {
            banner(symbol: "pause.circle", text: Text("Reporting is off.", bundle: .module)) {
                Button { onResumeReporting() } label: { Text("Turn on reporting", bundle: .module) }
            }
        } else {
            switch state {
            case .noICloud:
                banner(symbol: "icloud.slash",
                       text: Text("iCloud is off. Turn on iCloud to see your other devices.", bundle: .module)) {
                    SettingsButton()
                }
            case .syncError:
                banner(symbol: "exclamationmark.icloud",
                       text: Text("Couldn't update. Showing the last known levels.", bundle: .module)) {
                    Button { onDismiss() } label: {
                        Label { Text("Dismiss", bundle: .module) } icon: { Image(systemName: "xmark") }
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                }
            default:
                EmptyView()
            }
        }
    }

    private func banner(symbol: String, text: Text, @ViewBuilder action: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.orange).accessibilityHidden(true)
            text.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            action()
        }
        .padding(.vertical, 4)
    }
}

/// Opens the place where iCloud is turned on: iOS/iPadOS Settings, macOS System Settings ▸
/// Apple Account; nothing on watchOS (text only).
struct SettingsButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        #if os(iOS)
        Button { openURL(URL(string: UIApplication.openSettingsURLString)!) } label: { Text("Open", bundle: .module) }
        #elseif os(macOS)
        Link(destination: URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")!) {
            Text("Open", bundle: .module)
        }
        #else
        EmptyView()
        #endif
    }
}
