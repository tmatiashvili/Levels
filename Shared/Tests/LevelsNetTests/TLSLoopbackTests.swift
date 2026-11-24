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

    /// R12 (lead's call 31): 3 per paired device plus 3, so with one device the 7th drops.
    @Test func R12_connectionOverTheLimitIsDropped() async throws {
        let rig = try await rig()
        #expect(await rig.listener.maxConnections == 6)
        var open: [HubClientConnection] = []
        for _ in 0..<6 { open.append(try await connect(rig, identity: phoneID.recordName, key: Self.phoneKey).get()) }
        await waitFor { await rig.listener.connectionCount == 6 }
        let seventh = await connect(rig, identity: phoneID.recordName, key: Self.phoneKey)
        #expect(seventh.failure != nil)
        #expect(rig.events.withLock { $0 }.contains(.connectionRefused))
        for c in open { c.close() }
        await rig.listener.stop()
    }

    /// R12: the limit follows the key set at each rebuild.
    @Test func R12_limitGrowsWithPairedDevices() async throws {
        let rig = try await rig()
        for n in 0..<3 {
            try rig.store.save(PairedClient(id: DeviceID(UUID()), name: "iPad \(n)", kind: .ipad,
                                            key: Data(repeating: UInt8(n + 3), count: 32), pairedAt: t0))
        }
        #expect(await rig.listener.reload())
        #expect(await rig.listener.maxConnections == 15)
        // The pairing session uses the spare slots, not a device's.
        _ = rig.window.open(hub: hubInfo)
        #expect(await rig.listener.reload())
        #expect(await rig.listener.maxConnections == 15)
        rig.window.close()
        try rig.store.removeAll()
        #expect(await rig.listener.reload())
        #expect(await rig.listener.maxConnections == 3)
        await rig.listener.stop()
    }

    @Test func R12_limitIsThreePerDeviceCappedPlusThree() {
        let limits = HubListener.Limits.standard
        #expect(limits.maxConnections(devices: 0) == 3)
        #expect(limits.maxConnections(devices: 1) == 6)
        #expect(limits.maxConnections(devices: 4) == 15)
        #expect(limits.maxConnections(devices: 9) == 15)  // never more than maxPairedDevices count
    }

    /// R5: the identity is checked again when the handshake completes. A device removed
    /// between the selection block and `.ready` is closed and never served.
    @Test func R5_deviceRemovedDuringHandshakeIsClosedAtReady() async throws {
        let inner = InMemoryHubPairingStore([PairedClient(id: phoneID, name: "My iPhone", kind: .iphone,
                                                          key: Self.phoneKey.withUnsafeBytes { Data($0) }, pairedAt: t0)])
        // The first live check (the selection block) passes; the one at `.ready` sees it gone.
        let store = RevokingStore(inner, allowedLookups: 1)
        let window = PairingWindow(store: store)
        let events = EventLog()
        let listener = HubListener(router: HubRouter(backend: FakeBackend(devices: [macRecord()], window: window)),
                                   keyring: HubKeyring(store: store, window: window), loopbackOnly: true,
                                   events: { e in events.append(e) })
        let port = try await listener.start()
        let c = HubClientConnection(endpoint: FixedHubLocator(loopbackPort: port).endpoint,
                                    identity: phoneID.recordName, key: Self.phoneKey)
        let served: Bool
        do {
            try await c.open(timeout: .seconds(5))
            served = (try? await c.exchange(HTTPRequest(method: "GET", path: "/v1/snapshot"), timeout: .seconds(2))) != nil
        } catch {
            served = false
        }
        #expect(!served)
        #expect(store.lookups >= 2)
        await waitFor { await listener.connectionCount == 0 }
        #expect(!events.withLock { $0 }.contains(.handshakeSucceeded(.device(phoneID))))
        c.close()
        await listener.stop()
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

    /// R6: a flood of bad requests gets one 400 and the connection closes.
    ///
    /// Behaviour check only: on loopback the 400's send completes before the next bytes are
    /// read, so this passes even without the busy mark in `process` that stops a second 400.
    /// That race needs a slower network to show.
    @Test func R6_floodOfMalformedRequestsGetsOne400() async throws {
        let rig = try await rig()
        let raw = RawTLS(port: rig.port, identity: phoneID.recordName, key: Self.phoneKey)
        #expect(await raw.open())
        await waitFor { await rig.listener.connectionCount == 1 }
        // Header blocks over 8 KB, each its own TLS record: every chunk alone is a bad request.
        for _ in 0..<14 { raw.send(Data(repeating: 0x41, count: 9 * 1024)) }
        await waitFor(timeout: .seconds(3)) { raw.isClosed }
        let text = String(decoding: raw.received, as: UTF8.self)
        #expect(text.components(separatedBy: "HTTP/1.1 400").count - 1 == 1)
        await rig.listener.stop()
    }
}

/// A pairing store whose live `key(for:)` check passes only the first `allowedLookups` times,
/// as if the device were removed right after the TLS selection block ran.
final class RevokingStore: HubPairingStore {
    private let inner: InMemoryHubPairingStore
    private let state: Mutex<(allowed: Int, lookups: Int)>
    init(_ inner: InMemoryHubPairingStore, allowedLookups: Int) {
        self.inner = inner
        state = Mutex((allowedLookups, 0))
    }

    var lookups: Int { state.withLock { $0.lookups } }

    func key(for id: DeviceID) -> SymmetricKey? {
        let allowed = state.withLock { s in
            s.lookups += 1
            return s.lookups <= s.allowed
        }
        return allowed ? inner.key(for: id) : nil
    }

    func all() -> [PairedClient] { inner.all() }
    func save(_ client: PairedClient) throws { try inner.save(client) }
    func remove(_ id: DeviceID) throws { try inner.remove(id) }
    func removeAll() throws { try inner.removeAll() }
    func touch(_ id: DeviceID, at: Date) { inner.touch(id, at: at) }
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

    /// R12a: with every pending slot taken, the authenticated slots are still there.
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
    private let data = Mutex(Data())
    init(port: UInt16, parameters: NWParameters = .tcp) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    }

    var isClosed: Bool { closed.withLock { $0 } }
    /// Every byte the server sent.
    var received: Data { data.withLock { $0 } }

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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if let chunk { self.data.withLock { $0.append(chunk) } }
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
    var received: Data { raw.received }
    func open() async -> Bool { await raw.open() }
    func send(_ data: Data) { raw.send(data) }
}

extension Result {
    var failure: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
