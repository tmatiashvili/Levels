// UI-004 R1–R10: the menu-bar label, the popover content and the device window (MAC-001 R2a).
import AppKit
import LevelsModel
import LevelsUI
import SwiftUI

/// The menu-bar label (UI-004 R1–R5): a template symbol plus text, monochrome.
struct MenuBarLabel: View {
    let store: DeviceListStore
    let mode: MenuBarMode

    // No TimelineView here: inside a MenuBarExtra label it re-renders the status item in a
    // loop. The label updates whenever the store changes (at least every 30-min heartbeat).
    var body: some View {
        let content = MenuBarLabelModel.content(rows: store.rows, mode: mode, now: .now)
        HStack(spacing: 3) {
            Image(systemName: content.symbol)
            if let text = content.text { Text(text).monospacedDigit() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel)
    }
}

/// The popover (UI-004 R6): banner + list (this Mac first) + footer. Width 320, height up to 480.
struct MenuBarPopover: View {
    @Environment(MacAppModel.self) private var model

    var body: some View {
        DevicesPanel(highlighted: nil)
            .frame(width: 320)
            .frame(height: Self.height(rows: model.store.rows.count))
            .onAppear { model.popoverOpened() }  // UI-004 R7
    }

    /// Fits the rows up to 480 pt, then the list scrolls.
    static func height(rows: Int) -> CGFloat { min(480, CGFloat(max(rows, 1)) * 58 + 64) }
}

/// The device window (MAC-001 R2a): the popover content at window size, opened by
/// `levels://` URLs; it also opens Settings when asked (R5).
struct DeviceWindowView: View {
    @Environment(MacAppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        DevicesPanel(highlighted: model.highlighted)
            .frame(minWidth: 320, idealWidth: 380, minHeight: 240, idealHeight: 420)
            .onOpenURL { url in
                _ = model.handle(url)
                NSApp.activate()
                openSettingsIfRequested()
            }
            .onAppear {
                NSApp.activate()
                openSettingsIfRequested()
            }
            .onChange(of: model.settingsRequested) { openSettingsIfRequested() }
    }

    /// R5: Settings opens only from SwiftUI, once per request.
    private func openSettingsIfRequested() {
        guard model.settingsRequested else { return }
        model.settingsRequested = false
        openSettings()
        NSApp.activate()
    }
}

/// List and footer shared by the popover and the device window.
struct DevicesPanel: View {
    @Environment(MacAppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let highlighted: DeviceID?

    var body: some View {
        VStack(spacing: 0) {
            DeviceList(store: model.store, showsOldDevices: false, highlighted: highlighted)  // old devices: Settings (R9)
                .scrollContentBackground(.hidden)
            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            TimelineView(.everyMinute) { context in
                if let newest = model.store.rows.map({ $0.readingDate(now: context.date) }).max() {
                    Text("Updated \(AgeFormatting.text(readingDate: newest, now: context.date))")
                } else {
                    Text("Not updated yet")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Button { model.userRefresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r", modifiers: .command)  // UI-004 R6, R7
            .disabled(model.store.isRefreshing)
            .help("Refresh")
            .accessibilityLabel("Refresh")
            Menu {
                Button("Settings…") { showSettings() }.keyboardShortcut(",", modifiers: .command)
                Button("Hidden devices…") { showSettings() }
                Button("About Levels") {
                    NSApp.activate()
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Divider()
                Button("Quit Levels") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)  // MAC-001 R3, R12
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func showSettings() {
        openSettings()
        NSApp.activate()
    }
}
