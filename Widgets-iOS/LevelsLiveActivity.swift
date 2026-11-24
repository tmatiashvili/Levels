// LIVE-001 R12–R16: the "Live levels" Live Activity: this iPhone, the paired Mac and AirPods on
// the Lock Screen, in StandBy and in the Dynamic Island. Started, updated and ended by the app
// (Levels-iOS/LiveActivity); after enrollment the Mac also pushes new content (PUSH-001). A
// Live Activity can't use the network, so this only draws what it is given. The views live in
// LevelsWidgetKit (LiveLevelsViews.swift).
import ActivityKit
import LevelsModel
import LevelsWidgetKit
import SwiftUI
import WidgetKit

struct LevelsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LevelsLiveActivityAttributes.self) { context in
            LiveLevelsLockScreenView(state: context.state, names: context.attributes.names, isStale: context.isStale)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(LevelsAppConfig.listURL)
        } dynamicIsland: { context in
            let state = context.state
            let names = context.attributes.names
            let stale = context.isStale
            let compact = LiveLevelsDisplay.compact(state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if let d = state.device(.iphone) { LiveLevelColumn(device: d, names: names, isStale: stale) }
                }
                DynamicIslandExpandedRegion(.center) {
                    if let d = state.device(.mac) { LiveLevelColumn(device: d, names: names, isStale: stale) }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let d = state.device(.airpods) { LiveLevelColumn(device: d, names: names, isStale: stale) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LiveLevelsFooter(state: state, isStale: stale)
                }
            } compactLeading: {
                LiveLevelsCompactView(device: compact.leading, isStale: stale)
            } compactTrailing: {
                LiveLevelsCompactView(device: compact.trailing, isStale: stale)
            } minimal: {
                LiveLevelsMinimalView(state: state, isStale: stale)
            }
            .widgetURL(LevelsAppConfig.listURL)
        }
        .supplementalActivityFamilies([.small, .medium])  // Apple Watch Smart Stack, CarPlay
    }
}

// MARK: - Previews

private let previewNames = LiveLevelsNames(iphone: "iPhone", mac: "MacBook Air", airpods: "AirPods Pro")
private let previewState = LiveLevelsState(devices: [
    .init(role: .iphone, level: 64, charging: false, updatedAt: Int64(Date.now.timeIntervalSince1970)),
    .init(role: .mac, level: 82, charging: true, updatedAt: Int64(Date.now.timeIntervalSince1970)),
    .init(role: .airpods, level: 15, charging: false, updatedAt: Int64(Date.now.timeIntervalSince1970)),
])
private let previewAttributes = LevelsLiveActivityAttributes(names: previewNames, startedAt: .now)

#Preview("Lock Screen", as: .content, using: previewAttributes) { LevelsLiveActivity() } contentStates: { previewState }
#Preview("Compact", as: .dynamicIsland(.compact), using: previewAttributes) { LevelsLiveActivity() } contentStates: { previewState }
#Preview("Minimal", as: .dynamicIsland(.minimal), using: previewAttributes) { LevelsLiveActivity() } contentStates: { previewState }
#Preview("Expanded", as: .dynamicIsland(.expanded), using: previewAttributes) { LevelsLiveActivity() } contentStates: { previewState }
