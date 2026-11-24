import Foundation
import LevelsModel
import LevelsNet
import os

/// The Mac side of push-driven iPhone widgets (ADR-0023 on feature/push-relay). Fed by
/// ``LocalOnlySyncService``'s `onDevicesChanged`, it decides per widget token whether that
/// iPhone's widget must hear of the change and asks the relay to push.
///
/// Per token, against what that token was last pushed (the iPhone's own record left out: its
/// widget reads that itself):
/// - nothing a widget shows changed (``LocalOnlySyncService/widgetChange(before:after:received:now:)``
///   is `nil`): no push;
/// - a charger plugged or unplugged, charging started or stopped, or a level crossed
///   ``LocalOnlySyncService/lowLevel`` (20 %): push now;
/// - only levels moved a little: at most one push per ``Policy/levelOnlyInterval``;
/// - anything else: at most one push per ``Policy/minInterval``.
///
/// A 429 holds every push until its `Retry-After` (or a doubling backoff); an unreachable
/// relay backs off the same way. Tokens the relay reports gone are removed from the pairing
/// store. With no relay (push off) it does nothing at all.
public actor WidgetPushScheduler {
    public struct Policy: Sendable {
        public var minInterval: TimeInterval = 60
        /// Same budget as the Mac widget's level-only reloads (``LocalOnlySyncService/levelOnlyReloadInterval``).
        public var levelOnlyInterval: TimeInterval = LocalOnlySyncService.levelOnlyReloadInterval
        /// First wait after a 429 without `Retry-After`, or an unreachable relay; doubles up to ``maxBackoff``.
        public var firstBackoff: TimeInterval = 60
        public var maxBackoff: TimeInterval = 60 * 60
        public init() {}
    }

    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "push")

    private let relay: PushRelayClient?
    private let store: any HubPairingStore
    private let policy: Policy
    private let now: @Sendable () -> Date
    private let timer: @Sendable (Duration) -> @Sendable () async throws -> Void

    private struct TokenState {
        var owner: DeviceID
        var lastPushAt: Date?
        /// What this token's widget was last pushed (its owner's record left out).
        var pushed: [DeviceBattery]?
    }

    private var states: [String: TokenState] = [:]
    private var latest: [DeviceBattery]?
    private var holdUntil: Date?
    private var failures = 0
    private var timerTask: Task<Void, Never>?
    private var timerAt: Date?
    private var sending = false
    private var again = false

    /// - Parameters:
    ///   - relay: `nil` = push off (empty relay URL or `LEVELS_PUSH_ENABLED = NO`): no work, no network.
    ///   - store: the Mac's paired devices; tokens are read from it at each decision.
    public init<C: Clock<Duration>>(relay: PushRelayClient?, store: any HubPairingStore, policy: Policy = Policy(),
                                    now: @escaping @Sendable () -> Date = Date.init, clock: C = ContinuousClock()) {
        self.relay = relay
        self.store = store
        self.policy = policy
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

    /// When `token`'s widget should be pushed `view`, given what it was last pushed. `nil` = no push.
    static func due(pushed: [DeviceBattery]?, view: [DeviceBattery], lastPushAt: Date?, now: Date,
                    policy: Policy) -> Date? {
        guard let pushed else { return now }  // first change since launch: the widget's state is unknown
        guard let change = LocalOnlySyncService.widgetChange(before: pushed, after: view, received: pushed, now: now) else {
            return nil
        }
        if isUrgent(from: pushed, to: view) { return now }
        guard let lastPushAt else { return now }
        let interval = change == .levelOnly ? policy.levelOnlyInterval : policy.minInterval
        return max(now, lastPushAt.addingTimeInterval(interval))
    }

    /// A charger or charging change, or a level crossing ``LocalOnlySyncService/lowLevel``. Pure.
    static func isUrgent(from old: [DeviceBattery], to new: [DeviceBattery]) -> Bool {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let low = LocalOnlySyncService.lowLevel
        for d in new {
            guard let b = before[d.id] else { continue }
            if d.isPluggedIn != b.isPluggedIn || d.isCharging != b.isCharging { return true }
            if let l = d.level, let o = b.level, (l <= low) != (o <= low) { return true }
        }
        return false
    }

    /// What `owner`'s widget is told about: everything but its own record (and accessories of it).
    static func view(_ devices: [DeviceBattery], for owner: DeviceID) -> [DeviceBattery] {
        devices.filter { $0.id != owner && $0.accessory?.parentDeviceID != owner }
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
        let tokens = store.pushTokens()
        var live = Set<String>()
        var dueNow: [(PushToken, [DeviceBattery])] = []
        var next: Date?
        for (owner, list) in tokens {
            let view = Self.view(latest, for: owner)
            for token in list where token.kind == .widget {
                live.insert(token.token)
                let state = states[token.token] ?? TokenState(owner: owner)
                states[token.token] = state
                guard var due = Self.due(pushed: state.pushed, view: view, lastPushAt: state.lastPushAt, now: t,
                                         policy: policy) else { continue }
                if let holdUntil, holdUntil > due { due = holdUntil }
                if due <= t {
                    dueNow.append((token, view))
                } else {
                    next = min(next ?? due, due)
                }
            }
        }
        states = states.filter { live.contains($0.key) }  // forgotten devices, replaced tokens
        if !dueNow.isEmpty {
            next = await send(dueNow, via: relay, at: t).map { min(next ?? $0, $0) } ?? next
        }
        arm(next)
    }

    // MARK: Sending

    /// Returns when to look again after a failure, else `nil`.
    private func send(_ batch: [(PushToken, [DeviceBattery])], via relay: PushRelayClient, at t: Date) async -> Date? {
        let tokens = batch.map(\.0)
        let result = await relay.send(tokens)
        switch result {
        case .accepted(let invalid):
            failures = 0
            holdUntil = nil
            for (token, view) in batch where !invalid.contains(token.token) {
                states[token.token]?.lastPushAt = t
                states[token.token]?.pushed = view
            }
            if !invalid.isEmpty { drop(tokens.filter { invalid.contains($0.token) }) }
            return nil
        case .tokensGone:
            drop(tokens)
            return nil
        case .rateLimited(let retryAfter):
            let wait = retryAfter.map { min(policy.maxBackoff, max(1, $0)) } ?? backoff()
            holdUntil = t.addingTimeInterval(wait)
            Self.logger.notice("Push relay rate-limited; holding pushes \(Int(wait), privacy: .public) s")
            return holdUntil
        case .unreachable:
            let wait = backoff()
            holdUntil = t.addingTimeInterval(wait)
            return holdUntil
        case .rejected(let status):
            // 400/401: retrying the same request won't help. Count it as pushed so the next
            // real change tries again, not a loop.
            Self.logger.error("Push relay refused the request (\(status, privacy: .public))")
            for (token, view) in batch {
                states[token.token]?.lastPushAt = t
                states[token.token]?.pushed = view
            }
            return nil
        }
    }

    private func backoff() -> TimeInterval {
        let wait = min(policy.maxBackoff, policy.firstBackoff * pow(2, Double(min(failures, 16))))
        failures += 1
        return wait
    }

    private func drop(_ gone: [PushToken]) {
        let goneSet = Set(gone.map(\.token))
        for (owner, list) in store.pushTokens() where list.contains(where: { goneSet.contains($0.token) }) {
            do { _ = try store.setPushTokens(list.filter { !goneSet.contains($0.token) }, for: owner) } catch {
                Self.logger.error("Dropping gone push tokens failed: \(String(describing: error), privacy: .public)")
            }
        }
        for token in goneSet { states[token] = nil }
        Self.logger.notice("Dropped \(goneSet.count, privacy: .public) gone push token(s)")
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
