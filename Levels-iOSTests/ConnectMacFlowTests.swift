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

/// A pairer that reports a confirmation number and waits until released (the
/// feature/net-security shape), or answers at once.
private final class FakePairer: MacPairer {
    let result: Result<HubPairing, PairError>
    let confirmation: String?
    private let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
    private let waits: Bool
    init(_ result: Result<HubPairing, PairError>, confirmation: String? = nil, waits: Bool = false) {
        self.result = result
        self.confirmation = confirmation
        self.waits = waits
    }
    func release() { gate.withLock { $0?.resume(); $0 = nil } }
    func pair(hub: DiscoveredHub, code: String, me: PairRequestIdentity,
              onConfirmationNumber: @escaping @Sendable (String) -> Void) async throws(PairError) -> HubPairing {
        if let confirmation { onConfirmationNumber(confirmation) }
        if waits { await withCheckedContinuation { c in gate.withLock { $0 = c } } }
        return try result.get()
    }
}

@MainActor
@Suite struct ConnectMacFlowTests {
    func flow(_ pairer: any MacPairer, existing: HubPairing? = nil) -> ConnectMacFlowModel {
        ConnectMacFlowModel(browse: { AsyncThrowingStream { _ in } }, pairer: pairer, me: { me },
                            existing: { existing }, save: { _ in })
    }

    @Test func AC2_noBrowseBeforeContinue() {
        let f = flow(FakePairer(.failure(.refused)))
        #expect(f.step == .explain && f.browseCount == 0)
        f.continueTapped()
        #expect(f.step == .choose && f.browseCount == 1)
    }

    @Test func oneHubIsPreselectedAndClosedWindowsAreHidden() {
        let f = flow(FakePairer(.failure(.refused)))
        f.continueTapped()
        f._receive([hub("ab12"), hub("cd34", pairing: false)])
        #expect(f.hubs.map(\.tag) == ["ab12"] && f.selectedTag == "ab12")
    }

    @Test func codeFieldKeepsSixDigits() {
        let f = flow(FakePairer(.failure(.refused)))
        f.code = "12a3 4567"
        #expect(f.code == "123456")
        #expect(PairingText.grouped("123456") == "123 456")
    }

    @Test func wrongCodeShowsTheNET002TextAndKeepsTheField() async throws {
        let f = flow(FakePairer(.failure(.wrongCode)))
        f.continueTapped()
        f._receive([hub("ab12")])
        f.code = "111111"
        f.submit()
        try await waitUntil { f.step == .choose }
        #expect(f.errorText == "That code didn't work. Check the code on your Mac.")
        #expect(f.code == "111111")
    }

    @Test func confirmationNumberIsShownWhileWaitingThenConnected() async throws {
        let pairer = FakePairer(.success(pairing("ab12", name: "Office Mac")), confirmation: "482913", waits: true)
        let f = flow(pairer)
        f.continueTapped()
        f._receive([hub("ab12")])
        f.code = "123456"
        f.submit()
        try await waitUntil { f.step == .waitingForMac(confirmation: "482913") }
        pairer.release()
        try await waitUntil { f.step == .connected(macName: "Office Mac") }
    }

    @Test func cancelWhileWaitingIgnoresALateAnswer() async throws {
        let pairer = FakePairer(.success(pairing("ab12", name: "Office Mac")), waits: true)
        let f = flow(pairer)
        f.continueTapped()
        f._receive([hub("ab12")])
        f.code = "123456"
        f.submit()
        try await waitUntil { f.step == .waitingForMac(confirmation: nil) }
        f.cancelWaiting()
        #expect(f.step == .choose)
        pairer.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.step == .choose)
    }

    @Test func R10_anotherMacAsksToReplace() {
        let f = flow(FakePairer(.failure(.refused)), existing: pairing("zz99", name: "Old Mac"))
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
