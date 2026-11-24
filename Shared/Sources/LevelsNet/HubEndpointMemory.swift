// The Mac's last resolved address, kept so the next connection can skip Bonjour.
//
// Why: the widget has a few seconds per timeline load. A Bonjour browse, then the `.service`
// endpoint's own resolve inside `NWConnection`, then TCP and TLS, often did not fit in its 4 s
// (2 s find + 2 s ready). A failed widget fetch waited 60 min for the next try, which matched
// the 90 min gaps in the hub log. With the last host and port the widget connects directly
// and falls back to Bonjour when that fails. TLS-PSK still proves it is our Mac, so a stale
// or wrong address can only fail, never reach someone else.
import Foundation
import Network

/// One remembered hub address. Pure value, unit-tested.
public struct HubEndpointRecord: Codable, Sendable, Equatable {
    public var hubID: UUID
    public var host: String
    public var port: UInt16
    public var savedAt: Date

    public init(hubID: UUID, host: String, port: UInt16, savedAt: Date) {
        self.hubID = hubID
        self.host = host
        self.port = port
        self.savedAt = savedAt
    }

    /// A record for `endpoint`, or `nil` when it is not a plain address worth keeping: a
    /// Bonjour service, a name, or an IPv6 link-local address without its interface (it
    /// can't be dialled again).
    public init?(endpoint: NWEndpoint, hubID: UUID, savedAt: Date) {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        let text: String
        switch host {
        case .ipv4(let a):
            text = "\(a)"
        case .ipv6(let a):
            text = "\(a)"
            if a.isLinkLocal, !text.contains("%") { return nil }
        default:
            return nil
        }
        self.init(hubID: hubID, host: text, port: port.rawValue, savedAt: savedAt)
    }

    /// The endpoint to dial, or `nil` when the text no longer parses.
    public var endpoint: NWEndpoint? {
        guard let port = NWEndpoint.Port(rawValue: port), port.rawValue != 0 else { return nil }
        if let a = IPv4Address(host) { return .hostPort(host: .ipv4(a), port: port) }
        if let a = IPv6Address(host) { return .hostPort(host: .ipv6(a), port: port) }
        return nil
    }

    /// Older than this, the address is not tried (DHCP leases, a moved Mac).
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    /// Whether this record may be used for `hubID` at `now`.
    public func isUsable(for hubID: UUID, now: Date) -> Bool {
        self.hubID == hubID && now.timeIntervalSince(savedAt) < Self.maxAge && now >= savedAt.addingTimeInterval(-60)
            && endpoint != nil
    }
}

/// Where the last address is kept. The app and the widget share one in the App Group.
public protocol HubEndpointMemory: Sendable {
    func load() -> HubEndpointRecord?
    func save(_ record: HubEndpointRecord)
    func clear()
}

/// App Group `UserDefaults`, key `net.lastEndpoint`.
public struct UserDefaultsHubEndpointMemory: HubEndpointMemory {
    public static let key = "net.lastEndpoint"
    private let suiteName: String?

    public init(suiteName: String?) { self.suiteName = suiteName }

    private var defaults: UserDefaults? { suiteName.flatMap(UserDefaults.init(suiteName:)) }

    public func load() -> HubEndpointRecord? {
        guard let data = defaults?.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(HubEndpointRecord.self, from: data)
    }

    public func save(_ record: HubEndpointRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults?.set(data, forKey: Self.key)
    }

    public func clear() { defaults?.removeObject(forKey: Self.key) }
}

/// In memory (tests).
public final class InMemoryHubEndpointMemory: HubEndpointMemory, @unchecked Sendable {
    private let lock = NSLock()
    private var record: HubEndpointRecord?
    public init(_ record: HubEndpointRecord? = nil) { self.record = record }
    public func load() -> HubEndpointRecord? { lock.withLock { record } }
    public func save(_ record: HubEndpointRecord) { lock.withLock { self.record = record } }
    public func clear() { lock.withLock { record = nil } }
}
