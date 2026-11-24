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
    let onPairAgain: () -> Void
    @State private var showsAwayDetail = false

    /// - Parameter onPairAgain: "Pair again" on the hub banner `.forgotThisPhone` (NET-004 R4).
    public init(state: DeviceListStore.State, isReportingOff: Bool = false,
                onDismiss: @escaping () -> Void = {}, onResumeReporting: @escaping () -> Void = {},
                onPairAgain: @escaping () -> Void = {}) {
        self.state = state
        self.isReportingOff = isReportingOff
        self.onDismiss = onDismiss
        self.onResumeReporting = onResumeReporting
        self.onPairAgain = onPairAgain
    }

    /// True when the banner has something to show.
    nonisolated public static func isVisible(state: DeviceListStore.State, isReportingOff: Bool) -> Bool {
        if isReportingOff { return true }
        switch state {
        case .noICloud, .syncError, .hub: return true
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
            case .hub(let hub):
                hubBanner(hub)
            default:
                EmptyView()
            }
        }
    }

    /// NET-004 R4.
    @ViewBuilder private func hubBanner(_ hub: DeviceListStore.HubBanner) -> some View {
        switch hub {
        case .away(let at):
            Button { showsAwayDetail.toggle() } label: {
                VStack(alignment: .leading, spacing: 4) {
                    banner(symbol: "wifi.slash", text: Self.awayText(at)) { EmptyView() }
                    if showsAwayDetail {
                        Text("Levels updates when this iPhone and your Mac are on the same Wi-Fi and the Mac is awake. A VPN can block it.",
                             bundle: .module)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Shows why", bundle: .module))
        case .localNetworkOff:
            banner(symbol: "network.slash",
                   text: Text("Levels can't reach your Mac: Local Network access is off.", bundle: .module)) {
                SettingsButton(appSettings: true)
            }
        case .forgotThisPhone:
            banner(symbol: "exclamationmark.triangle",
                   text: Text("Your Mac no longer knows this iPhone.", bundle: .module)) {
                Button { onPairAgain() } label: { Text("Pair again", bundle: .module) }
            }
        case .updateNeeded:
            banner(symbol: "arrow.triangle.2.circlepath",
                   text: Text("Update Levels on your Mac and iPhone.", bundle: .module)) { EmptyView() }
        }
    }

    /// "Away from your Mac. Last update <age>." with a self-updating age (ADR-0017).
    static func awayText(_ at: Date?) -> Text {
        guard let at else { return Text("Away from your Mac.", bundle: .module) }
        let age = Text(at, style: .relative)
        return Text("Away from your Mac. Last update \(age) ago.", bundle: .module)
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
    /// iOS: true opens this app's own page (Local Network switch); same URL either way today.
    var appSettings = false

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
