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
    private let state = Mutex<(requests: [HTTPRequest], pushStatus: Int, reachable: Bool)>(([], 204, true))
    var requests: [HTTPRequest] { state.withLock { $0.requests } }
    var puts: [PushTokenUpload] {
        requests.filter { $0.path == HubProtocol.Path.pushTokens }
            .compactMap { try? HubWire.decoder().decode(PushTokenUpload.self, from: $0.body) }
    }
    func setPushStatus(_ s: Int) { state.withLock { $0.pushStatus = s } }
    func setReachable(_ r: Bool) { state.withLock { $0.reachable = r } }

    func send(_ request: HTTPRequest, to pairing: HubPairing, me: DeviceID, timeout: Duration) async throws(HubError) -> HTTPResponse {
        let (reachable, pushStatus) = state.withLock { s in
            if s.reachable { s.requests.append(request) }
            return (s.reachable, s.pushStatus)
        }
        guard reachable else { throw .notFound }
        switch request.path {
        case HubProtocol.Path.snapshot:
            let devices = [DeviceBattery(id: sMacID, name: "Mac", kind: .mac, level: 80, isCharging: false, updatedAt: Date())]
            let snap = HubSnapshot(hubID: sHubID, hubDeviceID: sMacID, generatedAt: Date(), devices: devices)
            return HTTPResponse(status: 200, headers: ["etag": HubWire.etag(for: devices)], body: try! HubWire.encoder().encode(snap))
        case HubProtocol.Path.pushTokens:
            return HTTPResponse(status: pushStatus)
        default:
            return HTTPResponse(status: 204)
        }
    }
}

final class TokenBox: Sendable {
    private let tokens = Mutex<[PushToken]>([])
    func set(_ t: [PushToken]) { tokens.withLock { $0 = t } }
    var value: [PushToken] { tokens.withLock { $0 } }
}

@Suite("PUSH iPhone sends its tokens to the Mac")
struct PushTokenSyncTests {
    let hub = ScriptedHub()
    let box = TokenBox()

    func service(pushOn: Bool = true) -> LocalNetworkSyncService {
        let cache = SnapshotCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("levels-pts-\(UUID().uuidString)"))
        let local = LocalOnlySyncService(cache: cache, widgetReloader: {})
        let pairing = InMemoryClientPairingStore(HubPairing(hubID: sHubID, hubTag: "c0ff", hubDeviceID: sMacID, hubName: "Mac",
                                                            key: Data(repeating: 7, count: 32), pairedAt: Date()))
        let box = box
        return LocalNetworkSyncService(local: local, outbox: HubOutbox(), transport: hub, pairing: pairing,
                                       identity: FixedDeviceIdentity(sPhoneID), cache: cache, persistsETag: false,
                                       pushTokens: pushOn ? { @Sendable in box.value } : nil)
    }

    @Test func pushOffNeverSendsTokens() async {
        box.set([sToken])
        let s = service(pushOn: false)
        await s.refresh(.userPull)
        await s.refresh(.userPull)
        #expect(hub.puts.isEmpty)
        #expect(!hub.requests.isEmpty)  // the snapshot fetch still happened
    }

    @Test func noTokenYetSendsNothing() async {
        let s = service()
        await s.refresh(.userPull)
        #expect(hub.puts.isEmpty)
    }

    @Test func sendsOnConnectAndOnChangeOnly() async {
        box.set([sToken])
        let s = service()
        await s.refresh(.userPull)
        await s.refresh(.userPull)
        #expect(hub.puts == [PushTokenUpload(tokens: [sToken])])
        box.set([sToken2])
        await s.refresh(.userPull)
        #expect(hub.puts.last == PushTokenUpload(tokens: [sToken2]))
        #expect(hub.puts.count == 2)
        // A new connection (scene went to the background) sends them again.
        await s.startLiveUpdates()
        await s.stopLiveUpdates()
        let before = hub.puts.count
        await s.refresh(.userPull)
        #expect(hub.puts.count == before + 1)
    }

    @Test func resendsAfterTheMacWasAway() async {
        box.set([sToken])
        let s = service()
        await s.refresh(.userPull)
        hub.setReachable(false)
        await s.refresh(.userPull)
        hub.setReachable(true)
        await s.refresh(.userPull)
        #expect(hub.puts.count == 2)
    }

    @Test func olderMacIsAskedOnce() async {
        hub.setPushStatus(404)
        box.set([sToken])
        let s = service()
        await s.refresh(.userPull)
        box.set([sToken2])
        await s.refresh(.userPull)
        #expect(hub.puts.count == 1)
    }

    @Test func failedSendIsRetried() async {
        hub.setPushStatus(503)
        box.set([sToken])
        let s = service()
        await s.refresh(.userPull)
        hub.setPushStatus(204)
        await s.refresh(.userPull)
        await s.refresh(.userPull)
        #expect(hub.puts.count == 2)
    }
}
