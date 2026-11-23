import CryptoKit
import Foundation
import LevelsModel
import Network
import os

/// Sends one request to the paired hub (NET-003 Design). The real one is
/// ``NWHubTransport``; tests fake it.
public protocol HubTransport: Sendable {
    func send(_ request: HTTPRequest, to pairing: HubPairing, me: DeviceID, timeout: Duration) async throws(HubError) -> HTTPResponse
}

/// Bonjour (or a fixed endpoint) + TLS-PSK + the HTTP subset. Keeps one connection alive
/// for the next request (long-poll loop, NET-003 R7); a second request while it is busy
/// gets its own short connection.
public actor NWHubTransport: HubTransport {
    private let locator: any HubLocator
    private let findTimeout: Duration
    private let readyTimeout: Duration
    private var kept: (hubID: UUID, me: DeviceID, connection: HubClientConnection)?

    /// - Parameters:
    ///   - findTimeout: Bonjour lookup limit (NET-003 R5: 5 s).
    ///   - readyTimeout: connection-ready limit (NET-003 R5: 5 s).
    public init(locator: any HubLocator = BonjourHubLocator(), findTimeout: Duration = .seconds(5), readyTimeout: Duration = .seconds(5)) {
        self.locator = locator
        self.findTimeout = findTimeout
        self.readyTimeout = readyTimeout
    }

    public func send(_ request: HTTPRequest, to pairing: HubPairing, me: DeviceID, timeout: Duration) async throws(HubError) -> HTTPResponse {
        var request = request
        request.headers[HubProtocol.deviceHeader] = me.recordName
        if let kept, kept.hubID == pairing.hubID, kept.me == me, kept.connection.isUsable {
            do {
                return try await kept.connection.exchange(request, timeout: timeout)
            } catch .notReady {
                self.kept = nil  // the server closed the kept-alive connection; try a fresh one
            }
        }
        let connection = try await open(pairing: pairing, me: me)
        let reusable = kept == nil || !(kept!.connection.isUsable)
        if reusable { kept = (pairing.hubID, me, connection) }
        defer { if !reusable { connection.close() } }
        return try await connection.exchange(request, timeout: timeout)
    }

    /// Drops the kept connection (Forget, scene background).
    public func reset() {
        kept?.connection.close()
        kept = nil
    }

    private func open(pairing: HubPairing, me: DeviceID) async throws(HubError) -> HubClientConnection {
        let endpoint = try await locator.endpoint(forTag: pairing.hubTag, timeout: findTimeout)
        let connection = HubClientConnection(endpoint: endpoint, identity: me.recordName, key: pairing.symmetricKey)
        try await connection.open(timeout: readyTimeout)
        return connection
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
///   ``PairingSession/confirmationCode`` the screen shows ("Check that your Mac shows
///   123 456, then tap They match on the Mac"), then ``PairingSession/finish(now:)``
///   waits for the owner's tap on the Mac and checks the new key. ``PairingSession/cancel()``
///   (or cancelling the task) stops it.
/// - ``pair(with:hubTag:code:me:now:onConfirmationCode:)`` does both in one call and
///   hands the number to `onConfirmationCode` as soon as it is known.
///
/// The caller saves the returned pairing (after the R10 "Replace?" confirmation when
/// another Mac is stored).
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
                              confirmationCode: sas, connection: session, decision: decision, stepTimeout: stepTimeout)
    }

    /// The whole flow in one call. `onConfirmationCode` gets the 6-digit number to show
    /// (``PairingCrypto/displayCode(_:)`` formats it) before the wait for the Mac starts.
    public func pair(with endpoint: NWEndpoint, hubTag: String, code: String,
                     me: PairRequestIdentity, now: Date = Date(),
                     onConfirmationCode: @escaping @Sendable (String) -> Void = { _ in }) async throws(PairError) -> HubPairing {
        let session = try await start(with: endpoint, hubTag: hubTag, code: code, me: me)
        onConfirmationCode(session.confirmationCode)
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

/// A pairing waiting for the owner's "They match" on the Mac (NET-002 R6a, lead's call 30).
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

    init(endpoint: NWEndpoint, hubTag: String, me: PairRequestIdentity, response: PairResponse, key: SymmetricKey,
         confirmationCode: String, connection: HubClientConnection,
         decision: Task<Result<HTTPResponse, HubError>, Never>, stepTimeout: Duration) {
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
    }

    deinit { connection.close() }

    /// Waits for the owner's decision on the Mac, then R7: a normal request with the new key.
    /// Throws `.refused` when the owner tapped Cancel (or the numbers didn't match) and
    /// `.timedOut` when the window ended first. Call it once.
    public func finish(now: Date = Date()) async throws(PairError) -> HubPairing {
        let answer = await withTaskCancellationHandler { await decision.value } onCancel: { [connection] in connection.close() }
        connection.close()
        switch answer {
        case .success(let r) where r.status == 204: break
        case .success(let r) where r.status == 408: throw .timedOut
        case .success(let r) where r.status == 423: throw .tooManyTries
        case .success: throw .refused
        case .failure(let e): throw PairingClient.map(e, handshake: .refused)
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

    /// Stops waiting; the Mac's held request ends when the connection closes.
    public func cancel() {
        decision.cancel()
        connection.close()
    }
}
