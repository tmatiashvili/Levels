import CryptoKit
import Foundation
import LevelsModel
import Network
import os
import Synchronization

/// Sends one request to the paired hub (NET-003 Design). The real one is
/// ``NWHubTransport``; tests fake it.
public protocol HubTransport: Sendable {
    func send(_ request: HTTPRequest, to pairing: HubPairing, me: DeviceID, timeout: Duration) async throws(HubError) -> HTTPResponse
}

/// Bonjour (or a fixed endpoint) + TLS-PSK + the HTTP subset. Keeps one connection alive
/// for the next request (long-poll loop, NET-003 R7); a second request while it is busy
/// gets its own short connection.
public actor NWHubTransport: HubTransport {
    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "hub")

    private let locator: any HubLocator
    private let findTimeout: Duration
    private let readyTimeout: Duration
    private let memory: (any HubEndpointMemory)?
    private let directTimeout: Duration
    private let now: @Sendable () -> Date
    private var kept: (hubID: UUID, me: DeviceID, connection: HubClientConnection)?

    /// - Parameters:
    ///   - findTimeout: Bonjour lookup limit (NET-003 R5: 5 s).
    ///   - readyTimeout: connection-ready limit (NET-003 R5: 5 s).
    ///   - memory: the Mac's last address. When set, a new connection first dials it
    ///     (``directTimeout``), then falls back to Bonjour; a Bonjour connection saves its
    ///     resolved address. `nil` = Bonjour only.
    public init(locator: any HubLocator = BonjourHubLocator(), findTimeout: Duration = .seconds(5),
                readyTimeout: Duration = .seconds(5), memory: (any HubEndpointMemory)? = nil,
                directTimeout: Duration = .milliseconds(1500), now: @escaping @Sendable () -> Date = Date.init) {
        self.locator = locator
        self.findTimeout = findTimeout
        self.readyTimeout = readyTimeout
        self.memory = memory
        self.directTimeout = directTimeout
        self.now = now
    }

    public func send(_ request: HTTPRequest, to pairing: HubPairing, me: DeviceID, timeout: Duration) async throws(HubError) -> HTTPResponse {
        var request = request
        request.headers[HubProtocol.deviceHeader] = me.recordName
        if let current = kept {
            if current.hubID == pairing.hubID, current.me == me, current.connection.isUsable {
                do {
                    return try await current.connection.exchange(request, timeout: timeout)
                } catch .notReady {
                    // The server closed the kept-alive connection; try a fresh one.
                    if kept?.connection === current.connection { kept = nil }
                }
            } else if current.hubID != pairing.hubID || current.me != me || !current.connection.isAlive {
                // Another pairing, or dead: close it. A live, busy one (the long-poll) stays.
                current.connection.close()
                if kept?.connection === current.connection { kept = nil }
            }
        }
        let connection = try await open(pairing: pairing, me: me)
        // Keep it only if nothing is kept now (checked after the await: the actor is
        // reentrant). A second request while the long-poll holds the kept connection gets
        // this short-lived one, closed when done; it never replaces the busy one.
        if kept == nil {
            kept = (pairing.hubID, me, connection)
            return try await connection.exchange(request, timeout: timeout)
        }
        defer { connection.close() }
        return try await connection.exchange(request, timeout: timeout)
    }

    /// Drops the kept connection (Forget, scene background).
    public func reset() {
        kept?.connection.close()
        kept = nil
    }

    private func open(pairing: HubPairing, me: DeviceID) async throws(HubError) -> HubClientConnection {
        let started = ContinuousClock.now
        if let memory, let record = memory.load() {
            if record.isUsable(for: pairing.hubID, now: now()), let endpoint = record.endpoint {
                let direct = HubClientConnection(endpoint: endpoint, identity: me.recordName, key: pairing.symmetricKey)
                do {
                    try await direct.open(timeout: directTimeout)
                    var seen = record
                    seen.savedAt = now()  // still good: keep it past ``HubEndpointRecord/maxAge``
                    memory.save(seen)
                    Self.logger.notice("Hub: connected to the last address in \(Self.ms(since: started), privacy: .public) ms")
                    return direct
                } catch .localNetworkDenied {
                    throw .localNetworkDenied  // Bonjour would be refused too
                } catch {
                    // A wrong or old address can only fail (TLS-PSK proves the Mac), even with
                    // a refusal: that is not "the Mac forgot this iPhone" until Bonjour says so.
                    Self.logger.notice("Hub: last address failed (\(String(describing: error), privacy: .public)) after \(Self.ms(since: started), privacy: .public) ms; using Bonjour")
                    memory.clear()
                }
            } else {
                memory.clear()
            }
        }
        let endpoint = try await locator.endpoint(forTag: pairing.hubTag, timeout: findTimeout)
        let found = Self.ms(since: started)
        let connection = HubClientConnection(endpoint: endpoint, identity: me.recordName, key: pairing.symmetricKey)
        try await connection.open(timeout: readyTimeout)
        Self.logger.notice("Hub: connected through Bonjour (found in \(found, privacy: .public) ms, ready in \(Self.ms(since: started), privacy: .public) ms)")
        if let memory, let resolved = connection.remoteEndpoint,
           let record = HubEndpointRecord(endpoint: resolved, hubID: pairing.hubID, savedAt: now()) {
            memory.save(record)
        }
        return connection
    }

    private static func ms(since start: ContinuousClock.Instant) -> Int64 {
        let d = ContinuousClock.now - start
        return d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000
    }
}

/// The answer to `GET /v1/snapshot`.
public enum HubFetch: Sendable, Equatable {
    case changed(HubSnapshot, etag: String)
    case notModified(etag: String)
}

/// The iPhone's (and the widget's) view of the hub API (NET-003 Design).
public actor HubClient {
    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "hub")

    private let transport: any HubTransport
    private let store: any ClientPairingStore
    private let me: DeviceID
    /// Margin added to a long-poll's `wait` for the answer to arrive.
    public static let answerMargin: Duration = .seconds(10)

    public init(transport: any HubTransport, pairing: any ClientPairingStore, me: DeviceID) {
        self.transport = transport
        self.store = pairing
        self.me = me
    }

    /// The stored pairing, if any.
    public var pairing: HubPairing? { store.current() }

    /// `GET /v1/snapshot` (with `?wait=` for a long-poll, NET-003 R3, R7).
    public func snapshot(ifNoneMatch etag: String?, wait: Duration? = nil) async throws(HubError) -> HubFetch {
        var request = HTTPRequest(method: "GET", path: HubProtocol.Path.snapshot)
        if let etag { request.headers["if-none-match"] = etag }
        var timeout = Self.answerMargin
        if let wait, wait > .zero {
            let seconds = min(wait, HubProtocol.maxWait).components.seconds
            request.query["wait"] = String(seconds)
            timeout += .seconds(seconds)
        }
        let response = try await send(request, timeout: timeout)
        switch response.status {
        case 200:
            guard let snapshot = try? HubWire.decoder().decode(HubSnapshot.self, from: response.body) else { throw .badResponse(200) }
            guard snapshot.v == HubProtocol.version else { throw .versionMismatch }
            return .changed(snapshot, etag: response.header("etag") ?? HubWire.etag(for: snapshot.devices))
        case 304:
            return .notModified(etag: response.header("etag") ?? etag ?? "")
        default:
            throw .badResponse(response.status)
        }
    }

    /// `POST /v1/readings` with this device's own record (NET-003 R4). Returns the new ETag.
    @discardableResult
    public func post(_ record: DeviceBattery) async throws(HubError) -> String? {
        guard let body = try? HubWire.encoder().encode([record]) else { throw .badResponse(0) }
        let request = HTTPRequest(method: "POST", path: HubProtocol.Path.readings,
                                  headers: ["content-type": "application/json"], body: body)
        let response = try await send(request, timeout: Self.answerMargin)
        guard response.status == 204 else { throw .badResponse(response.status) }
        return response.header("etag")
    }

    /// `PUT /v1/push-tokens` with this device's full token set. `false` when the Mac doesn't
    /// know the route (404/405: an older Mac); other errors throw.
    @discardableResult
    public func putPushTokens(_ tokens: [PushToken]) async throws(HubError) -> Bool {
        guard let body = try? HubWire.encoder().encode(PushTokenUpload(tokens: tokens)) else { throw .badResponse(0) }
        let request = HTTPRequest(method: "PUT", path: HubProtocol.Path.pushTokens,
                                  headers: ["content-type": "application/json"], body: body)
        let response = try await send(request, timeout: Self.answerMargin)
        switch response.status {
        case 204: return true
        case 404, 405: return false
        default: throw .badResponse(response.status)
        }
    }

    /// `DELETE /v1/devices/me` (NET-003 R10).
    public func deleteMe() async throws(HubError) {
        let response = try await send(HTTPRequest(method: "DELETE", path: HubProtocol.Path.devicesMe), timeout: Self.answerMargin)
        guard response.status == 204 else { throw .badResponse(response.status) }
    }

    /// "Forget this Mac" (NET-002 R9): `DELETE /v1/pairing` if the Mac is reachable (best
    /// effort), then deletes the stored pairing. Returns whether the Mac confirmed it.
    @discardableResult
    public func forget() async -> Bool {
        var confirmed = false
        if store.current() != nil {
            do {
                let response = try await send(HTTPRequest(method: "DELETE", path: HubProtocol.Path.pairing), timeout: .seconds(5))
                confirmed = response.status == 204
            } catch {
                Self.logger.notice("Forget: Mac not reachable (\(String(describing: error), privacy: .public)); forgetting locally")
            }
        }
        do { try store.remove() } catch {
            Self.logger.error("Forget: Keychain delete failed: \(String(describing: error), privacy: .public)")
        }
        if let nw = transport as? NWHubTransport { await nw.reset() }
        return confirmed
    }

    private func send(_ request: HTTPRequest, timeout: Duration) async throws(HubError) -> HTTPResponse {
        guard let pairing = store.current() else { throw .notPaired }
        return try await transport.send(request, to: pairing, me: me, timeout: timeout)
    }
}

/// The identity a device pairs with (NET-002 R5).
public struct PairRequestIdentity: Sendable, Equatable {
    public var deviceID: DeviceID
    public var name: String
    public var kind: DeviceKind
    public init(deviceID: DeviceID, name: String, kind: DeviceKind) {
        self.deviceID = deviceID
        self.name = name
        self.kind = kind
    }
}

/// The iPhone side of NET-002 R4–R7, end to end (lead's call 30). Two ways to run it:
///
/// - ``start(with:hubTag:code:me:)`` returns a ``PairingSession`` whose
///   ``PairingSession/confirmationCode`` the screen shows ("Does your Mac show this number?"
///   with They match / Cancel). ``PairingSession/confirmLocally()`` is the iPhone's They match;
///   ``PairingSession/finish(now:)`` returns only after BOTH that tap and the Mac's 204 (the
///   owner's They match on the Mac), in either order, and then checks the new key.
///   ``PairingSession/cancel()`` (or cancelling the task) stops it and nothing is returned.
/// - ``pair(with:hubTag:code:me:now:confirm:)`` does both in one call: `confirm` shows the
///   number and returns the owner's answer on the iPhone.
///
/// Two-sided comparison (NET-002 R6b): the iPhone never trusts the Mac's 204 alone, so a
/// man in the middle the owner refused on the Mac can't make the iPhone keep its key. The
/// caller saves the returned pairing (after the R10 "Replace?" confirmation when another
/// Mac is stored).
public struct PairingClient: Sendable {
    static let logger = Logger(subsystem: LevelsLog.subsystem, category: "hub")
    /// Every network step's limit (NET-002 Design: 10 s each).
    public let stepTimeout: Duration
    /// How long ``PairingSession/finish(now:)`` waits for "They match" on the Mac.
    public let confirmTimeout: Duration

    public init(stepTimeout: Duration = .seconds(10), confirmTimeout: Duration = .seconds(120)) {
        self.stepTimeout = stepTimeout
        self.confirmTimeout = confirmTimeout
    }

    /// R4–R6a: opens the `pair` session, swaps keys (commitment first), derives the key and
    /// the confirmation number, and reveals this device's key so the Mac shows the number too.
    public func start(with endpoint: NWEndpoint, hubTag: String, code: String,
                      me: PairRequestIdentity) async throws(PairError) -> PairingSession {
        let codeKey = PairingCrypto.codeKey(code: code, hubTag: hubTag)
        // R4: identity `pair`, key from the code.
        let session = HubClientConnection(endpoint: endpoint, identity: HubProtocol.pairIdentity, key: codeKey)
        var handedOff = false
        defer { if !handedOff { session.close() } }
        do { try await session.open(timeout: stepTimeout) } catch {
            Self.logger.notice("Pairing handshake failed: \(String(describing: error), privacy: .public)")
            throw Self.map(error, handshake: .wrongCode)
        }
        // R5: a fresh X25519 key; only its commitment goes first.
        let mine = Curve25519.KeyAgreement.PrivateKey()
        let myPublic = mine.publicKey.rawRepresentation
        let request = PairRequest(deviceID: me.deviceID, name: me.name, kind: me.kind,
                                  commitment: PairingCrypto.commitment(to: myPublic))
        let answer = try await post(HubProtocol.Path.pair, request, on: session, timeout: stepTimeout)
        switch answer.status {
        case 200: break
        case 409: throw .hubFull
        case 423: throw .tooManyTries
        default: throw .refused
        }
        guard let response = try? HubWire.decoder().decode(PairResponse.self, from: answer.body),
              let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: response.publicKey),
              let shared = try? mine.sharedSecretFromKeyAgreement(with: theirs)
        else { throw .refused }
        // R6, R6a
        let transcript = PairingTranscript(hubTag: hubTag, hubID: response.hubID, hubDeviceID: response.hubDeviceID,
                                           hubName: response.hubName, deviceID: me.deviceID, deviceName: me.name,
                                           kind: me.kind, devicePublicKey: myPublic, hubPublicKey: response.publicKey)
        let key = PairingCrypto.pairingKey(shared: shared, transcript: transcript)
        let sas = PairingCrypto.confirmationCode(shared: shared, transcript: transcript)
        // R5a: reveal the key; the Mac answers when the owner decides.
        guard let body = try? HubWire.encoder().encode(PairConfirmRequest(publicKey: myPublic)) else { throw .refused }
        let reveal = HTTPRequest(method: "POST", path: HubProtocol.Path.pairConfirm,
                                 headers: ["content-type": "application/json"], body: body)
        let confirmTimeout = confirmTimeout
        let decision = Task { () -> Result<HTTPResponse, HubError> in
            do throws(HubError) { return .success(try await session.exchange(reveal, timeout: confirmTimeout)) } catch { return .failure(error) }
        }
        handedOff = true
        return PairingSession(endpoint: endpoint, hubTag: hubTag, me: me, response: response, key: key,
                              confirmationCode: sas, connection: session, decision: decision,
                              stepTimeout: stepTimeout, confirmTimeout: confirmTimeout)
    }

    /// The whole flow in one call. `confirm` gets the 6-digit number to show
    /// (``PairingCrypto/displayCode(_:)`` formats it) and returns `true` when the owner taps
    /// They match on this device, `false` for Cancel. It runs while the Mac waits for its own
    /// tap; the pairing is returned only when both said yes (R6b).
    public func pair(with endpoint: NWEndpoint, hubTag: String, code: String,
                     me: PairRequestIdentity, now: Date = Date(),
                     confirm: @escaping @Sendable (String) async -> Bool) async throws(PairError) -> HubPairing {
        let session = try await start(with: endpoint, hubTag: hubTag, code: code, me: me)
        let asking = Task {
            if await confirm(session.confirmationCode) { session.confirmLocally() } else { session.cancel() }
        }
        defer { asking.cancel() }
        return try await session.finish(now: now)
    }

    private func post<T: Encodable>(_ path: String, _ value: T, on session: HubClientConnection,
                                    timeout: Duration) async throws(PairError) -> HTTPResponse {
        guard let body = try? HubWire.encoder().encode(value) else { throw .refused }
        do {
            return try await session.exchange(HTTPRequest(method: "POST", path: path,
                                                          headers: ["content-type": "application/json"], body: body),
                                              timeout: timeout)
        } catch {
            throw Self.map(error, handshake: .refused)
        }
    }

    static func map(_ error: HubError, handshake: PairError) -> PairError {
        switch error {
        case .handshakeRefused: handshake
        case .timedOut: .timedOut
        case .notFound, .notReady, .localNetworkDenied, .notPaired: .notReachable
        case .versionMismatch, .badResponse: .refused
        }
    }
}

/// The iPhone owner's answer to "Does your Mac show this number?" (NET-002 R6b). One-shot:
/// the first answer wins; `wait` returns it whenever it comes, before or after the call.
final class LocalConfirmation: Sendable {
    enum Answer: Sendable { case matched, cancelled, expired }
    private struct State {
        var answer: Answer?
        var waiters: [CheckedContinuation<Answer, Never>] = []
    }
    private let state = Mutex(State())

    /// Returns `false` when an answer was already given.
    @discardableResult func answer(_ a: Answer) -> Bool {
        let waiters: [CheckedContinuation<Answer, Never>]? = state.withLock { s in
            guard s.answer == nil else { return nil }
            s.answer = a
            defer { s.waiters = [] }
            return s.waiters
        }
        guard let waiters else { return false }
        for w in waiters { w.resume(returning: a) }
        return true
    }

    var current: Answer? { state.withLock { $0.answer } }

    func wait() async -> Answer {
        await withCheckedContinuation { c in
            let ready: Answer? = state.withLock { s in
                if let a = s.answer { return a }
                s.waiters.append(c)
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
    }
}

/// A pairing waiting for the owner's "They match" on BOTH screens (NET-002 R6a, R6b; lead's call 30).
public final class PairingSession: Sendable {
    /// The 6-digit number to show; the Mac shows the same one when nobody is in the middle.
    public let confirmationCode: String
    /// The Mac's display name, for "Pairing with <name>".
    public let hubName: String

    private let endpoint: NWEndpoint
    private let hubTag: String
    private let me: PairRequestIdentity
    private let response: PairResponse
    private let key: SymmetricKey
    private let connection: HubClientConnection
    private let decision: Task<Result<HTTPResponse, HubError>, Never>
    private let stepTimeout: Duration
    private let local: LocalConfirmation
    private let localDeadline: Task<Void, Never>

    init(endpoint: NWEndpoint, hubTag: String, me: PairRequestIdentity, response: PairResponse, key: SymmetricKey,
         confirmationCode: String, connection: HubClientConnection,
         decision: Task<Result<HTTPResponse, HubError>, Never>, stepTimeout: Duration, confirmTimeout: Duration) {
        self.endpoint = endpoint
        self.hubTag = hubTag
        self.me = me
        self.response = response
        self.key = key
        self.confirmationCode = confirmationCode
        self.hubName = response.hubName
        self.connection = connection
        self.decision = decision
        self.stepTimeout = stepTimeout
        let local = LocalConfirmation()
        self.local = local
        self.localDeadline = Task {
            try? await Task.sleep(for: confirmTimeout)
            if !Task.isCancelled { local.answer(.expired) }
        }
    }

    deinit {
        localDeadline.cancel()
        connection.close()
    }

    /// The owner tapped They match on this device (R6b). Ignored after ``cancel()``.
    public func confirmLocally() { local.answer(.matched) }

    /// Waits for BOTH the owner's They match on this device (``confirmLocally()``) and the
    /// Mac's 204, in either order, then R7: a normal request with the new key. Nothing that
    /// uses the new key happens before both. Throws `.refused` when the owner tapped Cancel
    /// on either screen (or the numbers didn't match) and `.timedOut` when the window ended
    /// first. Call it once.
    public func finish(now: Date = Date()) async throws(PairError) -> HubPairing {
        let answer = await withTaskCancellationHandler { await decision.value } onCancel: { [connection] in connection.close() }
        connection.close()
        if local.current == .cancelled { throw .refused }
        switch answer {
        case .success(let r) where r.status == 204: break
        case .success(let r) where r.status == 408: throw .timedOut
        case .success(let r) where r.status == 423: throw .tooManyTries
        case .success: throw .refused
        case .failure(let e): throw PairingClient.map(e, handshake: .refused)
        }
        if Task.isCancelled { throw .refused }
        // R6b: the Mac said yes; the iPhone's owner must say yes too before the key is used.
        let mine = await withTaskCancellationHandler { await local.wait() } onCancel: { [local] in local.answer(.cancelled) }
        localDeadline.cancel()
        switch mine {
        case .matched: break
        case .cancelled: throw .refused
        case .expired: throw .timedOut
        }
        if Task.isCancelled { throw .refused }
        // R7: a normal request with the new key confirms the pairing on the Mac.
        let confirm = HubClientConnection(endpoint: endpoint, identity: me.deviceID.recordName, key: key)
        defer { confirm.close() }
        do {
            try await confirm.open(timeout: stepTimeout)
            let check = try await confirm.exchange(HTTPRequest(method: "GET", path: HubProtocol.Path.snapshot,
                                                               headers: [HubProtocol.deviceHeader: me.deviceID.recordName]),
                                                   timeout: stepTimeout)
            guard check.status == 200 else { throw PairError.refused }
        } catch let error as HubError {
            throw PairingClient.map(error, handshake: .refused)
        } catch {
            throw .refused
        }
        PairingClient.logger.notice("Paired with hub \(self.hubTag, privacy: .public)")
        return HubPairing(hubID: response.hubID, hubTag: hubTag, hubDeviceID: response.hubDeviceID,
                          hubName: response.hubName, key: key.withUnsafeBytes { Data($0) }, pairedAt: now)
    }

    /// Cancel on this device: stops waiting and nothing is returned or saved, even after the
    /// Mac's 204 (the Mac drops the pending device when its first request never comes, R7).
    public func cancel() {
        local.answer(.cancelled)
        localDeadline.cancel()
        decision.cancel()
        connection.close()
    }
}
