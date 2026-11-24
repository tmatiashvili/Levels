import CryptoKit
import Foundation
import LevelsModel
import Synchronization
import Testing
@testable import LevelsNet

private let hexA = String(repeating: "ab", count: 32)
private let hexB = String(repeating: "cd", count: 32)
private func widgetToken(_ hex: String = hexA, env: APNsEnvironment = .development) -> PushToken {
    PushToken(token: hex, env: env, kind: .widget)
}

/// A grant as the relay shapes it (`g1.<base64url JSON>.<mac>`); the MAC is junk, which only the
/// relay could tell.
func fakeGrant(macKey: String, tokens: [PushToken], env: APNsEnvironment = .development, exp: Int64 = 1_900_000_000) -> String {
    let t = tokens.map { "[\"\($0.kind.rawValue)\",\"\(PushAuthV1.tokenHash($0.token))\"]" }.joined(separator: ",")
    let json = #"{"v":1,"env":"\#(env.rawValue)","mac":"\#(macKey)","dev":"dev1","t":[\#(t)],"iat":1800000000,"exp":\#(exp)}"#
    return "g1.\(PushAuthV1.base64URL(Data(json.utf8))).AAAA"
}

@Suite("PUSH tokens and wire types")
struct PushTokenTests {
    @Test func tokenFromDataIsLowercaseHex() {
        let token = PushToken(data: Data([0x00, 0xAB, 0x0F, 0xFF] + Array(repeating: 1, count: 28)), env: .production, kind: .widget)
        #expect(token.token.hasPrefix("00ab0fff0101"))
        #expect(token.token.count == 64)
        #expect(token.isValid)
    }

    @Test func validationMatchesTheRelayBounds() {
        #expect(!widgetToken("ABCD" + String(repeating: "0", count: 60)).isValid)  // uppercase
        #expect(!widgetToken("abc").isValid)  // odd, short
        #expect(!widgetToken(String(repeating: "zz", count: 16)).isValid)
        #expect(!widgetToken(String(repeating: "a", count: 30)).isValid)  // relay minimum is 32
        #expect(widgetToken(String(repeating: "a", count: 32)).isValid)
        #expect(widgetToken(String(repeating: "a", count: 512)).isValid)  // relay maximum
        #expect(!widgetToken(String(repeating: "a", count: 514)).isValid)
        #expect(widgetToken().isValid)
    }

    @Test func uploadEncodesTheContractFieldNames() throws {
        let v2 = try HubWire.encoder().encode(PushTokenUpload(tokens: [widgetToken(env: .production)], grant: "g1.x.y", grantExpiresAt: 1_900_000_000))
        #expect(String(decoding: v2, as: UTF8.self)
            == #"{"grant":"g1.x.y","grantExpiresAt":1900000000,"tokens":[{"env":"production","kind":"widget","token":"\#(hexA)"}],"v":2}"#)
        let v1 = try HubWire.encoder().encode(PushTokenUpload(v: 1, tokens: [widgetToken(env: .production)]))
        #expect(String(decoding: v1, as: UTF8.self) == #"{"tokens":[{"env":"production","kind":"widget","token":"\#(hexA)"}],"v":1}"#)
    }

    @Test func pairedClientWithoutPushFieldsStillDecodes() throws {
        // An item written before push existed.
        let old = #"{"id":"\#(phoneID.recordName)","kind":"iphone","key":"AAAA","name":"P","pairedAt":0}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let client = try decoder.decode(PairedClient.self, from: Data(old.utf8))
        #expect(client.pushTokens == nil)
        #expect(client.pushGrant == nil)
        #expect(client.pushRegistration == nil)
    }

    @Test func apsEnvironmentFromProfile() {
        func profile(_ env: String?) -> Data {
            let ent = env.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
            let plist = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Entitlements</key><dict>\#(ent)</dict></dict></plist>"#
            return Data([0x30, 0x82, 0x01]) + Data(plist.utf8) + Data([0xA0, 0x00])  // CMS bytes around it
        }
        #expect(APNsEnvironment.fromProvisioningProfile(nil) == .production)  // App Store / TestFlight
        #expect(APNsEnvironment.fromProvisioningProfile(profile("development")) == .development)
        #expect(APNsEnvironment.fromProvisioningProfile(profile("production")) == .production)
        #expect(APNsEnvironment.fromProvisioningProfile(profile(nil)) == .development)
        #expect(APNsEnvironment.fromProvisioningProfile(Data("garbage".utf8)) == .development)
    }

    @Test func widgetTokenStoreRoundTrip() {
        let suite = "levels-push-test-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = WidgetPushTokenStore(suiteName: suite)
        #expect(store.load() == nil)
        #expect(store.save(widgetToken()))
        #expect(!store.save(widgetToken()))  // unchanged
        #expect(store.load() == widgetToken())
        store.clear()
        #expect(store.load() == nil)
    }

    @Test func grantInfoReadsTheRelayShape() throws {
        let key = P256.Signing.PrivateKey()
        let mac = PushAuthV1.publicKeyString(key.publicKey)
        let grant = fakeGrant(macKey: mac, tokens: [widgetToken()])
        let info = try #require(PushGrantInfo.read(grant))
        #expect(info.env == .development)
        #expect(info.expiresAt == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(info.covers([widgetToken()], macKey: mac))
        #expect(!info.covers([widgetToken()], macKey: "other"))
        #expect(!info.covers([widgetToken(hexB)], macKey: mac))
        #expect(!info.covers([widgetToken(env: .production)], macKey: mac))
        #expect(PushGrantInfo.read("g2.x.y") == nil)
        #expect(PushGrantInfo.read("nonsense") == nil)
    }
}

@Suite("PUSH pairing store keeps tokens and grants per device")
struct PushTokenStorageTests {
    func client(_ id: DeviceID) -> PairedClient {
        PairedClient(id: id, name: "P", kind: .iphone, key: Data(repeating: 1, count: 32), pairedAt: t0)
    }

    @Test func keychainStoreSavesReplacesAndForgets() throws {
        let items = InMemoryKeychainItems()
        let store = KeychainHubPairingStore(service: "svc", items: items)
        try store.save(client(phoneID))
        try store.save(client(otherPhoneID))
        #expect(try store.setPushRegistration([widgetToken()], grant: "g1.a.b", expiresAt: 5, for: phoneID))
        #expect(try !store.setPushTokens([widgetToken()], for: macID))  // not paired
        // A fresh store reads it back from the Keychain item.
        let reread = KeychainHubPairingStore(service: "svc", items: items)
        #expect(reread.pushRegistrations()[phoneID]
            == PushRegistration(tokens: [widgetToken()], grant: "g1.a.b", grantExpiresAt: Date(timeIntervalSince1970: 5)))
        // touch keeps them
        reread.touch(phoneID, at: t0 + 3600)
        #expect(KeychainHubPairingStore(service: "svc", items: items).pushTokens()[phoneID] == [widgetToken()])
        // a refused grant is flagged and survives a reread; a new upload clears the flag
        #expect(try reread.setPushNeedsGrant(for: phoneID))
        #expect(KeychainHubPairingStore(service: "svc", items: items).pushRegistrations()[phoneID]?.needsGrant == true)
        #expect(try reread.setPushRegistration([widgetToken(hexB)], grant: "g1.c.d", expiresAt: 6, for: phoneID))
        #expect(reread.pushRegistrations()[phoneID]?.needsGrant == false)
        // dropping tokens keeps the grant
        #expect(try reread.setPushTokens([widgetToken(hexB)], for: phoneID))
        #expect(reread.pushRegistrations()[phoneID]?.grant == "g1.c.d")
        // clear with an empty set
        #expect(try reread.setPushRegistration([], grant: "g1.c.d", expiresAt: 6, for: phoneID))
        #expect(reread.pushTokens().isEmpty)
        // forget drops the tokens with the key
        #expect(try reread.setPushRegistration([widgetToken()], grant: nil, expiresAt: nil, for: phoneID))
        try reread.remove(phoneID)
        #expect(KeychainHubPairingStore(service: "svc", items: items).pushTokens().isEmpty)
        #expect(KeychainHubPairingStore(service: "svc", items: items).all().map(\.id) == [otherPhoneID])
    }

    @Test func inMemoryStoreMatches() throws {
        let store = InMemoryHubPairingStore([client(phoneID)])
        #expect(try store.setPushTokens([widgetToken()], for: phoneID))
        #expect(try !store.setPushTokens([widgetToken()], for: otherPhoneID))
        #expect(store.pushTokens() == [phoneID: [widgetToken()]])
        try store.removeAll()
        #expect(store.pushTokens().isEmpty)
    }
}

@Suite("PUSH hub routes: PUT /v1/push-tokens, GET /v1/push-key")
struct PushTokenRouteTests {
    func put(_ body: Data, header: DeviceID? = phoneID, method: String = "PUT") -> HTTPRequest {
        HTTPRequest(method: method, path: "/v1/push-tokens", headers: header.map { ["Levels-Device": $0.recordName] } ?? [:],
                    body: body)
    }

    func upload(_ tokens: [PushToken], v: Int = 2, grant: String? = nil, exp: Int64? = nil) throws -> Data {
        try HubWire.encoder().encode(PushTokenUpload(v: v, tokens: tokens, grant: grant, grantExpiresAt: exp))
    }

    @Test func storesTheCallersTokensAndGrant() async throws {
        let backend = FakeBackend()
        let router = HubRouter(backend: backend)
        let response = await router.handle(put(try upload([widgetToken(), widgetToken()], grant: "g1.a.b", exp: 9)), from: .device(phoneID))
        #expect(response.status == 204)
        #expect(backend.state.withLock { $0.pushTokens } == [phoneID: [widgetToken()]])  // duplicate dropped
        #expect(backend.state.withLock { $0.uploads.last?.grant } == "g1.a.b")
    }

    @Test func olderIPhoneV1BodyStillWorksWithoutAGrant() async throws {
        let backend = FakeBackend()
        let router = HubRouter(backend: backend)
        let body = Data(#"{"tokens":[{"env":"development","kind":"widget","token":"\#(hexA)"}],"v":1,"grant":"g1.ignored.x","grantExpiresAt":1}"#.utf8)
        #expect(await router.handle(put(body), from: .device(phoneID)).status == 204)
        #expect(backend.state.withLock { $0.uploads.last } == PushTokenUpload(v: 1, tokens: [widgetToken()]))
    }

    @Test func refusesOtherDevicesAndBadBodies() async throws {
        let backend = FakeBackend()
        let router = HubRouter(backend: backend)
        #expect(await router.handle(put(try upload([widgetToken()]), header: otherPhoneID), from: .device(phoneID)).status == 403)
        #expect(await router.handle(put(try upload([widgetToken()]), header: nil), from: .device(phoneID)).status == 403)
        #expect(await router.handle(put(try upload([widgetToken()])), from: .pairing).status == 403)
        #expect(await router.handle(put(try upload([widgetToken()]), header: otherPhoneID), from: .device(otherPhoneID)).status == 403)  // not paired
        #expect(await router.handle(put(Data("{".utf8)), from: .device(phoneID)).status == 400)
        #expect(await router.handle(put(try upload([widgetToken()], v: 3)), from: .device(phoneID)).status == 400)
        #expect(await router.handle(put(try upload([widgetToken("XYZ")])), from: .device(phoneID)).status == 400)
        #expect(await router.handle(put(try upload([widgetToken()], grant: "g1.a.b")), from: .device(phoneID)).status == 400)  // no expiry
        #expect(await router.handle(put(try upload([widgetToken()], exp: 5)), from: .device(phoneID)).status == 400)  // no grant
        let huge = String(repeating: "g", count: 5000)
        #expect(await router.handle(put(try upload([widgetToken()], grant: huge, exp: 5)), from: .device(phoneID)).status == 400)
        let five = (0..<5).map { widgetToken(String(repeating: String(format: "%02x", $0), count: 32)) }
        #expect(await router.handle(put(try upload(five)), from: .device(phoneID)).status == 400)
        #expect(await router.handle(put(try upload([widgetToken()]), method: "POST"), from: .device(phoneID)).status == 405)
        #expect(backend.state.withLock { $0.pushTokens }.isEmpty)
    }

    @Test func mismatchedGrantIs400() async throws {
        let backend = FakeBackend()
        backend.state.withLock { $0.uploadAnswer = .rejected }
        let router = HubRouter(backend: backend)
        #expect(await router.handle(put(try upload([widgetToken()], grant: "g1.a.b", exp: 9)), from: .device(phoneID)).status == 400)
    }

    @Test func pushKeyIsAuthenticatedAndVersioned() async throws {
        let backend = FakeBackend()
        let router = HubRouter(backend: backend)
        let get = { (header: DeviceID?) in
            HTTPRequest(method: "GET", path: "/v1/push-key", headers: header.map { ["Levels-Device": $0.recordName] } ?? [:])
        }
        #expect(await router.handle(get(phoneID), from: .device(phoneID)).status == 404)  // push off on this Mac
        backend.state.withLock { $0.pushKey = PushKeyAnswer(macKey: "BKEY", grant: .renew) }
        let ok = await router.handle(get(phoneID), from: .device(phoneID))
        #expect(ok.status == 200)
        #expect(String(decoding: ok.body, as: UTF8.self) == #"{"grant":"renew","macKey":"BKEY","v":1}"#)
        #expect(await router.handle(get(otherPhoneID), from: .device(phoneID)).status == 403)
        #expect(await router.handle(get(nil), from: .device(phoneID)).status == 403)
        #expect(await router.handle(get(phoneID), from: .pairing).status == 403)
        #expect(await router.handle(HTTPRequest(method: "PUT", path: "/v1/push-key"), from: .device(phoneID)).status == 405)
    }

    @Test func presenceTracksOpenLongPolls() async throws {
        let presence = HubPresence()
        #expect(!presence.isLive(phoneID, at: t0))
        presence.begin(phoneID)
        #expect(presence.isLive(phoneID, at: t0 + 3600))
        presence.end(phoneID, at: t0)
        #expect(presence.isLive(phoneID, at: t0 + 5))  // grace: the next long-poll follows at once
        #expect(!presence.isLive(phoneID, at: t0 + HubPresence.grace + 1))
        #expect(!presence.isLive(otherPhoneID, at: t0))
    }
}

/// Records relay requests and answers with a scripted response.
final class FakeRelayTransport: PushRelayTransport {
    struct Call: Sendable { var url: URL; var headers: [String: String]; var body: Data }
    private let state = Mutex<(calls: [Call], answers: [(Int, [String: String], Data)])>(([], []))
    init(_ answers: [(Int, [String: String], Data)] = []) { state.withLock { $0.answers = answers } }
    var calls: [Call] { state.withLock { $0.calls } }
    func answer(_ status: Int, _ body: String, headers: [String: String] = [:]) {
        state.withLock { $0.answers.append((status, headers, Data(body.utf8))) }
    }
    func post(url: URL, headers: [String: String], body: Data) async throws -> (status: Int, headers: [String: String], body: Data) {
        let answer = state.withLock { s -> (Int, [String: String], Data) in
            s.calls.append(Call(url: url, headers: headers, body: body))
            return s.answers.isEmpty ? (202, [:], Data()) : s.answers.removeFirst()
        }
        return answer
    }
}

@Suite("PUSH relay client")
struct PushRelayClientTests {
    let signer = MacPushSigner(key: P256.Signing.PrivateKey())

    @Test func emptyOrInsecureURLMeansPushOff() {
        #expect(PushRelayClient(relayURL: "", auth: signer) == nil)
        #expect(PushRelayClient(relayURL: "   ", auth: signer) == nil)
        #expect(PushRelayClient(relayURL: "http://relay.example", auth: signer) == nil)
        #expect(PushRelayClient(relayURL: "not a url", auth: signer) == nil)
        #expect(PushRelayClient(relayURL: "https://user@relay.example", auth: signer) == nil)
        #expect(PushRelayClient(relayURL: "https://relay.example/", auth: signer)?.endpoint.absoluteString == "https://relay.example/v1/widget-push")
        #expect(PushRelayClient(relayURL: "https://relay.example/base", auth: signer)?.endpoint.absoluteString == "https://relay.example/base/v1/widget-push")
    }

    @Test func sendsTheContractBodyWithVerifiableHeaders() async throws {
        let transport = FakeRelayTransport()
        let at = Date(timeIntervalSince1970: 1_800_000_123.9)
        let now: @Sendable () -> Date = { at }
        let client = try #require(PushRelayClient(relayURL: "https://relay.example", auth: signer, transport: transport, now: now))
        #expect(await client.send([widgetToken()], grants: ["g1.a.b", "g1.c.d"]) == .accepted(invalidTokens: []))
        let call = try #require(transport.calls.first)
        #expect(call.url.absoluteString == "https://relay.example/v1/widget-push")
        let body = String(decoding: call.body, as: UTF8.self)
        #expect(body == #"{"payload":{"aps":{"content-changed":true}},"tokens":[{"env":"development","kind":"widget","token":"\#(hexA)"}]}"#)
        #expect(call.headers["content-type"] == "application/json")
        #expect(call.headers["levels-grant"] == "g1.a.b,g1.c.d")
        #expect(call.headers["levels-timestamp"] == "1800000123")
        let sig = try #require(call.headers["levels-signature"].flatMap(PushAuthV1.data(base64URL:)))
        #expect(sig.count == 64)
        #expect(!call.headers["levels-signature"]!.contains("="))
        let message = PushAuthV1.signingString(timestamp: "1800000123", path: "/v1/widget-push", body: call.body)
        #expect(signer.key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: sig), for: Data(message.utf8)))
    }

    @Test func refusesBadGrantCountsWithoutSending() async throws {
        let transport = FakeRelayTransport()
        let client = try #require(PushRelayClient(relayURL: "https://relay.example", auth: signer, transport: transport))
        #expect(await client.send([widgetToken()], grants: []) == .rejected(status: 0))
        #expect(await client.send([widgetToken()], grants: Array(repeating: "g1.a.b", count: 5)) == .rejected(status: 0))
        #expect(transport.calls.isEmpty)
    }

    @Test func noTokensNoRequest() async throws {
        let transport = FakeRelayTransport()
        let client = try #require(PushRelayClient(relayURL: "https://relay.example", auth: signer, transport: transport))
        _ = await client.send([], grants: ["g1.a.b"])
        #expect(transport.calls.isEmpty)
    }

    @Test func mapsStatuses() {
        #expect(PushRelayClient.result(status: 202, headers: [:], body: Data()) == .accepted(invalidTokens: []))
        #expect(PushRelayClient.result(status: 202, headers: [:], body: Data(#"{"results":[{"index":0,"status":"unregistered"}],"invalidTokens":["AB"]}"#.utf8))
            == .accepted(invalidTokens: ["ab"]))
        #expect(PushRelayClient.result(status: 429, headers: ["Retry-After": "120"], body: Data()) == .rateLimited(retryAfter: 120))
        #expect(PushRelayClient.result(status: 429, headers: [:], body: Data()) == .rateLimited(retryAfter: nil))
        #expect(PushRelayClient.result(status: 410, headers: [:], body: Data(#"{"error":"tokens_invalid"}"#.utf8)) == .tokensGone)
        #expect(PushRelayClient.result(status: 400, headers: [:], body: Data()) == .rejected(status: 400))
        #expect(PushRelayClient.result(status: 401, headers: [:], body: Data(#"{"error":"grant_expired"}"#.utf8)) == .unauthorized(code: "grant_expired"))
        #expect(PushRelayClient.result(status: 401, headers: [:], body: Data()) == .unauthorized(code: ""))
        #expect(PushRelayClient.result(status: 500, headers: [:], body: Data(#"{"error":"internal"}"#.utf8)) == .serverError(status: 500))
    }
}

@Suite("PUSH Mac push key")
struct MacPushKeyStoreTests {
    @Test func madeOnceKeptAndResetMakesANewOne() throws {
        let items = InMemoryKeychainItems()
        let store = MacPushKeyStore(service: "push-key", items: items)
        let first = try #require(store.publicKey)
        #expect(PushAuthV1.data(base64URL: first)?.count == 65)
        #expect(MacPushKeyStore(service: "push-key", items: items).publicKey == first)  // relaunch
        store.reset()
        let second = try #require(store.publicKey)
        #expect(second != first)
        #expect(MacPushKeyStore(service: "push-key", items: items).publicKey == second)
    }
}
