// Levels-Mac entry point (ADR-0003: targets stay thin; logic lives in Shared/).
// Scene shape per ADR-0014 rule 1 and MAC-001 R2a: a MenuBarExtra in .window
// style, a suppressed "devices" Window opened by levels:// URLs, and Settings.
// Placeholder content until MAC-001 / UI-004 replace it.
import SwiftUI
import LevelsModel
import LevelsSync
import LevelsReaders
import LevelsUI
import LevelsWidgetKit

@main
struct LevelsMacApp: App {
    var body: some Scene {
        MenuBarExtra("Levels", systemImage: "battery.100percent") {
            Text("Levels")
                .padding()
        }
        .menuBarExtraStyle(.window)

        Window("Levels", id: "devices") {
            Text("Levels")
                .padding()
        }
        .handlesExternalEvents(matching: ["levels"])
        .defaultLaunchBehavior(.suppressed)

        Settings {
            Text("Settings")
                .padding()
        }
    }
}
