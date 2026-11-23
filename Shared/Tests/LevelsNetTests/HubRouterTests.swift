import CryptoKit
import Foundation
import LevelsModel
import Synchronization
import Testing
@testable import LevelsNet

@Suite("NET-001 HubRouter (R4, R8, R9, R11)")
struct HubRouterTests {
    let devices = [macRecord(), airpodRecord(), phoneRecord()]

    func make(_ backend: FakeBackend, clock: ManualClock = ManualClock(startDate: t0)) -> HubRouter {
        HubRouter(backend: backend, now: { clock.date }, clock: clock)
    }

    func get(_ query: [String: String] = [:], etag: String? = nil) -> HTTPRequest {
        HTTPRequest(method: "GET", path: "/v1/snapshot", query: query, headers: etag.map { ["If-None-Match": $0] } ?? [:])
    }

    func post(_ records: [DeviceBattery], header: DeviceID? = phoneID) throws -> HTTPRequest {
        HTTPRequest(method: "POST", path: "/v1/readings", headers: header.map { ["Levels-Device": $0.recordName] } ?? [:],
                    body: try HubWire.encoder().encode(records))
    }

    @Test func AC2_snapshotReturnsDevicesAndETag() async throws {
        let backend = FakeBackend(devices: devices)
        let response = await make(backend).handle(get(), from: .device(phoneID))
        #expect(response.status == 200)
        let snapshot = try HubWire.decoder().decode(HubSnapshot.self, from: response.body)
        #expect(snapshot.devices == devices && snapshot.v == 1 && snapshot.hubID == hubID && snapshot.hubDeviceID == macID)
        #expect(response.header("etag") == HubWire.etag(for: devices))
        #expect(backend.state.withLock { $0.seen } == [phoneID])
    }

    @Test func AC3_matchingETagGives304WithEmptyBody() async {
        let response = await make(FakeBackend(devices: devices)).handle(get(etag: HubWire.etag(for: devices)), from: .device(phoneID))
        #expect(response.status == 304 && response.body.isEmpty)
        #expect(response.header("etag") == HubWire.etag(for: devices))
        let stale = await make(FakeBackend(devices: devices)).handle(get(etag: "\"0000000000000000\""), from: .device(phoneID))
        #expect(stale.status == 200)
    }

    @Test func AC4_longPollAnswers200WhenTheCacheChanges() async throws {
        let clock = ManualClock(startDate: t0)
        let backend = FakeBackend(devices: devices)
        let router = make(backend, clock: clock)
        let task = Task { await router.handle(get(["wait": "25"], etag: HubWire.etag(for: devices)), from: .device(phoneID)) }
        await waitFor { clock.sleeperCount >= 1 }
        clock.advance(by: .seconds(3))
        let changed = [macRecord(level: 79), airpodRecord(), phoneRecord()]
        backend.setDevices(changed)
        let response = await task.value
        #expect(response.status == 200)
        #expect(response.header("etag") == HubWire.etag(for: changed))
        let snapshot = try HubWire.decoder().decode(HubSnapshot.self, from: response.body)
        #expect(snapshot.generatedAt == t0 + 3)
    }

    @Test func AC4_longPollIgnoresChangesThatKeepTheTag() async {
        let clock = ManualClock(startDate: t0)
        let backend = FakeBackend(devices: devices)
        let router = make(backend, clock: clock)
        let task = Task { await router.handle(get(["wait": "25"], etag: HubWire.etag(for: devices)), from: .device(phoneID)) }
        await waitFor { clock.sleeperCount >= 1 }
        backend.setDevices(devices)  // a signal without a real change
        await settle()
        clock.advance(by: .seconds(25))
        #expect(await task.value.status == 304)
    }

    @Test(arguments: [25, 99])
    func AC4_longPollWithoutChangeGives304At25s(wait: Int) async {
        let clock = ManualClock(startDate: t0)
        let router = make(FakeBackend(devices: devices), clock: clock)
        let task = Task { await router.handle(get(["wait": String(wait)], etag: HubWire.etag(for: devices)), from: .device(phoneID)) }
        await waitFor { clock.sleeperCount >= 1 }
        clock.advance(by: .seconds(24))
        await settle()
        #expect(clock.sleeperCount >= 1)  // still held
        clock.advance(by: .seconds(1))
        let response = await task.value
        #expect(response.status == 304 && response.body.isEmpty)
        #expect(clock.requests.contains { $0.duration == .seconds(25) })
    }

    @Test func R11_cancelledHoldEnds() async {
        let clock = ManualClock(startDate: t0)
        let router = make(FakeBackend(devices: devices), clock: clock)
        let task = Task { await router.handle(get(["wait": "25"], etag: HubWire.etag(for: devices)), from: .device(phoneID)) }
        await waitFor { clock.sleeperCount >= 1 }
        task.cancel()
        _ = await task.value
        #expect(clock.sleeperCount == 0)
    }

    @Test func AC5_postFromPairedDeviceIngestsWithServerTime() async throws {
        let clock = ManualClock(startDate: t0 + 500)
        let backend = FakeBackend(devices: devices)
        let record = phoneRecord(level: 120, at: t0 + 9_999)  // clock ahead, level out of range
        let response = await make(backend, clock: clock).handle(try post([record]), from: .device(phoneID))
        #expect(response.status == 204)
        let ingested = backend.state.withLock { $0.ingested }
        #expect(ingested.count == 1)
        #expect(ingested[0].serverModifiedAt == t0 + 500)
        #expect(ingested[0].level == 100)
        #expect(response.header("etag") != nil)
    }

    @Test func AC6_postRejectsOtherRecords() async throws {
        let backend = FakeBackend(devices: devices)
        let router = make(backend)
        let mac = DeviceBattery(id: phoneID, name: "x", kind: .mac, level: 1, isCharging: false, updatedAt: t0)
        let cases: [HTTPRequest] = [
            try post([phoneRecord(otherPhoneID)]),  // not the caller's record
            try post([mac]),
            try post([phoneRecord(), phoneRecord()]),
            try post([phoneRecord()], header: nil),
            try post([phoneRecord()], header: otherPhoneID),
            try post([]),
        ]
        for request in cases {
            #expect(await router.handle(request, from: .device(phoneID)).status == 403)
        }
        var acc = airpodRecord()
        acc.id = phoneID
        #expect(await router.handle(try post([acc]), from: .device(phoneID)).status == 403)
        #expect(backend.state.withLock { $0.ingested }.isEmpty)
        let garbage = HTTPRequest(method: "POST", path: "/v1/readings", headers: ["Levels-Device": phoneID.recordName], body: Data("{".utf8))
        #expect(await router.handle(garbage, from: .device(phoneID)).status == 400)
    }

    @Test func deletesAnd404And405() async {
        let backend = FakeBackend(devices: devices)
        let router = make(backend)
        #expect(await router.handle(HTTPRequest(method: "DELETE", path: "/v1/devices/me"), from: .device(phoneID)).status == 204)
        #expect(backend.state.withLock { $0.removed } == [phoneID])
        let forget = await router.handle(HTTPRequest(method: "DELETE", path: "/v1/pairing"), from: .device(phoneID))
        #expect(forget.status == 204 && forget.header("connection") == "close")
        #expect(backend.state.withLock { $0.forgotten } == [phoneID])
        #expect(await router.handle(HTTPRequest(method: "GET", path: "/v2/x"), from: .device(phoneID)).status == 404)
        #expect(await router.handle(HTTPRequest(method: "POST", path: "/v1/snapshot"), from: .device(phoneID)).status == 405)
        #expect(await router.handle(HTTPRequest(method: "GET", path: "/v1/readings"), from: .device(phoneID)).status == 405)
    }

    @Test func R5_pairIdentityReachesOnlyThePairRoute() async throws {
        let store = InMemoryHubPairingStore()
        let window = PairingWindow(store: store, now: { t0 })
        window.open(hub: hubInfo)
        let backend = FakeBackend(devices: devices, window: window)
        let router = make(backend)
        #expect(await router.handle(get(), from: .pairing).status == 403)
        #expect(await router.handle(try post([phoneRecord()]), from: .pairing).status == 403)
        let phoneKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let body = try HubWire.encoder().encode(PairRequest(deviceID: phoneID, name: "My iPhone", kind: .iphone,
                                                            commitment: PairingCrypto.commitment(to: phoneKey)))
        let pairRequest = HTTPRequest(method: "POST", path: "/v1/pair", body: body)
        #expect(await router.handle(pairRequest, from: .device(phoneID)).status == 403)
        let answer = await router.handle(pairRequest, from: .pairing)
        #expect(answer.status == 200)
        #expect((try? HubWire.decoder().decode(PairResponse.self, from: answer.body))?.hubID == hubID)
        // R5a: the reveal is held until the owner taps "They match" (call 30).
        let reveal = HTTPRequest(method: "POST", path: "/v1/pair/confirm",
                                 body: try HubWire.encoder().encode(PairConfirmRequest(publicKey: phoneKey)))
        #expect(await router.handle(reveal, from: .device(phoneID)).status == 403)
        let held = Task { await router.handle(reveal, from: .pairing) }
        await waitFor {
            if case .confirming = window.state { return true }
            return false
        }
        // Before the tap, the device's request confirms nothing.
        _ = await router.handle(get(), from: .device(phoneID))
        #expect(store.key(for: phoneID) == nil)
        window.approve()
        #expect(await held.value.status == 204)
        // The confirming request (R7).
        _ = await router.handle(get(), from: .device(phoneID))
        #expect(store.key(for: phoneID) != nil)
        #expect(window.state == .paired(name: "My iPhone"))
    }

    @Test func cancelOnTheMacRefusesTheHeldReveal() async throws {
        let window = PairingWindow(store: InMemoryHubPairingStore(), now: { t0 })
        window.open(hub: hubInfo)
        let router = make(FakeBackend(devices: devices, window: window))
        let phoneKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let pair = HTTPRequest(method: "POST", path: "/v1/pair", body: try HubWire.encoder().encode(
            PairRequest(deviceID: phoneID, name: "My iPhone", kind: .iphone, commitment: PairingCrypto.commitment(to: phoneKey))))
        #expect(await router.handle(pair, from: .pairing).status == 200)
        let reveal = HTTPRequest(method: "POST", path: "/v1/pair/confirm",
                                 body: try HubWire.encoder().encode(PairConfirmRequest(publicKey: phoneKey)))
        let held = Task { await router.handle(reveal, from: .pairing) }
        await waitFor {
            if case .confirming = window.state { return true }
            return false
        }
        window.close()
        #expect(await held.value.status == 403)
        #expect(await router.handle(HTTPRequest(method: "POST", path: "/v1/pair/confirm", body: Data("x".utf8)),
                                    from: .pairing).status == 400)
    }

    @Test func pairErrorsMapToStatuses() {
        #expect(HubRouter.status(for: .hubFull) == 409)
        #expect(HubRouter.status(for: .tooManyTries) == 423)
        #expect(HubRouter.status(for: .refused) == 403)
        #expect(HubRouter.status(for: .timedOut) == 408)
    }

    @Test func reportingOffGives503() async {
        let backend = FakeBackend(devices: devices)
        backend.state.withLock { $0.reporting = false }
        #expect(await make(backend).handle(get(), from: .device(phoneID)).status == 503)
    }
}

@Suite("NET-003 HubClient over a fake transport")
struct HubClientTests {
    final class FakeTransport: HubTransport {
        let sent = Mutex<[HTTPRequest]>([])
        let answer: @Sendable (HTTPRequest) throws(HubError) -> HTTPResponse
        init(_ answer: @escaping @Sendable (HTTPRequest) throws(HubError) -> HTTPResponse) { self.answer = answer }
        func send(_ request: HTTPRequest, to pairing: HubPairing, me: DeviceID, timeout: Duration) async throws(HubError) -> HTTPResponse {
            var r = request
            r.headers["levels-device"] = me.recordName
            sent.withLock { $0.append(r) }
            return try answer(r)
        }
    }

    let pairing = HubPairing(hubID: hubID, hubTag: "ab12", hubDeviceID: macID, hubName: "Office Mac", key: Data(repeating: 1, count: 32), pairedAt: t0)

    @Test func snapshotDecodesAndSendsETagAndWait() async throws {
        let snapshot = HubSnapshot(hubID: hubID, hubDeviceID: macID, generatedAt: t0, devices: [macRecord()])
        let body = try HubWire.encoder().encode(snapshot)
        let transport = FakeTransport { r in
            r.header("if-none-match") == "\"old\"" && r.query["wait"] == "25"
                ? HTTPResponse(status: 200, headers: ["etag": "\"new\""], body: body) : HTTPResponse(status: 304)
        }
        let client = HubClient(transport: transport, pairing: InMemoryClientPairingStore(pairing), me: phoneID)
        #expect(try await client.snapshot(ifNoneMatch: "\"old\"", wait: .seconds(99)) == .changed(snapshot, etag: "\"new\""))
        #expect(try await client.snapshot(ifNoneMatch: "\"new\"") == .notModified(etag: "\"new\""))
    }

    @Test func notPairedMakesNoCall() async {
        let transport = FakeTransport { _ in HTTPResponse(status: 200) }
        let client = HubClient(transport: transport, pairing: InMemoryClientPairingStore(), me: phoneID)
        await #expect(throws: HubError.notPaired) { try await client.snapshot(ifNoneMatch: nil) }
        #expect(transport.sent.withLock { $0 }.isEmpty)
    }

    @Test func versionMismatchAndErrors() async throws {
        let body = try HubWire.encoder().encode(HubSnapshot(v: 2, hubID: hubID, hubDeviceID: macID, generatedAt: t0, devices: []))
        let client = HubClient(transport: FakeTransport { _ in HTTPResponse(status: 200, body: body) },
                               pairing: InMemoryClientPairingStore(pairing), me: phoneID)
        await #expect(throws: HubError.versionMismatch) { try await client.snapshot(ifNoneMatch: nil) }
        let refused = HubClient(transport: FakeTransport { _ throws(HubError) in throw .handshakeRefused },
                                pairing: InMemoryClientPairingStore(pairing), me: phoneID)
        await #expect(throws: HubError.handshakeRefused) { try await refused.post(phoneRecord()) }
    }

    @Test func postSendsOwnRecordAndForgetDeletesPairing() async throws {
        let transport = FakeTransport { _ in HTTPResponse(status: 204, headers: ["etag": "\"t\""]) }
        let store = InMemoryClientPairingStore(pairing)
        let client = HubClient(transport: transport, pairing: store, me: phoneID)
        #expect(try await client.post(phoneRecord()) == "\"t\"")
        let sent = try #require(transport.sent.withLock { $0 }.first)
        #expect(sent.method == "POST" && sent.path == "/v1/readings" && sent.header("levels-device") == phoneID.recordName)
        #expect(try HubWire.decoder().decode([DeviceBattery].self, from: sent.body) == [phoneRecord()])
        try await client.deleteMe()
        #expect(await client.forget())
        #expect(store.current() == nil)
        #expect(transport.sent.withLock { $0 }.map(\.path) == ["/v1/readings", "/v1/devices/me", "/v1/pairing"])
    }

    @Test func forgetWorksWhenTheMacIsAway() async {
        let store = InMemoryClientPairingStore(pairing)
        let client = HubClient(transport: FakeTransport { _ throws(HubError) in throw .notFound }, pairing: store, me: phoneID)
        #expect(await client.forget() == false)
        #expect(store.current() == nil)
    }
}
