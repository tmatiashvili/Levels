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

/// The iPhone side of NET-002 R4–R7, end to end. The caller saves the returned pairing
/// (after the R10 "Replace?" confirmation when another Mac is stored).
public struct PairingClient: Sendable {
    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "hub")
    /// Every step's limit (NET-002 Design: 10 s each, 30 s total).
    public let stepTimeout: Duration

    public init(stepTimeout: Duration = .seconds(10)) { self.stepTimeout = stepTimeout }

    public func pair(with endpoint: NWEndpoint, hubTag: String, code: String,
                     me: PairRequestIdentity, now: Date = Date()) async throws(PairError) -> HubPairing {
        let codeKey = PairingCrypto.codeKey(code: code, hubTag: hubTag)
        // R4: identity `pair`, key from the code.
        let session = HubClientConnection(endpoint: endpoint, identity: HubProtocol.pairIdentity, key: codeKey)
        defer { session.close() }
        do { try await session.open(timeout: stepTimeout) } catch {
            Self.logger.notice("Pairing handshake failed: \(String(describing: error), privacy: .public)")
            throw Self.map(error, handshake: .wrongCode)
        }
        // R5: swap fresh X25519 keys.
        let mine = Curve25519.KeyAgreement.PrivateKey()
        let request = PairRequest(deviceID: me.deviceID, name: me.name, kind: me.kind, publicKey: mine.publicKey.rawRepresentation)
        guard let body = try? HubWire.encoder().encode(request) else { throw .refused }
        let answer: HTTPResponse
        do {
            answer = try await session.exchange(HTTPRequest(method: "POST", path: HubProtocol.Path.pair,
                                                            headers: ["content-type": "application/json"], body: body),
                                                timeout: stepTimeout)
        } catch {
            throw Self.map(error, handshake: .refused)
        }
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
        // R6
        let key = PairingCrypto.pairingKey(shared: shared, codeKey: codeKey, hubID: response.hubID, deviceID: me.deviceID)
        session.close()
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
            throw Self.map(error, handshake: .refused)
        } catch {
            throw .refused
        }
        Self.logger.notice("Paired with hub \(hubTag, privacy: .public)")
        return HubPairing(hubID: response.hubID, hubTag: hubTag, hubDeviceID: response.hubDeviceID,
                          hubName: response.hubName, key: key.withUnsafeBytes { Data($0) }, pairedAt: now)
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
