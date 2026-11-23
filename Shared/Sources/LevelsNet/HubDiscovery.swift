import Foundation
import Network
import dnssd

/// One hub found by Bonjour (NET-002 R3).
public struct DiscoveredHub: Sendable, Equatable, Identifiable {
    /// `Levels-<tag>`.
    public var name: String
    public var tag: String
    /// TXT `v`; `nil` when missing.
    public var version: Int?
    /// TXT `pair=1`: the pairing window is open.
    public var isPairing: Bool
    public var endpoint: NWEndpoint

    public var id: String { name }

    public init(name: String, tag: String, version: Int?, isPairing: Bool, endpoint: NWEndpoint) {
        self.name = name
        self.tag = tag
        self.version = version
        self.isPairing = isPairing
        self.endpoint = endpoint
    }
}

/// Finds the endpoint of a paired hub (NET-003 R5).
public protocol HubLocator: Sendable {
    func endpoint(forTag tag: String, timeout: Duration) async throws(HubError) -> NWEndpoint
}

/// A fixed endpoint (tests, loopback, debugging).
public struct FixedHubLocator: HubLocator {
    public let endpoint: NWEndpoint
    public init(_ endpoint: NWEndpoint) { self.endpoint = endpoint }
    /// `127.0.0.1:<port>`.
    public init(loopbackPort port: UInt16) {
        endpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
    }
    public func endpoint(forTag tag: String, timeout: Duration) async throws(HubError) -> NWEndpoint { endpoint }
}

/// Bonjour `_levels._tcp` on infrastructure Wi-Fi (NET-003 R5). Never stores an address.
public struct BonjourHubLocator: HubLocator {
    public init() {}

    public func endpoint(forTag tag: String, timeout: Duration) async throws(HubError) -> NWEndpoint {
        let hubs = try await HubBrowser.discover(timeout: timeout) { $0.contains { $0.tag == tag } }
        guard let hub = hubs.first(where: { $0.tag == tag }) else { throw .notFound }
        guard hub.version == HubProtocol.version else { throw .versionMismatch }
        return hub.endpoint
    }
}

/// Bonjour browsing for `_levels._tcp` (NET-002 R3, NET-003 R5).
public enum HubBrowser {
    /// Browses until `isEnough` holds for the results or `timeout` passes, then returns
    /// what was found. Policy denied throws `.localNetworkDenied`.
    public static func discover(timeout: Duration,
                                until isEnough: @escaping @Sendable ([DiscoveredHub]) -> Bool = { _ in false })
        async throws(HubError) -> [DiscoveredHub] {
        let result: Result<[DiscoveredHub], HubError> = await withCheckedContinuation { c in
            let queue = DispatchQueue(label: "levels.hub.browse")
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: HubProtocol.serviceType, domain: nil), using: parameters)
            let state = BrowseState()
            let finish: @Sendable (Result<[DiscoveredHub], HubError>) -> Void = { r in
                guard state.finish() else { return }
                browser.cancel()
                c.resume(returning: r)
            }
            browser.browseResultsChangedHandler = { results, _ in
                let hubs = results.compactMap(Self.hub)
                state.set(hubs)
                if isEnough(hubs) { finish(.success(hubs)) }
            }
            browser.stateUpdateHandler = { s in
                switch s {
                case .failed(let error), .waiting(let error):
                    if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                        finish(.failure(.localNetworkDenied))
                    } else if case .failed = s {
                        finish(.failure(.notFound))
                    }
                default: break
                }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + HubClientConnection.seconds(timeout)) { finish(.success(state.hubs)) }
        }
        return try result.get()
    }

    /// Live results for a pairing screen; the browser stops when the stream ends.
    public static func results() -> AsyncThrowingStream<[DiscoveredHub], any Error> {
        AsyncThrowingStream { continuation in
            let queue = DispatchQueue(label: "levels.hub.browse")
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: HubProtocol.serviceType, domain: nil), using: parameters)
            browser.browseResultsChangedHandler = { results, _ in continuation.yield(results.compactMap(Self.hub)) }
            browser.stateUpdateHandler = { s in
                if case .waiting(let error) = s, case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                    continuation.finish(throwing: HubError.localNetworkDenied)
                } else if case .failed(let error) = s {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: queue)
        }
    }

    static func map(_ error: NWError) -> HubError {
        if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) { return .localNetworkDenied }
        return .notFound
    }

    static func hub(_ result: NWBrowser.Result) -> DiscoveredHub? {
        guard case .service(let name, let type, _, _) = result.endpoint, type.hasPrefix(HubProtocol.serviceType) else { return nil }
        var txt: [String: String] = [:]
        if case .bonjour(let record) = result.metadata { txt = record.dictionary }
        let tag = txt["hub"] ?? (name.hasPrefix("Levels-") ? String(name.dropFirst("Levels-".count)) : "")
        guard !tag.isEmpty else { return nil }
        return DiscoveredHub(name: name, tag: tag, version: txt["v"].flatMap(Int.init), isPairing: txt["pair"] == "1",
                             endpoint: result.endpoint)
    }
}

/// Browse results and the once-only finish flag, shared by the browser's callbacks.
final class BrowseState: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var found: [DiscoveredHub] = []

    func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }

    func set(_ hubs: [DiscoveredHub]) {
        lock.lock(); defer { lock.unlock() }
        found = hubs
    }

    var hubs: [DiscoveredHub] {
        lock.lock(); defer { lock.unlock() }
        return found
    }
}
