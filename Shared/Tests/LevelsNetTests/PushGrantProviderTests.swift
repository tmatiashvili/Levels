import CryptoKit
import Foundation
import LevelsModel
import Synchronization
import Testing
@testable import LevelsNet

/// `DCAppAttestService` stand-in: counts keys, attestations and assertions.
final class FakeAppAttest: AppAttesting {
    struct State { var keys = 0; var attested: [String] = []; var assertions: [String] = []; var failAssertion = false }
    let state = Mutex(State())
    let isSupported: Bool
    init(supported: Bool = true) { isSupported = supported }
    func generateKey() async throws -> String {
        state.withLock { s in
            s.keys += 1
            return Data(SHA256.hash(data: Data("key\(s.keys)".utf8))).base64EncodedString()
        }
    }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        state.withLock { $0.attested.append(keyId) }
        return Data("attestation".utf8)
    }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try state.withLock { s in
            if s.failAssertion { s.failAssertion = false; throw CancellationError() }
            s.assertions.append(keyId)
            return Data("assertion".utf8)
        }
    }
}

/// Answers the relay's iPhone routes.
final class FakeGrantRelay: PushRelayTransport {
    struct State { var calls: [(path: String, body: Data)] = []; var grantAnswers: [(Int, String)] = []; var down = false; var n = 0 }
    let state = Mutex(State())
    func paths() -> [String] { state.withLock { $0.calls.map(\.path) } }
    func body(of path: String) -> [String: String]? {
        state.withLock { s in s.calls.last { $0.path == path }.flatMap { try? JSONDecoder().decode([String: String].self, from: $0.body) } }
    }
    func post(url: URL, headers: [String: String], body: Data) async throws -> (status: Int, headers: [String: String], body: Data) {
        try state.withLock { s in
            if s.down { throw URLError(.notConnectedToInternet) }
            s.calls.append((url.path(), body))
            s.n += 1
            switch url.path() {
            case "/v1/challenge": return (200, [:], Data(#"{"challenge":"ch1.c\#(s.n).m","expiresAt":1800000300}"#.utf8))
            case "/v1/attest": return (200, [:], Data(#"{"credential":"c1.cred\#(s.n).m","env":"development","expiresAt":1831536000}"#.utf8))
            default:
                if !s.grantAnswers.isEmpty { let (st, b) = s.grantAnswers.removeFirst(); return (st, [:], Data(b.utf8)) }
                return (200, [:], Data(#"{"grant":"g1.grant\#(s.n).m","env":"development","expiresAt":1802592000}"#.utf8))
            }
        }
    }
}

@Suite("PUSH iPhone grant provider (App Attest → credential → grant)")
struct PushGrantProviderTests {
    let attest = FakeAppAttest()
    let relay = FakeGrantRelay()
    let items = InMemoryKeychainItems()
    let token = PushToken(token: String(repeating: "ab", count: 32), env: .development, kind: .widget)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func provider(_ attest: FakeAppAttest? = nil) -> RelayPushGrantProvider {
        let token = token
        let now = now
        return RelayPushGrantProvider(relay: PushGrantRelayClient(relayURL: "https://relay.example", transport: relay)!,
                                      attest: attest ?? self.attest, items: items, service: "push", tokens: { [token] },
                                      now: { now })
    }

    @Test func attestsOnceThenReusesCredentialAndGrant() async throws {
        let p = provider()
        let g = try #require(await p.grant(for: [token], macKey: "MACKEY", forceNew: false))
        #expect(g.grant.hasPrefix("g1.grant"))
        #expect(relay.paths() == ["/v1/challenge", "/v1/attest", "/v1/challenge", "/v1/grant"])
        // R34 client data: the challenge, the Mac key and the R33 hash; the assertion signs it.
        let sent = try #require(relay.body(of: "/v1/grant"))
        let clientData = try #require(sent["clientData"].flatMap { Data(base64Encoded: $0) })
        #expect(String(decoding: clientData, as: UTF8.self)
            == #"{"challenge":"ch1.c3.m","macKey":"MACKEY","tokens":[{"hash":"\#(PushAuthV1.tokenHash(token.token))","kind":"widget"}]}"#)
        #expect(sent["credential"] == "c1.cred2.m")
        // R31: the attestation's client data hash is SHA-256 of the challenge string.
        #expect(relay.body(of: "/v1/attest")?["challenge"] == "ch1.c1.m")
        // Cached: no relay call. A fresh provider reads the Keychain.
        #expect(await p.grant(for: [token], macKey: "MACKEY", forceNew: false) == g)
        #expect(await provider().grant(for: [token], macKey: "MACKEY", forceNew: false) == g)
        #expect(relay.paths().count == 4)
        // Another Mac key, or forceNew: a new grant with the same credential.
        _ = try #require(await p.grant(for: [token], macKey: "OTHER", forceNew: false))
        _ = try #require(await p.grant(for: [token], macKey: "OTHER", forceNew: true))
        #expect(relay.paths().filter { $0 == "/v1/attest" }.count == 1)
        #expect(attest.state.withLock { $0.keys } == 1)
    }

    @Test func noAppAttestNoGrant() async {
        let p = provider(FakeAppAttest(supported: false))
        #expect(await p.grant(for: [token], macKey: "MACKEY", forceNew: false) == nil)
        #expect(relay.paths().isEmpty)
    }

    @Test func staleCredentialIsReplacedByANewKeyOnce() async throws {
        relay.state.withLock { $0.grantAnswers = [(401, #"{"error":"credential_invalid"}"#)] }
        let p = provider()
        _ = try #require(await p.grant(for: [token], macKey: "MACKEY", forceNew: false))
        #expect(attest.state.withLock { $0.keys } == 2)
        #expect(relay.paths().filter { $0 == "/v1/attest" }.count == 2)
    }

    @Test func lostKeyAttestsAgain() async throws {
        attest.state.withLock { $0.failAssertion = true }
        let p = provider()
        _ = try #require(await p.grant(for: [token], macKey: "MACKEY", forceNew: false))
        #expect(attest.state.withLock { $0.keys } == 2)
    }

    @Test func relayDownBacksOff() async {
        relay.state.withLock { $0.down = true }
        let p = provider()
        #expect(await p.grant(for: [token], macKey: "MACKEY", forceNew: false) == nil)
        relay.state.withLock { $0.down = false }
        #expect(await p.grant(for: [token], macKey: "MACKEY", forceNew: false) == nil)  // still backing off
        #expect(relay.paths().isEmpty)
    }

    @Test func tooManyTokensAreRefusedLocally() async {
        let p = provider()
        let five = (0..<5).map { PushToken(token: String(repeating: String(format: "%02x", $0), count: 32), env: .development, kind: .widget) }
        #expect(await p.grant(for: five, macKey: "MACKEY", forceNew: false) == nil)
        #expect(relay.paths().isEmpty)
    }
}
