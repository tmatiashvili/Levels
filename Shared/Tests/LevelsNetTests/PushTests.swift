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

@Suite("PUSH tokens and wire types")
struct PushTokenTests {
    @Test func tokenFromDataIsLowercaseHex() {
        let token = PushToken(data: Data([0x00, 0xAB, 0x0F, 0xFF, 1, 2, 3, 4]), env: .production, kind: .widget)
        #expect(token.token == "00ab0fff01020304")
        #expect(token.isValid)
    }

    @Test func validationRejectsBadHex() {
        #expect(!widgetToken("ABCD" + String(repeating: "0", count: 60)).isValid)  // uppercase
        #expect(!widgetToken("abc").isValid)  // odd, short
        #expect(!widgetToken(String(repeating: "zz", count: 16)).isValid)
        #expect(!widgetToken(String(repeating: "a", count: PushToken.maxHexLength + 2)).isValid)
        #expect(widgetToken().isValid)
    }

    @Test func uploadEncodesTheContractFieldNames() throws {
        let data = try HubWire.encoder().encode(PushTokenUpload(tokens: [widgetToken(env: .production)]))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json == #"{"tokens":[{"env":"production","kind":"widget","token":"\#(hexA)"}],"v":1}"#)
    }

    @Test func pairedClientWithoutTokensStillDecodes() throws {
        // An item written before push existed.
        let old = #"{"id":"\#(phoneID.recordName)","kind":"iphone","key":"AAAA","name":"P","pairedAt":0}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let client = try decoder.decode(PairedClient.self, from: Data(old.utf8))
        #expect(client.pushTokens == nil)
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
}

@Suite("PUSH pairing store keeps tokens per device")
struct PushTokenStorageTests {
    func client(_ id: DeviceID) -> PairedClient {
        PairedClient(id: id, name: "P", kind: .iphone, key: Data(repeating: 1, count: 32), pairedAt: t0)
    }

    @Test func keychainStoreSavesReplacesAndForgets() throws {
        let items = InMemoryKeychainItems()
        let store = KeychainHubPairingStore(service: "svc", items: items)
        try store.save(client(phoneID))
        try store.save(client(otherPhoneID))
        #expect(try store.setPushTokens([widgetToken()], for: phoneID))
        #expect(try !store.setPushTokens([widgetToken()], for: macID))  // not paired
        // A fresh store reads it back from the Keychain item.
        let reread = KeychainHubPairingStore(service: "svc", items: items)
        #expect(reread.pushTokens() == [phoneID: [widgetToken()]])
        // touch keeps them
        reread.touch(phoneID, at: t0 + 3600)
        #expect(KeychainHubPairingStore(service: "svc", items: items).pushTokens()[phoneID] == [widgetToken()])
        // replace, then clear with an empty set
        #expect(try reread.setPushTokens([widgetToken(hexB)], for: phoneID))
        #expect(reread.pushTokens()[phoneID] == [widgetToken(hexB)])
        #expect(try reread.setPushTokens([], for: phoneID))
        #expect(reread.pushTokens().isEmpty)
        // forget drops the tokens with the key
        #expect(try reread.setPushTokens([widgetToken()], for: phoneID))
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

@Suite("PUSH PUT /v1/push-tokens")
struct PushTokenRouteTests {
    func put(_ body: Data, header: DeviceID? = phoneID, method: String = "PUT") -> HTTPRequest {
        HTTPRequest(method: method, path: "/v1/push-tokens", headers: header.map { ["Levels-Device": $0.recordName] } ?? [:],
                    body: body)
    }

    func upload(_ tokens: [PushToken], v: Int = 1) throws -> Data {
        try HubWire.encoder().encode(PushTokenUpload(v: v, tokens: tokens))
    }

    @Test func storesTheCallersTokens() async throws {
        let backend = FakeBackend()
        let router = HubRouter(backend: backend)
        let response = await router.handle(put(try upload([widgetToken(), widgetToken()])), from: .device(phoneID))
        #expect(response.status == 204)
        #expect(backend.state.withLock { $0.pushTokens } == [phoneID: [widgetToken()]])  // duplicate dropped
    }

    @Test func refusesOtherDevicesAndBadBodies() async throws {
        let backend = FakeBackend()
        let router = HubRouter(backend: backend)
        #expect(await router.handle(put(try upload([widgetToken()]), header: otherPhoneID), from: .device(phoneID)).status == 403)
        #expect(await router.handle(put(try upload([widgetToken()]), header: nil), from: .device(phoneID)).status == 403)
        #expect(await router.handle(put(try upload([widgetToken()])), from: .pairing).status == 403)
        #expect(await router.handle(put(try upload([widgetToken()]), header: otherPhoneID), from: .device(otherPhoneID)).status == 403)  // not paired
        #expect(await router.handle(put(Data("{".utf8)), from: .device(phoneID)).status == 400)
        #expect(await router.handle(put(try upload([widgetToken()], v: 2)), from: .device(phoneID)).status == 400)
        #expect(await router.handle(put(try upload([widgetToken("XYZ")])), from: .device(phoneID)).status == 400)
        let five = (0..<5).map { widgetToken(String(repeating: String(format: "%02x", $0), count: 32)) }
        #expect(await router.handle(put(try upload(five)), from: .device(phoneID)).status == 400)
        #expect(await router.handle(put(try upload([widgetToken()]), method: "POST"), from: .device(phoneID)).status == 405)
        #expect(backend.state.withLock { $0.pushTokens }.isEmpty)
    }
}

/// Records relay requests and answers with a scripted response.
final class FakeRelayTransport: PushRelayTransport {
    struct Call: Sendable { var url: URL; var headers: [String: String]; var body: Data }
    private let state = Mutex<(calls: [Call], answers: [(Int, [String: String], Data)])>(([], []))
    init(_ answers: [(Int, [String: String], Data)] = []) { state.withLock { $0.answers = answers } }
    var calls: [Call] { state.withLock { $0.calls } }
    func post(url: URL, headers: [String: String], body: Data) async throws -> (status: Int, headers: [String: String], body: Data) {
        let answer = state.withLock { s -> (Int, [String: String], Data) in
            s.calls.append(Call(url: url, headers: headers, body: body))
            return s.answers.isEmpty ? (202, [:], Data()) : s.answers.removeFirst()
        }
        return answer
    }
}

struct SigningAuth: PushRelayAuth {
    func headers(for body: Data) async throws -> [String: String] { ["X-Levels-Sig": "len-\(body.count)"] }
}

@Suite("PUSH relay client")
struct PushRelayClientTests {
    @Test func emptyOrInsecureURLMeansPushOff() {
        #expect(PushRelayClient(relayURL: "") == nil)
        #expect(PushRelayClient(relayURL: "   ") == nil)
        #expect(PushRelayClient(relayURL: "http://relay.example") == nil)
        #expect(PushRelayClient(relayURL: "not a url") == nil)
        #expect(PushRelayClient(relayURL: "https://relay.example/")?.endpoint.absoluteString == "https://relay.example/v1/widget-push")
        #expect(PushRelayClient(relayURL: "https://relay.example/base")?.endpoint.absoluteString == "https://relay.example/base/v1/widget-push")
    }

    @Test func encodesTheContractBodyAndSigns() async throws {
        let transport = FakeRelayTransport()
        let client = try #require(PushRelayClient(relayURL: "https://relay.example", auth: SigningAuth(), transport: transport))
        #expect(await client.send([widgetToken()]) == .accepted(invalidTokens: []))
        let call = try #require(transport.calls.first)
        #expect(call.url.absoluteString == "https://relay.example/v1/widget-push")
        let body = String(decoding: call.body, as: UTF8.self)
        #expect(body == #"{"payload":{"aps":{"content-changed":true}},"tokens":[{"env":"development","kind":"widget","token":"\#(hexA)"}]}"#)
        #expect(call.headers["content-type"] == "application/json")
        #expect(call.headers["x-levels-sig"] == "len-\(call.body.count)")
    }

    @Test func noTokensNoRequest() async throws {
        let transport = FakeRelayTransport()
        let client = try #require(PushRelayClient(relayURL: "https://relay.example", transport: transport))
        _ = await client.send([])
        #expect(transport.calls.isEmpty)
    }

    @Test func mapsStatuses() {
        #expect(PushRelayClient.result(status: 202, headers: [:], body: Data()) == .accepted(invalidTokens: []))
        #expect(PushRelayClient.result(status: 202, headers: [:], body: Data(#"{"invalidTokens":["AB"]}"#.utf8))
            == .accepted(invalidTokens: ["ab"]))
        #expect(PushRelayClient.result(status: 429, headers: ["Retry-After": "120"], body: Data()) == .rateLimited(retryAfter: 120))
        #expect(PushRelayClient.result(status: 429, headers: [:], body: Data()) == .rateLimited(retryAfter: nil))
        #expect(PushRelayClient.result(status: 410, headers: [:], body: Data()) == .tokensGone)
        #expect(PushRelayClient.result(status: 400, headers: [:], body: Data()) == .rejected(status: 400))
        #expect(PushRelayClient.result(status: 401, headers: [:], body: Data()) == .rejected(status: 401))
    }
}
