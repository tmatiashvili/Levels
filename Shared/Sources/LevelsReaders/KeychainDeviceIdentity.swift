import Foundation
import LevelsModel
import os
import Security

/// This device's `deviceId` in a non-syncing, this-device-only Keychain item (ADR-0007).
///
/// Rules (ADR-0007): read first; create only on `errSecItemNotFound` (rule 1); on
/// `errSecDuplicateItem` read again and use the stored value (rule 2); any other error
/// returns `nil` without creating an ID, so the caller skips reporting (rule 1). Never
/// `kSecAttrSynchronizableAny` (rule 7).
public struct KeychainDeviceIdentity: DeviceIdentityProviding {
    /// The `SecItem` calls, so rules 1–2 are testable without a Keychain.
    public protocol Backend: Sendable {
        /// `SecItemCopyMatching` for the item's value.
        func read(_ query: [String: any Sendable]) -> (OSStatus, String?)
        /// `SecItemAdd`.
        func add(_ attributes: [String: any Sendable]) -> OSStatus
    }

    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "identity")

    public let service: String
    public let accessGroup: String?
    private let backend: any Backend

    /// - Parameters:
    ///   - service: `<bundle-prefix>.levels.device-identity`.
    ///   - accessGroup: `<TeamID>.<bundle-prefix>.levels.shared` (the `keychain-access-groups`
    ///     entitlement); `nil` uses the app's default group.
    public init(service: String, accessGroup: String?, backend: (any Backend)? = nil) {
        self.service = service
        self.accessGroup = accessGroup
        self.backend = backend ?? SecItemBackend()
    }

    public static let account = "deviceId"

    public func currentDeviceID() throws -> DeviceID? {
        switch read() {
        case .found(let id): return id
        case .failed: return nil
        case .notFound: break
        }
        let new = DeviceID(UUID())
        var attributes = baseQuery()
        attributes[kSecValueData as String] = Data(new.recordName.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        let status = backend.add(attributes)
        switch status {
        case errSecSuccess:
            Self.logger.info("Created device ID \(new.recordName, privacy: .public)")
            return new
        case errSecDuplicateItem:  // rule 2: another process won the race
            if case .found(let id) = read() { return id }
            return nil
        default:
            Self.logger.error("Keychain add failed: \(status)")
            return nil
        }
    }

    private enum ReadResult { case found(DeviceID), notFound, failed }

    private func read() -> ReadResult {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne as String
        let (status, value) = backend.read(query)
        switch status {
        case errSecSuccess:
            if let value, let id = DeviceID(recordName: value) { return .found(id) }
            Self.logger.error("Keychain device ID is not a UUID; not replacing it")
            return .failed
        case errSecItemNotFound:
            return .notFound
        default:  // e.g. errSecInteractionNotAllowed before first unlock: never create (rule 1)
            Self.logger.error("Keychain read failed: \(status)")
            return .failed
        }
    }

    private func baseQuery() -> [String: any Sendable] {
        var q: [String: any Sendable] = [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }
}

/// The real `SecItem` calls.
struct SecItemBackend: KeychainDeviceIdentity.Backend {
    func read(_ query: [String: any Sendable]) -> (OSStatus, String?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let value = (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
        return (status, value)
    }

    func add(_ attributes: [String: any Sendable]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
