// Widgets-Mac entry point (ADR-0003, UI-004 R11–R14). Widget extensions link only
// LevelsModel, LevelsUI and LevelsWidgetKit: never LevelsSync or LevelsReaders (ADR-0003 §3,
// SYNC-001 R14). The widget reads the App Group snapshot cache and never fetches; it reads this
// Mac's own battery live (MacOwnBattery).
import LevelsWidgetKit
import SwiftUI
import WidgetKit

@main
struct LevelsMacWidgets: WidgetBundle {
    var body: some Widget {
        LevelsDevicesWidget(readOwn: MacOwnBattery.read)  // live reading of this Mac
    }
}
