// Push (ADR-0023, PUSH-001): the tokens this iPhone sends to the Mac. Compiled only with
// LEVELS_PUSH_ENABLED = YES (Config/Levels.xcconfig).
#if LEVELS_PUSH
import Foundation
import LevelsNet
import WidgetKit

enum PushTokenSource {
    /// The widget's token from the App Group (the widget's push handler writes it, and clears
    /// it when no widget is configured). Before the handler has run once, WidgetKit's own
    /// `currentPushInfo` is used.
    static func current(appGroupID: String?) async -> [PushToken] {
        let store = WidgetPushTokenStore(suiteName: appGroupID)
        if let token = store.load() { return [token] }
        guard let info = await WidgetCenter.shared.currentPushInfo else { return [] }
        return [PushToken(data: info.token, env: APNsEnvironment.current(), kind: .widget)]
    }
}
#endif
