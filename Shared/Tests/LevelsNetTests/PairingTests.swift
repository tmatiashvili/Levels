import CryptoKit
import Foundation
import LevelsModel
import Synchronization
import Testing
@testable import LevelsNet

@Suite("NET-002 PairingCrypto (R2, R4, R6)")
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

    @Test func AC2_codeKeyVector() {
        #expect(hex(PairingCrypto.codeKey(code: "123456", hubTag: "ab12")) == Self.codeKeyVector)
    }

    @Test func AC2_bothSidesDeriveTheSameKey() throws {
        let codeKey = PairingCrypto.codeKey(code: "123456", hubTag: "ab12")
        let phoneSide = try Self.phonePrivate.sharedSecretFromKeyAgreement(with: Self.macPrivate.publicKey)
        let macSide = try Self.macPrivate.sharedSecretFromKeyAgreement(with: Self.phonePrivate.publicKey)
        let a = PairingCrypto.pairingKey(shared: phoneSide, codeKey: codeKey, hubID: hubID, deviceID: phoneID)
        let b = PairingCrypto.pairingKey(shared: macSide, codeKey: codeKey, hubID: hubID, deviceID: phoneID)
        #expect(hex(a) == hex(b))
        #expect(hex(a) == Self.pairingKeyVector)
        #expect(a.bitCount == 256)
    }

    @Test func AC2_anyInputChangesTheKey() throws {
        let shared = try Self.phonePrivate.sharedSecretFromKeyAgreement(with: Self.macPrivate.publicKey)
        let other = try Self.phonePrivate.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x33, count: 32)).publicKey)
        let code = PairingCrypto.codeKey(code: "123456", hubTag: "ab12")
        let base = hex(PairingCrypto.pairingKey(shared: shared, codeKey: code, hubID: hubID, deviceID: phoneID))
        let variants = [
            PairingCrypto.pairingKey(shared: other, codeKey: code, hubID: hubID, deviceID: phoneID),
            PairingCrypto.pairingKey(shared: shared, codeKey: PairingCrypto.codeKey(code: "123457", hubTag: "ab12"), hubID: hubID, deviceID: phoneID),
            PairingCrypto.pairingKey(shared: shared, codeKey: PairingCrypto.codeKey(code: "123456", hubTag: "ab13"), hubID: hubID, deviceID: phoneID),
            PairingCrypto.pairingKey(shared: shared, codeKey: code, hubID: UUID(), deviceID: phoneID),
            PairingCrypto.pairingKey(shared: shared, codeKey: code, hubID: hubID, deviceID: otherPhoneID),
        ]
        for v in variants { #expect(hex(v) != base) }
    }

    static let codeKeyVector = "4b6597e81433313b458a609ba5a2dbd1f49591fc487190379b88a6b9a8475075"  // also checked with Python hmac
    static let pairingKeyVector = "64d8d63a73cc8806a53e3275ea57980e3f66a671da0493ba6a20244affbc16bb"
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

    func request(_ id: DeviceID = phoneID, kind: DeviceKind = .iphone, name: String = "My iPhone") -> PairRequest {
        PairRequest(deviceID: id, name: name, kind: kind, publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
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
        var notified = 0
        let count = Mutex(0)
        window.setObserver { count.withLock { $0 += 1 } }
        window.open(hub: hubInfo)
        _ = try window.accept(request())
        #expect(window.pendingID == phoneID)
        clock.advance(119)
        #expect(window.isOpen)
        clock.advance(1)
        window.expireIfDue()
        #expect(window.state == .closed)
        #expect(window.pendingID == nil && window.codeKey == nil)
        #expect(window.confirm(phoneID) == nil)
        #expect(store.all().isEmpty)
        notified = count.withLock { $0 }
        #expect(notified == 3)  // open, accept, expiry
    }

    @Test func AC5_acceptThenConfirmStoresKeyAndEndsWindow() throws {
        let (window, _, store) = make()
        window.open(hub: hubInfo)
        let response = try window.accept(request(name: "  A very long iPhone name that goes past the forty character limit  "))
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

    @Test func AC6_refusedKindsAndFullHub() {
        let (window, _, _) = make()
        window.open(hub: hubInfo)
        #expect(throws: PairError.refused) { try window.accept(request(kind: .mac)) }
        #expect(throws: PairError.refused) { try window.accept(request(kind: .accessory)) }
        #expect(throws: PairError.refused) {
            try window.accept(PairRequest(deviceID: phoneID, name: "x", kind: .iphone, publicKey: Data([1, 2, 3])))
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
        _ = try window.accept(request())
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
        #expect(Set(ring.keys().keys) == [otherPhoneID.recordName, phoneID.recordName, "pair"])
        #expect(ring.allows("pair") && ring.allows(phoneID.recordName))
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
