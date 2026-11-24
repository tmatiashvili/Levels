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

    func rig(limits: HubListener.Limits = .standard) async throws -> Rig {
        let store = InMemoryHubPairingStore([PairedClient(id: phoneID, name: "My iPhone", kind: .iphone,
                                                          key: Self.phoneKey.withUnsafeBytes { Data($0) }, pairedAt: t0)])
        let window = PairingWindow(store: store)
        let backend = FakeBackend(devices: [macRecord()], window: window)
        let events = EventLog()
        let listener = HubListener(router: HubRouter(backend: backend), keyring: HubKeyring(store: store, window: window),
                                   loopbackOnly: true, limits: limits, events: { e in events.append(e) })
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

    /// Only "unknown key or identity" TLS answers mean the Mac forgot this iPhone; a closed or
    /// aborted handshake is "not reachable" (it used to show "Forgot this iPhone").
    @Test func onlyRefusalTLSStatusesMapToHandshakeRefused() {
        for status: OSStatus in [-9864, -9820, -9846, -9824] {
            #expect(HubClientConnection.map(.tls(status)) == .handshakeRefused)
        }
        for status: OSStatus in [-9806, -9816, -9800] {
            #expect(HubClientConnection.map(.tls(status)) == .notReady)
        }
        #expect(HubClientConnection.map(.posix(.ECONNRESET)) == .notReady)
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

    /// `reload()` reports whether the listener runs with the current keys, so the app never
    /// shows "sharing" (or answers a pairing confirm) while it is down.
    @Test func reloadReportsWhetherTheListenerRuns() async throws {
        let rig = try await rig()
        #expect(await rig.listener.reload())
        let newID = DeviceID(UUID())
        try rig.store.save(PairedClient(id: newID, name: "iPad", kind: .iphone, key: Data(repeating: 3, count: 32), pairedAt: t0))
        #expect(await rig.listener.reload())  // rebuilt with the new key
        let c = try await connect(rig, identity: newID.recordName, key: SymmetricKey(data: Data(repeating: 3, count: 32))).get()
        c.close()
        await rig.listener.stop()
        #expect(await rig.listener.reload() == false)
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

extension TLSLoopbackTests {
    /// R12a: half-open TCP connections that never send a ClientHello are closed at the
    /// handshake deadline, and while they wait they use only the pending budget, not the
    /// authenticated slots.
    @Test func R12a_handshakeDeadlineFreesSlots() async throws {
        let rig = try await rig(limits: .init(maxPendingHandshakes: 2, handshakeTimeout: .milliseconds(600)))
        let authenticated = try await connect(rig, identity: phoneID.recordName, key: Self.phoneKey).get()
        let raws = [RawTCP(port: rig.port), RawTCP(port: rig.port)]
        for raw in raws { #expect(await raw.open()) }
        await waitFor { await rig.listener.connectionCount == 3 }
        // The pending budget is full: a new handshake is refused …
        #expect(await connect(rig, identity: phoneID.recordName, key: Self.phoneKey).failure != nil)
        #expect(rig.events.withLock { $0 }.contains(.connectionRefused))
        // … but the authenticated connection keeps working.
        #expect(try await authenticated.exchange(HTTPRequest(method: "GET", path: "/v1/snapshot"), timeout: .seconds(5)).status == 200)
        // At the deadline the half-open ones are closed and new handshakes get through.
        await waitFor(timeout: .seconds(3)) { await rig.listener.connectionCount == 1 }
        for raw in raws { await waitFor { raw.isClosed } }
        let fresh = try await connect(rig, identity: phoneID.recordName, key: Self.phoneKey).get()
        #expect(try await fresh.exchange(HTTPRequest(method: "GET", path: "/v1/snapshot"), timeout: .seconds(5)).status == 200)
        authenticated.close()
        fresh.close()
        await rig.listener.stop()
    }

    /// R12a: with every pending slot taken, the 4 authenticated slots are still there.
    @Test func R12a_pendingHandshakesDontTakeAuthenticatedSlots() async throws {
        let rig = try await rig(limits: .init(maxPendingHandshakes: 1, handshakeTimeout: .seconds(30)))
        var open: [HubClientConnection] = []
        for _ in 0..<3 { open.append(try await connect(rig, identity: phoneID.recordName, key: Self.phoneKey).get()) }
        let raw = RawTCP(port: rig.port)
        #expect(await raw.open())
        await waitFor { await rig.listener.connectionCount == 4 }
        // One half-open connection holds the one pending slot; the server refuses more raw ones.
        let second = RawTCP(port: rig.port)
        _ = await second.open()
        await waitFor { second.isClosed }
        raw.close()
        await waitFor { await rig.listener.connectionCount == 3 }
        // The 4th authenticated connection still fits.
        open.append(try await connect(rig, identity: phoneID.recordName, key: Self.phoneKey).get())
        await waitFor { await rig.listener.connectionCount == 4 }
        for c in open { c.close() }
        await rig.listener.stop()
    }

    /// R6: the buffer is bounded while a request is in flight. A held long-poll plus more
    /// than `maxHeader + maxBody` bytes closes the connection.
    @Test func R6_bufferCapClosesTheConnection() async throws {
        let rig = try await rig()
        let probe = try await connect(rig, identity: phoneID.recordName, key: Self.phoneKey).get()
        let etag = try await probe.exchange(HTTPRequest(method: "GET", path: "/v1/snapshot"), timeout: .seconds(5)).header("etag")!
        probe.close()
        let raw = RawTLS(port: rig.port, identity: phoneID.recordName, key: Self.phoneKey)
        #expect(await raw.open())
        await waitFor { await rig.listener.connectionCount == 1 }
        // A long-poll the server holds for 25 s …
        raw.send(HTTPCodec.serialize(HTTPRequest(method: "GET", path: "/v1/snapshot", query: ["wait": "25"],
                                                 headers: ["if-none-match": etag])))
        try await Task.sleep(for: .milliseconds(200))
        // … then a flood while it is in flight.
        // 64 KB stays under the 72 KB cap (maxHeader + maxBody) …
        for _ in 0..<8 { raw.send(Data(repeating: 0x41, count: 8 * 1024)) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await rig.listener.connectionCount == 1 && !raw.isClosed)
        // … 80 KB goes over it.
        for _ in 0..<2 { raw.send(Data(repeating: 0x41, count: 8 * 1024)) }
        await waitFor(timeout: .seconds(3)) { await rig.listener.connectionCount == 0 }
        await waitFor { raw.isClosed }
        await rig.listener.stop()
    }
}

/// A plain TCP connection that never starts TLS (a half-open handshake).
final class RawTCP: @unchecked Sendable {
    let connection: NWConnection
    private let closed = Mutex(false)
    init(port: UInt16, parameters: NWParameters = .tcp) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    }

    var isClosed: Bool { closed.withLock { $0 } }

    /// Waits until ready; `false` on failure. Then watches for the server closing it.
    func open() async -> Bool {
        let ok: Bool = await withCheckedContinuation { c in
            let once = Mutex<CheckedContinuation<Bool, Never>?>(c)
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: once.withLock { $0.take() }?.resume(returning: true)
                case .failed, .cancelled:
                    self?.closed.withLock { $0 = true }
                    once.withLock { $0.take() }?.resume(returning: false)
                default: break
                }
            }
            connection.start(queue: .global())
        }
        if ok { watch() }
        return ok
    }

    private func watch() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.closed.withLock { $0 = true }
                self.connection.cancel()
                return
            }
            self.watch()
        }
    }

    func send(_ data: Data) { connection.send(content: data, completion: .idempotent) }
    func close() { connection.cancel() }
}

/// A TLS-PSK client connection that sends raw bytes.
final class RawTLS: @unchecked Sendable {
    let raw: RawTCP
    init(port: UInt16, identity: String, key: SymmetricKey) {
        raw = RawTCP(port: port, parameters: NWParameters(tls: HubTLS.clientOptions(identity: identity, key: key), tcp: .init()))
    }
    var isClosed: Bool { raw.isClosed }
    func open() async -> Bool { await raw.open() }
    func send(_ data: Data) { raw.send(data) }
}

extension Result {
    var failure: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
