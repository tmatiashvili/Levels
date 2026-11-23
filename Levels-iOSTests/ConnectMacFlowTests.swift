// NET-004 AC2 and the pairing flow around the MacPairer seam (NET-002 R3, R10).
import Foundation
import LevelsModel
import LevelsNet
import Network
import Synchronization
import Testing
@testable import Levels

private let me = PairRequestIdentity(deviceID: DeviceID(UUID()), name: "iPhone", kind: .iphone)
private func hub(_ tag: String, pairing: Bool = true) -> DiscoveredHub {
    DiscoveredHub(name: "Levels-\(tag)", tag: tag, version: HubProtocol.version, isPairing: pairing,
                  endpoint: .hostPort(host: .ipv4(.loopback), port: 1))
}
private func pairing(_ tag: String, name: String) -> HubPairing {
    HubPairing(hubID: UUID(), hubTag: tag, hubDeviceID: DeviceID(UUID()), hubName: name, key: Data(count: 32), pairedAt: .now)
}

/// A session that returns `result` only after both They match taps (local + `macApproves()`),
/// like ``PairingSession`` (NET-002 R6b).
private final class FakeSession: MacPairingSession {
    let confirmationCode: String
    let result: Result<HubPairing, PairError>
    private struct State {
        var local: Bool?
        var mac = false
        var waiter: CheckedContinuation<Result<HubPairing, PairError>, Never>?
    }
    private let state = Mutex(State())
    init(_ result: Result<HubPairing, PairError>, confirmation: String) {
        self.result = result
        self.confirmationCode = confirmation
    }
    var confirmedLocally: Bool { state.withLock { $0.local == true } }
    var cancelled: Bool { state.withLock { $0.local == false } }
    func confirmLocally() { update { if $0.local == nil { $0.local = true } } }
    func cancel() { update { if $0.local == nil { $0.local = false } } }
    func macApproves() { update { $0.mac = true } }
    func macRefuses() { update { s in s.waiter?.resume(returning: .failure(.refused)); s.waiter = nil } }
    private func update(_ change: (inout State) -> Void) {
        state.withLock { s in
            change(&s)
            guard let w = s.waiter else { return }
            if s.local == false { w.resume(returning: .failure(.refused)); s.waiter = nil }
            else if s.local == true && s.mac { w.resume(returning: result); s.waiter = nil }
        }
    }
    func finish() async throws(PairError) -> HubPairing {
        let r = await withCheckedContinuation { c in
            state.withLock { $0.waiter = c }
            update { _ in }
        }
        return try r.get()
    }
}

private final class Saves: Sendable {
    private let n = Mutex(0)
    var count: Int { n.withLock { $0 } }
    func add() { n.withLock { $0 += 1 } }
}

private final class FakePairer: MacPairer {
    let session: FakeSession?
    let startError: PairError?
    init(session: FakeSession) { self.session = session; self.startError = nil }
    init(failing error: PairError) { self.session = nil; self.startError = error }
    func start(hub: DiscoveredHub, code: String, me: PairRequestIdentity) async throws(PairError) -> any MacPairingSession {
        if let startError { throw startError }
        return session!
    }
}

@MainActor
@Suite struct ConnectMacFlowTests {
    func flow(_ pairer: any MacPairer, existing: HubPairing? = nil) -> ConnectMacFlowModel {
        ConnectMacFlowModel(browse: { AsyncThrowingStream { _ in } }, pairer: pairer, me: { me },
                            existing: { existing }, save: { _ in })
    }

    @Test func AC2_noBrowseBeforeContinue() {
        let f = flow(FakePairer(failing: .refused))
        #expect(f.step == .explain && f.browseCount == 0)
        f.continueTapped()
        #expect(f.step == .choose && f.browseCount == 1)
    }

    @Test func oneHubIsPreselectedAndClosedWindowsAreHidden() {
        let f = flow(FakePairer(failing: .refused))
        f.continueTapped()
        f._receive([hub("ab12"), hub("cd34", pairing: false)])
        #expect(f.hubs.map(\.tag) == ["ab12"] && f.selectedTag == "ab12")
    }

    @Test func codeFieldKeepsSixDigits() {
        let f = flow(FakePairer(failing: .refused))
        f.code = "12a3 4567"
        #expect(f.code == "123456")
        #expect(PairingText.grouped("123456") == "123 456")
    }

    @Test func wrongCodeShowsTheNET002TextAndKeepsTheField() async throws {
        let f = flow(FakePairer(failing: .wrongCode))
        f.continueTapped()
        f._receive([hub("ab12")])
        f.code = "111111"
        f.submit()
        try await waitUntil { f.step == .choose }
        #expect(f.errorText == "That code didn't work. Check the code on your Mac.")
        #expect(f.code == "111111")
    }

    private func submitted(_ pairer: FakePairer, saved: Saves? = nil) -> ConnectMacFlowModel {
        let f = ConnectMacFlowModel(browse: { AsyncThrowingStream { _ in } }, pairer: pairer, me: { me },
                                    existing: { nil }, save: { _ in saved?.add() })
        f.continueTapped()
        f._receive([hub("ab12")])
        f.code = "123456"
        f.submit()
        return f
    }

    @Test func R6b_numberThenBothTapsConnect() async throws {
        let session = FakeSession(.success(pairing("ab12", name: "Office Mac")), confirmation: "482913")
        let saved = Saves()
        let f = submitted(FakePairer(session: session), saved: saved)
        try await waitUntil { f.step == .compare(number: "482913", confirmedHere: false) }
        session.macApproves()                 // the Mac's 204 alone is not enough
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.step == .compare(number: "482913", confirmedHere: false) && saved.count == 0)
        f.confirmMatch()
        #expect(session.confirmedLocally)
        try await waitUntil { f.step == .connected(macName: "Office Mac") }
        #expect(saved.count == 1)
    }

    @Test func R6b_iPhoneFirstThenWaitsForTheMac() async throws {
        let session = FakeSession(.success(pairing("ab12", name: "Office Mac")), confirmation: "482913")
        let f = submitted(FakePairer(session: session))
        try await waitUntil { f.step == .compare(number: "482913", confirmedHere: false) }
        f.confirmMatch()
        #expect(f.step == .compare(number: "482913", confirmedHere: true))
        session.macApproves()
        try await waitUntil { f.step == .connected(macName: "Office Mac") }
    }

    @Test func R6b_cancelOnTheIPhoneAfterTheMacSavesNothing() async throws {
        let session = FakeSession(.success(pairing("ab12", name: "Office Mac")), confirmation: "482913")
        let saved = Saves()
        let f = submitted(FakePairer(session: session), saved: saved)
        try await waitUntil { f.step == .compare(number: "482913", confirmedHere: false) }
        session.macApproves()
        f.cancelWaiting()
        #expect(f.step == .choose && session.cancelled)
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.step == .choose && saved.count == 0 && f.errorText == nil)
    }

    @Test func cancelOnTheMacShowsTheText() async throws {
        let session = FakeSession(.success(pairing("ab12", name: "Office Mac")), confirmation: "482913")
        let f = submitted(FakePairer(session: session))
        try await waitUntil { f.step == .compare(number: "482913", confirmedHere: false) }
        f.confirmMatch()
        session.macRefuses()
        try await waitUntil { f.step == .choose }
        #expect(f.errorText == "Pairing was cancelled on the Mac. Get a new code and try again.")
    }

    @Test func R10_anotherMacAsksToReplace() {
        let f = flow(FakePairer(failing: .refused), existing: pairing("zz99", name: "Old Mac"))
        f.continueTapped()
        f._receive([hub("ab12")])
        f.code = "123456"
        f.submit()
        #expect(f.replaceName == "Old Mac" && f.step == .choose)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition not met")
    }
}
