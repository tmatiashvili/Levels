import CryptoKit
import Foundation
import LevelsModel
import Network
import os

/// The keys and live checks the server's TLS uses (NET-001 R5, NET-002 R4, R7):
/// every paired device, the pending (accepted, unconfirmed) device, and `pair` while the
/// window is open.
public struct HubKeyring: Sendable {
    public let store: any HubPairingStore
    public let window: PairingWindow

    public init(store: any HubPairingStore, window: PairingWindow) {
        self.store = store
        self.window = window
    }

    /// Every identity the listener should hold a PSK for now.
    public func keys() -> [String: SymmetricKey] {
        var keys: [String: SymmetricKey] = [:]
        for client in store.all() { keys[client.id.recordName] = client.symmetricKey }
        if let id = window.pendingID, let key = window.pendingKey(for: id) { keys[id.recordName] = key }
        if let code = window.codeKey { keys[HubProtocol.pairIdentity] = code }
        return keys
    }

    /// The live check per handshake: refuses a removed device or a closed window at once.
    public func allows(_ identity: String) -> Bool {
        if identity == HubProtocol.pairIdentity { return window.isOpen }
        guard let id = DeviceID(recordName: identity), id.recordName == identity else { return false }
        return store.key(for: id) != nil || window.pendingID == id
    }
}

/// The Mac hub's network side (NET-001 R2, R5, R6, R12): an `NWListener` with TLS-PSK,
/// optional Bonjour advertising, the HTTP subset per connection, and the limits. All
/// Network callbacks run on one private serial queue; each request hops into ``HubRouter``.
///
/// The PSK set is fixed when an `NWListener` is made (AC1 spike), so ``reload()`` rebuilds
/// the listener on the same port whenever the keys or the TXT record change. Open
/// connections survive a rebuild.
public actor HubListener {
    public enum Event: Sendable, Equatable {
        case ready(port: UInt16)
        case failed(String)
        case handshakeSucceeded(HubCaller)
        /// A TLS handshake failed; `identity` is the PSK identity the client offered, when known.
        case handshakeFailed(identity: String?)
        case connectionRefused
    }

    /// What the Bonjour record shows (NET-001 R2).
    public struct Advertisement: Sendable, Equatable {
        public var tag: String
        public var pairing: Bool
        public init(tag: String, pairing: Bool) {
            self.tag = tag
            self.pairing = pairing
        }
    }

    /// The connection limits (NET-001 R6, R12, R12a). Tests shorten them.
    public struct Limits: Sendable, Equatable {
        /// Authenticated connections.
        public var maxConnections: Int
        /// Connections still in the TLS handshake, counted apart from ``maxConnections``.
        public var maxPendingHandshakes: Int
        public var handshakeTimeout: Duration
        /// Bytes buffered per connection, also while a request is in flight.
        public var maxBuffered: Int

        public init(maxConnections: Int = HubProtocol.maxConnections,
                    maxPendingHandshakes: Int = HubProtocol.maxPendingHandshakes,
                    handshakeTimeout: Duration = HubProtocol.handshakeTimeout,
                    maxBuffered: Int = HubProtocol.maxBuffered) {
            self.maxConnections = maxConnections
            self.maxPendingHandshakes = maxPendingHandshakes
            self.handshakeTimeout = handshakeTimeout
            self.maxBuffered = maxBuffered
        }

        public static let standard = Limits()
    }

    private let engine: Engine
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - advertise: the Bonjour record to publish, or `nil` for none (tests).
    ///   - loopbackOnly: listen on the loopback interface only (tests).
    ///   - limits: connection limits (tests shorten them).
    ///   - events: called on the listener's queue.
    public init(router: HubRouter, keyring: HubKeyring, advertise: @escaping @Sendable () -> Advertisement? = { nil },
                loopbackOnly: Bool = false, limits: Limits = .standard, events: @escaping @Sendable (Event) -> Void = { _ in }) {
        engine = Engine(router: router, keyring: keyring, advertise: advertise, loopbackOnly: loopbackOnly,
                        limits: limits, events: events)
    }

    /// Starts (or rebuilds) the listener and waits until it is ready. Returns the port.
    @discardableResult
    public func start() async throws -> UInt16 {
        await acquire()
        defer { release() }
        return try await engine.rebuild(force: true)
    }

    /// Rebuilds the listener on the same port when the keys or the advertisement changed.
    /// Does nothing when it is not running.
    public func reload() async {
        await acquire()
        defer { release() }
        guard engine.isRunning else { return }
        do { _ = try await engine.rebuild(force: false) } catch {
            Engine.logger.error("Hub listener rebuild failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Cancels the listener and every connection; the Bonjour record goes away.
    public func stop() async {
        await acquire()
        defer { release() }
        await engine.stop()
    }

    /// Closes every connection of one device (Remove, NET-002 R9).
    public func closeConnections(of id: DeviceID) async { await engine.close(caller: .device(id)) }

    public var port: UInt16? { get async { await engine.currentPort() } }
    public var isRunning: Bool { engine.isRunning }
    public var connectionCount: Int { get async { await engine.connectionCount() } }

    private func acquire() async {
        if isBusy { await withCheckedContinuation { waiters.append($0) } } else { isBusy = true }
    }

    private func release() {
        if waiters.isEmpty { isBusy = false } else { waiters.removeFirst().resume() }
    }
}

// MARK: - Engine (queue-confined)

extension HubListener {
    final class Engine: @unchecked Sendable {
        static let logger = Logger(subsystem: LevelsLog.subsystem, category: "hub")

        let queue = DispatchQueue(label: "levels.hub.listener")
        let router: HubRouter
        let keyring: HubKeyring
        let advertise: @Sendable () -> Advertisement?
        let loopbackOnly: Bool
        let limits: Limits
        let events: @Sendable (Event) -> Void

        // Everything below is touched on `queue` only (`running` is also read under its lock).
        private var listener: NWListener?
        private var port: NWEndpoint.Port?
        private var fingerprint: String?
        private var connections: [ObjectIdentifier: Conn] = [:]
        /// Identities seen by the TLS selection block, keyed by the handshake's metadata.
        private var identities: [ObjectIdentifier: (metadata: AnyObject, identity: String, at: Date)] = [:]
        private var lastRefusalLog: Date?
        private let running = OSAllocatedUnfairLock(initialState: false)

        init(router: HubRouter, keyring: HubKeyring, advertise: @escaping @Sendable () -> Advertisement?,
             loopbackOnly: Bool, limits: Limits, events: @escaping @Sendable (Event) -> Void) {
            self.router = router
            self.keyring = keyring
            self.advertise = advertise
            self.loopbackOnly = loopbackOnly
            self.limits = limits
            self.events = events
        }

        var isRunning: Bool { running.withLock { $0 } }

        func currentPort() async -> UInt16? { await onQueue { self.port?.rawValue } }
        func connectionCount() async -> Int { await onQueue { self.connections.count } }

        private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
            await withCheckedContinuation { c in queue.async { c.resume(returning: body()) } }
        }

        // MARK: Listener

        func rebuild(force: Bool) async throws -> UInt16 {
            let keys = keyring.keys()
            let ad = advertise()
            let print = Self.fingerprint(keys: keys, advertisement: ad)
            if !force, let current = await onQueue({ self.fingerprint }), current == print,
               let port = await currentPort() {
                return port
            }
            let previous: NWEndpoint.Port? = await onQueue {
                self.listener?.cancel()
                self.listener = nil
                return self.port
            }
            // Same port first, so clients holding the endpoint keep working; then any port.
            var lastError: (any Error)?
            for attempt in 0..<4 {
                let port: NWEndpoint.Port = attempt < 3 ? (previous ?? .any) : .any
                do {
                    let ready = try await start(keys: keys, advertisement: ad, port: port)
                    await onQueue { self.fingerprint = print }
                    return ready
                } catch {
                    lastError = error
                    if previous == nil { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            running.withLock { $0 = false }
            throw lastError ?? NWError.posix(.EADDRINUSE)
        }

        private func start(keys: [String: SymmetricKey], advertisement: Advertisement?, port: NWEndpoint.Port) async throws -> UInt16 {
            let tls = HubTLS.serverOptions(keys: keys, queue: queue) { [weak self] identity, metadata in
                guard let self else { return false }
                self.remember(identity: identity, metadata: metadata)
                return self.keyring.allows(identity)
            }
            let tcp = NWProtocolTCP.Options()
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            let parameters = NWParameters(tls: tls, tcp: tcp)
            parameters.includePeerToPeer = false  // infrastructure Wi-Fi only (R2)
            parameters.allowLocalEndpointReuse = true
            if loopbackOnly { parameters.requiredInterfaceType = .loopback }
            let listener = try NWListener(using: parameters, on: port)
            if let advertisement {
                let txt = NWTXTRecord(HubProtocol.txtEntries(tag: advertisement.tag, pairing: advertisement.pairing))
                listener.service = NWListener.Service(name: HubProtocol.serviceName(tag: advertisement.tag),
                                                      type: HubProtocol.serviceType, domain: nil, txtRecord: txt)
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.serviceRegistrationUpdateHandler = { change in
                if case .add(let endpoint) = change {
                    Self.logger.notice("Bonjour registered \(String(describing: endpoint), privacy: .public)")
                }
            }
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, any Error>) in
                let flag = Flag()
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        let p = listener?.port ?? port
                        self.listener = listener
                        self.port = p
                        self.running.withLock { $0 = true }
                        Self.logger.notice("Hub listener ready on port \(p.rawValue, privacy: .public)")
                        self.events(.ready(port: p.rawValue))
                        if flag.set() { c.resume(returning: p.rawValue) }
                    case .failed(let error), .waiting(let error):
                        Self.logger.error("Hub listener failed: \(String(describing: error), privacy: .public)")
                        listener?.cancel()
                        if flag.set() {
                            c.resume(throwing: error)
                        } else if self.listener === listener {
                            self.listener = nil
                            self.running.withLock { $0 = false }
                            self.events(.failed(String(describing: error)))
                        }
                    case .cancelled:
                        if flag.set() { c.resume(throwing: CancellationError()) }
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
        }

        func stop() async {
            await onQueue {
                self.listener?.cancel()
                self.listener = nil
                self.port = nil
                self.fingerprint = nil
                self.running.withLock { $0 = false }
                for conn in self.connections.values { conn.connection.cancel() }
            }
        }

        func close(caller: HubCaller) async {
            await onQueue {
                for conn in self.connections.values where conn.caller == caller { conn.connection.cancel() }
            }
        }

        static func fingerprint(keys: [String: SymmetricKey], advertisement: Advertisement?) -> String {
            var hasher = SHA256()
            for (identity, key) in keys.sorted(by: { $0.key < $1.key }) {
                hasher.update(data: Data(identity.utf8))
                key.withUnsafeBytes { hasher.update(bufferPointer: $0) }
            }
            let ad = advertisement.map { "\($0.tag)|\($0.pairing)" } ?? "-"
            hasher.update(data: Data(ad.utf8))
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        // MARK: TLS identities

        /// On `queue` (the selection block's queue).
        private func remember(identity: String, metadata: sec_protocol_metadata_t) {
            let now = Date()
            identities = identities.filter { now.timeIntervalSince($0.value.at) < 30 }
            identities[ObjectIdentifier(metadata as AnyObject)] = (metadata as AnyObject, identity, now)
        }

        /// The identity of a handshake, by its metadata; else (a failed handshake whose
        /// metadata is gone) the oldest unclaimed one.
        private func claimIdentity(for connection: NWConnection) -> String? {
            if let meta = (connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata)?.securityProtocolMetadata {
                let key = ObjectIdentifier(meta as AnyObject)
                if let entry = identities.removeValue(forKey: key) { return entry.identity }
                return nil
            }
            guard let oldest = identities.min(by: { $0.value.at < $1.value.at }) else { return nil }
            identities[oldest.key] = nil
            return oldest.value.identity
        }

        // MARK: Connections (R6, R12, R12a)

        private var authenticatedCount: Int { connections.values.count { $0.caller != nil } }

        private func refuse(_ connection: NWConnection, _ why: String) {
            connection.cancel()
            let now = Date()
            if lastRefusalLog.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
                lastRefusalLog = now
                Self.logger.error("Hub: \(why, privacy: .public); dropping extras")
            }
            events(.connectionRefused)
        }

        private func accept(_ connection: NWConnection) {
            let authenticated = authenticatedCount
            guard authenticated < limits.maxConnections else {
                refuse(connection, "\(limits.maxConnections) connections open")
                return
            }
            // R12a: handshakes in progress have their own small budget, so half-open
            // connections can't hold the authenticated slots.
            guard connections.count - authenticated < limits.maxPendingHandshakes else {
                refuse(connection, "\(limits.maxPendingHandshakes) handshakes pending")
                return
            }
            let conn = Conn(connection: connection)
            let key = ObjectIdentifier(connection)
            connections[key] = conn
            // R12a: one-shot handshake deadline; a connection not ready by then is closed.
            queue.asyncAfter(deadline: .now() + Self.seconds(limits.handshakeTimeout)) { [weak conn] in
                guard let conn, conn.caller == nil else { return }
                Self.logger.notice("Hub: handshake not finished in time; closing")
                conn.connection.cancel()
            }
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.ready(conn)
                case .failed(let error), .waiting(let error):
                    if conn.caller == nil {
                        let identity = self.claimIdentity(for: connection)
                        if case .tls = error {
                            Self.logger.notice("Hub handshake failed for \(identity ?? "unknown", privacy: .public): \(String(describing: error), privacy: .public)")
                            if identity == HubProtocol.pairIdentity { self.keyring.window.handshakeFailed() }
                            self.events(.handshakeFailed(identity: identity))
                        }
                    }
                    connection.cancel()
                case .cancelled:
                    conn.task?.cancel()
                    conn.idle?.cancel()
                    self.connections[key] = nil
                default: break
                }
            }
            connection.start(queue: queue)
        }

        private func ready(_ conn: Conn) {
            guard let identity = claimIdentity(for: conn.connection) else {
                conn.connection.cancel()
                return
            }
            // Another handshake may have finished first and taken the last slot.
            guard authenticatedCount < limits.maxConnections else {
                refuse(conn.connection, "\(limits.maxConnections) connections open")
                return
            }
            let caller: HubCaller
            if identity == HubProtocol.pairIdentity {
                caller = .pairing
            } else if let id = DeviceID(recordName: identity) {
                caller = .device(id)
            } else {
                conn.connection.cancel()
                return
            }
            conn.caller = caller
            events(.handshakeSucceeded(caller))
            armIdle(conn)
            receive(conn)
        }

        private func receive(_ conn: Conn) {
            conn.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    // R6: bounded also while a request is in flight (receive keeps running
                    // so a closed long-poll is noticed).
                    guard conn.buffer.count + data.count <= self.limits.maxBuffered else {
                        Self.logger.notice("Hub: more than \(self.limits.maxBuffered) bytes buffered; closing")
                        conn.buffer = Data()
                        conn.connection.cancel()
                        return
                    }
                    conn.buffer.append(data)
                    self.armIdle(conn)
                }
                if isComplete || error != nil {
                    conn.connection.cancel()  // ends a held long-poll too (R11)
                    return
                }
                self.process(conn)
                self.receive(conn)
            }
        }

        private func process(_ conn: Conn) {
            guard conn.task == nil, let caller = conn.caller else { return }  // one request at a time
            let request: HTTPRequest
            do {
                guard let parsed = try HTTPCodec.parseRequest(&conn.buffer) else { return }
                request = parsed
            } catch {
                send(HTTPResponse(status: error.status, headers: ["connection": "close"]), on: conn, close: true)
                return
            }
            let now = Date()
            conn.recent = conn.recent.filter { now.timeIntervalSince($0) < 1 }
            if conn.recent.count >= HubProtocol.maxRequestsPerSecond {
                send(HTTPResponse(status: 429), on: conn, close: false)
                return
            }
            conn.recent.append(now)
            conn.idle?.cancel()  // a held request is not idle
            let router = router
            conn.task = Task { [weak self] in
                let response = await router.handle(request, from: caller)
                guard !Task.isCancelled else { return }
                self?.queue.async {
                    guard let self else { return }
                    let close = response.header("connection") == "close"
                    self.send(response, on: conn, close: close)
                    if close, request.path == HubProtocol.Path.pairing, case .device = caller {
                        // Forget: the device's other connections close too (NET-002 R9).
                        for other in self.connections.values where other !== conn && other.caller == caller {
                            other.connection.cancel()
                        }
                    }
                }
            }
        }

        /// On `queue`.
        private func send(_ response: HTTPResponse, on conn: Conn, close: Bool) {
            conn.connection.send(content: HTTPCodec.serialize(response), completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                conn.task = nil
                if close {
                    conn.connection.cancel()
                } else {
                    self.armIdle(conn)
                    self.process(conn)
                }
            })
        }

        private func armIdle(_ conn: Conn) {
            conn.idle?.cancel()
            let item = DispatchWorkItem { [weak conn] in
                guard let conn, conn.task == nil else { return }
                conn.connection.cancel()
            }
            conn.idle = item
            queue.asyncAfter(deadline: .now() + Self.seconds(HubProtocol.idleTimeout), execute: item)  // one-shot per connection (R12, R17)
        }

        static func seconds(_ d: Duration) -> Double {
            let c = d.components
            return Double(c.seconds) + Double(c.attoseconds) / 1e18
        }
    }

    /// Queue-confined connection state.
    final class Conn: @unchecked Sendable {
        let connection: NWConnection
        var caller: HubCaller?
        var buffer = Data()
        var task: Task<Void, Never>?
        var idle: DispatchWorkItem?
        var recent: [Date] = []
        init(connection: NWConnection) { self.connection = connection }
    }
}

/// A once-only flag for callbacks on one serial queue.
final class Flag: @unchecked Sendable {
    private var value = false
    /// Sets the flag; returns `true` only the first time.
    func set() -> Bool {
        if value { return false }
        value = true
        return true
    }
}
