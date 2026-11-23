// Levels-Mac entry point (MAC-001, ADR-0014 rule 1): a MenuBarExtra in .window style, a
// suppressed "devices" Window opened by levels:// URLs (decision 12), and Settings.
// Logic lives in Shared/ (ADR-0003); this target wires it (MacAppModel).
import AppKit
import LevelsModel
import LevelsUI
import SwiftUI

@main
struct LevelsMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("showMenuBarItem") var showMenuBarItem = true  // MAC-001 R4(c)
    @AppStorage(MenuBarMode.key, store: UserDefaults(suiteName: LevelsAppConfig.appGroupID ?? ""))
    var menuBarMode: MenuBarMode = .lowest  // UI-004 R4

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarItem) {
            MenuBarPopover()
                .environment(appDelegate.model)
        } label: {
            MenuBarLabel(store: appDelegate.model.store, mode: menuBarMode)
        }
        .menuBarExtraStyle(.window)

        Window("Levels", id: "devices") {  // R2a: opened by levels:// URLs and reopen, never at launch
            DeviceWindowView()
                .environment(appDelegate.model)
        }
        .handlesExternalEvents(matching: ["levels"])
        .defaultLaunchBehavior(.suppressed)
        // Sized to its content like the popover (UI-004 R6): the first open uses the view's
        // ideal size; after that SwiftUI restores the size the user left it at. Resizable,
        // never smaller than the content's minimum.
        .windowResizability(.contentMinSize)
        .defaultWindowPlacement { content, _ in
            WindowPlacement(size: content.sizeThatFits(.unspecified))
        }

        Settings {
            MacSettingsView()
                .environment(appDelegate.model)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MacAppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MacAppModel.logger.notice("Launched \(Bundle.main.bundlePath, privacy: .public)")
        Task { await model.start() }
    }

    /// R5: launched again while running. Only sets the flag; SwiftUI opens Settings from the
    /// device window, which `levels://settings` brings up (the R5 fallback).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.settingsRequested = true
        NSWorkspace.shared.open(LevelsAppConfig.settingsURL)
        return true
    }

    /// R2a assumption fallback: closing the device window never quits the agent.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
