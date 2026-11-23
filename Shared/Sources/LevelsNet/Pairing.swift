import CryptoKit
import Foundation
import LevelsModel
import Synchronization

// Pairing (NET-002, lead's call 21): a 6-digit code opens a TLS-PSK session with identity
// `pair`; inside it both sides swap fresh X25519 keys and derive a per-device 256-bit key.

public enum PairingCrypto {
    /// R4: `HKDF<SHA256>(code as UTF-8, salt: "levels-hub-" + tag, info: "levels-pair-v1", 32 bytes)`.
    public static func codeKey(code: String, hubTag: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
                               salt: Data("levels-hub-\(hubTag)".utf8),
                               info: Data("levels-pair-v1".utf8), outputByteCount: 32)
    }

    /// R6: `HKDF<SHA256>(X25519 shared secret, salt: codeKey, info: "levels-key-v1" + hubID + deviceID, 32 bytes)`,
    /// both IDs as lowercase strings.
    public static func pairingKey(shared: SharedSecret, codeKey: SymmetricKey, hubID: UUID, deviceID: DeviceID) -> SymmetricKey {
        let secret = shared.withUnsafeBytes { Data($0) }
        return pairingKey(sharedSecret: secret, codeKey: codeKey, hubID: hubID, deviceID: deviceID)
    }

    /// R6 over raw shared-secret bytes (test vectors).
    public static func pairingKey(sharedSecret: Data, codeKey: SymmetricKey, hubID: UUID, deviceID: DeviceID) -> SymmetricKey {
        let salt = codeKey.withUnsafeBytes { Data($0) }
        let info = Data("levels-key-v1\(hubID.uuidString.lowercased())\(deviceID.recordName)".utf8)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: sharedSecret), salt: salt, info: info, outputByteCount: 32)
    }

    /// R2: uniform over 000000–999999.
    public static func newCode<G: RandomNumberGenerator>(using g: inout G) -> String {
        let n = Int.random(in: 0..<1_000_000, using: &g)
        return String(format: "%06d", n)
    }

    /// `123 456` (R1).
    public static func displayCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}

/// `POST /v1/pair` body (R5).
public struct PairRequest: Codable, Sendable, Equatable {
    public var deviceID: DeviceID
    public var name: String
    public var kind: DeviceKind
    /// Raw X25519 public key (base64 in JSON).
    public var publicKey: Data

    public init(deviceID: DeviceID, name: String, kind: DeviceKind, publicKey: Data) {
        self.deviceID = deviceID
        self.name = name
        self.kind = kind
        self.publicKey = publicKey
    }
}

/// `POST /v1/pair` answer (R5).
public struct PairResponse: Codable, Sendable, Equatable {
    public var hubID: UUID
    public var hubDeviceID: DeviceID
    /// The Mac's display name (SYNC-002 R17); sent only inside the encrypted session.
    public var hubName: String
    public var publicKey: Data

    public init(hubID: UUID, hubDeviceID: DeviceID, hubName: String, publicKey: Data) {
        self.hubID = hubID
        self.hubDeviceID = hubDeviceID
        self.hubName = hubName
        self.publicKey = publicKey
    }
}

/// One paired client as the Mac stores it (R8).
public struct PairedClient: Codable, Sendable, Equatable, Identifiable {
    public var id: DeviceID
    public var name: String
    public var kind: DeviceKind
    public var key: Data
    public var pairedAt: Date
    public var lastSeenAt: Date?

    public init(id: DeviceID, name: String, kind: DeviceKind, key: Data, pairedAt: Date, lastSeenAt: Date? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.key = key
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
    }

    public var symmetricKey: SymmetricKey { SymmetricKey(data: key) }
}

/// The iPhone's one pairing (NET-003 Design, NET-002 R8).
public struct HubPairing: Codable, Sendable, Equatable {
    public var hubID: UUID
    /// The 4-character Bonjour tag (TXT `hub`).
    public var hubTag: String
    public var hubDeviceID: DeviceID
    public var hubName: String
    public var key: Data
    public var pairedAt: Date

    public init(hubID: UUID, hubTag: String, hubDeviceID: DeviceID, hubName: String, key: Data, pairedAt: Date) {
        self.hubID = hubID
        self.hubTag = hubTag
        self.hubDeviceID = hubDeviceID
        self.hubName = hubName
        self.key = key
        self.pairedAt = pairedAt
    }

    public var symmetricKey: SymmetricKey { SymmetricKey(data: key) }
}

/// Pairing failures as the iPhone shows them (NET-002 R4, R11).
public enum PairError: Error, Equatable, Sendable {
    /// The handshake with the code key failed (wrong or expired code, or the window is locked).
    case wrongCode
    /// The Mac's window is locked after 5 failures.
    case tooManyTries
    /// The Mac already has 4 devices (`409`).
    case hubFull
    case notReachable
    /// The Mac refused the request (`403`: wrong kind, window not open, bad key).
    case refused
    case timedOut
}

/// The Mac's own details sent in a ``PairResponse``.
public struct HubInfo: Sendable, Equatable {
    public var hubID: UUID
    public var hubDeviceID: DeviceID
    public var hubName: String

    public init(hubID: UUID, hubDeviceID: DeviceID, hubName: String) {
        self.hubID = hubID
        self.hubDeviceID = hubDeviceID
        self.hubName = hubName
    }

    public var tag: String { HubProtocol.tag(for: hubID) }
}

/// The Mac's pairing window (NET-002 R1, R2, R5, R7, R11). Synchronous and lock-protected,
/// because the TLS key lookup (``HubTLS``) runs on Network.framework's queue. Time comes
/// from `now`; the window expires lazily (each read checks `endsAt`), and the Mac schedules
/// one `expireIfDue()` call at `endsAt` so the listener drops the `pair` key on time.
public final class PairingWindow: Sendable {
    public enum State: Sendable, Equatable {
        case closed
        case open(code: String, endsAt: Date, failures: Int)
        /// 5 failed handshakes; the sheet asks for a new code (R2).
        case locked
        /// The last window ended with a confirmed pairing (R7).
        case paired(name: String)
    }

    public static let duration: TimeInterval = 120
    public static let maxFailures = 5

    private struct Inner {
        var state: State = .closed
        var hub: HubInfo?
        var codeKey: SymmetricKey?
        /// Accepted but not yet confirmed (R7).
        var pending: PairedClient?
    }

    private let inner = Mutex(Inner())
    private let store: any HubPairingStore
    private let now: @Sendable () -> Date
    private let observer = Mutex<(@Sendable () -> Void)?>(nil)

    public init(store: any HubPairingStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    /// Called after every state or key change (from any thread).
    public func setObserver(_ observer: @escaping @Sendable () -> Void) {
        self.observer.withLock { $0 = observer }
    }

    /// The current state; an open window past `endsAt` reads as `.closed` (R2).
    public var state: State {
        let (state, expired) = inner.withLock { s -> (State, Bool) in
            let expired = Self.expire(&s, now: now())
            return (s.state, expired)
        }
        if expired { notify() }
        return state
    }

    /// True while identity `pair` may handshake (R5 of NET-001).
    public var isOpen: Bool {
        if case .open = state { return true }
        return false
    }

    /// The `pair` PSK while the window is open; `nil` otherwise (R3 of AC3, AC5).
    public var codeKey: SymmetricKey? {
        _ = state
        return inner.withLock { s in
            if case .open = s.state { return s.codeKey }
            return nil
        }
    }

    /// The key of an accepted, unconfirmed device, so it can make R7's confirming request.
    public func pendingKey(for id: DeviceID) -> SymmetricKey? {
        _ = state
        return inner.withLock { $0.pending?.id == id ? $0.pending?.symmetricKey : nil }
    }

    /// The pending device's ID, if any.
    public var pendingID: DeviceID? {
        _ = state
        return inner.withLock { $0.pending?.id }
    }

    /// Opens a new window with a fresh code (R1, R2). Replaces any open window.
    @discardableResult
    public func open(hub: HubInfo) -> String {
        var g = SystemRandomNumberGenerator()
        return open(hub: hub, using: &g)
    }

    /// Testable form of ``open(hub:)``.
    @discardableResult
    public func open<G: RandomNumberGenerator>(hub: HubInfo, using g: inout G) -> String {
        let code = PairingCrypto.newCode(using: &g)
        let endsAt = now().addingTimeInterval(Self.duration)
        inner.withLock { s in
            s.state = .open(code: code, endsAt: endsAt, failures: 0)
            s.hub = hub
            s.codeKey = PairingCrypto.codeKey(code: code, hubTag: hub.tag)
            s.pending = nil
        }
        notify()
        return code
    }

    /// Cancel, or the sheet closed (R2). Drops an unconfirmed entry (R7).
    public func close() {
        let changed = inner.withLock { s -> Bool in
            let was = s.state
            if case .open = s.state { s.state = .closed }
            if case .locked = s.state { s.state = .closed }
            s.codeKey = nil
            s.pending = nil
            return was != s.state
        }
        if changed { notify() }
    }

    /// Applies the 2-minute timeout now if it is due. The Mac calls this once at `endsAt`.
    public func expireIfDue() { _ = state }

    /// One failed `pair` handshake (R2, R4). The 5th locks the window.
    public func handshakeFailed() {
        let changed = inner.withLock { s -> Bool in
            _ = Self.expire(&s, now: now())
            guard case .open(let code, let endsAt, let failures) = s.state else { return false }
            if failures + 1 >= Self.maxFailures {
                s.state = .locked
                s.codeKey = nil
                s.pending = nil
            } else {
                s.state = .open(code: code, endsAt: endsAt, failures: failures + 1)
            }
            return true
        }
        if changed { notify() }
    }

    /// R5, R6, R11: checks the request, makes the Mac's key pair, derives and holds the
    /// pairing key as unconfirmed, and returns the answer. The window stays open until
    /// ``confirm(_:)``. Re-pairing a paired device replaces its key on confirm (R10).
    public func accept(_ request: PairRequest) throws(PairError) -> PairResponse {
        _ = state
        let result: Result<PairResponse, PairError> = inner.withLock { s in
            switch s.state {
            case .open: break
            case .locked: return .failure(.tooManyTries)
            case .closed, .paired: return .failure(.refused)
            }
            guard let hub = s.hub, let codeKey = s.codeKey else { return .failure(.refused) }
            guard request.kind == .iphone || request.kind == .ipad else { return .failure(.refused) }
            let paired = store.all()
            if paired.count >= HubProtocol.maxPairedDevices, !paired.contains(where: { $0.id == request.deviceID }) {
                return .failure(.hubFull)
            }
            guard let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.publicKey) else {
                return .failure(.refused)
            }
            let mine = Curve25519.KeyAgreement.PrivateKey()
            guard let shared = try? mine.sharedSecretFromKeyAgreement(with: theirs) else { return .failure(.refused) }
            let key = PairingCrypto.pairingKey(shared: shared, codeKey: codeKey, hubID: hub.hubID, deviceID: request.deviceID)
            s.pending = PairedClient(id: request.deviceID, name: Self.cleanName(request.name, kind: request.kind),
                                     kind: request.kind, key: key.withUnsafeBytes { Data($0) }, pairedAt: now())
            return .success(PairResponse(hubID: hub.hubID, hubDeviceID: hub.hubDeviceID, hubName: hub.hubName,
                                         publicKey: mine.publicKey.rawRepresentation))
        }
        let response = try result.get()
        notify()
        return response
    }

    /// R7: the pending device made its first request with the new key. Saves it in the
    /// store and ends the window as `.paired(name:)`. Returns the saved entry, or `nil`
    /// when `id` was not pending (or the save failed).
    @discardableResult
    public func confirm(_ id: DeviceID) -> PairedClient? {
        _ = state
        guard let client = inner.withLock({ s -> PairedClient? in s.pending?.id == id ? s.pending : nil }) else { return nil }
        do {
            try store.save(client)
        } catch {
            return nil
        }
        inner.withLock { s in
            s.pending = nil
            s.codeKey = nil
            s.state = .paired(name: client.name)
        }
        notify()
        return client
    }

    /// Trimmed, at most 40 characters; blank names get the kind's default.
    static func cleanName(_ name: String, kind: DeviceKind) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (kind == .ipad ? "iPad" : "iPhone") : String(trimmed.prefix(40))
    }

    /// Moves an open window past `endsAt` to `.closed` and drops the pending entry.
    private static func expire(_ s: inout Inner, now: Date) -> Bool {
        guard case .open(_, let endsAt, _) = s.state, now >= endsAt else { return false }
        s.state = .closed
        s.codeKey = nil
        s.pending = nil
        return true
    }

    private func notify() { observer.withLock { $0 }?() }
}
