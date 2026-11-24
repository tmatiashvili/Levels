import Foundation
import LevelsModel
import LevelsNet
import os

/// The Mac side of push-driven iPhone widgets (ADR-0023, PUSH-001 R50–R56). Fed by
/// ``LocalOnlySyncService``'s `onDevicesChanged`, it decides per paired iPhone whether that
/// iPhone's widget must hear of the change and asks the relay to push.
///
/// Per iPhone, against what its widget was last pushed (its own record left out: its widget
/// reads that itself):
/// - nothing a widget shows changed (``LocalOnlySyncService/widgetChange(before:after:received:now:)``
///   is `nil`): no push (R50);
/// - at most one push per ``Policy/minInterval`` (15 min); changes inside the gap are coalesced
///   into one push at its end (R51);
/// - a shown device plugged in or unplugged, or crossing the low-battery alert threshold, skips
///   the gap (R52) but still counts toward the day;
/// - at most ``Policy/maxPerDay`` (48) pushes per local day; then none until midnight (R53);
/// - while that iPhone has a long-poll open (app in the foreground), no push: the app reloads
///   its widgets itself (R54);
/// - only to iPhones that sent a grant that isn't expired or refused (R56).
///
/// This is only for pushes. The Mac's own widget reloads keep their coalescing in
/// ``LocalOnlySyncService``.
///
/// A 429 holds that iPhone until its `Retry-After`; a 5xx or an unreachable relay backs off.
/// Tokens the relay reports gone are removed and that iPhone is asked for a new grant (R16);
/// a refused grant stops pushes to it until a new one arrives (R19). With no relay (push off)
/// it does nothing at all.
///
/// The day count lives in memory: a Mac relaunch starts the day's count again (the relay's own
/// limit of 100 per token per 24 h still applies).
public actor WidgetPushScheduler {
    public struct Policy: Sendable {
        /// R51.
        public var minInterval: TimeInterval = 15 * 60
        /// R53.
        public var maxPerDay = 48
        /// First wait after a 429 without `Retry-After`, a 5xx or an unreachable relay; doubles
        /// up to ``maxBackoff``.
        public var firstBackoff: TimeInterval = 60
        public var maxBackoff: TimeInterval = 60 * 60
        /// Local days for R53.
        public var calendar: Calendar = .current
        public init() {}
    }

    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "push")

    private let relay: PushRelayClient?
    private let store: any HubPairingStore
    private let policy: Policy
    private let now: @Sendable () -> Date
    private let alertThreshold: @Sendable () -> Int
    private let isLive: @Sendable (DeviceID, Date) -> Bool
    private let timer: @Sendable (Duration) -> @Sendable () async throws -> Void

    struct DeviceState: Equatable {
        var lastPushAt: Date?
        /// What this iPhone's widget was last pushed (its own record left out).
        var pushed: [DeviceBattery]?
        /// Start of the local day `count` belongs to.
        var day: Date?
        var count = 0
        var holdUntil: Date?
        var failures = 0
    }

    private var states: [DeviceID: DeviceState] = [:]
    private var latest: [DeviceBattery]?
    private var timerTask: Task<Void, Never>?
    private var timerAt: Date?
    private var sending = false
    private var again = false

    /// - Parameters:
    ///   - relay: `nil` = push off (empty relay URL or `LEVELS_PUSH_ENABLED = NO`): no work, no network.
    ///   - store: the Mac's paired devices; tokens and grants are read from it at each decision.
    ///   - alertThreshold: the ALR-001 low-battery threshold (R52).
    ///   - isLive: whether that iPhone has a long-poll open (``HubPresence``, R54).
    public init<C: Clock<Duration>>(relay: PushRelayClient?, store: any HubPairingStore, policy: Policy = Policy(),
                                    alertThreshold: @escaping @Sendable () -> Int = { AlertSettings.defaultThreshold },
                                    isLive: @escaping @Sendable (DeviceID, Date) -> Bool = { _, _ in false },
                                    now: @escaping @Sendable () -> Date = Date.init, clock: C = ContinuousClock()) {
        self.relay = relay
        self.store = store
        self.policy = policy
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

    /// When this iPhone's widget should be pushed `view`. `nil` = no push. Pure; unit-tested.
    static func due(_ state: DeviceState, view: [DeviceBattery], now: Date, threshold: Int, policy: Policy) -> Date? {
        var urgent = false
        if let pushed = state.pushed {
            guard LocalOnlySyncService.widgetChange(before: pushed, after: view, received: pushed, now: now) != nil else {
                return nil
            }
            urgent = isUrgent(from: pushed, to: view, threshold: threshold)
        }
        if let day = state.day, state.count >= policy.maxPerDay {
            return policy.calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
        guard let last = state.lastPushAt, !urgent else { return now }
        return max(now, last.addingTimeInterval(policy.minInterval))
    }

    /// R52: a shown device plugged in or unplugged (charging started or stopped where the device
    /// doesn't report the charger), or a level crossing the alert threshold. Pure.
    static func isUrgent(from old: [DeviceBattery], to new: [DeviceBattery], threshold: Int) -> Bool {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for d in new {
            guard let b = before[d.id] else { continue }
            if d.isPluggedIn != nil || b.isPluggedIn != nil {
                if d.isPluggedIn != b.isPluggedIn { return true }
            } else if d.isCharging != b.isCharging {
                return true
            }
            if let l = d.level, let o = b.level, (l <= threshold) != (o <= threshold) { return true }
        }
        return false
    }

    /// What `owner`'s widget is told about: everything but its own record (and accessories of it).
    static func view(_ devices: [DeviceBattery], for owner: DeviceID) -> [DeviceBattery] {
        devices.filter { $0.id != owner && $0.accessory?.parentDeviceID != owner }
    }

    /// Whether the scheduler may push to this registration at all (R56).
    static func usable(_ r: PushRegistration, now: Date) -> (tokens: [PushToken], grant: String)? {
        let tokens = r.tokens.filter { $0.kind == .widget }
        guard !tokens.isEmpty, let grant = r.grant, !r.needsGrant else { return nil }
        if let exp = r.grantExpiresAt, exp <= now { return nil }
        return (tokens, grant)
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
        let today = policy.calendar.startOfDay(for: t)
        let threshold = alertThreshold()
        var live = Set<DeviceID>()
        var next: Date?
        for (owner, registration) in store.pushRegistrations() {
            guard let target = Self.usable(registration, now: t) else { continue }
            live.insert(owner)
            var state = states[owner] ?? DeviceState()
            if state.day != today {
                state.day = today
                state.count = 0
            }
            let view = Self.view(latest, for: owner)
            if isLive(owner, t) {
                // R54: the app is in the foreground and reloads its own widgets.
                state.pushed = view
                states[owner] = state
                continue
            }
            states[owner] = state
            guard var due = Self.due(state, view: view, now: t, threshold: threshold, policy: policy) else { continue }
            if let hold = state.holdUntil, hold > due { due = hold }
            if due <= t {
                if let retry = await send(target.tokens, grant: target.grant, owner: owner, view: view, via: relay, at: t) {
                    next = min(next ?? retry, retry)
                }
            } else {
                next = min(next ?? due, due)
            }
        }
        states = states.filter { live.contains($0.key) }  // forgotten devices, no grant
        arm(next)
    }

    // MARK: Sending

    /// Returns when to look again after a failure, else `nil`.
    private func send(_ tokens: [PushToken], grant: String, owner: DeviceID, view: [DeviceBattery], via relay: PushRelayClient,
                      at t: Date) async -> Date? {
        let result = await relay.send(Array(tokens.prefix(PushRelayClient.maxTokensPerRequest)), grants: [grant])
        var state = states[owner] ?? DeviceState()
        defer { states[owner] = state }
        switch result {
        case .accepted(let invalid):
            state.failures = 0
            state.holdUntil = nil
            state.lastPushAt = t
            state.pushed = view
            state.count += 1
            let gone = tokens.filter { invalid.contains($0.token) }
            if !gone.isEmpty { drop(gone, of: owner) }
            return nil
        case .tokensGone:
            state.pushed = view
            drop(tokens, of: owner)
            return nil
        case .unauthorized(let code):
            state.pushed = view  // no loop; the next change tries again (or a new grant does)
            if code == "timestamp_skew" {
                Self.logger.error("Push relay: this Mac's clock is off by more than 5 minutes")
            } else {
                // grant_expired, token_not_granted, grant_invalid, signature_invalid, …: wait for a new grant.
                Self.logger.notice("Push relay refused the grant (\(code, privacy: .public)); waiting for a new one")
                needsGrant(owner)
            }
            return nil
        case .rateLimited(let retryAfter):
            let wait = retryAfter.map { min(policy.maxBackoff, max(1, $0)) } ?? backoff(&state)
            state.holdUntil = t.addingTimeInterval(wait)
            Self.logger.notice("Push relay rate-limited; holding pushes to one iPhone \(Int(wait), privacy: .public) s")
            return state.holdUntil
        case .unreachable, .serverError:
            state.holdUntil = t.addingTimeInterval(backoff(&state))
            return state.holdUntil
        case .rejected(let status):
            // 400 and the like: retrying the same request won't help. Count it as pushed so the
            // next real change tries again, not a loop.
            Self.logger.error("Push relay refused the request (\(status, privacy: .public))")
            state.pushed = view
            return nil
        }
    }

    private func backoff(_ state: inout DeviceState) -> TimeInterval {
        let wait = min(policy.maxBackoff, policy.firstBackoff * pow(2, Double(min(state.failures, 16))))
        state.failures += 1
        return wait
    }

    /// R16: drop the tokens and ask that iPhone for new ones.
    private func drop(_ gone: [PushToken], of owner: DeviceID) {
        let goneSet = Set(gone.map(\.token))
        let remaining = (store.pushRegistrations()[owner]?.tokens ?? []).filter { !goneSet.contains($0.token) }
        do {
            _ = try store.setPushTokens(remaining, for: owner)
            _ = try store.setPushNeedsGrant(for: owner)
        } catch {
            Self.logger.error("Dropping gone push tokens failed: \(String(describing: error), privacy: .public)")
        }
        Self.logger.notice("Dropped \(goneSet.count, privacy: .public) gone push token(s)")
    }

    private func needsGrant(_ owner: DeviceID) {
        do { _ = try store.setPushNeedsGrant(for: owner) } catch {
            Self.logger.error("Marking a push grant refused failed: \(String(describing: error), privacy: .public)")
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
