import Foundation
import LevelsModel
import Security
import Synchronization
import Testing
@testable import LevelsReaders

/// An in-memory Keychain that can be told to fail (ADR-0007 rules 1–2).
final class FakeKeychain: KeychainDeviceIdentity.Backend {
    struct State {
        var stored: String?
        var readStatus: OSStatus?   // forced status for reads
        var addStatus: OSStatus?    // forced status for adds
        var storeOnDuplicate: String?  // value "another process" saved before our add
        var adds: [[String: String]] = []
    }
    let state: Mutex<State>
    init(_ s: State = State()) { state = Mutex(s) }

    func read(_ query: [String: any Sendable]) -> (OSStatus, String?) {
        state.withLock { s in
            if let forced = s.readStatus { return (forced, nil) }
            return s.stored.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        }
    }

    func add(_ attributes: [String: any Sendable]) -> OSStatus {
        state.withLock { s in
            s.adds.append(attributes.compactMapValues { "\($0)" })
            if let other = s.storeOnDuplicate { s.stored = other; return errSecDuplicateItem }
            if let forced = s.addStatus { return forced }
            s.stored = (attributes[kSecValueData as String] as? Data).flatMap { String(data: $0, encoding: .utf8) }
            return errSecSuccess
        }
    }
}

@Suite("ADR-0007 KeychainDeviceIdentity")
struct KeychainDeviceIdentityTests {
    func identity(_ k: FakeKeychain) -> KeychainDeviceIdentity {
        KeychainDeviceIdentity(service: "com.example.levels.device-identity", accessGroup: "T.com.example.levels.shared", backend: k)
    }

    @Test("Creates once on not-found, then returns the same ID")
    func createsOnce() throws {
        let k = FakeKeychain()
        let first = try #require(try identity(k).currentDeviceID())
        #expect(try identity(k).currentDeviceID() == first)
        let adds = k.state.withLock { $0.adds }
        #expect(adds.count == 1)
        #expect(adds[0][kSecAttrSynchronizable as String] == "false")
        #expect(adds[0][kSecAttrAccessible as String] == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(adds[0][kSecAttrAccessGroup as String] == "T.com.example.levels.shared")
        #expect(adds[0][kSecAttrAccount as String] == "deviceId")
    }

    @Test("Rule 1: a read error other than not-found creates nothing and returns nil")
    func interactionNotAllowed() throws {
        let k = FakeKeychain(.init(readStatus: errSecInteractionNotAllowed))
        #expect(try identity(k).currentDeviceID() == nil)
        #expect(k.state.withLock { $0.adds.isEmpty })
    }

    @Test("Rule 2: duplicate on add reads the winner's value")
    func duplicate() throws {
        let winner = DeviceID(UUID())
        let k = FakeKeychain(.init(storeOnDuplicate: winner.recordName))
        #expect(try identity(k).currentDeviceID() == winner)
    }

    @Test("A failed add returns nil")
    func addFails() throws {
        let k = FakeKeychain(.init(addStatus: errSecMissingEntitlement))
        #expect(try identity(k).currentDeviceID() == nil)
    }
}
