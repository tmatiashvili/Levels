import CryptoKit
import Foundation
import LevelsModel
import Synchronization
import Testing
@testable import LevelsNet

@Suite("NET-002 PairingCrypto (R2, R4, R5, R6, R6a)")
struct PairingCryptoTests {
    @Test func AC1_codesAreSixDigitsAndEveryFirstDigitAppears() {
        var g = SeededGenerator(seed: 42)
        var firstDigits = Set<Character>()
        for _ in 0..<100_000 {
            let code = PairingCrypto.newCode(using: &g)
            #expect(code.count == 6 && code.allSatisfy(\.isNumber))
            firstDigits.insert(code.first!)
        }
        #expect(firstDigits == Set("0123456789"))
        #expect(PairingCrypto.displayCode("123456") == "123 456")
    }

    // Checked-in vectors (AC2). Fixed X25519 private keys make the shared secret repeatable.
    static let phonePrivate = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
    static let macPrivate = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
    static let attackerToPhone = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x33, count: 32))
    static let attackerToMac = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x44, count: 32))

    static func transcript(phone: Curve25519.KeyAgreement.PublicKey = phonePrivate.publicKey,
                           mac: Curve25519.KeyAgreement.PublicKey = macPrivate.publicKey) -> PairingTranscript {
        PairingTranscript(hubTag: "ab12", hubID: hubID, hubDeviceID: macID, hubName: "Office Mac", deviceID: phoneID,
                          deviceName: "My iPhone", kind: .iphone, devicePublicKey: phone.rawRepresentation,
                          hubPublicKey: mac.rawRepresentation)
    }

    static func secret(_ mine: Curve25519.KeyAgreement.PrivateKey, _ theirs: Curve25519.KeyAgreement.PublicKey) -> Data {
        try! mine.sharedSecretFromKeyAgreement(with: theirs).withUnsafeBytes { Data($0) }
    }

    @Test func AC2_codeKeyVector() {
        #expect(hex(PairingCrypto.codeKey(code: "123456", hubTag: "ab12")) == Self.codeKeyVector)
    }

    @Test func AC2_transcriptAndCommitmentVectors() {
        #expect(hexData(Self.secret(Self.phonePrivate, Self.macPrivate.publicKey)) == Self.sharedSecretVector)
        #expect(hexData(Self.transcript().digest) == Self.transcriptVector)
        #expect(hexData(PairingCrypto.commitment(to: Self.phonePrivate.publicKey.rawRepresentation)) == Self.commitmentVector)
    }

    @Test func AC2_bothSidesDeriveTheSameKeyAndNumber() throws {
        let phoneSide = try Self.phonePrivate.sharedSecretFromKeyAgreement(with: Self.macPrivate.publicKey)
        let macSide = try Self.macPrivate.sharedSecretFromKeyAgreement(with: Self.phonePrivate.publicKey)
        let t = Self.transcript()
        let a = PairingCrypto.pairingKey(shared: phoneSide, transcript: t)
        let b = PairingCrypto.pairingKey(shared: macSide, transcript: t)
        #expect(hex(a) == hex(b))
        #expect(hex(a) == Self.pairingKeyVector)
        #expect(a.bitCount == 256)
        let sasA = PairingCrypto.confirmationCode(shared: phoneSide, transcript: t)
        #expect(sasA == PairingCrypto.confirmationCode(shared: macSide, transcript: t))
        #expect(sasA == Self.confirmationVector)
        #expect(sasA.count == 6 && sasA.allSatisfy(\.isNumber))
    }

    @Test func AC2_anyTranscriptFieldChangesTheKey() {
        let shared = Self.secret(Self.phonePrivate, Self.macPrivate.publicKey)
        let base = Self.transcript()
        let baseKey = hex(PairingCrypto.pairingKey(sharedSecret: shared, transcript: base))
        var variants: [PairingTranscript] = []
        var t = base; t.hubTag = "ab13"; variants.append(t)
        t = base; t.hubID = UUID(); variants.append(t)
        t = base; t.hubDeviceID = otherPhoneID; variants.append(t)
        t = base; t.hubName = "Home Mac"; variants.append(t)
        t = base; t.deviceID = otherPhoneID; variants.append(t)
        t = base; t.deviceName = "My iPhone 2"; variants.append(t)
        t = base; t.kind = .ipad; variants.append(t)
        t = base; t.devicePublicKey = Self.attackerToPhone.publicKey.rawRepresentation; variants.append(t)
        t = base; t.hubPublicKey = Self.attackerToMac.publicKey.rawRepresentation; variants.append(t)
        // Length prefixes: moving a character between two fields changes the digest.
        t = base; t.hubName = "Office Ma"; t.deviceID = base.deviceID; t.deviceName = "cMy iPhone"; variants.append(t)
        for v in variants {
            #expect(v.digest != base.digest)
            #expect(hex(PairingCrypto.pairingKey(sharedSecret: shared, transcript: v)) != baseKey)
        }
    }

    /// Call 30: a passive attacker who cracked the code from the recorded handshake sees the
    /// whole exchange (both public keys, the transcript) but not the X25519 shared secret.
    /// The key depends on that secret, and the code is not an input at all.
    @Test func crackedCodeIsNotEnoughForTheKey() {
        let t = Self.transcript()
        let real = PairingCrypto.pairingKey(sharedSecret: Self.secret(Self.phonePrivate, Self.macPrivate.publicKey), transcript: t)
        // Everything public, with the attacker's own key against each side.
        let guesses = [
            Self.secret(Self.attackerToPhone, Self.phonePrivate.publicKey),
            Self.secret(Self.attackerToMac, Self.macPrivate.publicKey),
            Data(repeating: 0, count: 32),
            t.digest,
            PairingCrypto.codeKey(code: "123456", hubTag: "ab12").withUnsafeBytes { Data($0) },
        ]
        for g in guesses { #expect(hex(PairingCrypto.pairingKey(sharedSecret: g, transcript: t)) != hex(real)) }
        // Changing only the shared secret changes the key and the number.
        let other = Self.secret(Self.phonePrivate, Self.attackerToPhone.publicKey)
        #expect(hex(PairingCrypto.pairingKey(sharedSecret: other, transcript: t)) != hex(real))
        #expect(PairingCrypto.confirmationCode(sharedSecret: other, transcript: t)
            != PairingCrypto.confirmationCode(sharedSecret: Self.secret(Self.phonePrivate, Self.macPrivate.publicKey), transcript: t))
    }

    /// Call 30: a man in the middle runs two separate key agreements (iPhone ↔ attacker and
    /// attacker ↔ Mac). The numbers on the two screens differ, so the owner cancels.
    @Test func manInTheMiddleShowsDifferentNumbers() {
        let phoneTranscript = Self.transcript(phone: Self.phonePrivate.publicKey, mac: Self.attackerToPhone.publicKey)
        let macTranscript = Self.transcript(phone: Self.attackerToMac.publicKey, mac: Self.macPrivate.publicKey)
        let phoneSees = PairingCrypto.confirmationCode(sharedSecret: Self.secret(Self.phonePrivate, Self.attackerToPhone.publicKey),
                                                       transcript: phoneTranscript)
        let macSees = PairingCrypto.confirmationCode(sharedSecret: Self.secret(Self.macPrivate, Self.attackerToMac.publicKey),
                                                     transcript: macTranscript)
        #expect(phoneSees != macSees)
        // And the attacker's two keys differ from each other and from an honest run.
        let honest = PairingCrypto.pairingKey(sharedSecret: Self.secret(Self.phonePrivate, Self.macPrivate.publicKey),
                                              transcript: Self.transcript())
        let k1 = PairingCrypto.pairingKey(sharedSecret: Self.secret(Self.phonePrivate, Self.attackerToPhone.publicKey), transcript: phoneTranscript)
        let k2 = PairingCrypto.pairingKey(sharedSecret: Self.secret(Self.macPrivate, Self.attackerToMac.publicKey), transcript: macTranscript)
        #expect(Set([hex(honest), hex(k1), hex(k2)]).count == 3)
    }

    @Test func confirmationNumbersSpreadOverSixDigits() {
        var seen = Set<String>()
        var firstDigits = Set<Character>()
        for i in 0..<2000 {
            var t = Self.transcript()
            t.deviceName = "Phone \(i)"
            let sas = PairingCrypto.confirmationCode(sharedSecret: Data(repeating: 7, count: 32), transcript: t)
            #expect(sas.count == 6 && sas.allSatisfy(\.isNumber))
            seen.insert(sas)
            firstDigits.insert(sas.first!)
        }
        #expect(seen.count > 1990)
        #expect(firstDigits == Set("0123456789"))
    }

    static let codeKeyVector = "4b6597e81433313b458a609ba5a2dbd1f49591fc487190379b88a6b9a8475075"  // also checked with Python hmac
    // Checked with an independent Python implementation (RFC 7748 X25519, RFC 5869 HKDF).
    static let sharedSecretVector = "9e004098efc091d4ec2663b4e9f5cfd4d7064571690b4bea97ab146ab9f35056"
    static let transcriptVector = "1e11c9254e8b0ffb7ef0ff0bb72c002bd3098dda1b70d2fa7f2a92dc3c3c1dbe"
    static let commitmentVector = "e187787cb9f1b6e7f07bbe0b5c9ce901c3eeb55148b63f24fe1bbbd12a32de0c"
    static let pairingKeyVector = "f1eae5b966baca4b202ab01669b153b3a118b73dcbf7a0578dc65939049f9d48"
    static let confirmationVector = "294317"
}

@Suite("NET-002 PairingWindow (R1, R2, R5, R7, R11)")
struct PairingWindowTests {
    final class Clock: Sendable {
        let date = Mutex(t0)
        func advance(_ s: TimeInterval) { date.withLock { $0 += s } }
        var now: Date { date.withLock { $0 } }
    }

    func make(store: InMemoryHubPairingStore = InMemoryHubPairingStore()) -> (PairingWindow, Clock, InMemoryHubPairingStore) {
        let clock = Clock()
        return (PairingWindow(store: store, now: { clock.now }), clock, store)
    }

    static let phoneKey = Curve25519.KeyAgreement.PrivateKey()

    func request(_ id: DeviceID = phoneID, kind: DeviceKind = .iphone, name: String = "My iPhone") -> PairRequest {
        PairRequest(deviceID: id, name: name, kind: kind,
                    commitment: PairingCrypto.commitment(to: Self.phoneKey.publicKey.rawRepresentation))
    }

    var reveal: PairConfirmRequest { PairConfirmRequest(publicKey: Self.phoneKey.publicKey.rawRepresentation) }

    /// accept → reveal → approve: the Mac side up to R7's confirming request.
    func match(_ window: PairingWindow, _ request: PairRequest) throws -> PairResponse {
        let response = try window.accept(request)
        try window.reveal(reveal)
        #expect(window.approve())
        return response
    }

    /// Regression (owner's first pairing, 2026-11-24): the hub stopped its listener once the window
    /// left `.open`, which cancelled the pairing while the owner compared the numbers.
    @Test func windowStaysInProgressWhileConfirmingAndMatched() throws {
        let (window, _, _) = make()
        #expect(!window.isInProgress)
        window.open(hub: hubInfo)
        #expect(window.isInProgress)
        _ = try window.accept(request())
        try window.reveal(reveal)
        #expect(!window.isOpen)
        #expect(window.isInProgress)
        #expect(window.approve())
        #expect(window.isInProgress)
    }

    @Test func windowIsNotInProgressWhenLocked() {
        let (window, _, _) = make()
        window.open(hub: hubInfo)
        for _ in 0..<5 { window.handshakeFailed() }
        if case .locked = window.state {} else { Issue.record("not locked") }
        #expect(!window.isInProgress)
    }

    @Test func openGivesCodeAndPairKey() {
        let (window, _, _) = make()
        let code = window.open(hub: hubInfo)
        guard case .open(let c, let endsAt, 0) = window.state else { Issue.record("not open"); return }
        #expect(c == code && endsAt == t0 + 120)
        #expect(window.codeKey.map(hex) == hex(PairingCrypto.codeKey(code: code, hubTag: "ab12")))
        #expect(window.isOpen)
    }

    @Test func AC3_fiveFailuresLock() {
        let (window, _, _) = make()
        window.open(hub: hubInfo)
        for _ in 0..<4 { window.handshakeFailed() }
        guard case .open(_, _, 4) = window.state else { Issue.record("expected 4 failures"); return }
        window.handshakeFailed()
        #expect(window.state == .locked)
        #expect(window.codeKey == nil)
        #expect(!window.isOpen)
        #expect(throws: PairError.tooManyTries) { try window.accept(request()) }
    }

    @Test func AC4_twoMinutesCloseAndDropUnconfirmed() throws {
        let (window, clock, store) = make()
        let count = Mutex(0)
        window.setObserver { count.withLock { $0 += 1 } }
        window.open(hub: hubInfo)
        _ = try match(window, request())
        #expect(window.pendingID == phoneID)
        clock.advance(119)
        #expect(window.state == .matched(name: "My iPhone"))
        clock.advance(1)
        window.expireIfDue()
        #expect(window.state == .closed)
        #expect(window.pendingID == nil && window.codeKey == nil && window.deadline == nil)
        #expect(window.confirm(phoneID) == nil)
        #expect(store.all().isEmpty)
        #expect(count.withLock { $0 } == 5)  // open, accept, reveal, approve, expiry
    }

    @Test func AC5_acceptThenConfirmStoresKeyAndEndsWindow() throws {
        let (window, _, store) = make()
        window.open(hub: hubInfo)
        let response = try match(window, request(name: "  A very long iPhone name that goes past the forty character limit  "))
        #expect(response.hubID == hubID && response.hubDeviceID == macID && response.hubName == "Office Mac")
        #expect(response.publicKey.count == 32)
        let pendingKey = try #require(window.pendingKey(for: phoneID))
        #expect(store.key(for: phoneID) == nil)
        let saved = try #require(window.confirm(phoneID))
        #expect(saved.name.count == 40 && !saved.name.hasPrefix(" "))
        #expect(store.key(for: phoneID).map(hex) == hex(pendingKey))
        #expect(window.state == .paired(name: saved.name))
        #expect(window.codeKey == nil)
        #expect(window.pendingID == nil)
    }

    /// Call 30: the Mac's key equals the iPhone's, computed the iPhone's way from the answer.
    @Test func macAndPhoneDeriveTheSameKeyAndNumber() throws {
        let (window, _, _) = make()
        window.open(hub: hubInfo)
        let response = try window.accept(request())
        let sas = try window.reveal(reveal)
        let shared = try Self.phoneKey.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: response.publicKey))
        let t = PairingTranscript(hubTag: "ab12", hubID: response.hubID, hubDeviceID: response.hubDeviceID, hubName: response.hubName,
                                  deviceID: phoneID, deviceName: "My iPhone", kind: .iphone,
                                  devicePublicKey: Self.phoneKey.publicKey.rawRepresentation, hubPublicKey: response.publicKey)
        #expect(PairingCrypto.confirmationCode(shared: shared, transcript: t) == sas)
        guard case .confirming("My iPhone", sas, _) = window.state else { Issue.record("not confirming"); return }
        window.approve()
        #expect(window.pendingKey(for: phoneID).map(hex) == hex(PairingCrypto.pairingKey(shared: shared, transcript: t)))
    }

    /// Call 30: without "They match" on the Mac, the device's key never reaches the listener
    /// and its first request can't confirm the pairing.
    @Test func pairingNeedsTheOwnersTap() throws {
        let (window, _, store) = make()
        let ring = HubKeyring(store: store, window: window)
        window.open(hub: hubInfo)
        _ = try window.accept(request())
        try window.reveal(reveal)
        #expect(window.pendingKey(for: phoneID) == nil && window.pendingID == nil)
        #expect(ring.keys().isEmpty)  // neither the device key nor `pair` any more
        #expect(!ring.allows(phoneID.recordName) && !ring.allows("pair"))
        #expect(window.confirm(phoneID) == nil)
        #expect(store.all().isEmpty)
        // Cancel ends it for good.
        window.close()
        #expect(!window.approve())
        #expect(window.confirm(phoneID) == nil && store.all().isEmpty)
    }

    @Test func decisionReportsMatchCancelAndExpiry() async throws {
        do {
            let (window, _, _) = make()
            window.open(hub: hubInfo)
            _ = try window.accept(request())
            try window.reveal(reveal)
            let waiting = Task { await window.decision() }
            try await Task.sleep(for: .milliseconds(20))
            window.approve()
            #expect(await waiting.value == .matched)
            #expect(await window.decision() == .matched)  // late caller
        }
        do {
            let (window, _, _) = make()
            window.open(hub: hubInfo)
            _ = try window.accept(request())
            try window.reveal(reveal)
            let waiting = Task { await window.decision() }
            try await Task.sleep(for: .milliseconds(20))
            window.close()
            #expect(await waiting.value == .cancelled)
        }
        do {
            let (window, clock, _) = make()
            window.open(hub: hubInfo)
            _ = try window.accept(request())
            try window.reveal(reveal)
            let waiting = Task { await window.decision() }
            try await Task.sleep(for: .milliseconds(20))
            clock.advance(121)
            window.expireIfDue()
            #expect(await waiting.value == .expired)
            #expect(window.state == .closed)
        }
        do {
            // A cancelled wait (the device hung up) leaves the window as it is.
            let (window, _, _) = make()
            window.open(hub: hubInfo)
            _ = try window.accept(request())
            try window.reveal(reveal)
            let waiting = Task { await window.decision() }
            try await Task.sleep(for: .milliseconds(20))
            waiting.cancel()
            #expect(await waiting.value == .cancelled)
            if case .confirming = window.state {} else { Issue.record("window changed") }
        }
    }

    @Test func wrongRevealEndsTheWindow() throws {
        let (window, _, store) = make()
        window.open(hub: hubInfo)
        _ = try window.accept(request())
        let other = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        #expect(throws: PairError.refused) { try window.reveal(PairConfirmRequest(publicKey: other)) }
        #expect(window.state == .closed && window.codeKey == nil)
        #expect(throws: PairError.refused) { try window.reveal(reveal) }
        #expect(store.all().isEmpty)
    }

    @Test func oneDevicePerWindow() throws {
        let (window, _, _) = make()
        window.open(hub: hubInfo)
        _ = try window.accept(request())
        #expect(throws: PairError.refused) { try window.accept(request(otherPhoneID)) }
        try window.reveal(reveal)
        #expect(throws: PairError.refused) { try window.accept(request(otherPhoneID)) }
        #expect(throws: PairError.refused) { try window.reveal(reveal) }
    }

    @Test func lateRevealStillGetsTimeToCompare() throws {
        let (window, clock, _) = make()
        window.open(hub: hubInfo)
        _ = try window.accept(request())
        clock.advance(110)
        try window.reveal(reveal)
        #expect(window.deadline == t0 + 110 + PairingWindow.minConfirmTime)
        clock.advance(25)
        if case .confirming = window.state {} else { Issue.record("expired too early") }
        clock.advance(5)
        #expect(window.state == .closed)
    }

    @Test func AC6_refusedKindsAndFullHub() {
        let (window, _, _) = make()
        window.open(hub: hubInfo)
        #expect(throws: PairError.refused) { try window.accept(request(kind: .mac)) }
        #expect(throws: PairError.refused) { try window.accept(request(kind: .accessory)) }
        #expect(throws: PairError.refused) {
            try window.accept(PairRequest(deviceID: phoneID, name: "x", kind: .iphone, commitment: Data([1, 2, 3])))
        }
        let full = InMemoryHubPairingStore((0..<4).map {
            PairedClient(id: DeviceID(UUID()), name: "P\($0)", kind: .iphone, key: Data(repeating: 1, count: 32), pairedAt: t0)
        })
        let (fullWindow, _, _) = make(store: full)
        fullWindow.open(hub: hubInfo)
        #expect(throws: PairError.hubFull) { try fullWindow.accept(request()) }
        // Re-pairing one of the four is allowed (R10).
        let existing = full.all()[0].id
        #expect((try? fullWindow.accept(request(existing))) != nil)
    }

    @Test func closedWindowRefusesAndCloseDropsPending() throws {
        let (window, _, _) = make()
        #expect(throws: PairError.refused) { try window.accept(request()) }
        window.open(hub: hubInfo)
        _ = try match(window, request())
        window.close()
        #expect(window.state == .closed && window.pendingID == nil && window.codeKey == nil)
    }

    @Test func keyringFollowsTheWindow() throws {
        let store = InMemoryHubPairingStore([PairedClient(id: otherPhoneID, name: "Old", kind: .iphone,
                                                          key: Data(repeating: 9, count: 32), pairedAt: t0)])
        let (window, _, _) = make(store: store)
        let ring = HubKeyring(store: store, window: window)
        #expect(Set(ring.keys().keys) == [otherPhoneID.recordName])
        #expect(!ring.allows("pair") && ring.allows(otherPhoneID.recordName) && !ring.allows(phoneID.recordName))
        #expect(!ring.allows(otherPhoneID.recordName.uppercased()))
        window.open(hub: hubInfo)
        _ = try window.accept(request())
        #expect(Set(ring.keys().keys) == [otherPhoneID.recordName, "pair"])
        try window.reveal(reveal)
        #expect(Set(ring.keys().keys) == [otherPhoneID.recordName])
        #expect(!ring.allows("pair") && !ring.allows(phoneID.recordName))
        window.approve()
        #expect(Set(ring.keys().keys) == [otherPhoneID.recordName, phoneID.recordName])
        #expect(ring.allows(phoneID.recordName))
        try store.remove(otherPhoneID)
        #expect(!ring.allows(otherPhoneID.recordName))
    }
}

@Suite("NET-002 pairing stores (R8, R10)")
struct PairingStoreTests {
    @Test func hubStoreSavesListsTouchesAndRemoves() throws {
        let items = InMemoryKeychainItems()
        let store = KeychainHubPairingStore(service: "x.levels.hub.client", items: items)
        let client = PairedClient(id: phoneID, name: "My iPhone", kind: .iphone, key: Data(repeating: 7, count: 32), pairedAt: t0)
        try store.save(client)
        // A fresh store reads what the first one wrote.
        let reread = KeychainHubPairingStore(service: "x.levels.hub.client", items: items)
        #expect(reread.all() == [client])
        #expect(reread.key(for: phoneID).map(hex) == hex(client.symmetricKey))
        reread.touch(phoneID, at: t0 + 60)
        #expect(reread.all()[0].lastSeenAt == t0 + 60)
        reread.touch(phoneID, at: t0 + 120)  // within 10 min: not written
        #expect(KeychainHubPairingStore(service: "x.levels.hub.client", items: items).all()[0].lastSeenAt == t0 + 60)
        reread.touch(phoneID, at: t0 + 60 + 600)
        #expect(reread.all()[0].lastSeenAt == t0 + 660)
        try reread.remove(phoneID)
        #expect(reread.all().isEmpty && reread.key(for: phoneID) == nil)
        try store.save(client)
        try store.removeAll()
        #expect(KeychainHubPairingStore(service: "x.levels.hub.client", items: items).all().isEmpty)
    }

    @Test func AC8_clientStoreKeepsOnlyTheNewestHub() throws {
        let items = InMemoryKeychainItems()
        let store = KeychainClientPairingStore(service: "x.levels.hub", items: items)
        let first = HubPairing(hubID: hubID, hubTag: "ab12", hubDeviceID: macID, hubName: "Office Mac", key: Data(repeating: 1, count: 32), pairedAt: t0)
        let second = HubPairing(hubID: UUID(), hubTag: "cd34", hubDeviceID: DeviceID(UUID()), hubName: "Home Mac", key: Data(repeating: 2, count: 32), pairedAt: t0 + 10)
        try store.save(first)
        #expect(store.current() == first)
        try store.save(second)
        #expect(store.current() == second)
        #expect(try items.readAll(service: "x.levels.hub").count == 1)
        try store.remove()
        #expect(store.current() == nil)
    }
}
