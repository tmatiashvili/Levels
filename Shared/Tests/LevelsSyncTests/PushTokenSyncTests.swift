import Foundation
import LevelsModel
import LevelsNet
import Synchronization
import Testing
@testable import LevelsSync

private let sMacID = DeviceID(UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000C1")!)
private let sPhoneID = DeviceID(UUID(uuidString: "BBBBBBBB-0000-0000-0000-0000000000C2")!)
private let sHubID = UUID(uuidString: "C0FFEE00-0000-4000-8000-0000000000C3")!
private let sToken = PushToken(token: String(repeating: "ab", count: 32), env: .development, kind: .widget)
private let sToken2 = PushToken(token: String(repeating: "cd", count: 32), env: .development, kind: .widget)

/// Answers the hub routes without a network and records every request.
final class ScriptedHub: HubTransport {
    struct State {
        var requests: [HTTPRequest] = []
        var pushStatus = 204
        var reachable = true
        /// `nil` = 404 (older Mac or push off).
        var pushKey: PushKeyAnswer? = PushKeyAnswer(macKey: "MACKEY", grant: .none)
    }
    private let state = Mutex(State())
    var requests: [HTTPRequest] { state.withLock { $0.requests } }
    var puts: [PushTokenUpload] {
        requests.filter { $0.path == HubProtocol.Path.pushTokens }
            .compactMap { try? HubWire.decoder().decode(PushTokenUpload.self, from: $0.body) }
    }
    var keyReads: Int { requests.filter { $0.path == HubProtocol.Path.pushKey }.count }
    func setPushStatus(_ s: Int) { state.withLock { $0.pushStatus = s } }
    func setReachable(_ r: Bool) { state.withLock { $0.reachable = r } }
    func setPushKey(_ k: PushKeyAnswer?) { state.withLock { $0.pushKey = k } }

    func send(_ request: HTTPRequest, to pairing: HubPairing, me: DeviceID, timeout: Duration) async throws(HubError) -> HTTPResponse {
        let s = state.withLock { s in
            if s.reachable { s.requests.append(request) }
            return s
        }
        guard s.reachable else { throw .notFound }
        switch request.path {
        case HubProtocol.Path.snapshot:
            let devices = [DeviceBattery(id: sMacID, name: "Mac", kind: .mac, level: 80, isCharging: false, updatedAt: Date())]
            let snap = HubSnapshot(hubID: sHubID, hubDeviceID: sMacID, generatedAt: Date(), devices: devices)
            return HTTPResponse(status: 200, headers: ["etag": HubWire.etag(for: devices)], body: try! HubWire.encoder().encode(snap))
        case HubProtocol.Path.pushKey:
            guard let key = s.pushKey else { return HTTPResponse(status: 404) }
            return HTTPResponse(status: 200, body: try! HubWire.encoder().encode(key))
        case HubProtocol.Path.pushTokens:
            return HTTPResponse(status: s.pushStatus)
        default:
            return HTTPResponse(status: 204)
        }
    }
}

/// Tokens from a box; grants counted, `forceNew` recorded.
final class FakePushSource: PushRegistrationSource {
    struct State { var tokens: [PushToken] = []; var available = true; var asks: [Bool] = []; var minted = 0 }
    let state = Mutex(State())
    func set(_ t: [PushToken]) { state.withLock { $0.tokens = t } }
    func setAvailable(_ a: Bool) { state.withLock { $0.available = a } }
    var asks: [Bool] { state.withLock { $0.asks } }
    func tokens() async -> [PushToken] { state.withLock { $0.tokens } }
    func grant(for tokens: [PushToken], macKey: String, forceNew: Bool) async -> PushGrant? {
        state.withLock { s in
            s.asks.append(forceNew)
            guard s.available else { return nil }
            s.minted += 1
            return PushGrant(grant: "g1.\(macKey).\(s.minted)", env: .development, expiresAt: 1_900_000_000)
        }
    }
}

final class DateBox: Sendable {
    private let d = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var value: Date { d.withLock { $0 } }
    func advance(_ s: TimeInterval) { d.withLock { $0 += s } }
}

@Suite("PUSH iPhone sends its tokens and grant to the Mac (R72)")
struct PushTokenSyncTests {
    let hub = ScriptedHub()
    let source = FakePushSource()
    let date = DateBox()

    func service(pushOn: Bool = true) -> LocalNetworkSyncService {
        let cache = SnapshotCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("levels-pts-\(UUID().uuidString)"))
        let local = LocalOnlySyncService(cache: cache, widgetReloader: {})
        let pairing = InMemoryClientPairingStore(HubPairing(hubID: sHubID, hubTag: "c0ff", hubDeviceID: sMacID, hubName: "Mac",
                                                            key: Data(repeating: 7, count: 32), pairedAt: Date()))
        let date = date
        return LocalNetworkSyncService(local: local, outbox: HubOutbox(), transport: hub, pairing: pairing,
                                       identity: FixedDeviceIdentity(sPhoneID), cache: cache, persistsETag: false,
                                       now: { date.value }, push: pushOn ? source : nil)
    }

    @Test func pushOffNeverSendsTokens() async {
        source.set([sToken])
        let s = service(pushOn: false)
        await s.refresh(.userPull)
        await s.refresh(.userPull)
        #expect(hub.puts.isEmpty)
        #expect(hub.keyReads == 0)
        #expect(!hub.requests.isEmpty)  // the snapshot fetch still happened
    }

    @Test func noTokenYetSendsNothing() async {
        let s = service()
        await s.refresh(.userPull)
        #expect(hub.puts.isEmpty)
        #expect(hub.keyReads == 0)
    }

    @Test func sendsTokensWithAGrantOnConnectAndOnChangeOnly() async {
        source.set([sToken])
        let s = service()
        await s.refresh(.userPull)
        await s.refresh(.userPull)
        #expect(hub.puts == [PushTokenUpload(tokens: [sToken], grant: "g1.MACKEY.1", grantExpiresAt: 1_900_000_000)])
        source.set([sToken2])
        await s.refresh(.userPull)
        #expect(hub.puts.last?.tokens == [sToken2])
        #expect(hub.puts.count == 2)
        // A new connection (scene went to the background) sends them again.
        await s.startLiveUpdates()
        await s.stopLiveUpdates()
        let before = hub.puts.count
        await s.refresh(.userPull)
        #expect(hub.puts.count == before + 1)
        #expect(source.asks.allSatisfy { !$0 })  // the Mac never asked for a new one
    }

    @Test func clearsTheMacsTokensWhenTheWidgetIsGone() async {
        source.set([sToken])
        let s = service()
        await s.refresh(.userPull)
        source.set([])
        await s.refresh(.userPull)
        #expect(hub.puts.last == PushTokenUpload(tokens: []))
    }

    @Test func renewFromTheMacForcesANewGrant() async {
        source.set([sToken])
        let s = service()
        await s.refresh(.userPull)
        hub.setPushKey(PushKeyAnswer(macKey: "MACKEY", grant: .renew))
        date.advance(LocalNetworkSyncService.pushKeyCheckInterval - 1)
        await s.refresh(.userPull)
        #expect(hub.puts.count == 1)  // not asked yet
        date.advance(1)
        await s.refresh(.userPull)
        #expect(hub.puts.count == 2)
        #expect(source.asks == [false, true])
    }

    @Test func okFromTheMacNeedsNoNewGrant() async {
        source.set([sToken])
        let s = service()
        await s.refresh(.userPull)
        hub.setPushKey(PushKeyAnswer(macKey: "MACKEY", grant: .ok))
        date.advance(LocalNetworkSyncService.pushKeyCheckInterval)
        await s.refresh(.userPull)
        #expect(hub.puts.count == 1)
        #expect(hub.keyReads == 2)
    }

    @Test func newMacKeyGetsANewGrant() async {
        source.set([sToken])
        let s = service()
        await s.refresh(.userPull)
        hub.setPushKey(PushKeyAnswer(macKey: "NEWKEY", grant: .ok))
        date.advance(LocalNetworkSyncService.pushKeyCheckInterval)
        await s.refresh(.userPull)
        #expect(hub.puts.last?.grant == "g1.NEWKEY.2")
    }

    @Test func olderMacIsAskedOnceAndNeverSentV2() async {
        hub.setPushKey(nil)
        source.set([sToken])
        let s = service()
        await s.refresh(.userPull)
        source.set([sToken2])
        await s.refresh(.userPull)
        #expect(hub.puts.isEmpty)
        #expect(hub.keyReads == 1)
    }

    @Test func noGrantNoUploadThenRetried() async {
        source.setAvailable(false)
        source.set([sToken])
        let s = service()
        await s.refresh(.userPull)
        #expect(hub.puts.isEmpty)
        source.setAvailable(true)
        await s.refresh(.userPull)
        #expect(hub.puts.count == 1)
    }

    @Test func refusedGrantGetsANewOneNextTime() async {
        hub.setPushStatus(400)
        source.set([sToken])
        let s = service()
        await s.refresh(.userPull)
        hub.setPushStatus(204)
        await s.refresh(.userPull)
        #expect(source.asks == [false, true])
        #expect(hub.puts.count == 2)
    }

    @Test func resendsAfterTheMacWasAway() async {
        source.set([sToken])
        let s = service()
        await s.refresh(.userPull)
        hub.setReachable(false)
        await s.refresh(.userPull)
        hub.setReachable(true)
        await s.refresh(.userPull)
        #expect(hub.puts.count == 2)
    }

    @Test func failedSendIsRetried() async {
        hub.setPushStatus(503)
        source.set([sToken])
        let s = service()
        await s.refresh(.userPull)
        hub.setPushStatus(204)
        await s.refresh(.userPull)
        await s.refresh(.userPull)
        #expect(hub.puts.count == 2)
    }
}
