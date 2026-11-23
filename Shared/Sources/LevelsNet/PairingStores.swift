import CryptoKit
import Foundation
import LevelsModel
import Security
import Synchronization
import os

// Pairing storage (NET-002 R8). Mac: one Keychain item per client. iPhone: one item in
// the shared access group, so the widget extension can read it (NET-004 variant B).

/// The Mac's paired clients. Reads are synchronous: the TLS key lookup calls them.
public protocol HubPairingStore: Sendable {
    func key(for id: DeviceID) -> SymmetricKey?
    func all() -> [PairedClient]
    func save(_ client: PairedClient) throws
    func remove(_ id: DeviceID) throws
    /// "Remove all pairings" (NET-001 R14).
    func removeAll() throws
    /// Updates `lastSeenAt`, written at most once per 10 minutes.
    func touch(_ id: DeviceID, at: Date)
}

/// The iPhone's one hub pairing (lead's call 26).
public protocol ClientPairingStore: Sendable {
    func current() -> HubPairing?
    /// Replaces any stored pairing (R10: one hub per iPhone).
    func save(_ pairing: HubPairing) throws
    func remove() throws
}

/// How often `touch` writes `lastSeenAt`.
let touchInterval: TimeInterval = 10 * 60

// MARK: - In memory (tests, previews)

public final class InMemoryHubPairingStore: HubPairingStore {
    private let clients = Mutex<[DeviceID: PairedClient]>([:])
    public init(_ clients: [PairedClient] = []) {
        self.clients.withLock { c in for client in clients { c[client.id] = client } }
    }
    public func key(for id: DeviceID) -> SymmetricKey? { clients.withLock { $0[id]?.symmetricKey } }
    public func all() -> [PairedClient] { clients.withLock { Array($0.values) }.sorted { $0.pairedAt < $1.pairedAt } }
    public func save(_ client: PairedClient) throws { clients.withLock { $0[client.id] = client } }
    public func remove(_ id: DeviceID) throws { _ = clients.withLock { $0.removeValue(forKey: id) } }
    public func removeAll() throws { clients.withLock { $0 = [:] } }
    public func touch(_ id: DeviceID, at date: Date) {
        clients.withLock { c in
            guard var client = c[id] else { return }
            if let last = client.lastSeenAt, date.timeIntervalSince(last) < touchInterval { return }
            client.lastSeenAt = date
            c[id] = client
        }
    }
}

public final class InMemoryClientPairingStore: ClientPairingStore {
    private let pairing: Mutex<HubPairing?>
    public init(_ pairing: HubPairing? = nil) { self.pairing = Mutex(pairing) }
    public func current() -> HubPairing? { pairing.withLock { $0 } }
    public func save(_ pairing: HubPairing) throws { self.pairing.withLock { $0 = pairing } }
    public func remove() throws { pairing.withLock { $0 = nil } }
}

// MARK: - Keychain

/// The `SecItem` calls for one service's generic-password items, so the stores are
/// testable without a Keychain.
public protocol KeychainItems: Sendable {
    /// Every item of `service`: account → data.
    func readAll(service: String) throws -> [String: Data]
    /// Adds or replaces one item.
    func write(service: String, account: String, data: Data) throws
    /// Deletes one item, or every item of the service when `account` is `nil`.
    func delete(service: String, account: String?) throws
}

public struct KeychainError: Error, Equatable, Sendable {
    public var status: OSStatus
    public init(_ status: OSStatus) { self.status = status }
}

/// The real Keychain: data-protection keychain, this device only, readable after first
/// unlock, never synchronizable (NET-002 R8, ADR-0007 rule 7).
public struct SecKeychainItems: KeychainItems {
    public let accessGroup: String?

    /// - Parameter accessGroup: the `keychain-access-groups` entry, e.g.
    ///   `<TeamID>.<rdns>.levels.shared`; `nil` uses the app's default group.
    public init(accessGroup: String?) { self.accessGroup = accessGroup }

    private func base(_ service: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func readAll(service: String) throws -> [String: Data] {
        var q = base(service)
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess else { throw KeychainError(status) }
        var out: [String: Data] = [:]
        for item in (result as? [[String: Any]]) ?? [] {
            if let account = item[kSecAttrAccount as String] as? String, let data = item[kSecValueData as String] as? Data {
                out[account] = data
            }
        }
        return out
    }

    public func write(service: String, account: String, data: Data) throws {
        var q = base(service)
        q[kSecAttrAccount as String] = account
        let update = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(update) }
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(q as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainError(add) }
    }

    public func delete(service: String, account: String?) throws {
        var q = base(service)
        if let account { q[kSecAttrAccount as String] = account }
        let status = SecItemDelete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status) }
    }
}

/// An in-memory ``KeychainItems`` (tests).
public final class InMemoryKeychainItems: KeychainItems {
    private let items = Mutex<[String: [String: Data]]>([:])
    public init() {}
    public func readAll(service: String) throws -> [String: Data] { items.withLock { $0[service] ?? [:] } }
    public func write(service: String, account: String, data: Data) throws {
        items.withLock { $0[service, default: [:]][account] = data }
    }
    public func delete(service: String, account: String?) throws {
        items.withLock { i in
            if let account { i[service]?[account] = nil } else { i[service] = nil }
        }
    }
}

private let storeLogger = Logger(subsystem: LevelsLog.subsystem, category: "hub")

private func storeEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .millisecondsSince1970
    e.outputFormatting = [.sortedKeys]
    return e
}

private func storeDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .millisecondsSince1970
    return d
}

/// Mac: service `<rdns>.levels.hub.client`, account = device ID (NET-002 R8). Loads every
/// item once and serves reads from memory (the TLS key lookup runs per handshake).
public final class KeychainHubPairingStore: HubPairingStore {
    public let service: String
    private let items: any KeychainItems
    private let cache = Mutex<[DeviceID: PairedClient]?>(nil)

    public init(service: String, items: any KeychainItems) {
        self.service = service
        self.items = items
    }

    private func loaded() -> [DeviceID: PairedClient] {
        if let c = cache.withLock({ $0 }) { return c }
        var out: [DeviceID: PairedClient] = [:]
        do {
            for (account, data) in try items.readAll(service: service) {
                guard let id = DeviceID(recordName: account),
                      let client = try? storeDecoder().decode(PairedClient.self, from: data), client.id == id
                else { continue }
                out[id] = client
            }
        } catch {
            // Before first unlock or a Keychain error: no keys now; try again next time.
            storeLogger.error("Hub pairing read failed: \(String(describing: error), privacy: .public)")
            return [:]
        }
        cache.withLock { $0 = out }
        return out
    }

    public func key(for id: DeviceID) -> SymmetricKey? { loaded()[id]?.symmetricKey }
    public func all() -> [PairedClient] { loaded().values.sorted { $0.pairedAt < $1.pairedAt } }

    public func save(_ client: PairedClient) throws {
        var all = loaded()
        try items.write(service: service, account: client.id.recordName, data: storeEncoder().encode(client))
        all[client.id] = client
        cache.withLock { $0 = all }
    }

    public func remove(_ id: DeviceID) throws {
        var all = loaded()
        try items.delete(service: service, account: id.recordName)
        all[id] = nil
        cache.withLock { $0 = all }
    }

    public func removeAll() throws {
        try items.delete(service: service, account: nil)
        cache.withLock { $0 = [:] }
    }

    public func touch(_ id: DeviceID, at date: Date) {
        guard var client = loaded()[id] else { return }
        if let last = client.lastSeenAt, date.timeIntervalSince(last) < touchInterval { return }
        client.lastSeenAt = date
        do { try save(client) } catch {
            storeLogger.error("Hub lastSeen write failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// iPhone: service `<rdns>.levels.hub`, account = hub ID, in the shared access group
/// (NET-002 R8). Holds at most one item.
public final class KeychainClientPairingStore: ClientPairingStore {
    public let service: String
    private let items: any KeychainItems

    public init(service: String, items: any KeychainItems) {
        self.service = service
        self.items = items
    }

    public func current() -> HubPairing? {
        do {
            let all = try items.readAll(service: service)
            return all.compactMap { try? storeDecoder().decode(HubPairing.self, from: $0.value) }
                .max { $0.pairedAt < $1.pairedAt }
        } catch {
            storeLogger.error("Client pairing read failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public func save(_ pairing: HubPairing) throws {
        let account = pairing.hubID.uuidString.lowercased()
        try items.write(service: service, account: account, data: storeEncoder().encode(pairing))
        for other in try items.readAll(service: service).keys where other != account {
            try items.delete(service: service, account: other)
        }
    }

    public func remove() throws { try items.delete(service: service, account: nil) }
}
