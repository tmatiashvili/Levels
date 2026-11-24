import CryptoKit
import Foundation
import Testing
@testable import LevelsNet

/// Cross-check with the relay (PUSH-001 AC20). Reads the same file relay/test/vectors.test.ts
/// asserts, so the Swift client and the Worker can't drift: body bytes, body hash, signing
/// string, token hash, key format, and a node:crypto signature CryptoKit must accept (the relay
/// test accepts the CryptoKit one).
@Suite("PUSH auth v1 shared vectors")
struct PushAuthVectorTests {
    struct Vectors: Decodable {
        struct Signatures: Decodable { var node: String; var swift: String }
        struct TokenHash: Decodable { var token: String; var hash: String }
        var macPrivateKeyRawHex: String
        var macPublicKey: String
        var timestamp: String
        var method: String
        var path: String
        var token: String
        var body: String
        var bodySha256: String
        var signingString: String
        var signatures: Signatures
        var tokenHashes: [TokenHash]
    }

    /// `<repo>/relay/test/vectors/push-auth-v1.json`. A missing file fails the test.
    static func load() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LevelsNetTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Shared
            .deletingLastPathComponent()  // repo
            .appendingPathComponent("relay/test/vectors/push-auth-v1.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    static func bytes(hex: String) -> Data {
        var out = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    @Test func bodySigningStringAndHash() throws {
        let v = try Self.load()
        let body = try PushRelayBody(tokens: [PushToken(token: v.token, env: .production, kind: .widget)],
                                     payload: .widgetContentChanged).encoded()
        #expect(String(decoding: body, as: UTF8.self) == v.body)  // the bytes the Mac sends and signs
        #expect(PushAuthV1.hex(Data(SHA256.hash(data: body))) == v.bodySha256)
        #expect(PushAuthV1.signingString(timestamp: v.timestamp, method: v.method, path: v.path, body: body) == v.signingString)
        #expect(PushAuthV1.timestamp(Date(timeIntervalSince1970: TimeInterval(v.timestamp)! + 0.999)) == v.timestamp)
    }

    @Test func tokenHashes() throws {
        let v = try Self.load()
        for t in v.tokenHashes {
            #expect(PushAuthV1.tokenHash(t.token) == t.hash)
            #expect(t.hash.count == 22)
        }
    }

    @Test func publicKeyFormat() throws {
        let v = try Self.load()
        let key = try P256.Signing.PrivateKey(rawRepresentation: Self.bytes(hex: v.macPrivateKeyRawHex))
        #expect(MacPushSigner(key: key).publicKey == v.macPublicKey)
    }

    @Test func bothSignaturesVerifyAndAFreshOneMatchesTheRelayRules() throws {
        let v = try Self.load()
        let key = try P256.Signing.PrivateKey(rawRepresentation: Self.bytes(hex: v.macPrivateKeyRawHex))
        let message = Data(v.signingString.utf8)
        for sig in [v.signatures.swift, v.signatures.node] {
            let raw = try #require(PushAuthV1.data(base64URL: sig))
            #expect(raw.count == 64)
            #expect(key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: raw), for: message))
        }
        // The signer's own headers for the vector body at the vector time.
        let headers = try MacPushSigner(key: key).headers(for: Data(v.body.utf8), path: v.path,
                                                          at: Date(timeIntervalSince1970: TimeInterval(v.timestamp)!),
                                                          grants: ["g1.a.b"])
        #expect(headers[PushAuthV1.timestampHeader] == v.timestamp)
        #expect(headers[PushAuthV1.grantHeader] == "g1.a.b")
        let fresh = try #require(headers[PushAuthV1.signatureHeader].flatMap(PushAuthV1.data(base64URL:)))
        #expect(key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: fresh), for: message))
    }
}
