import CryptoKit
import Foundation
import LevelsModel
import Security
import Synchronization
import os

// The Mac's request authentication to the push relay and the token hash both sides use
// (PUSH-001 R17, R18, R33; relay/src/auth.ts and relay/src/signed.ts are the source of truth).
// Shared test vectors: relay/test/vectors/push-auth-v1.json, asserted by the Swift tests
// (PushAuthVectorTests) and by relay/test/vectors.test.ts, so the two can't drift.

/// Wire rules of version 1 of the relay's Mac authentication. Pure; unit-tested.
public enum PushAuthV1 {
    public static let context = "levels-push-v1"
    public static let tokenHashPrefix = "levels-token-v1:"
    public static let grantHeader = "Levels-Grant"
    public static let timestampHeader = "Levels-Timestamp"
    public static let signatureHeader = "Levels-Signature"
    /// Relay limit: at most this many grants in one `Levels-Grant` header.
    public static let maxGrantsPerRequest = 4

    /// `levels-push-v1\n<ts>\nPOST\n<path>\n<lowercase hex SHA-256 of body>`, no trailing newline.
    public static func signingString(timestamp: String, method: String = "POST", path: String, body: Data) -> String {
        "\(context)\n\(timestamp)\n\(method)\n\(path)\n\(hex(Data(SHA256.hash(data: body))))"
    }

    /// Whole Unix seconds, decimal.
    public static func timestamp(_ date: Date) -> String { String(Int64(date.timeIntervalSince1970.rounded(.down))) }

    /// R33: base64url (no padding) of the first 16 bytes of SHA-256 of
    /// `"levels-token-v1:" + lowercase hex token`. 22 characters.
    public static func tokenHash(_ hexToken: String) -> String {
        let digest = SHA256.hash(data: Data((tokenHashPrefix + hexToken.lowercased()).utf8))
        return base64URL(Data(digest.prefix(16)))
    }

    public static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// base64url without padding.
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes base64url or standard base64, with or without padding.
    public static func data(base64URL text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.hasSuffix("=") { s.removeLast() }
        guard s.count % 4 != 1 else { return nil }
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    /// R18: base64url (no padding) of the 65-byte `x963Representation`.
    public static func publicKeyString(_ key: P256.Signing.PublicKey) -> String { base64URL(key.x963Representation) }
}

/// Signs one relay request (PUSH-001 R17).
public protocol PushRelayAuth: Sendable {
    /// The three `Levels-*` headers for this exact `body`, sent to `path` at `date`, carrying
    /// `grants` (1…``PushAuthV1/maxGrantsPerRequest``, all naming this Mac's key).
    func headers(for body: Data, path: String, at date: Date, grants: [String]) throws -> [String: String]
}

public enum PushAuthError: Error, Equatable, Sendable {
    case grantCount(Int)
}

/// The Mac's signer: a P-256 key (R18). Software key in the Keychain (Builder's call: the
/// Developer ID Mac app has no keychain-access-groups entitlement on the free team, and a
/// Secure Enclave key adds nothing the relay can check).
public struct MacPushSigner: PushRelayAuth {
    public let key: P256.Signing.PrivateKey
    public init(key: P256.Signing.PrivateKey) { self.key = key }

    /// R18 format.
    public var publicKey: String { PushAuthV1.publicKeyString(key.publicKey) }

    public func headers(for body: Data, path: String, at date: Date, grants: [String]) throws -> [String: String] {
        guard (1...PushAuthV1.maxGrantsPerRequest).contains(grants.count) else { throw PushAuthError.grantCount(grants.count) }
        let ts = PushAuthV1.timestamp(date)
        let message = Data(PushAuthV1.signingString(timestamp: ts, path: path, body: body).utf8)
        let signature = try key.signature(for: message)  // ECDSA P-256 over SHA-256 of `message`
        return [
            PushAuthV1.grantHeader: grants.joined(separator: ","),
            PushAuthV1.timestampHeader: ts,
            PushAuthV1.signatureHeader: PushAuthV1.base64URL(signature.rawRepresentation),
        ]
    }
}

/// The Mac's push key in the Keychain (R18): made on first use, replaced by "Remove all
/// pairings". Service `<rdns>.levels.push-key`, one item. Signs with whatever key is current,
/// so a reset key is used from the next request on.
public final class MacPushKeyStore: PushRelayAuth {
    public enum KeyError: Error { case unavailable }

    public func headers(for body: Data, path: String, at date: Date, grants: [String]) throws -> [String: String] {
        guard let key = current() else { throw KeyError.unavailable }
        return try MacPushSigner(key: key).headers(for: body, path: path, at: date, grants: grants)
    }

    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "push")
    static let account = "mac"
    public let service: String
    private let items: any KeychainItems
    private let cached = Mutex<P256.Signing.PrivateKey?>(nil)

    public init(service: String, items: any KeychainItems) {
        self.service = service
        self.items = items
    }

    /// The key, made and stored on first use. `nil` when the Keychain can't be read or written
    /// (push then stays off; never a key that would change on every launch).
    public func current() -> P256.Signing.PrivateKey? {
        if let key = cached.withLock({ $0 }) { return key }
        do {
            if let raw = try items.readAll(service: service)[Self.account] {
                let key = try P256.Signing.PrivateKey(rawRepresentation: raw)
                cached.withLock { $0 = key }
                return key
            }
            let key = P256.Signing.PrivateKey()
            try items.write(service: service, account: Self.account, data: key.rawRepresentation)
            cached.withLock { $0 = key }
            Self.logger.notice("Made a new Mac push key")
            return key
        } catch {
            Self.logger.error("Mac push key unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public var publicKey: String? { current().map { PushAuthV1.publicKeyString($0.publicKey) } }

    /// "Remove all pairings": drop the key; the next ``current()`` makes a new one, so every
    /// old grant stops working at the relay.
    public func reset() {
        cached.withLock { $0 = nil }
        do { try items.delete(service: service, account: nil) } catch {
            Self.logger.error("Mac push key delete failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// What a grant says, read without checking its relay MAC (the Mac can't; only the relay holds
/// the key). Used for sanity checks only: the relay decides. Format `g1.<base64url JSON>.<mac>`,
/// JSON `{v:1, env, mac, dev, t:[[kind, hash]…], iat, exp}`.
public struct PushGrantInfo: Sendable, Equatable {
    public var env: APNsEnvironment
    public var macKey: String
    public var tokens: Set<String>  // "kind:hash"
    public var expiresAt: Date

    public static func read(_ grant: String) -> PushGrantInfo? {
        let parts = grant.split(separator: ".", omittingEmptySubsequences: false)
        guard grant.utf8.count <= 4096, parts.count == 3, parts[0] == "g1",
              let json = PushAuthV1.data(base64URL: String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              obj["v"] as? Int == 1,
              let env = (obj["env"] as? String).flatMap(APNsEnvironment.init(rawValue:)),
              let mac = obj["mac"] as? String,
              let t = obj["t"] as? [[String]],
              let exp = obj["exp"] as? Double
        else { return nil }
        var tokens = Set<String>()
        for pair in t {
            guard pair.count == 2 else { return nil }
            tokens.insert("\(pair[0]):\(pair[1])")
        }
        return PushGrantInfo(env: env, macKey: mac, tokens: tokens, expiresAt: Date(timeIntervalSince1970: exp))
    }

    /// Whether the grant names `macKey` and covers every token (same kind and env).
    public func covers(_ list: [PushToken], macKey: String) -> Bool {
        self.macKey == macKey && list.allSatisfy { $0.env == env && tokens.contains("\($0.kind.rawValue):\(PushAuthV1.tokenHash($0.token))") }
    }
}
