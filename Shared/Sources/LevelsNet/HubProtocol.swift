import CryptoKit
import Foundation
import LevelsModel
import Synchronization

// Wire constants and JSON types of the Mac hub (ADR-0020, NET-001 R2, R4, R7, R8; lead's calls 20–22).

/// Constants shared by the Mac hub and its clients.
public enum HubProtocol {
    /// Bonjour service type (NET-001 R2).
    public static let serviceType = "_levels._tcp"
    /// Protocol version: TXT `v` and `HubSnapshot.v`.
    public static let version = 1
    /// Largest accepted body (NET-001 R6).
    public static let maxBody = 64 * 1024
    /// Largest accepted header block (NET-001 R6).
    public static let maxHeader = 8 * 1024
    /// Longest long-poll hold (NET-001 R4, lead's call 22).
    public static let maxWait: Duration = .seconds(25)
    /// PSK identity of the pairing session (NET-002 R4).
    public static let pairIdentity = "pair"
    /// At most this many paired devices (NET-002 R11).
    public static let maxPairedDevices = 4
    /// At most this many open connections (NET-001 R12).
    public static let maxConnections = 4
    /// At most this many connections still in the TLS handshake, on top of
    /// ``maxConnections`` (NET-001 R12a): half-open connections can't take the slots of
    /// authenticated ones.
    public static let maxPendingHandshakes = 3
    /// A connection not through the TLS handshake after this long is closed (NET-001 R12a).
    public static let handshakeTimeout: Duration = .seconds(10)
    /// Most bytes buffered for one connection; more closes it (NET-001 R6).
    public static let maxBuffered = maxHeader + maxBody
    /// A connection idle this long is closed (NET-001 R12).
    public static let idleTimeout: Duration = .seconds(60)
    /// Requests per second per connection before `429` (NET-001 R12).
    public static let maxRequestsPerSecond = 10

    /// The client's device ID header (ADR-0020 Decision 4).
    public static let deviceHeader = "levels-device"

    /// Routes (NET-001 R4, NET-002 R5).
    public enum Path {
        public static let snapshot = "/v1/snapshot"
        public static let readings = "/v1/readings"
        public static let devicesMe = "/v1/devices/me"
        public static let pairing = "/v1/pairing"
        public static let pair = "/v1/pair"
        /// Reveal the device key and wait for "They match" (NET-002 R5a, lead's call 30).
        public static let pairConfirm = "/v1/pair/confirm"
    }

    /// `Levels-<tag>`: the Bonjour instance name for a hub tag (NET-001 R2).
    public static func serviceName(tag: String) -> String { "Levels-\(tag)" }

    /// The first 4 lowercase hex characters of the hub ID (NET-001 R2).
    public static func tag(for hubID: UUID) -> String {
        String(hubID.uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(4))
    }

    /// TXT record entries: `v`, `hub` and, while the window is open, `pair=1` (NET-001 R2).
    public static func txtEntries(tag: String, pairing: Bool) -> [String: String] {
        var entries = ["v": String(version), "hub": tag]
        if pairing { entries["pair"] = "1" }
        return entries
    }
}

/// `GET /v1/snapshot` body (NET-001 R7).
public struct HubSnapshot: Codable, Sendable, Equatable {
    public var v: Int
    public var hubID: UUID
    public var hubDeviceID: DeviceID
    /// The Mac's clock when it answered.
    public var generatedAt: Date
    /// Everything the Mac's cache holds, sorted as `SnapshotFile.sorted`.
    public var devices: [DeviceBattery]

    public init(v: Int = HubProtocol.version, hubID: UUID, hubDeviceID: DeviceID, generatedAt: Date, devices: [DeviceBattery]) {
        self.v = v
        self.hubID = hubID
        self.hubDeviceID = hubDeviceID
        self.generatedAt = generatedAt
        self.devices = devices
    }
}

/// JSON settings and the ETag rule (NET-001 R7, R8).
public enum HubWire {
    /// `.millisecondsSince1970` dates, `.sortedKeys`.
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    /// `.millisecondsSince1970` dates. Unknown fields are ignored (Codable default).
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }

    /// `"` + first 16 hex characters of SHA-256 over the R7 JSON of `devices` + `"`.
    /// No stored state: the same devices give the same tag across relaunches.
    public static func etag(for devices: [DeviceBattery]) -> String {
        let data = (try? encoder().encode(devices)) ?? Data()
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\"\(hex.prefix(16))\""
    }
}

/// Fans one "changed" signal out to every stream from ``stream()`` (NET-001 R11).
/// The Mac fires it whenever its cache changes; each held long-poll listens to one stream.
public final class HubChangeSignal: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])

    public init() {}

    /// A new stream; it ends when the consumer stops iterating or its task is cancelled.
    public func stream() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.continuations.withLock { $0.removeValue(forKey: id) }
        }
        return stream
    }

    /// Signals every open stream.
    public func fire() {
        for c in continuations.withLock({ Array($0.values) }) { c.yield() }
    }
}
