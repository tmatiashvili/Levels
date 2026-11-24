// Push-driven widget updates (ADR-0023, PUSH-001). WidgetKit gives the extension a push token
// through `WidgetPushHandler` (iOS 26); it goes into the App Group, where the app picks it up
// and sends it to the paired Mac (`PUT /v1/push-tokens`). The Mac asks the relay to push
// `{"aps":{"content-changed":true}}` when what this widget shows changed; WidgetKit then
// reloads the timeline and `WidgetHubFetch` reads the Mac.
//
// Only with LEVELS_PUSH_ENABLED = YES (Config/Levels.xcconfig): a free Personal Team can't
// sign aps-environment, so the default build has no handler at all.
import Foundation
import LevelsModel
import LevelsNet
import LevelsWidgetKit
import WidgetKit

enum WidgetPushState {
    static var store: WidgetPushTokenStore { WidgetPushTokenStore(suiteName: LevelsAppConfig.appGroupID) }

    /// How long the cache counts as fresh at a timeline load: seconds while push is on (a
    /// reload is then usually a push), else the normal 15 minutes.
    @Sendable static func freshFor() -> TimeInterval {
        #if LEVELS_PUSH
        store.load() != nil ? HubWidgetPlan.freshForWithPush : HubWidgetPlan.freshFor
        #else
        HubWidgetPlan.freshFor
        #endif
    }
}

#if LEVELS_PUSH
struct LevelsWidgetPushHandler: WidgetPushHandler {
    init() {}

    /// Called for the first token, every token change, and when the set of configured widgets
    /// changes. No widgets left: the token is cleared, so the Mac stops pushing.
    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        let store = WidgetPushState.store
        guard !widgets.isEmpty else {
            store.clear()
            WidgetHubFetch.logger.notice("Widget push: no widgets configured; token cleared")
            return
        }
        let token = PushToken(data: pushInfo.token, env: APNsEnvironment.current(), kind: .widget)
        if store.save(token) {
            WidgetHubFetch.logger.notice("Widget push: new token (\(token.env.rawValue, privacy: .public)) for \(widgets.count, privacy: .public) widget(s)")
        }
    }
}
#endif
