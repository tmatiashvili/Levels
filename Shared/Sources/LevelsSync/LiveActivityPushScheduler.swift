import Foundation
import LevelsModel
import LevelsNet
import os

/// The Mac side of the "Live levels" Live Activity (LIVE-001 R20–R29, PUSH-001 R55). Fed by
/// the same cache changes as ``WidgetPushScheduler``; per paired iPhone that sent a Live
/// Activity token with a grant, it builds the activity's content-state (that iPhone, this Mac,
/// AirPods; ``LiveLevels/state(from:iphoneID:macID:)``) and pushes it through the relay when
/// what the activity shows changed:
///
/// - only a visible change (a whole-percent level, charging, a device appearing) is pushed (R20);
/// - priority 5 at most once per ``Policy/minInterval`` (60 s), changes inside the gap coalesced
///   into one push at its end (R24);
/// - plug-in or unplug, reaching 100 % or crossing the alert threshold go at once as priority 10
///   (R23), at most ``Policy/maxUrgentPerHour`` an hour, then as priority 5 (R25);
/// - every push carries `stale-date` = now + 30 min (R22);
/// - while that iPhone's app is in the foreground (long-poll open) the app updates the
///   activity itself: nothing is pushed, and what it shows counts as pushed (R26);
/// - a token is pushed for at most 8 hours after the Mac first saw it: iOS has ended the
///   activity by then (R27);
/// - only with a usable grant (PUSH-001 R56); gone tokens and refused grants are handled like
///   the widget's (R16, R19).
///
/// With no relay (push off, the free build) it does nothing at all.
public actor LiveActivityPushScheduler {
    public struct Policy: Sendable {
        public var minInterval: TimeInterval = LiveLevelsPolicy.minPushInterval
        public var maxUrgentPerHour = LiveLevelsPolicy.maxUrgentPerHour
        public var maxActivityAge: TimeInterval = LiveLevelsPolicy.maxDuration
        public var staleAfter: TimeInterval = LiveLevelsPolicy.staleAfter
        public var firstBackoff: TimeInterval = 60
        public var maxBackoff: TimeInterval = 60 * 60
        public init() {}
    }

    /// When and how to push next.
    struct Plan: Equatable {
        var at: Date
        var priority: Int
    }

    struct State: Equatable {
        /// The tokens this state belongs to; a new set (a new activity) starts over.
        var tokens: Set<String>
        var firstSeen: Date
        /// What the activity was last pushed (or shown by the app itself, R26).
        var pushed: LiveLevelsState?
        var lastPushAt: Date?
        /// Times of the priority-10 pushes in the last hour.
        var urgentAt: [Date] = []
        var holdUntil: Date?
        var failures = 0
    }

    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "push")

    private let relay: PushRelayClient?
    private let store: any HubPairingStore
    private let policy: Policy
    private let macID: @Sendable () -> DeviceID?
    private let alertThreshold: @Sendable () -> Int
    private let isLive: @Sendable (DeviceID, Date) -> Bool
    private let now: @Sendable () -> Date
    private let timer: @Sendable (Duration) -> @Sendable () async throws -> Void

    private var states: [DeviceID: State] = [:]
    private var latest: [DeviceBattery]?
    private var timerTask: Task<Void, Never>?
    private var timerAt: Date?
    private var sending = false
    private var again = false

    /// - Parameters:
    ///   - relay: `nil` = push off: no work, no network.
    ///   - macID: this Mac's own device ID (its record is the activity's Mac).
    public init<C: Clock<Duration>>(relay: PushRelayClient?, store: any HubPairingStore, policy: Policy = Policy(),
                                    macID: @escaping @Sendable () -> DeviceID?,
                                    alertThreshold: @escaping @Sendable () -> Int = { AlertSettings.defaultThreshold },
                                    isLive: @escaping @Sendable (DeviceID, Date) -> Bool = { _, _ in false },
                                    now: @escaping @Sendable () -> Date = Date.init, clock: C = ContinuousClock()) {
        self.relay = relay
        self.store = store
        self.policy = policy
        self.macID = macID
        self.alertThreshold = alertThreshold
        self.isLive = isLive
        self.now = now
        self.timer = { duration in
            let deadline = clock.now.advanced(by: duration)
            return { try await clock.sleep(until: deadline, tolerance: nil) }
        }
    }

    public var isEnabled: Bool { relay != nil }

    /// The cache's devices changed.
    public func devicesChanged(_ devices: [DeviceBattery]) async {
        guard relay != nil else { return }
        latest = devices
        await evaluate()
    }

    // MARK: Deciding

    /// When to push `content` to an activity in `state`, and with which priority. `nil` = no
    /// push. Pure; unit-tested.
    static func plan(_ state: State, content: LiveLevelsState, now: Date, threshold: Int, policy: Policy) -> Plan? {
        guard now.timeIntervalSince(state.firstSeen) < policy.maxActivityAge else { return nil }  // R27
        guard LiveLevelsPolicy.isVisibleChange(from: state.pushed, to: content) else { return nil }  // R20
        let recentUrgent = state.urgentAt.filter { now.timeIntervalSince($0) < 3600 }.count
        if LiveLevelsPolicy.isUrgent(from: state.pushed, to: content, threshold: threshold),
           recentUrgent < policy.maxUrgentPerHour {
            return Plan(at: now, priority: 10)  // R23
        }
        guard let last = state.lastPushAt else { return Plan(at: now, priority: 5) }
        return Plan(at: max(now, last.addingTimeInterval(policy.minInterval)), priority: 5)  // R24, R25
    }

    /// The Live Activity tokens and grant of a registration, when usable (PUSH-001 R56).
    static func usable(_ r: PushRegistration, now: Date) -> (tokens: [PushToken], grant: String)? {
        let tokens = r.tokens.filter { $0.kind == .liveActivity }
        guard !tokens.isEmpty, let grant = r.grant, !r.needsGrant else { return nil }
        if let exp = r.grantExpiresAt, exp <= now { return nil }
        return (tokens, grant)
    }

    /// The payload for `content` at `now` (R22).
    static func payload(_ content: LiveLevelsState, priority: Int, now: Date, policy: Policy) -> LiveActivityPushPayload {
        let t = Int64(now.timeIntervalSince1970.rounded(.down))
        return LiveActivityPushPayload(contentState: content, event: .update, timestamp: t,
                                       staleDate: t + Int64(policy.staleAfter), priority: priority)
    }

    private func evaluate() async {
        if sending { again = true; return }
        sending = true
        defer { sending = false }
        repeat {
            again = false
            await evaluateOnce()
        } while again
    }

    private func evaluateOnce() async {
        guard let relay, let latest else { return }
        let t = now()
        let threshold = alertThreshold()
        let mac = macID()
        var seen = Set<DeviceID>()
        var next: Date?
        for (owner, registration) in store.pushRegistrations() {
            guard let target = Self.usable(registration, now: t) else { continue }
            seen.insert(owner)
            let tokenSet = Set(target.tokens.map(\.token))
            var state = states[owner].flatMap { $0.tokens == tokenSet ? $0 : nil } ?? State(tokens: tokenSet, firstSeen: t)
            let content = LiveLevels.state(from: latest, iphoneID: owner, macID: mac)
            if isLive(owner, t) {
                state.pushed = content  // R26: the app shows this itself
                states[owner] = state
                continue
            }
            states[owner] = state
            guard var plan = Self.plan(state, content: content, now: t, threshold: threshold, policy: policy) else { continue }
            if let hold = state.holdUntil, hold > plan.at { plan.at = hold }
            if plan.at <= t {
                if let retry = await send(target.tokens, grant: target.grant, owner: owner, content: content,
                                          priority: plan.priority, via: relay, at: t) {
                    next = min(next ?? retry, retry)
                }
            } else {
                next = min(next ?? plan.at, plan.at)
            }
        }
        states = states.filter { seen.contains($0.key) }
        arm(next)
    }

    // MARK: Sending

    /// Returns when to look again after a failure, else `nil`.
    private func send(_ tokens: [PushToken], grant: String, owner: DeviceID, content: LiveLevelsState, priority: Int,
                      via relay: PushRelayClient, at t: Date) async -> Date? {
        let payload = Self.payload(content, priority: priority, now: t, policy: policy)
        let result = await relay.sendLiveActivity(Array(tokens.prefix(PushRelayClient.maxTokensPerRequest)),
                                                  grants: [grant], payload: payload)
        guard var state = states[owner] else { return nil }
        defer { states[owner] = state }
        switch result {
        case .accepted(let invalid):
            state.failures = 0
            state.holdUntil = nil
            state.lastPushAt = t
            state.pushed = content
            if priority == 10 { state.urgentAt = state.urgentAt.filter { t.timeIntervalSince($0) < 3600 } + [t] }
            let gone = tokens.filter { invalid.contains($0.token) }
            if !gone.isEmpty { drop(gone, of: owner) }
            return nil
        case .tokensGone:
            state.pushed = content
            drop(tokens, of: owner)
            return nil
        case .unauthorized(let code):
            state.pushed = content
            if code == "timestamp_skew" {
                Self.logger.error("Push relay: this Mac's clock is off by more than 5 minutes")
            } else {
                Self.logger.notice("Push relay refused the Live Activity grant (\(code, privacy: .public)); waiting for a new one")
                do { _ = try store.setPushNeedsGrant(for: owner) } catch {
                    Self.logger.error("Marking a push grant refused failed: \(String(describing: error), privacy: .public)")
                }
            }
            return nil
        case .rateLimited(let retryAfter):
            let wait = retryAfter.map { min(policy.maxBackoff, max(1, $0)) } ?? backoff(&state)
            state.holdUntil = t.addingTimeInterval(wait)
            return state.holdUntil
        case .unreachable, .serverError:
            state.holdUntil = t.addingTimeInterval(backoff(&state))
            return state.holdUntil
        case .rejected(let status):
            Self.logger.error("Push relay refused the Live Activity request (\(status, privacy: .public))")
            state.pushed = content
            return nil
        }
    }

    private func backoff(_ state: inout State) -> TimeInterval {
        let wait = min(policy.maxBackoff, policy.firstBackoff * pow(2, Double(min(state.failures, 16))))
        state.failures += 1
        return wait
    }

    /// PUSH-001 R16: drop the tokens and ask that iPhone for new ones.
    private func drop(_ gone: [PushToken], of owner: DeviceID) {
        let goneSet = Set(gone.map(\.token))
        let remaining = (store.pushRegistrations()[owner]?.tokens ?? []).filter { !goneSet.contains($0.token) }
        do {
            _ = try store.setPushTokens(remaining, for: owner)
            _ = try store.setPushNeedsGrant(for: owner)
        } catch {
            Self.logger.error("Dropping gone Live Activity tokens failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func arm(_ at: Date?) {
        guard let at else {
            timerTask?.cancel()
            timerTask = nil
            timerAt = nil
            return
        }
        if let timerAt, timerAt == at, timerTask != nil { return }
        timerTask?.cancel()
        timerAt = at
        let sleep = timer(.milliseconds(Int64((max(0, at.timeIntervalSince(now())) * 1000).rounded(.up))))
        timerTask = Task {
            do { try await sleep() } catch { return }
            await self.timerFired(at)
        }
    }

    private func timerFired(_ at: Date) async {
        guard timerAt == at else { return }
        timerTask = nil
        timerAt = nil
        await evaluate()
    }
}
