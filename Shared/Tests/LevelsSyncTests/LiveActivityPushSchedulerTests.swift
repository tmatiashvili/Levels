import CryptoKit
import Foundation
import LevelsModel
import LevelsNet
import Synchronization
import Testing
@testable import LevelsSync

private let lMacID = DeviceID(UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000A1")!)
private let lPhoneID = DeviceID(UUID(uuidString: "BBBBBBBB-0000-0000-0000-0000000000B1")!)
private let widgetToken = PushToken(token: String(repeating: "aa", count: 32), env: .development, kind: .widget)
private let laToken = PushToken(token: String(repeating: "cc", count: 32), env: .development, kind: .liveActivity)
private let laToken2 = PushToken(token: String(repeating: "dd", count: 32), env: .development, kind: .liveActivity)
private let grant = "g1.grant.mac"

private func mac(_ level: Int = 80, plugged: Bool = false, at: Date) -> DeviceBattery {
    DeviceBattery(id: lMacID, name: "Mac", kind: .mac, level: level, isCharging: plugged, isPluggedIn: plugged, updatedAt: at)
}

private func phone(_ level: Int = 50, at: Date) -> DeviceBattery {
    DeviceBattery(id: lPhoneID, name: "iPhone", kind: .iphone, level: level, isCharging: false, updatedAt: at)
}

/// Records each Live Activity request the relay got.
final class RecordingLARelay: PushRelayTransport {
    struct Call: Sendable, Equatable {
        var tokens: [String]
        var priority: Int
        var state: LiveLevelsState
        var staleDate: Int64?
        var timestamp: Int64
    }
    private let state = Mutex<(calls: [Call], answers: [(Int, [String: String], Data)])>(([], []))
    var calls: [Call] { state.withLock { $0.calls } }
    func answer(_ status: Int, headers: [String: String] = [:], body: String = "") {
        state.withLock { $0.answers.append((status, headers, Data(body.utf8))) }
    }
    func post(url: URL, headers: [String: String], body: Data) async throws -> (status: Int, headers: [String: String], body: Data) {
        let decoded = try JSONDecoder().decode(LiveActivityRelayBody.self, from: body)
        return state.withLock { s in
            s.calls.append(Call(tokens: decoded.tokens.map(\.token), priority: decoded.payload.priority,
                                state: decoded.payload.contentState, staleDate: decoded.payload.staleDate,
                                timestamp: decoded.payload.timestamp))
            return s.answers.isEmpty ? (202, [:], Data(#"{"results":[{"index":0,"status":"sent"}]}"#.utf8)) : s.answers.removeFirst()
        }
    }
}

@Suite("LIVE-001 LiveActivityPushScheduler (R20–R29)")
struct LiveActivityPushSchedulerTests {
    let clock = ManualClock()
    let relay = RecordingLARelay()
    let live = LiveSet()
    let store: InMemoryHubPairingStore

    init() throws {
        store = InMemoryHubPairingStore([
            PairedClient(id: lPhoneID, name: "iPhone", kind: .iphone, key: Data(repeating: 1, count: 32), pairedAt: Date()),
        ])
        _ = try store.setPushRegistration([widgetToken, laToken], grant: grant, expiresAt: 1_900_000_000, for: lPhoneID)
    }

    func scheduler(relayURL: String = "https://relay.example", threshold: Int = 20) -> LiveActivityPushScheduler {
        let clock = clock, live = live
        return LiveActivityPushScheduler(
            relay: PushRelayClient(relayURL: relayURL, auth: MacPushSigner(key: P256.Signing.PrivateKey()), transport: relay,
                                   now: { clock.date }),
            store: store, macID: { lMacID }, alertThreshold: { threshold },
            isLive: { id, _ in live.contains(id) }, now: { clock.date }, clock: clock)
    }

    @Test func pushOffMakesNoNetworkCalls() async {
        let s = scheduler(relayURL: "")
        #expect(await !s.isEnabled)
        await s.devicesChanged([mac(at: clock.date)])
        await settle()
        #expect(relay.calls.isEmpty)
    }

    @Test func firstPushCarriesThisIPhoneTheMacAndAStaleDate() async {
        let s = scheduler()
        let t = clock.date
        await s.devicesChanged([mac(80, at: t), phone(50, at: t)])
        let call = try? #require(relay.calls.first)
        #expect(relay.calls.count == 1)
        #expect(call?.tokens == [laToken.token])  // only the Live Activity token, never the widget's
        #expect(call?.priority == 5)
        #expect(call?.state.devices.map(\.role) == [.iphone, .mac])
        #expect(call?.timestamp == Int64(t.timeIntervalSince1970))
        #expect(call?.staleDate == Int64(t.timeIntervalSince1970) + 1800)  // R22
    }

    @Test func levelStepsInsideAMinuteCoalesce() async {
        let s = scheduler()
        let t = clock.date
        await s.devicesChanged([mac(80, at: t)])
        clock.advance(by: .seconds(10))
        await s.devicesChanged([mac(79, at: t + 10)])
        clock.advance(by: .seconds(10))
        await s.devicesChanged([mac(78, at: t + 20)])
        #expect(relay.calls.count == 1)
        await waitFor { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(40))
        await waitFor { relay.calls.count == 2 }
        #expect(relay.calls.last?.state.device(.mac)?.level == 78)  // the newest, once
        #expect(relay.calls.last?.priority == 5)
    }

    @Test func unchangedLevelsAreNotPushed() async {
        let s = scheduler()
        let t = clock.date
        await s.devicesChanged([mac(80, at: t)])
        clock.advance(by: .seconds(120))
        await s.devicesChanged([mac(80, at: t + 120)])  // newer reading, same picture
        await settle()
        #expect(relay.calls.count == 1)
    }

    @Test func plugAndUnplugGoAtOnceAsPriorityTen() async {
        let s = scheduler()
        let t = clock.date
        await s.devicesChanged([mac(50, at: t)])
        clock.advance(by: .seconds(5))
        await s.devicesChanged([mac(50, plugged: true, at: t + 5)])
        clock.advance(by: .seconds(5))
        await s.devicesChanged([mac(50, at: t + 10)])
        #expect(relay.calls.map(\.priority) == [5, 10, 10])
    }

    @Test func urgentPushesAreCappedPerHour() {
        var policy = LiveActivityPushScheduler.Policy()
        policy.maxUrgentPerHour = 2
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let a = LiveLevelsState(devices: [.init(role: .mac, level: 50, charging: false, updatedAt: 0)])
        var b = a; b.devices[0].charging = true
        var state = LiveActivityPushScheduler.State(tokens: [], firstSeen: t, pushed: a, lastPushAt: t)
        state.urgentAt = [t - 100, t - 50]
        let plan = LiveActivityPushScheduler.plan(state, content: b, now: t, threshold: 20, policy: policy)
        #expect(plan == .init(at: t + 60, priority: 5))  // over the cap: an ordinary push after the gap
        state.urgentAt = [t - 3700, t - 50]
        #expect(LiveActivityPushScheduler.plan(state, content: b, now: t, threshold: 20, policy: policy) == .init(at: t, priority: 10))
    }

    @Test func nothingWhileTheAppIsInTheForegroundThenOnlyNewChanges() async {
        let s = scheduler()
        let t = clock.date
        live.set(lPhoneID, true)
        await s.devicesChanged([mac(80, at: t)])
        #expect(relay.calls.isEmpty)  // R26: the app updates the activity itself
        live.set(lPhoneID, false)
        await s.devicesChanged([mac(80, at: t)])
        await settle()
        #expect(relay.calls.isEmpty)  // what the app showed counts as pushed
        clock.advance(by: .seconds(5))
        await s.devicesChanged([mac(79, at: t + 5)])
        #expect(relay.calls.count == 1)
    }

    @Test func stopsEightHoursAfterTheTokenAppeared() async {
        let s = scheduler()
        let t = clock.date
        await s.devicesChanged([mac(80, at: t)])
        clock.advance(by: .seconds(8 * 3600))
        await s.devicesChanged([mac(40, at: t + 8 * 3600)])
        await settle()
        #expect(relay.calls.count == 1)  // R27
    }

    @Test func aNewActivityTokenStartsOver() async throws {
        let s = scheduler()
        let t = clock.date
        await s.devicesChanged([mac(80, at: t)])
        clock.advance(by: .seconds(8 * 3600))
        _ = try store.setPushRegistration([widgetToken, laToken2], grant: grant, expiresAt: 1_900_000_000, for: lPhoneID)
        await s.devicesChanged([mac(40, at: t + 8 * 3600)])
        #expect(relay.calls.last?.tokens == [laToken2.token])
        #expect(relay.calls.count == 2)
    }

    @Test func noGrantOrOnlyAWidgetTokenSendsNothing() async throws {
        _ = try store.setPushRegistration([widgetToken], grant: grant, expiresAt: 1_900_000_000, for: lPhoneID)
        let s = scheduler()
        await s.devicesChanged([mac(80, at: clock.date)])
        _ = try store.setPushRegistration([laToken], grant: nil, expiresAt: nil, for: lPhoneID)
        await s.devicesChanged([mac(70, at: clock.date)])
        await settle()
        #expect(relay.calls.isEmpty)
    }

    @Test func goneTokenIsDroppedAndTheIPhoneAskedForANewGrant() async {
        relay.answer(410, body: #"{"error":"tokens_invalid","invalidTokens":["\#(laToken.token)"]}"#)
        let s = scheduler()
        await s.devicesChanged([mac(80, at: clock.date)])
        let r = store.pushRegistrations()[lPhoneID]
        #expect(r?.tokens == [widgetToken])
        #expect(r?.needsGrant == true)
    }

    @Test func refusedGrantStopsPushes() async {
        relay.answer(401, body: #"{"error":"grant_expired"}"#)
        let s = scheduler()
        let t = clock.date
        await s.devicesChanged([mac(80, at: t)])
        clock.advance(by: .seconds(5))
        await s.devicesChanged([mac(50, plugged: true, at: t + 5)])
        await settle()
        #expect(relay.calls.count == 1)
        #expect(store.pushRegistrations()[lPhoneID]?.needsGrant == true)
    }

    @Test func rateLimitHoldsUntilRetryAfter() async {
        relay.answer(429, headers: ["retry-after": "120"], body: #"{"error":"rate_limited"}"#)
        let s = scheduler()
        let t = clock.date
        await s.devicesChanged([mac(80, at: t)])
        #expect(relay.calls.count == 1)
        await waitFor { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(119))
        await settle()
        #expect(relay.calls.count == 1)
        clock.advance(by: .seconds(1))
        await waitFor { relay.calls.count == 2 }
    }
}
