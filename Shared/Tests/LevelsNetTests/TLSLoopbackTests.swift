import CryptoKit
import Foundation
import LevelsModel
import Network
import Synchronization
import Testing
@testable import LevelsNet

/// NET-001 AC1 (in part) on loopback: real `NWListener` and `NWConnection` with TLS-PSK.
@Suite("NET-001 TLS-PSK on loopback (R5, R12)", .serialized)
struct TLSLoopbackTests {
    struct Rig {
        let listener: HubListener
        let port: UInt16
        let store: InMemoryHubPairingStore
        let window: PairingWindow
        let events: EventLog
    }

    final class EventLog: Sendable {
        private let m = Mutex<[HubListener.Event]>([])
        func append(_ e: HubListener.Event) { m.withLock { $0.append(e) } }
        func withLock<T: Sendable>(_ body: (inout [HubListener.Event]) -> T) -> T { m.withLock { body(&$0) } }
    }

    static let phoneKey = SymmetricKey(data: Data(repeating: 0xA1, count: 32))

    func rig() async throws -> Rig {
        let store = InMemoryHubPairingStore([PairedClient(id: phoneID, name: "My iPhone", kind: .iphone,
                                                          key: Self.phoneKey.withUnsafeBytes { Data($0) }, pairedAt: t0)])
        let window = PairingWindow(store: store)
        let backend = FakeBackend(devices: [macRecord()], window: window)
        let events = EventLog()
        let listener = HubListener(router: HubRouter(backend: backend), keyring: HubKeyring(store: store, window: window),
                                   loopbackOnly: true, events: { e in events.append(e) })
        let port = try await listener.start()
        return Rig(listener: listener, port: port, store: store, window: window, events: events)
    }

    func connect(_ rig: Rig, identity: String, key: SymmetricKey) async -> Result<HubClientConnection, HubError> {
        let c = HubClientConnection(endpoint: FixedHubLocator(loopbackPort: rig.port).endpoint, identity: identity, key: key)
        do {
            try await c.open(timeout: .seconds(5))
            return .success(c)
        } catch {
            return .failure(error)
        }
    }

    @Test func AC1_rightKeyConnectsAndServesHTTP() async throws {
        let rig = try await rig()
        let c = try await connect(rig, identity: phoneID.recordName, key: Self.phoneKey).get()
        let response = try await c.exchange(HTTPRequest(method: "GET", path: "/v1/snapshot"), timeout: .seconds(5))
        #expect(response.status == 200)
        // Keep-alive: a second request on the same connection.
        let again = try await c.exchange(HTTPRequest(method: "GET", path: "/v1/snapshot",
                                                     headers: ["if-none-match": response.header("etag")!]), timeout: .seconds(5))
        #expect(again.status == 304)
        #expect(rig.events.withLock { $0 }.contains(.handshakeSucceeded(.device(phoneID))))
        c.close()
        await rig.listener.stop()
    }

    @Test func AC1_wrongKeyFailsOnBothSides() async throws {
        let rig = try await rig()
        let result = await connect(rig, identity: phoneID.recordName, key: SymmetricKey(data: Data(repeating: 0xB2, count: 32)))
        #expect(result.failure == .handshakeRefused)
        await waitFor { rig.events.withLock { $0 }.contains(.handshakeFailed(identity: phoneID.recordName)) }
        await rig.listener.stop()
    }

    @Test func AC1_unknownIdentityFails() async throws {
        let rig = try await rig()
        #expect(await connect(rig, identity: otherPhoneID.recordName, key: Self.phoneKey).failure == .handshakeRefused)
        #expect(await connect(rig, identity: "pair", key: Self.phoneKey).failure == .handshakeRefused)  // window closed
        await rig.listener.stop()
    }

    @Test func NET002_AC10_wrongCodeCountsOneFailure() async throws {
        let rig = try await rig()
        let code = rig.window.open(hub: hubInfo)
        await rig.listener.reload()
        let wrong = code == "000000" ? "000001" : "000000"
        #expect(await connect(rig, identity: "pair", key: PairingCrypto.codeKey(code: wrong, hubTag: "ab12")).failure == .handshakeRefused)
        await waitFor {
            if case .open(_, _, 1) = rig.window.state { return true }
            return false
        }
        let right = try await connect(rig, identity: "pair", key: PairingCrypto.codeKey(code: code, hubTag: "ab12")).get()
        right.close()
        await rig.listener.stop()
    }

    @Test func R5_removedDeviceIsRefusedWithoutRebuild() async throws {
        let rig = try await rig()
        try rig.store.remove(phoneID)  // the selection block checks the store live
        #expect(await connect(rig, identity: phoneID.recordName, key: Self.phoneKey).failure == .handshakeRefused)
        await rig.listener.stop()
    }

    @Test func R12_fifthConnectionIsDropped() async throws {
        let rig = try await rig()
        var open: [HubClientConnection] = []
        for _ in 0..<4 { open.append(try await connect(rig, identity: phoneID.recordName, key: Self.phoneKey).get()) }
        await waitFor { await rig.listener.connectionCount == 4 }
        let fifth = await connect(rig, identity: phoneID.recordName, key: Self.phoneKey)
        #expect(fifth.failure != nil)
        #expect(rig.events.withLock { $0 }.contains(.connectionRefused))
        for c in open { c.close() }
        await rig.listener.stop()
    }

    @Test func R6_malformedRequestGets400AndCloses() async throws {
        let rig = try await rig()
        let c = try await connect(rig, identity: phoneID.recordName, key: Self.phoneKey).get()
        let raw = HTTPRequest(method: "GET", path: "/v1/snapshot", headers: ["transfer-encoding": "chunked"])
        let response = try await c.exchange(raw, timeout: .seconds(5))
        #expect(response.status == 400)
        await rig.listener.stop()
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
