// LIVE-001: starts, updates and ends the "Live levels" Live Activity from the app.
//
// Without push (the free build, today) the app is the only thing that updates it: on every
// cache change while the process runs (foreground long-poll, the iPhone's own battery events,
// a Shortcuts "Report Battery" run, a background refresh), from the App Group snapshot with
// this iPhone's live `UIDevice` reading laid over it (R20, R21). With push (LEVELS_PUSH) it
// also asks for a push token and puts it in the App Group, where PushTokenSource sends it to
// the Mac with the widget's token and a relay grant (R31).
import ActivityKit
import Foundation
import LevelsModel
import LevelsNet
import LevelsWidgetKit
import Observation
import UIKit
import os

@MainActor @Observable final class LiveActivityController {
    nonisolated static let logger = Logger(subsystem: LevelsLog.subsystem, category: "live-activity")
    typealias LiveActivity = Activity<LevelsLiveActivityAttributes>

    /// An activity of ours is on screen.
    private(set) var isRunning = false

    @ObservationIgnored private let cache: SnapshotCache
    @ObservationIgnored private let pairing: @Sendable () -> HubPairing?
    @ObservationIgnored private let tokens: WidgetPushTokenStore
    @ObservationIgnored private let onTokenChange: @Sendable () -> Void
    @ObservationIgnored private var activity: LiveActivity?
    @ObservationIgnored private var shown: (state: LiveLevelsState, at: Date)?
    @ObservationIgnored private var watchers: [Task<Void, Never>] = []
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false

    /// - Parameters:
    ///   - onTokenChange: the activity's push token changed or went away (push builds only).
    init(cache: SnapshotCache, appGroupID: String?, pairing: @escaping @Sendable () -> HubPairing?,
         onTokenChange: @escaping @Sendable () -> Void = {}) {
        self.cache = cache
        self.pairing = pairing
        self.tokens = WidgetPushTokenStore(suiteName: appGroupID, key: WidgetPushTokenStore.liveActivityKey)
        self.onTokenChange = onTokenChange
    }

    // MARK: Start and stop (R1–R8)

    /// Why "Start" can't work right now, or `nil`.
    func startBlocker(isDemo: Bool) -> LiveLevelsPolicy.StartBlocker? {
        LiveLevelsPolicy.startBlocker(isAllowed: LiveActivityAccess.isAllowed(),
                                      activitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled,
                                      isPaired: pairing() != nil, isDemo: isDemo)
    }

    /// At launch: adopt the activity iOS still shows (the app was relaunched), end any extra one
    /// (R5: one at a time), then apply the end rules.
    func restore() async {
        let all = LiveActivity.activities.filter { $0.activityState == .active || $0.activityState == .stale }
        if let first = all.first {
            for extra in all.dropFirst() { await Self.end(Box(activity: extra), nil) }
            adopt(first)
            Self.logger.notice("Live Activity restored")
        } else {
            clearToken()
        }
        await refresh()
    }

    /// R1: the user pressed Start. Throws ActivityKit's error (Settings off, too many activities).
    func start(isDemo: Bool, now: Date = .now) async throws {
        if let blocker = startBlocker(isDemo: isDemo) {
            Self.logger.notice("Live Activity not started: \(String(describing: blocker), privacy: .public)")
            return
        }
        for old in LiveActivity.activities { await Self.end(Box(activity: old), nil) }  // R5
        let (state, names) = content(now: now)
        let attributes = LevelsLiveActivityAttributes(names: names, startedAt: now)
        let initial = ActivityContent(state: state, staleDate: now.addingTimeInterval(LiveLevelsPolicy.staleAfter))
        #if LEVELS_PUSH
        let pushType: PushType? = .token  // R31: the Mac pushes new content after enrollment
        #else
        let pushType: PushType? = nil  // free team: no aps-environment, local updates only
        #endif
        let activity = try LiveActivity.request(attributes: attributes, content: initial, pushType: pushType)
        adopt(activity)
        shown = (state, now)
        Self.logger.notice("Live Activity started (\(state.devices.count, privacy: .public) devices)")
    }

    /// R6: the user pressed Stop, or an end rule fired (R7, R8).
    func stop(reason: String = "user") async {
        guard let activity else { return }
        let final = shown.map { ActivityContent(state: $0.state, staleDate: nil) }
        await Self.end(Box(activity: activity), final)
        forget()
        Self.logger.notice("Live Activity ended (\(reason, privacy: .public))")
    }

    // MARK: Updates (R20–R22)

    /// The cache changed, or the app came to the foreground: update the activity if what it
    /// shows changed, and end it when an end rule says so. Coalesced: one refresh at a time.
    func refresh(now: Date = .now) async {
        guard let activity else { return }
        if refreshing { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        var t = now
        repeat {
            if refreshAgain { t = .now }  // a change came in while updating
            refreshAgain = false
            if let reason = LiveLevelsPolicy.endReason(startedAt: activity.attributes.startedDate, now: t,
                                                       isPaired: pairing() != nil) {
                await stop(reason: reason == .expired ? "8 hours" : "unpaired")
                return
            }
            let state = LiveLevels.newest(activity.content.state, content(now: t).0)  // keep newer pushed levels
            guard LiveLevelsPolicy.shouldUpdate(shown: shown?.state, shownAt: shown?.at, new: state, now: t) else { continue }
            await Self.update(Box(activity: activity),
                              ActivityContent(state: state, staleDate: t.addingTimeInterval(LiveLevelsPolicy.staleAfter)))
            shown = (state, t)
            Self.logger.notice("Live Activity updated locally")
        } while refreshAgain
    }

    /// The content-state and names from the App Group snapshot plus this iPhone's live reading.
    private func content(now: Date) -> (LiveLevelsState, LiveLevelsNames) {
        let file = cache.read()?.overlaying(own: Self.ownReading(now: now))
        let devices = file?.devices ?? []
        let macID = pairing()?.hubDeviceID
        let state = LiveLevels.state(from: devices, iphoneID: file?.ownDeviceID, macID: macID)
        let name: (DeviceBattery?) -> String? = { $0?.name }
        let mac = devices.first { $0.id == macID } ?? devices.filter { $0.kind == .mac }.max { $0.updatedAt < $1.updatedAt }
        let pods = devices.filter { $0.accessory?.kind == .airpods }.max { $0.updatedAt < $1.updatedAt }
        let names = LiveLevelsNames(iphone: name(devices.first { $0.id == file?.ownDeviceID }),
                                    mac: name(mac) ?? pairing()?.hubName, airpods: name(pods))
        return (state, names)
    }

    private static func ownReading(now: Date) -> OwnBatteryReading? {
        let device = UIDevice.current
        guard device.isBatteryMonitoringEnabled else { return nil }
        let state: OwnBatteryReading.State = switch device.batteryState {
        case .unplugged: .unplugged
        case .charging: .charging
        case .full: .full
        case .unknown: .unknown
        @unknown default: .unknown
        }
        return OwnBatteryReading(level: OwnBatteryReading.level(fromFraction: Double(device.batteryLevel)), state: state,
                                 isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, readAt: now)
    }

    // MARK: Lifecycle of one activity

    /// `Activity` isn't `Sendable`; its `end` and `update` are nonisolated async. ActivityKit
    /// documents them as safe to call from any context, so the reference crosses to them boxed.
    private struct Box: @unchecked Sendable { let activity: LiveActivity }

    private nonisolated static func end(_ box: Box, _ content: ActivityContent<LiveLevelsState>?) async {
        await box.activity.end(content, dismissalPolicy: .immediate)
    }

    private nonisolated static func update(_ box: Box, _ content: ActivityContent<LiveLevelsState>) async {
        await box.activity.update(content)
    }

    private func adopt(_ activity: LiveActivity) {
        for w in watchers { w.cancel() }
        watchers = []
        self.activity = activity
        isRunning = true
        // Ended from the Lock Screen (swipe), by iOS after 8 hours, or by us.
        watchers.append(Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard state == .ended || state == .dismissed else { continue }
                await MainActor.run { if self?.activity?.id == activity.id { self?.forget() } }
                return
            }
        })
        #if LEVELS_PUSH
        let tokens = tokens, onTokenChange = onTokenChange
        watchers.append(Task {
            for await data in activity.pushTokenUpdates {
                let token = PushToken(data: data, env: APNsEnvironment.current(), kind: .liveActivity)
                if tokens.save(token) {
                    Self.logger.notice("Live Activity push token (\(token.env.rawValue, privacy: .public))")
                    onTokenChange()
                }
            }
        })
        #endif
    }

    private func forget() {
        for w in watchers { w.cancel() }
        watchers = []
        activity = nil
        shown = nil
        isRunning = false
        clearToken()
    }

    private func clearToken() {
        guard tokens.load() != nil else { return }
        tokens.clear()  // the Mac stops pushing once the next token upload drops it
        onTokenChange()
    }
}
