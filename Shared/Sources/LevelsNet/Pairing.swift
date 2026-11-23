import CryptoKit
import Foundation
import LevelsModel
import Synchronization

// Pairing (NET-002, lead's calls 21 and 30). A 6-digit code opens a TLS-PSK session with
// identity `pair`. The code only gates who may try: it has 20 bits, so anyone who records
// the handshake can find it offline. Inside the session both sides run an ephemeral X25519
// key agreement with a hash commitment, derive the per-device key from the shared secret
// and the full transcript, and show a 6-digit confirmation number that the owner compares
// on both screens before the Mac accepts the device (SAS-authenticated key agreement, the
// numeric-comparison model of Bluetooth Secure Simple Pairing and ZRTP; not a PAKE).

public enum PairingCrypto {
    /// R4: `HKDF<SHA256>(code as UTF-8, salt: "levels-hub-" + tag, info: "levels-pair-v1", 32 bytes)`.
    /// The TLS-PSK of the `pair` session only; never an input of the pairing key (call 30).
    public static func codeKey(code: String, hubTag: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
                               salt: Data("levels-hub-\(hubTag)".utf8),
                               info: Data("levels-pair-v1".utf8), outputByteCount: 32)
    }

    /// R5: `SHA-256("levels-commit-v2" + raw X25519 public key)`. The iPhone sends this first
    /// and reveals the key only after it has the Mac's key, so a man in the middle can't
    /// pick its own keys to make both confirmation numbers equal.
    public static func commitment(to publicKey: Data) -> Data {
        var h = SHA256()
        h.update(data: Data("levels-commit-v2".utf8))
        h.update(data: publicKey)
        return Data(h.finalize())
    }

    /// R6: `HKDF<SHA256>(X25519 shared secret, salt: transcript digest, info: "levels-key-v2", 32 bytes)`.
    public static func pairingKey(shared: SharedSecret, transcript: PairingTranscript) -> SymmetricKey {
        pairingKey(sharedSecret: shared.withUnsafeBytes { Data($0) }, transcript: transcript)
    }

    /// R6 over raw shared-secret bytes (test vectors).
    public static func pairingKey(sharedSecret: Data, transcript: PairingTranscript) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: sharedSecret), salt: transcript.digest,
                               info: Data("levels-key-v2".utf8), outputByteCount: 32)
    }

    /// R6a: the confirmation number both screens show. `HKDF<SHA256>(shared secret, salt:
    /// transcript digest, info: "levels-sas-v2", 8 bytes)` read as a big-endian `UInt64`,
    /// modulo 1,000,000, as 6 digits.
    public static func confirmationCode(shared: SharedSecret, transcript: PairingTranscript) -> String {
        confirmationCode(sharedSecret: shared.withUnsafeBytes { Data($0) }, transcript: transcript)
    }

    /// R6a over raw shared-secret bytes (test vectors).
    public static func confirmationCode(sharedSecret: Data, transcript: PairingTranscript) -> String {
        let bytes = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: sharedSecret), salt: transcript.digest,
                                           info: Data("levels-sas-v2".utf8), outputByteCount: 8)
            .withUnsafeBytes { Array($0) }
        let n = bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return String(format: "%06d", Int(n % 1_000_000))
    }

    /// R2: uniform over 000000–999999.
    public static func newCode<G: RandomNumberGenerator>(using g: inout G) -> String {
        let n = Int.random(in: 0..<1_000_000, using: &g)
        return String(format: "%06d", n)
    }

    /// `123 456` (R1); also for the confirmation number.
    public static func displayCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}

/// Everything both sides saw in the pairing exchange (R6). Both public keys, the hub tag
/// and IDs, and the device's identity as it sent it.
public struct PairingTranscript: Sendable, Equatable {
    public var hubTag: String
    public var hubID: UUID
    public var hubDeviceID: DeviceID
    public var hubName: String
    public var deviceID: DeviceID
    /// The name as the device sent it (before the Mac trims it).
    public var deviceName: String
    public var kind: DeviceKind
    public var devicePublicKey: Data
    public var hubPublicKey: Data

    public init(hubTag: String, hubID: UUID, hubDeviceID: DeviceID, hubName: String, deviceID: DeviceID,
                deviceName: String, kind: DeviceKind, devicePublicKey: Data, hubPublicKey: Data) {
        self.hubTag = hubTag
        self.hubID = hubID
        self.hubDeviceID = hubDeviceID
        self.hubName = hubName
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.kind = kind
        self.devicePublicKey = devicePublicKey
        self.hubPublicKey = hubPublicKey
    }

    /// `SHA-256` over each field with a 4-byte big-endian length in front, in this order:
    /// `"levels-pair-v2"`, hub tag, hub ID (lowercase), hub device ID, hub name, device ID,
    /// device name, kind, device public key, hub public key. Strings as UTF-8.
    public var digest: Data {
        var h = SHA256()
        func field(_ d: Data) {
            var length = UInt32(d.count).bigEndian
            withUnsafeBytes(of: &length) { h.update(bufferPointer: $0) }
            h.update(data: d)
        }
        for s in ["levels-pair-v2", hubTag, hubID.uuidString.lowercased(), hubDeviceID.recordName, hubName,
                  deviceID.recordName, deviceName, kind.rawValue] {
            field(Data(s.utf8))
        }
        field(devicePublicKey)
        field(hubPublicKey)
        return Data(h.finalize())
    }
}

/// `POST /v1/pair` body (R5).
public struct PairRequest: Codable, Sendable, Equatable {
    public var deviceID: DeviceID
    public var name: String
    public var kind: DeviceKind
    /// ``PairingCrypto/commitment(to:)`` of the device's fresh X25519 public key (base64 in JSON).
    public var commitment: Data

    public init(deviceID: DeviceID, name: String, kind: DeviceKind, commitment: Data) {
        self.deviceID = deviceID
        self.name = name
        self.kind = kind
        self.commitment = commitment
    }
}

/// `POST /v1/pair/confirm` body (R5a): the device reveals its public key. The Mac holds the
/// answer until the owner taps "They match" (`204`) or Cancel (`403`), or the window ends (`408`).
public struct PairConfirmRequest: Codable, Sendable, Equatable {
    /// Raw X25519 public key (base64 in JSON); must match the commitment.
    public var publicKey: Data

    public init(publicKey: Data) { self.publicKey = publicKey }
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

/// The Mac's pairing window (NET-002 R1, R2, R5–R7, R11; lead's call 30). Synchronous and
/// lock-protected, because the TLS key lookup (``HubTLS``) runs on Network.framework's
/// queue. Time comes from `now`; the window expires lazily (each read checks the deadline),
/// and the Mac schedules one `expireIfDue()` call at ``deadline`` so the listener drops the
/// keys on time.
///
/// Flow: `.open` → ``accept(_:)`` (commitment, Mac key) → ``reveal(_:)`` (device key; the
/// `pair` key is dropped) → `.confirming` with the confirmation number → the owner taps
/// "They match" (``approve()``) → `.matched`, and only now the device's key reaches the
/// listener → the device's first request (``confirm(_:)``) → `.paired`.
public final class PairingWindow: Sendable {
    public enum State: Sendable, Equatable {
        case closed
        case open(code: String, endsAt: Date, failures: Int)
        /// 5 failed handshakes; the sheet asks for a new code (R2).
        case locked
        /// The device revealed its key; the Mac shows `confirmationCode` and asks the owner
        /// whether the iPhone shows the same number (R6a).
        case confirming(name: String, confirmationCode: String, endsAt: Date)
        /// The owner tapped "They match"; waiting for the device's first request (R7).
        case matched(name: String)
        /// The last window ended with a confirmed pairing (R7).
        case paired(name: String)
    }

    /// How the owner's decision ended (``decision()``).
    public enum Decision: Sendable, Equatable {
        case matched
        /// Cancel, or the window closed or was replaced.
        case cancelled
        case expired
    }

    public static let duration: TimeInterval = 120
    public static let maxFailures = 5
    /// The owner gets at least this long to compare the numbers, even late in the window.
    public static let minConfirmTime: TimeInterval = 30

    private struct Pending {
        var request: PairRequest
        var hubPrivate: Curve25519.KeyAgreement.PrivateKey
        /// Set by ``reveal(_:)``.
        var client: PairedClient?
    }

    private struct Inner {
        var state: State = .closed
        var endsAt: Date?
        var hub: HubInfo?
        var codeKey: SymmetricKey?
        var pending: Pending?
        var waiters: [UUID: CheckedContinuation<Decision, Never>] = [:]
        /// How the last confirming phase ended, for a late ``decision()`` call.
        var outcome: Decision?
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

    /// The current state; a window past its deadline reads as `.closed` (R2).
    public var state: State { read { $0.state } }

    /// When the current window ends (open, confirming or matched); `nil` otherwise.
    public var deadline: Date? { read { $0.endsAt } }

    /// True while identity `pair` may handshake (R5 of NET-001).
    public var isOpen: Bool {
        if case .open = state { return true }
        return false
    }

    /// True from the moment the window opens until pairing ends (open, confirming or matched).
    /// The listener must keep running for all of these, or the confirm step can't arrive.
    public var isInProgress: Bool {
        if case .closed = state { return false }
        return true
    }

    /// The `pair` PSK while the window is open and no device has revealed its key yet;
    /// `nil` otherwise (R2, AC3, AC5).
    public var codeKey: SymmetricKey? {
        read { s in
            if case .open = s.state { return s.codeKey }
            return nil
        }
    }

    /// The key of the matched, unconfirmed device, so it can make R7's confirming request.
    /// `nil` until the owner tapped "They match" (call 30).
    public func pendingKey(for id: DeviceID) -> SymmetricKey? {
        read { s in
            guard case .matched = s.state, let client = s.pending?.client, client.id == id else { return nil }
            return client.symmetricKey
        }
    }

    /// The matched device's ID, if any.
    public var pendingID: DeviceID? {
        read { s in
            guard case .matched = s.state else { return nil }
            return s.pending?.client?.id
        }
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
        change { s in
            Self.end(&s, as: .cancelled)
            s.state = .open(code: code, endsAt: endsAt, failures: 0)
            s.endsAt = endsAt
            s.hub = hub
            s.codeKey = PairingCrypto.codeKey(code: code, hubTag: hub.tag)
            s.outcome = nil
            return true
        }
        return code
    }

    /// Cancel, or the sheet closed (R2). Drops an unconfirmed entry (R7) and answers a
    /// waiting device with "cancelled".
    public func close() {
        change { s in
            switch s.state {
            case .open, .locked, .confirming, .matched:
                Self.end(&s, as: .cancelled)
                s.state = .closed
                return true
            case .closed, .paired:
                return false
            }
        }
    }

    /// Applies the timeout now if it is due. The Mac calls this once at ``deadline``.
    public func expireIfDue() { _ = state }

    /// One failed `pair` handshake (R2, R4). The 5th locks the window.
    public func handshakeFailed() {
        change { s in
            guard case .open(let code, let endsAt, let failures) = s.state else { return false }
            if failures + 1 >= Self.maxFailures {
                Self.end(&s, as: .cancelled)
                s.state = .locked
            } else {
                s.state = .open(code: code, endsAt: endsAt, failures: failures + 1)
            }
            return true
        }
    }

    /// R5, R11: checks the request, makes the Mac's ephemeral key pair, holds the device's
    /// commitment and returns the answer. One device per window: a second request is
    /// refused (single use).
    public func accept(_ request: PairRequest) throws(PairError) -> PairResponse {
        let result: Result<PairResponse, PairError> = changeReturning { s in
            switch s.state {
            case .open: break
            case .locked: return (.failure(.tooManyTries), false)
            case .closed, .paired, .confirming, .matched: return (.failure(.refused), false)
            }
            guard s.pending == nil, let hub = s.hub else { return (.failure(.refused), false) }
            guard request.kind == .iphone || request.kind == .ipad else { return (.failure(.refused), false) }
            guard request.commitment.count == SHA256.byteCount else { return (.failure(.refused), false) }
            let paired = store.all()
            if paired.count >= HubProtocol.maxPairedDevices, !paired.contains(where: { $0.id == request.deviceID }) {
                return (.failure(.hubFull), false)
            }
            let mine = Curve25519.KeyAgreement.PrivateKey()
            s.pending = Pending(request: request, hubPrivate: mine)
            return (.success(PairResponse(hubID: hub.hubID, hubDeviceID: hub.hubDeviceID, hubName: hub.hubName,
                                          publicKey: mine.publicKey.rawRepresentation)), true)
        }
        return try result.get()
    }

    /// R5a, R6, R6a: the device reveals its public key. Checks it against the commitment,
    /// derives the pairing key and the confirmation number from the shared secret and the
    /// transcript, drops the `pair` key, and moves to `.confirming`. A key that doesn't match
    /// the commitment ends the window (a man in the middle, or a broken client).
    @discardableResult
    public func reveal(_ reveal: PairConfirmRequest) throws(PairError) -> String {
        let result: Result<String, PairError> = changeReturning { s in
            guard case .open = s.state, let pending = s.pending, pending.client == nil, let hub = s.hub,
                  let endsAt = s.endsAt
            else { return (.failure(.refused), false) }
            guard PairingCrypto.commitment(to: reveal.publicKey) == pending.request.commitment,
                  let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: reveal.publicKey),
                  let shared = try? pending.hubPrivate.sharedSecretFromKeyAgreement(with: theirs)
            else {
                Self.end(&s, as: .cancelled)
                s.state = .closed
                return (.failure(.refused), true)
            }
            let transcript = PairingTranscript(
                hubTag: hub.tag, hubID: hub.hubID, hubDeviceID: hub.hubDeviceID, hubName: hub.hubName,
                deviceID: pending.request.deviceID, deviceName: pending.request.name, kind: pending.request.kind,
                devicePublicKey: reveal.publicKey, hubPublicKey: pending.hubPrivate.publicKey.rawRepresentation)
            let key = PairingCrypto.pairingKey(shared: shared, transcript: transcript)
            let sas = PairingCrypto.confirmationCode(shared: shared, transcript: transcript)
            let name = Self.cleanName(pending.request.name, kind: pending.request.kind)
            s.pending?.client = PairedClient(id: pending.request.deviceID, name: name, kind: pending.request.kind,
                                             key: key.withUnsafeBytes { Data($0) }, pairedAt: now())
            let confirmEnds = max(endsAt, now().addingTimeInterval(Self.minConfirmTime))
            s.state = .confirming(name: name, confirmationCode: sas, endsAt: confirmEnds)
            s.endsAt = confirmEnds
            s.codeKey = nil
            return (.success(sas), true)
        }
        return try result.get()
    }

    /// The owner tapped "They match" (R6a). Only now does the device's key reach the
    /// listener. Returns `false` when nothing was waiting for a decision.
    @discardableResult
    public func approve() -> Bool {
        var approved = false
        change { s in
            guard case .confirming(let name, _, _) = s.state else { return false }
            s.state = .matched(name: name)
            s.outcome = .matched
            Self.resume(&s, .matched)
            approved = true
            return true
        }
        return approved
    }

    /// Waits for the owner's decision on the revealed device (the held `POST /v1/pair/confirm`).
    /// Returns at once when the decision is already made. A cancelled task gets `.cancelled`
    /// and leaves the window as it is.
    public func decision() async -> Decision {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Decision, Never>) in
                let ready: Decision? = inner.withLock { s in
                    _ = Self.expire(&s, now: now())
                    switch s.state {
                    case .confirming:
                        if Task.isCancelled { return .cancelled }
                        s.waiters[id] = c
                        return nil
                    case .matched, .paired:
                        return .matched
                    default:
                        return s.outcome ?? .cancelled
                    }
                }
                if let ready { c.resume(returning: ready) }
            }
        } onCancel: {
            let c = inner.withLock { $0.waiters.removeValue(forKey: id) }
            c?.resume(returning: .cancelled)
        }
    }

    /// R7: the matched device made its first request with the new key. Saves it in the
    /// store and ends the window as `.paired(name:)`. Returns the saved entry, or `nil`
    /// when `id` was not matched (or the save failed).
    @discardableResult
    public func confirm(_ id: DeviceID) -> PairedClient? {
        guard pendingID == id,
              let client = inner.withLock({ s -> PairedClient? in s.pending?.client?.id == id ? s.pending?.client : nil })
        else { return nil }
        do {
            try store.save(client)
        } catch {
            return nil
        }
        change { s in
            guard case .matched = s.state, s.pending?.client?.id == id else { return false }
            Self.end(&s, as: .matched)
            s.state = .paired(name: client.name)
            return true
        }
        return client
    }

    /// Trimmed, at most 40 characters; blank names get the kind's default.
    static func cleanName(_ name: String, kind: DeviceKind) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (kind == .ipad ? "iPad" : "iPhone") : String(trimmed.prefix(40))
    }

    // MARK: Internals

    /// Drops the keys and the pending device and answers waiters with `decision`.
    private static func end(_ s: inout Inner, as decision: Decision) {
        if s.pending?.client != nil { s.outcome = decision }
        s.endsAt = nil
        s.codeKey = nil
        s.pending = nil
        resume(&s, decision)
    }

    private static func resume(_ s: inout Inner, _ decision: Decision) {
        let waiters = s.waiters.values
        s.waiters = [:]
        for w in waiters { w.resume(returning: decision) }
    }

    /// Moves a window past its deadline to `.closed` and drops the pending entry.
    private static func expire(_ s: inout Inner, now: Date) -> Bool {
        guard let endsAt = s.endsAt, now >= endsAt else { return false }
        switch s.state {
        case .open, .confirming, .matched:
            end(&s, as: .expired)
            s.state = .closed
            return true
        case .closed, .locked, .paired:
            s.endsAt = nil
            return false
        }
    }

    private func read<T>(_ body: (Inner) -> T) -> T {
        let (value, expired) = inner.withLock { s -> (T, Bool) in
            let expired = Self.expire(&s, now: now())
            return (body(s), expired)
        }
        if expired { notify() }
        return value
    }

    /// Runs `body` after the expiry check; notifies when it (or the expiry) changed something.
    private func change(_ body: (inout Inner) -> Bool) {
        let changed = inner.withLock { s -> Bool in
            let expired = Self.expire(&s, now: now())
            return body(&s) || expired
        }
        if changed { notify() }
    }

    private func changeReturning<T>(_ body: (inout Inner) -> (T, Bool)) -> T {
        let (value, changed) = inner.withLock { s -> (T, Bool) in
            let expired = Self.expire(&s, now: now())
            let (v, c) = body(&s)
            return (v, c || expired)
        }
        if changed { notify() }
        return value
    }

    private func notify() { observer.withLock { $0 }?() }
}
