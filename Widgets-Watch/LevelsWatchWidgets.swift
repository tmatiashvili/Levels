// Widgets-Watch entry point (ADR-0003). Widget extensions link only LevelsModel,
// LevelsUI and LevelsWidgetKit: never LevelsSync or LevelsReaders (ADR-0003 §3,
// SYNC-001 R14). Placeholder widget until the shared LevelsDevicesWidget from
// LevelsWidgetKit replaces it.
import SwiftUI
import WidgetKit
import LevelsModel
import LevelsUI
import LevelsWidgetKit

@main
struct LevelsWatchWidgets: WidgetBundle {
    var body: some Widget {
        PlaceholderWidget()
    }
}

struct PlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LevelsPlaceholder", provider: PlaceholderProvider()) { _ in
            Text("Levels")
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Levels")
        .description("Placeholder.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct PlaceholderEntry: TimelineEntry {
    let date: Date
}

struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry {
        PlaceholderEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (PlaceholderEntry) -> Void) {
        completion(PlaceholderEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [PlaceholderEntry(date: .now)], policy: .never))
    }
}
