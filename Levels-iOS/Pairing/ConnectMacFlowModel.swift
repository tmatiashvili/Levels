// NET-004 R2, R3 and NET-002 R3–R7, R10: the "Connect to your Mac" flow as a model the views
// drive and Levels-iOSTests checks (AC2: no browse before Continue).
import Foundation
import LevelsModel
import LevelsNet
import Observation

/// The pairing step behind the Connect flow (NET-002 R4–R7, lead's call 30).
///
/// `start` runs the code handshake and the key exchange and returns a session with the
/// 6-digit confirmation number. The flow shows it ("Does your Mac show this number?") with
/// They match and Cancel; `finish` returns only after the owner tapped They match on BOTH
/// the iPhone and the Mac (R6b), so the iPhone never trusts the Mac's answer alone.
protocol MacPairer: Sendable {
    func start(hub: DiscoveredHub, code: String, me: PairRequestIdentity) async throws(PairError) -> any MacPairingSession
}

/// One pairing in progress (``PairingSession`` in the app).
protocol MacPairingSession: AnyObject, Sendable {
    var confirmationCode: String { get }
    /// They match on the iPhone.
    func confirmLocally()
    /// Both They match taps, then the first request with the new key.
    func finish() async throws(PairError) -> HubPairing
    /// Cancel on the iPhone: nothing is returned or saved.
    func cancel()
}

extension PairingSession: MacPairingSession {
    func finish() async throws(PairError) -> HubPairing { try await finish(now: Date()) }
}

/// The real pairer (NET-002 with the confirmation number).
struct CodePairer: MacPairer {
    var client = PairingClient()
    func start(hub: DiscoveredHub, code: String, me: PairRequestIdentity) async throws(PairError) -> any MacPairingSession {
        try await client.start(with: hub.endpoint, hubTag: hub.tag, code: code, me: me)
    }
}

/// NET-002 / NET-004 texts for pairing failures.
enum PairingText {
    static func message(_ error: PairError) -> String {
        switch error {
        case .wrongCode: String(localized: "That code didn't work. Check the code on your Mac.")
        case .tooManyTries: String(localized: "Too many tries. Get a new code on your Mac.")
        case .hubFull: String(localized: "This Mac already has 4 devices. Remove one on the Mac first.")
        case .notReachable: String(localized: "Can't reach your Mac. Check that both are on the same Wi-Fi.")
        case .refused: String(localized: "Pairing was cancelled on the Mac. Get a new code and try again.")
        case .timedOut: String(localized: "The numbers weren't confirmed in time. Get a new code on your Mac and try again.")
        }
    }

    /// "123 456" (NET-002 R1 style) for codes and confirmation numbers.
    static func grouped(_ digits: String) -> String {
        guard digits.count == 6 else { return digits }
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }

    /// The code field keeps digits only, at most 6.
    static func codeValue(_ input: String) -> String { String(input.filter(\.isASCII).filter(\.isNumber).prefix(6)) }
}

@MainActor @Observable final class ConnectMacFlowModel {
    enum Step: Equatable {
        /// R2: one line about the Local Network prompt, then Continue.
        case explain
        /// R3: pick the Mac and type the code.
        case choose
        /// After the code: spinner and Cancel until the confirmation number is known.
        case connecting
        /// R6a, R6b: "Does your Mac show this number?" with They match and Cancel.
        /// `confirmedHere` once the owner tapped They match on the iPhone (then: waiting for the Mac).
        case compare(number: String, confirmedHere: Bool)
        case connected(macName: String)
    }

    private(set) var step: Step = .explain
    /// Hubs with the pairing window open and our protocol version.
    private(set) var hubs: [DiscoveredHub] = []
    var selectedTag: String?
    var code = "" { didSet { if code != PairingText.codeValue(code) { code = PairingText.codeValue(code) } } }
    private(set) var errorText: String?
    private(set) var isLocalNetworkDenied = false
    /// NET-002 R10: set when another Mac is stored; the view asks "Replace <name>?".
    var replaceName: String?
    /// How many times browsing started (AC2).
    private(set) var browseCount = 0

    @ObservationIgnored private let browse: @Sendable () -> AsyncThrowingStream<[DiscoveredHub], any Error>
    @ObservationIgnored private let pairer: any MacPairer
    @ObservationIgnored private let me: () -> PairRequestIdentity?
    @ObservationIgnored private let existing: () -> HubPairing?
    @ObservationIgnored private let save: (HubPairing) async throws -> Void
    @ObservationIgnored private var browseTask: Task<Void, Never>?
    @ObservationIgnored private var pairTask: Task<Void, Never>?
    @ObservationIgnored private var session: (any MacPairingSession)?
    @ObservationIgnored private var attempt = 0

    init(browse: @escaping @Sendable () -> AsyncThrowingStream<[DiscoveredHub], any Error>,
         pairer: any MacPairer, me: @escaping () -> PairRequestIdentity?,
         existing: @escaping () -> HubPairing?, save: @escaping (HubPairing) async throws -> Void) {
        self.browse = browse
        self.pairer = pairer
        self.me = me
        self.existing = existing
        self.save = save
    }

    var selectedHub: DiscoveredHub? { hubs.first { $0.tag == selectedTag } }
    var canSubmit: Bool { code.count == 6 && selectedHub != nil && step == .choose }

    /// R2: only now does browsing start (the system prompt appears on first use).
    func continueTapped() {
        step = .choose
        startBrowsing()
    }

    func startBrowsing() {
        browseTask?.cancel()
        browseCount += 1
        isLocalNetworkDenied = false
        let stream = browse()
        browseTask = Task { [weak self] in
            do {
                for try await found in stream { self?.update(found) }
            } catch HubError.localNetworkDenied {
                self?.isLocalNetworkDenied = true
            } catch {}
        }
    }

    func stop() {
        browseTask?.cancel()
        browseTask = nil
        cancelWaiting()
    }

    private func update(_ found: [DiscoveredHub]) {
        hubs = found.filter { $0.isPairing && $0.version == HubProtocol.version }.sorted { $0.name < $1.name }
        if selectedHub == nil { selectedTag = hubs.count == 1 ? hubs[0].tag : nil }
    }

    /// R3, R10.
    func submit(replacing: Bool = false) {
        guard canSubmit, let hub = selectedHub, let me = me() else { return }
        if !replacing, let old = existing(), old.hubTag != hub.tag {
            replaceName = old.hubName
            return
        }
        errorText = nil
        attempt += 1
        let current = attempt
        let code = code
        let pairer = pairer
        step = .connecting
        pairTask = Task { [weak self] in
            do {
                let session = try await pairer.start(hub: hub, code: code, me: me)
                guard let self, current == self.attempt else { session.cancel(); return }  // cancelled meanwhile
                self.session = session
                self.step = .compare(number: session.confirmationCode, confirmedHere: false)
                let pairing = try await session.finish()
                guard current == self.attempt else { return }
                self.session = nil
                try await self.save(pairing)
                self.browseTask?.cancel()
                self.step = .connected(macName: pairing.hubName)
            } catch let error as PairError {
                self?.fail(PairingText.message(error), attempt: current)
            } catch {
                self?.fail(String(localized: "Couldn't save the pairing. Try again."), attempt: current)
            }
        }
    }

    /// R6b: They match on the iPhone. The pairing is saved only once the Mac agrees too.
    func confirmMatch() {
        guard case .compare(let number, false) = step, let session else { return }
        session.confirmLocally()
        step = .compare(number: number, confirmedHere: true)
    }

    /// Cancel while connecting or comparing: back to the code; nothing is saved and a late
    /// answer is ignored.
    func cancelWaiting() {
        switch step {
        case .connecting, .compare: break
        default: return
        }
        attempt += 1
        session?.cancel()
        session = nil
        pairTask?.cancel()
        step = .choose
    }

    private func fail(_ text: String, attempt current: Int) {
        guard current == attempt else { return }
        session = nil
        errorText = text
        step = .choose
    }

    #if DEBUG
    /// Tests: feed browse results without a network.
    func _receive(_ found: [DiscoveredHub]) { update(found) }
    #endif
}
