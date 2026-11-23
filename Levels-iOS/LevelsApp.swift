// Levels-iOS entry point (ADR-0003: targets stay thin; logic lives in Shared/).
// Placeholder until UI-002 / RPT-001 / SYNC-001 wire the real scenes.
import SwiftUI
import LevelsModel
import LevelsSync
import LevelsReaders
import LevelsUI
import LevelsWidgetKit

@main
struct LevelsApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Levels")
        }
    }
}
