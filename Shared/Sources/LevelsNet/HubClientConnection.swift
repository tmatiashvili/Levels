import CryptoKit
import Foundation
import Network
import dnssd

/// Client-side failures (NET-003 R9).
public enum HubError: Error, Equatable, Sendable {
    /// No pairing is stored.
    case notPaired
    /// The hub's Bonjour record was not found in time (away).
    case notFound
    /// Found, but the connection didn't become ready in time, or it dropped.
    case notReady
    /// TLS refused the stored key: the Mac no longer knows this device.
    case handshakeRefused
    /// Local Network permission denied (policy denied).
    case localNetworkDenied
    /// TXT `v` or body `v` differs from ``HubProtocol/version``.
    case versionMismatch
    case timedOut
    /// An unexpected status (or `0` for an unreadable answer).
    case badResponse(Int)
}

/// One client `NWConnection` with TLS-PSK and the HTTP subset: open, then exchange one
/// request at a time. Callbacks run on a private queue.
final class HubClientConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "levels.hub.client")
    // On `queue` only.
    private var buffer = Data()
    private var failure: HubError?
    private var busy = false

    init(endpoint: NWEndpoint, identity: String, key: SymmetricKey) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: HubTLS.clientOptions(identity: identity, key: key), tcp: tcp)
        parameters.includePeerToPeer = false
        connection = NWConnection(to: endpoint, using: parameters)
    }

    /// A dropped connection must not stay open (a replaced or forgotten one used to linger).
    deinit { connection.cancel() }

    /// Waits until ready. TLS errors that mean "the Mac doesn't know this key" map to
    /// `.handshakeRefused`, policy denied to `.localNetworkDenied`, the rest (and the
    /// timeout) to `.notReady`.
    func open(timeout: Duration) async throws(HubError) {
        let result: Result<Void, HubError> = await withCheckedContinuation { c in
            let once = Once(c)
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: once.resume(.success(()))
                case .waiting(let error), .failed(let error):
                    let mapped = Self.map(error)
                    self?.failure = mapped
                    self?.connection.cancel()
                    once.resume(.failure(mapped))
                case .cancelled:
                    once.resume(.failure(self?.failure ?? .notReady))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + Self.seconds(timeout)) { [weak self] in
                guard !once.isDone else { return }
                self?.failure = .notReady
                self?.connection.cancel()
                once.resume(.failure(.notReady))
            }
        }
        try result.get()
    }

    /// Usable for another request: ready, not failed, not busy.
    var isUsable: Bool {
        queue.sync { connection.state == .ready && failure == nil && !busy }
    }

    /// Ready and not failed; it may be busy with a request (the long-poll).
    var isAlive: Bool {
        queue.sync { connection.state == .ready && failure == nil }
    }

    /// Sends one request and reads one response.
    func exchange(_ request: HTTPRequest, timeout: Duration) async throws(HubError) -> HTTPResponse {
        let result: Result<HTTPResponse, HubError> = await withCheckedContinuation { c in
            queue.async { [self] in
                let once = Once(c) { [self] r in  // runs on `queue`
                    busy = false
                    if case .failure(let e) = r {
                        failure = e
                        connection.cancel()
                    }
                }
                guard connection.state == .ready, failure == nil, !busy else {
                    once.resume(.failure(failure ?? .notReady))
                    return
                }
                busy = true
                connection.send(content: HTTPCodec.serialize(request), completion: .contentProcessed { error in
                    if error != nil { once.resume(.failure(.notReady)) }
                })
                read(once)
                queue.asyncAfter(deadline: .now() + Self.seconds(timeout)) { once.resume(.failure(.timedOut)) }
            }
        }
        return try result.get()
    }

    /// On `queue`: parses what is buffered, else receives more.
    private func read(_ once: Once<Result<HTTPResponse, HubError>>) {
        do {
            if let response = try HTTPCodec.parseResponse(&buffer) {
                if response.header("connection") == "close" { connection.cancel() }
                once.resume(.success(response))
                return
            }
        } catch {
            once.resume(.failure(.badResponse(0)))
            return
        }
        guard !once.isDone else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if error != nil || isComplete {
                if let response = try? HTTPCodec.parseResponse(&buffer) {
                    once.resume(.success(response))
                } else {
                    once.resume(.failure(.notReady))
                }
                return
            }
            read(once)
        }
    }

    func close() { connection.cancel() }

    static func map(_ error: NWError) -> HubError {
        switch error {
        // Only the statuses below mean the Mac refused this iPhone; any other TLS failure
        // (reset, aborted mid-handshake) is "not reachable", not "forgot this iPhone".
        case .tls(let status) where refusedTLSStatuses.contains(status): return .handshakeRefused
        case .dns(let code) where code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied): return .localNetworkDenied
        default: return .notReady
        }
    }

    /// The Mac's TLS answers that mean "unknown key or identity": `errSSLUnknownPSKIdentity`,
    /// `errSSLPeerBadRecordMac` (wrong key), `errSSLBadRecordMac`, and
    /// `errSSLPeerHandshakeFail` (its PSK selection refused the identity, e.g. a removed device).
    /// Closed or aborted handshakes (-9806, -9816) and the rest are "not reachable".
    static let refusedTLSStatuses: Set<OSStatus> = [-9864, -9820, -9846, -9824]

    static func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

/// Resumes a continuation once; later calls do nothing. `before` runs just before the
/// resume. Used on one serial queue (or with its lock), hence `@unchecked`.
final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private let before: ((T) -> Void)?

    init(_ continuation: CheckedContinuation<T, Never>, before: ((T) -> Void)? = nil) {
        self.continuation = continuation
        self.before = before
    }

    var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return continuation == nil
    }

    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        guard let c else { return }
        before?(value)
        c.resume(returning: value)
    }
}
