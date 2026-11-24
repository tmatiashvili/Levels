// LIVE-001 Design: the ActivityKit type of the "Live levels" Live Activity. One definition for
// the app (which starts, updates and ends it) and the widget extension (which draws it), so
// both sides agree on the type. iOS only: ActivityKit doesn't exist on the Mac, which builds
// the same `LiveLevelsState` from LevelsModel for its pushes.
#if os(iOS)
import ActivityKit
import Foundation
import LevelsModel

public struct LevelsLiveActivityAttributes: ActivityAttributes, Sendable {
    /// Pushed by the Mac (PUSH-001 R10) and set by the app; small (LIVE-001 R11).
    public typealias ContentState = LiveLevelsState

    /// Names as the iPhone shows them, set at start. Never pushed (ADR-0023 Decision 6).
    public var names: LiveLevelsNames
    /// When the app started the activity, Unix seconds (8-hour end, LIVE-001 R7).
    public var startedAt: Int64

    public init(names: LiveLevelsNames, startedAt: Date) {
        self.names = names
        self.startedAt = Int64(startedAt.timeIntervalSince1970.rounded(.down))
    }

    public var startedDate: Date { Date(timeIntervalSince1970: TimeInterval(startedAt)) }
}
#endif
