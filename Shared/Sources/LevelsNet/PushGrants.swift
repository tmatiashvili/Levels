import CryptoKit
import Foundation
import LevelsModel
import os

// The iPhone's side of push grants (PUSH-001 R30–R36, R71–R72). The app proves it is a
// genuine Levels app with App Attest once (`/v1/challenge` → `/v1/attest` → credential), then
// asks the relay for a grant naming the paired Mac's public key and this iPhone's tokens
// (`/v1/grant`). The grant goes to the Mac over the hub (`PUT /v1/push-tokens`, v2).
// `DCAppAttestService` itself lives in the app target (Levels-iOS/Reporting/AppAttest.swift):
// LevelsNet stays free of DeviceCheck, and the widget extension can't use App Attest anyway.

/// `DCAppAttestService`, as the grant provider needs it. Fakes in tests.
public protocol AppAttesting: Sendable {
    /// `false` on the simulator and where App Attest isn't available: push stays off (R71).
    var isSupported: Bool { get }
    /// A new Secure Enclave key; returns its key ID (base64).
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

/// A grant the relay issued (R34).
public struct PushGrant: Codable, Sendable, Equatable {
    public var grant: String
    public var env: APNsEnvironment
    /// Unix seconds.
    public var expiresAt: Int64
    public init(grant: String, env: APNsEnvironment, expiresAt: Int64) {
        self.grant = grant
        self.env = env
        self.expiresAt = expiresAt
    }
}

/// Errors from the relay's iPhone routes.
public enum PushGrantError: Error, Equatable, Sendable {
    /// 401 with this code (`credential_invalid`, `credential_expired`, `attest_<reason>`, `challenge_*`).
    case unauthorized(String)
    case rateLimited(retryAfter: TimeInterval?)
    case status(Int)
    case unreachable
    case badAnswer
}

/// `{"error":"<code>"}` (PUSH-001 R2).
struct RelayErrorBody: Decodable { var error: String }

/// The relay's `/v1/challenge`, `/v1/attest` and `/v1/grant` (R30, R31, R34).
public struct PushGrantRelayClient: Sendable {
    private let base: String
    private let transport: any PushRelayTransport

    public init?(relayURL: String, transport: any PushRelayTransport = URLSessionPushRelayTransport()) {
        guard RelayBaseURL.make(relayURL, path: "/v1/challenge") != nil else { return nil }
        var trimmed = relayURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.base = trimmed
        self.transport = transport
    }

    public struct Challenge: Decodable, Sendable { public var challenge: String; public var expiresAt: Int64 }
    public struct Credential: Codable, Sendable, Equatable {
        public var credential: String
        public var env: APNsEnvironment
        public var expiresAt: Int64
    }

    public func challenge() async throws(PushGrantError) -> Challenge {
        try await call("/v1/challenge", body: Data("{}".utf8))
    }

    public func attest(keyId: String, attestation: Data, challenge: String) async throws(PushGrantError) -> Credential {
        try await call("/v1/attest", json: ["keyId": keyId, "attestation": attestation.base64EncodedString(), "challenge": challenge])
    }

    public func grant(credential: String, clientData: Data, assertion: Data) async throws(PushGrantError) -> PushGrant {
        try await call("/v1/grant", json: ["credential": credential, "clientData": clientData.base64EncodedString(),
                                           "assertion": assertion.base64EncodedString()])
    }

    private func call<T: Decodable>(_ path: String, json: [String: String]) async throws(PushGrantError) -> T {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let body = try? e.encode(json) else { throw .badAnswer }
        return try await call(path, body: body)
    }

    private func call<T: Decodable>(_ path: String, body: Data) async throws(PushGrantError) -> T {
        guard let url = URL(string: base + path) else { throw .badAnswer }
        let answer: (status: Int, headers: [String: String], body: Data)
        do { answer = try await transport.post(url: url, headers: ["content-type": "application/json"], body: body) } catch {
            throw .unreachable
        }
        switch answer.status {
        case 200:
            guard let value = try? JSONDecoder().decode(T.self, from: answer.body) else { throw .badAnswer }
            return value
        case 401:
            throw .unauthorized((try? JSONDecoder().decode(RelayErrorBody.self, from: answer.body))?.error ?? "")
        case 429:
            let raw = answer.headers.first { $0.key.lowercased() == "retry-after" }?.value
            throw .rateLimited(retryAfter: raw.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) })
        default:
            throw .status(answer.status)
        }
    }
}

/// What the iPhone's hub sync needs from push (LocalNetworkSyncService). `nil` there = push off.
public protocol PushRegistrationSource: Sendable {
    /// This iPhone's current tokens (the widget's from the App Group).
    func tokens() async -> [PushToken]
    /// A grant naming `macKey` for `tokens`. Cached grants with more than 7 days left are
    /// reused unless `forceNew`. `nil` = none now (no App Attest, relay down or backing off).
    func grant(for tokens: [PushToken], macKey: String, forceNew: Bool) async -> PushGrant?
}

/// Keeps the App Attest key ID and credential (Keychain) and the last grant, and talks to the
/// relay. One per app process.
public actor RelayPushGrantProvider: PushRegistrationSource {
    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "push")
    /// R72: a grant with less than this left is renewed.
    public static let renewBefore: TimeInterval = 7 * 24 * 3600
    static let credentialAccount = "credential"
    static let grantAccount = "grant"

    struct StoredCredential: Codable, Equatable {
        var keyId: String
        var credential: String?
        var env: APNsEnvironment?
        var expiresAt: Int64?
    }

    struct StoredGrant: Codable, Equatable {
        var grant: PushGrant
        var macKey: String
        /// "kind:hash" of the tokens it covers.
        var tokens: [String]
    }

    private let relay: PushGrantRelayClient
    private let attest: any AppAttesting
    private let items: any KeychainItems
    private let service: String
    private let tokenSource: @Sendable () async -> [PushToken]
    private let now: @Sendable () -> Date
    private var retryAt: Date?
    private var failures = 0

    /// - Parameters:
    ///   - service: Keychain service for the App Attest key ID, credential and last grant
    ///     (`<rdns>.levels.push`); this device only, never synchronized.
    public init(relay: PushGrantRelayClient, attest: any AppAttesting, items: any KeychainItems, service: String,
                tokens: @escaping @Sendable () async -> [PushToken], now: @escaping @Sendable () -> Date = Date.init) {
        self.relay = relay
        self.attest = attest
        self.items = items
        self.service = service
        self.tokenSource = tokens
        self.now = now
    }

    public func tokens() async -> [PushToken] { await tokenSource() }

    public func grant(for tokens: [PushToken], macKey: String, forceNew: Bool) async -> PushGrant? {
        let t = now()
        let wanted = tokens.map { "\($0.kind.rawValue):\(PushAuthV1.tokenHash($0.token))" }.sorted()
        if !forceNew, let cached = load(StoredGrant.self, Self.grantAccount), cached.macKey == macKey, cached.tokens == wanted,
           TimeInterval(cached.grant.expiresAt) - t.timeIntervalSince1970 > Self.renewBefore {
            return cached.grant
        }
        guard attest.isSupported else { return nil }
        if let retryAt, retryAt > t { return nil }
        guard (1...4).contains(tokens.count) else { return nil }  // relay: 1–4 tokens per grant
        do {
            let grant = try await mint(tokens: tokens, macKey: macKey, retryOnStaleCredential: true)
            save(StoredGrant(grant: grant, macKey: macKey, tokens: wanted), Self.grantAccount)
            failures = 0
            retryAt = nil
            Self.logger.notice("Push grant issued (\(grant.env.rawValue, privacy: .public))")
            return grant
        } catch {
            let wait: TimeInterval
            if case .rateLimited(let after?) = error { wait = max(60, after) } else {
                wait = min(6 * 3600, 60 * pow(2, Double(min(failures, 10))))
            }
            failures += 1
            retryAt = t.addingTimeInterval(wait)
            Self.logger.notice("Push grant not issued: \(String(describing: error), privacy: .public); next try in \(Int(wait), privacy: .public) s")
            return nil
        }
    }

    private func mint(tokens: [PushToken], macKey: String, retryOnStaleCredential: Bool) async throws(PushGrantError) -> PushGrant {
        let credential = try await credential()
        let challenge = try await relay.challenge()
        struct ClientData: Encodable {
            struct T: Encodable { var kind: String; var hash: String }
            var challenge: String
            var macKey: String
            var tokens: [T]
        }
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let clientData = try? e.encode(ClientData(challenge: challenge.challenge, macKey: macKey,
                                                        tokens: tokens.map { .init(kind: $0.kind.rawValue, hash: PushAuthV1.tokenHash($0.token)) }))
        else { throw .badAnswer }
        let assertion: Data
        do {
            assertion = try await attest.generateAssertion(credential.keyId, clientDataHash: Data(SHA256.hash(data: clientData)))
        } catch {
            // The key is gone (app reinstalled, or the system invalidated it): attest again.
            Self.logger.notice("App Attest assertion failed: \(String(describing: error), privacy: .public); attesting again")
            clear(Self.credentialAccount)
            guard retryOnStaleCredential else { throw .unauthorized("assertion") }
            return try await mint(tokens: tokens, macKey: macKey, retryOnStaleCredential: false)
        }
        do {
            return try await relay.grant(credential: credential.credential ?? "", clientData: clientData, assertion: assertion)
        } catch .unauthorized(let code) where code.hasPrefix("credential_") || code.hasPrefix("attest_") {
            // Relay key rotated, credential expired or the key's counter is off: attest again once.
            clear(Self.credentialAccount)
            guard retryOnStaleCredential else { throw .unauthorized(code) }
            return try await mint(tokens: tokens, macKey: macKey, retryOnStaleCredential: false)
        }
    }

    /// The stored credential, or a new one (R31). A key that was made but never attested is
    /// reused, so an interrupted attestation doesn't leak Secure Enclave keys.
    private func credential() async throws(PushGrantError) -> StoredCredential {
        let t = now().timeIntervalSince1970
        var stored = load(StoredCredential.self, Self.credentialAccount)
        if let s = stored, s.credential != nil, let exp = s.expiresAt, TimeInterval(exp) - t > Self.renewBefore { return s }
        // A key can be attested only once: an expiring credential needs a new key.
        if stored == nil || stored?.credential != nil {
            do { stored = StoredCredential(keyId: try await attest.generateKey()) } catch {
                Self.logger.error("App Attest key not made: \(String(describing: error), privacy: .public)")
                throw .unauthorized("generate_key")
            }
            save(stored!, Self.credentialAccount)
        }
        let keyId = stored!.keyId
        let challenge = try await relay.challenge()
        let attestation: Data
        do {
            attestation = try await attest.attestKey(keyId, clientDataHash: Data(SHA256.hash(data: Data(challenge.challenge.utf8))))
        } catch {
            // A key can be attested once; a failed or repeated attestation needs a new key.
            clear(Self.credentialAccount)
            Self.logger.error("App Attest attestation failed: \(String(describing: error), privacy: .public)")
            throw .unauthorized("attest_key")
        }
        let answer: PushGrantRelayClient.Credential
        do { answer = try await relay.attest(keyId: keyId, attestation: attestation, challenge: challenge.challenge) } catch {
            if case .unauthorized = error { clear(Self.credentialAccount) }  // this key is spent
            throw error
        }
        let done = StoredCredential(keyId: keyId, credential: answer.credential, env: answer.env, expiresAt: answer.expiresAt)
        save(done, Self.credentialAccount)
        return done
    }

    // MARK: Keychain

    private func load<T: Decodable>(_ type: T.Type, _ account: String) -> T? {
        guard let data = try? items.readAll(service: service)[account] else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ account: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        do { try items.write(service: service, account: account, data: data) } catch {
            Self.logger.error("Push Keychain write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func clear(_ account: String) { try? items.delete(service: service, account: account) }
}
