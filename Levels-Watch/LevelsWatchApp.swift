// Levels-Watch entry point (ADR-0003: targets stay thin; logic lives in Shared/).
// Placeholder until UI-006 / RPT-004 / SYNC-001 wire the real scenes.
import SwiftUI
import LevelsModel
import LevelsSync
import LevelsReaders
import LevelsUI
import LevelsWidgetKit

@main
struct LevelsWatchApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Levels")
        }
    }
}
