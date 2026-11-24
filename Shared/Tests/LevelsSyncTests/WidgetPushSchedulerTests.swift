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

private func mac(_ level: Int = 80, plugged: Bool = false, at: Date) -> DeviceBattery {
    DeviceBattery(id: pMacID, name: "Mac", kind: .mac, level: level, isCharging: plugged, isPluggedIn: plugged, updatedAt: at)
}

private func phone(_ level: Int = 50, id: DeviceID = pPhoneID, at: Date) -> DeviceBattery {
    DeviceBattery(id: id, name: "iPhone", kind: .iphone, level: level, isCharging: false, updatedAt: at)
}

/// A relay transport recording which tokens each request carried.
final class RecordingRelay: PushRelayTransport {
    private let state = Mutex<(calls: [[String]], answers: [(Int, [String: String], Data)])>(([], []))
    var calls: [[String]] { state.withLock { $0.calls } }
    func answer(_ status: Int, headers: [String: String] = [:], body: String = "") {
        state.withLock { $0.answers.append((status, headers, Data(body.utf8))) }
    }
    func post(url: URL, headers: [String: String], body: Data) async throws -> (status: Int, headers: [String: String], body: Data) {
        let decoded = try JSONDecoder().decode(PushRelayBody.self, from: body)
        return state.withLock { s in
            s.calls.append(decoded.tokens.map(\.token))
            return s.answers.isEmpty ? (202, [:], Data()) : s.answers.removeFirst()
        }
    }
}

@Suite("PUSH WidgetPushScheduler (coalescing, backoff, gone tokens)")
struct WidgetPushSchedulerTests {
    let clock = ManualClock()
    let relay = RecordingRelay()
    let store: InMemoryHubPairingStore

    init() throws {
        store = InMemoryHubPairingStore([
            PairedClient(id: pPhoneID, name: "iPhone", kind: .iphone, key: Data(repeating: 1, count: 32), pairedAt: Date()),
            PairedClient(id: pPhone2ID, name: "iPhone 2", kind: .iphone, key: Data(repeating: 2, count: 32), pairedAt: Date()),
        ])
        _ = try store.setPushTokens([tokenA], for: pPhoneID)
    }

    func scheduler(relayURL: String = "https://relay.example") -> WidgetPushScheduler {
        let clock = clock
        return WidgetPushScheduler(relay: PushRelayClient(relayURL: relayURL, transport: relay), store: store,
                                   now: { clock.date }, clock: clock)
    }

    @Test func pushOffMakesNoNetworkCalls() async {
        let s = scheduler(relayURL: "")
        #expect(await !s.isEnabled)
        await s.devicesChanged([mac(at: clock.date)])
        await s.devicesChanged([mac(10, plugged: true, at: clock.date)])
        await settle()
        #expect(relay.calls.isEmpty)
    }

    @Test func firstChangePushesThenCoalescesTo60s() async {
        let s = scheduler()
        let t = clock.date
        await s.devicesChanged([mac(80, at: t)])
        #expect(relay.calls == [[tokenA.token]])
        // A name change (shown, not urgent) 10 s later waits for the 60 s window.
        clock.advance(by: .seconds(10))
        var renamed = mac(80, at: t + 10); renamed.name = "Office Mac"
        await s.devicesChanged([renamed])
        #expect(relay.calls.count == 1)
        await waitFor { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(49))
        await settle()
        #expect(relay.calls.count == 1)
        clock.advance(by: .seconds(1))
        await waitFor { relay.calls.count == 2 }
        // Nothing new: no more pushes.
        await s.devicesChanged([renamed])
        await settle()
        #expect(relay.calls.count == 2)
    }

    @Test func chargerChangeAndCrossing20ArePushedAtOnce() async {
        let s = scheduler()
        let t = clock.date
        await s.devicesChanged([mac(25, at: t)])
        clock.advance(by: .seconds(5))
        await s.devicesChanged([mac(25, plugged: true, at: t + 5)])  // plugged in
        #expect(relay.calls.count == 2)
        clock.advance(by: .seconds(5))
        await s.devicesChanged([mac(25, at: t + 10)])  // unplugged
        #expect(relay.calls.count == 3)
        clock.advance(by: .seconds(5))
        await s.devicesChanged([mac(20, at: t + 15)])  // crossed 20 %
        #expect(relay.calls.count == 4)
    }

    @Test func smallLevelMovesWaitFiveMinutes() async {
        let s = scheduler()
        let t = clock.date
        await s.devicesChanged([mac(80, at: t)])
        clock.advance(by: .seconds(90))
        await s.devicesChanged([mac(79, at: t + 90)])
        #expect(relay.calls.count == 1)  // levelOnly: due at t + 300
        await waitFor { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(209))
        await settle()
        #expect(relay.calls.count == 1)
        clock.advance(by: .seconds(1))
        await waitFor { relay.calls.count == 2 }
    }

    @Test func ownRecordDoesNotPushItsOwnWidget() async {
        let s = scheduler()
        let t = clock.date
        await s.devicesChanged([mac(at: t), phone(50, at: t)])
        #expect(relay.calls.count == 1)
        clock.advance(by: .seconds(120))
        await s.devicesChanged([mac(at: t), phone(10, at: t + 120)])  // only this iPhone changed
        await settle()
        #expect(relay.calls.count == 1)
    }

    @Test func eachTokenOfSeveralPhonesIsBatched() async throws {
        _ = try store.setPushTokens([tokenB], for: pPhone2ID)
        let s = scheduler()
        await s.devicesChanged([mac(at: clock.date)])
        #expect(relay.calls.count == 1)
        #expect(Set(relay.calls[0]) == [tokenA.token, tokenB.token])
    }

    @Test func rateLimitHoldsUntilRetryAfter() async {
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

    @Test func goneTokensAreDroppedFromTheStore() async throws {
        _ = try store.setPushTokens([tokenB], for: pPhone2ID)
        relay.answer(202, body: #"{"invalidTokens":["\#(tokenB.token)"]}"#)
        let s = scheduler()
        await s.devicesChanged([mac(at: clock.date)])
        #expect(store.pushTokens() == [pPhoneID: [tokenA]])
        relay.answer(410)
        clock.advance(by: .seconds(5))
        await s.devicesChanged([mac(10, plugged: true, at: clock.date)])
        #expect(store.pushTokens().isEmpty)
        clock.advance(by: .seconds(5))
        await s.devicesChanged([mac(80, at: clock.date)])
        await settle()
        #expect(relay.calls.count == 2)  // nobody left to push
    }

    @Test func forgottenDeviceGetsNoPush() async throws {
        let s = scheduler()
        try store.remove(pPhoneID)
        await s.devicesChanged([mac(at: clock.date)])
        await settle()
        #expect(relay.calls.isEmpty)
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
