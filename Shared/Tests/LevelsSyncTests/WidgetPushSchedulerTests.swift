import CryptoKit
import Foundation
import LevelsModel
import LevelsNet
import Synchronization
import Testing
@testable import LevelsSync

private let pMacID = DeviceID(UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000A1")!)
private let pPhoneID = DeviceID(UUID(uuidString: "BBBBBBBB-0000-0000-0000-0000000000B1")!)
private let pPhone2ID = DeviceID(UUID(uuidString: "BBBBBBBB-0000-0000-0000-0000000000B2")!)
private let tokenA = PushToken(token: String(repeating: "aa", count: 32), env: .development, kind: .widget)
private let tokenB = PushToken(token: String(repeating: "bb", count: 32), env: .production, kind: .widget)
private let grantA = "g1.grant-a.mac"
private let grantB = "g1.grant-b.mac"

private func mac(_ level: Int = 80, plugged: Bool = false, at: Date) -> DeviceBattery {
    DeviceBattery(id: pMacID, name: "Mac", kind: .mac, level: level, isCharging: plugged, isPluggedIn: plugged, updatedAt: at)
}

private func phone(_ level: Int = 50, id: DeviceID = pPhoneID, at: Date) -> DeviceBattery {
    DeviceBattery(id: id, name: "iPhone", kind: .iphone, level: level, isCharging: false, updatedAt: at)
}

/// A relay transport recording which tokens and grants each request carried.
final class RecordingRelay: PushRelayTransport {
    struct Call: Sendable, Equatable { var tokens: [String]; var grants: String?; var signed: Bool }
    private let state = Mutex<(calls: [Call], answers: [(Int, [String: String], Data)])>(([], []))
    var calls: [Call] { state.withLock { $0.calls } }
    var tokenCalls: [[String]] { calls.map(\.tokens) }
    func answer(_ status: Int, headers: [String: String] = [:], body: String = "") {
        state.withLock { $0.answers.append((status, headers, Data(body.utf8))) }
    }
    func post(url: URL, headers: [String: String], body: Data) async throws -> (status: Int, headers: [String: String], body: Data) {
        let decoded = try JSONDecoder().decode(PushRelayBody.self, from: body)
        return state.withLock { s in
            s.calls.append(Call(tokens: decoded.tokens.map(\.token), grants: headers["levels-grant"],
                                signed: headers["levels-signature"] != nil && headers["levels-timestamp"] != nil))
            return s.answers.isEmpty ? (202, [:], Data(#"{"results":[{"index":0,"status":"sent"}]}"#.utf8)) : s.answers.removeFirst()
        }
    }
}

final class LiveSet: Sendable {
    private let ids = Mutex<Set<DeviceID>>([])
    func set(_ id: DeviceID, _ on: Bool) { ids.withLock { if on { $0.insert(id) } else { $0.remove(id) } } }
    func contains(_ id: DeviceID) -> Bool { ids.withLock { $0.contains(id) } }
}

@Suite("PUSH WidgetPushScheduler (R50–R56: 15-min gap, 48/day, urgent skips, grants)")
struct WidgetPushSchedulerTests {
    let clock = ManualClock()
    let relay = RecordingRelay()
    let live = LiveSet()
    let store: InMemoryHubPairingStore

    init() throws {
        store = InMemoryHubPairingStore([
            PairedClient(id: pPhoneID, name: "iPhone", kind: .iphone, key: Data(repeating: 1, count: 32), pairedAt: Date()),
            PairedClient(id: pPhone2ID, name: "iPhone 2", kind: .iphone, key: Data(repeating: 2, count: 32), pairedAt: Date()),
        ])
        _ = try store.setPushRegistration([tokenA], grant: grantA, expiresAt: 1_900_000_000, for: pPhoneID)
    }

    func scheduler(relayURL: String = "https://relay.example", threshold: Int = 20) -> WidgetPushScheduler {
        let clock = clock
        let live = live
        var policy = WidgetPushScheduler.Policy()
        policy.calendar = Calendar(identifier: .gregorian)
        policy.calendar.timeZone = TimeZone(identifier: "UTC")!
        return WidgetPushScheduler(relay: PushRelayClient(relayURL: relayURL, auth: MacPushSigner(key: P256.Signing.PrivateKey()),
                                                          transport: relay, now: { clock.date }),
                                   store: store, policy: policy, alertThreshold: { threshold },
                                   isLive: { id, _ in live.contains(id) }, now: { clock.date }, clock: clock)
    }

    @Test func pushOffMakesNoNetworkCalls() async {
        let s = scheduler(relayURL: "")
        #expect(await !s.isEnabled)
        await s.devicesChanged([mac(at: clock.date)])
        await s.devicesChanged([mac(10, plugged: true, at: clock.date)])
        await settle()
        #expect(relay.calls.isEmpty)
    }

    @Test func firstChangePushesSignedWithTheGrant() async {
        let s = scheduler()
        await s.devicesChanged([mac(80, at: clock.date)])
        #expect(relay.calls == [RecordingRelay.Call(tokens: [tokenA.token], grants: grantA, signed: true)])
    }

    @Test func changesInsideTheGapCoalesceIntoOnePushAt15Minutes() async {
        let s = scheduler()
        let t = clock.date
        await s.devicesChanged([mac(80, at: t)])
        #expect(relay.calls.count == 1)
        // Two shown, non-urgent changes inside the gap (a rename, then a level step).
        clock.advance(by: .seconds(60))
        var renamed = mac(80, at: t + 60); renamed.name = "Office Mac"
        await s.devicesChanged([renamed])
        clock.advance(by: .seconds(60))
        var moved = mac(70, at: t + 120); moved.name = "Office Mac"
        await s.devicesChanged([moved])
        #expect(relay.calls.count == 1)
        await waitFor { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(15 * 60 - 121))
        await settle()
        #expect(relay.calls.count == 1)
        clock.advance(by: .seconds(1))
        await waitFor { relay.calls.count == 2 }  // one push at the end of the gap
        // Nothing new: no more pushes.
        await s.devicesChanged([moved])
        await settle()
        #expect(relay.calls.count == 2)
    }

    @Test func plugUnplugAndAlertThresholdCrossingSkipTheGap() async {
        let s = scheduler(threshold: 30)
        let t = clock.date
        await s.devicesChanged([mac(35, at: t)])
        clock.advance(by: .seconds(5))
        await s.devicesChanged([mac(35, plugged: true, at: t + 5)])  // plugged in
        #expect(relay.calls.count == 2)
        clock.advance(by: .seconds(5))
        await s.devicesChanged([mac(35, at: t + 10)])  // unplugged
        #expect(relay.calls.count == 3)
        clock.advance(by: .seconds(5))
        await s.devicesChanged([mac(30, at: t + 15)])  // crossed the 30 % alert threshold
        #expect(relay.calls.count == 4)
        clock.advance(by: .seconds(5))
        await s.devicesChanged([mac(29, at: t + 20)])  // still below: waits for the gap
        #expect(relay.calls.count == 4)
    }

    @Test func accessoryChargingChangeIsUrgentWhenNoChargerIsReported() {
        // A record that reports charging but no charger state (an iPhone, an accessory).
        let a = DeviceBattery(id: pPhone2ID, name: "iPhone 2", kind: .iphone, level: 50, isCharging: false, updatedAt: Date())
        var b = a; b.isCharging = true
        #expect(WidgetPushScheduler.isUrgent(from: [a], to: [b], threshold: 20))
        var c = mac(50, at: Date()); c.isCharging = false
        var d = c; d.isCharging = true  // charging resumed on a plugged-in Mac: not a plug change
        c.isPluggedIn = true; d.isPluggedIn = true
        #expect(!WidgetPushScheduler.isUrgent(from: [c], to: [d], threshold: 20))
    }

    @Test func atMost48PushesPerDayThenNoneUntilMidnight() async {
        let s = scheduler()
        var plugged = false
        await s.devicesChanged([mac(80, plugged: plugged, at: clock.date)])
        for _ in 0..<60 {  // urgent changes every minute
            clock.advance(by: .seconds(60))
            plugged.toggle()
            await s.devicesChanged([mac(80, plugged: plugged, at: clock.date)])
        }
        #expect(relay.calls.count == 48)
        // Midnight UTC (the test calendar): the day's count starts again with the held change.
        let midnight = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1,
            to: { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }().startOfDay(for: clock.date))!
        await waitFor { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(Int64(midnight.timeIntervalSince(clock.date)) - 1))
        await settle()
        #expect(relay.calls.count == 48)
        clock.advance(by: .seconds(1))
        await waitFor { relay.calls.count == 49 }
    }

    @Test func ownRecordDoesNotPushItsOwnWidget() async {
        let s = scheduler()
        let t = clock.date
        await s.devicesChanged([mac(at: t), phone(50, at: t)])
        #expect(relay.calls.count == 1)
        clock.advance(by: .seconds(20 * 60))
        await s.devicesChanged([mac(at: t), phone(10, at: t + 1200)])  // only this iPhone changed
        await settle()
        #expect(relay.calls.count == 1)
    }

    @Test func eachIPhoneGetsItsOwnRequestAndGrant() async throws {
        _ = try store.setPushRegistration([tokenB], grant: grantB, expiresAt: 1_900_000_000, for: pPhone2ID)
        let s = scheduler()
        await s.devicesChanged([mac(at: clock.date)])
        #expect(Set(relay.calls.map { $0.grants ?? "" }) == [grantA, grantB])
        #expect(Set(relay.tokenCalls) == [[tokenA.token], [tokenB.token]])
    }

    @Test func noGrantRefusedGrantOrExpiredGrantMeansNoPush() async throws {
        _ = try store.setPushRegistration([tokenA], grant: nil, expiresAt: nil, for: pPhoneID)  // v1 upload
        _ = try store.setPushRegistration([tokenB], grant: grantB, expiresAt: Int64(clock.date.timeIntervalSince1970) - 1, for: pPhone2ID)
        let s = scheduler()
        await s.devicesChanged([mac(at: clock.date)])
        await settle()
        #expect(relay.calls.isEmpty)
        _ = try store.setPushRegistration([tokenA], grant: grantA, expiresAt: 1_900_000_000, for: pPhoneID)
        _ = try store.setPushNeedsGrant(for: pPhoneID)
        clock.advance(by: .seconds(60))
        await s.devicesChanged([mac(10, plugged: true, at: clock.date)])
        await settle()
        #expect(relay.calls.isEmpty)
    }

    @Test func refusedGrantStopsPushesUntilANewOne() async throws {
        relay.answer(401, body: #"{"error":"grant_expired"}"#)
        let s = scheduler()
        await s.devicesChanged([mac(80, at: clock.date)])
        #expect(relay.calls.count == 1)
        #expect(store.pushRegistrations()[pPhoneID]?.needsGrant == true)
        clock.advance(by: .seconds(60))
        await s.devicesChanged([mac(80, plugged: true, at: clock.date)])
        await settle()
        #expect(relay.calls.count == 1)
        // The iPhone sends a new grant: pushing resumes.
        _ = try store.setPushRegistration([tokenA], grant: "g1.new.grant", expiresAt: 1_900_000_000, for: pPhoneID)
        clock.advance(by: .seconds(60))
        await s.devicesChanged([mac(80, at: clock.date)])
        #expect(relay.calls.last?.grants == "g1.new.grant")
    }

    @Test func clockSkewDoesNotDropTheGrant() async {
        relay.answer(401, body: #"{"error":"timestamp_skew"}"#)
        let s = scheduler()
        await s.devicesChanged([mac(80, at: clock.date)])
        #expect(store.pushRegistrations()[pPhoneID]?.needsGrant == false)
    }

    @Test func rateLimitHoldsThatIPhoneUntilRetryAfter() async {
        relay.answer(429, headers: ["Retry-After": "120"])
        let s = scheduler()
        let t = clock.date
        await s.devicesChanged([mac(80, at: t)])
        #expect(relay.calls.count == 1)
        // Even an urgent change waits for the hold.
        clock.advance(by: .seconds(5))
        await s.devicesChanged([mac(80, plugged: true, at: t + 5)])
        #expect(relay.calls.count == 1)
        await waitFor { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(114))
        await settle()
        #expect(relay.calls.count == 1)
        clock.advance(by: .seconds(1))
        await waitFor { relay.calls.count == 2 }
    }

    @Test func goneTokensAreDroppedAndANewGrantIsAskedFor() async throws {
        relay.answer(202, body: #"{"results":[{"index":0,"status":"unregistered"}],"invalidTokens":["\#(tokenA.token)"]}"#)
        _ = try store.setPushRegistration([tokenA, PushToken(token: String(repeating: "cc", count: 32), env: .development, kind: .widget)],
                                          grant: grantA, expiresAt: 1_900_000_000, for: pPhoneID)
        let s = scheduler()
        await s.devicesChanged([mac(at: clock.date)])
        let reg = try #require(store.pushRegistrations()[pPhoneID])
        #expect(reg.tokens.map(\.token) == [String(repeating: "cc", count: 32)])
        #expect(reg.needsGrant)
        // 410: everything gone.
        _ = try store.setPushRegistration([tokenA], grant: grantA, expiresAt: 1_900_000_000, for: pPhoneID)
        relay.answer(410, body: #"{"error":"tokens_invalid"}"#)
        clock.advance(by: .seconds(5))
        await s.devicesChanged([mac(10, plugged: true, at: clock.date)])
        #expect(store.pushTokens().isEmpty)
    }

    @Test func noPushWhileThatIPhoneIsLive() async {
        live.set(pPhoneID, true)
        let s = scheduler()
        await s.devicesChanged([mac(80, at: clock.date)])
        clock.advance(by: .seconds(60))
        await s.devicesChanged([mac(80, plugged: true, at: clock.date)])
        await settle()
        #expect(relay.calls.isEmpty)
        // Back in the background: the widget already shows what the app reloaded; nothing to push.
        live.set(pPhoneID, false)
        clock.advance(by: .seconds(60))
        await s.devicesChanged([mac(80, plugged: true, at: clock.date)])
        await settle()
        #expect(relay.calls.isEmpty)
        // The next real change is pushed.
        clock.advance(by: .seconds(60))
        await s.devicesChanged([mac(80, plugged: false, at: clock.date)])
        #expect(relay.calls.count == 1)
    }

    @Test func forgottenDeviceGetsNoPush() async throws {
        let s = scheduler()
        try store.remove(pPhoneID)
        await s.devicesChanged([mac(at: clock.date)])
        await settle()
        #expect(relay.calls.isEmpty)
    }
}

@Suite("PUSH Mac grant state for GET /v1/push-key")
struct PushGrantStateTests {
    let key = PushAuthV1.publicKeyString(P256.Signing.PrivateKey().publicKey)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func grant(_ tokens: [PushToken], mac: String? = nil, exp: Int64 = 1_900_000_000) -> String {
        let t = tokens.map { "[\"\($0.kind.rawValue)\",\"\(PushAuthV1.tokenHash($0.token))\"]" }.joined(separator: ",")
        let json = #"{"v":1,"env":"\#(tokens.first?.env.rawValue ?? "development")","mac":"\#(mac ?? key)","dev":"d","t":[\#(t)],"iat":0,"exp":\#(exp)}"#
        return "g1.\(PushAuthV1.base64URL(Data(json.utf8))).AAAA"
    }

    func client(_ tokens: [PushToken], grant: String?, exp: Int64? = 1_900_000_000, refused: Bool = false) -> PairedClient {
        PairedClient(id: pPhoneID, name: "P", kind: .iphone, key: Data(repeating: 1, count: 32), pairedAt: now,
                     pushTokens: tokens, pushGrant: grant, pushGrantExpiresAt: grant == nil ? nil : exp, pushNeedsGrant: refused ? true : nil)
    }

    @Test func states() {
        #expect(HubCacheBackend.grantState(nil, macKey: key, now: now) == .none)
        #expect(HubCacheBackend.grantState(client([tokenA], grant: nil), macKey: key, now: now) == .none)
        #expect(HubCacheBackend.grantState(client([tokenA], grant: grant([tokenA])), macKey: key, now: now) == .ok)
        #expect(HubCacheBackend.grantState(client([tokenA], grant: grant([tokenA]), refused: true), macKey: key, now: now) == .renew)
        #expect(HubCacheBackend.grantState(client([tokenA], grant: grant([tokenA], mac: "old")), macKey: key, now: now) == .renew)
        #expect(HubCacheBackend.grantState(client([tokenA], grant: grant([tokenB])), macKey: key, now: now) == .renew)
        let soon = Int64(now.timeIntervalSince1970) + 6 * 86_400
        #expect(HubCacheBackend.grantState(client([tokenA], grant: grant([tokenA], exp: soon), exp: soon), macKey: key, now: now) == .renew)
    }
}

@Suite("PUSH LocalOnlySyncService reports device changes")
struct DevicesChangedHookTests {
    @Test func calledOnlyWhenDevicesChange() async {
        let clock = ManualClock()
        let seen = Mutex<[[DeviceBattery]]>([])
        let cache = SnapshotCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("levels-push-\(UUID().uuidString)"))
        let s = LocalOnlySyncService(cache: cache, widgetReloader: {}, onDevicesChanged: { d in seen.withLock { $0.append(d) } },
                                     now: { clock.date }, clock: clock)
        let t = clock.date
        await s.ingest([mac(70, at: t)], replacingAllExcept: nil)
        await s.ingest([mac(70, at: t)], replacingAllExcept: nil)  // same: no call
        await s.removeLocal(pMacID)
        #expect(seen.withLock { $0 }.map(\.count) == [1, 0])
    }
}
