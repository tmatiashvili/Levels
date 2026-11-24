import Foundation
import LevelsModel
import Testing
@testable import LevelsNet

/// Cross-check with the relay (LIVE-001 R30, AC9). Reads `relay/test/vectors/live-activity-v1.json`,
/// which relay/test/live-activity-vector.test.ts also asserts: the Mac must encode exactly
/// `body`, and the iPhone must decode the `content-state` the relay puts in `apnsBody`.
@Suite("LIVE-001 Live Activity shared vector")
struct LiveActivityVectorTests {
    struct Vector: Decodable {
        var now: Int64
        var token: String
        var env: APNsEnvironment
        var priority: Int
        var body: String
        var apnsBody: String
    }

    static func load() throws -> Vector {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LevelsNetTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Shared
            .deletingLastPathComponent()  // repo
            .appendingPathComponent("relay/test/vectors/live-activity-v1.json")
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    }

    static let state = LiveLevelsState(devices: [
        .init(role: .iphone, level: 64, charging: false, updatedAt: 1_799_999_990),
        .init(role: .mac, level: 82, charging: true, updatedAt: 1_800_000_000),
        .init(role: .airpods, level: 15, charging: false, updatedAt: 1_799_999_900),
    ])

    @Test func macEncodesExactlyTheVectorBody() throws {
        let v = try Self.load()
        let body = LiveActivityRelayBody(
            tokens: [PushToken(token: v.token, env: v.env, kind: .liveActivity)],
            payload: LiveActivityPushPayload(contentState: Self.state, timestamp: v.now, staleDate: v.now + 1800, priority: v.priority))
        #expect(String(decoding: try body.encoded(), as: UTF8.self) == v.body)
    }

    @Test func iPhoneDecodesTheRelaysContentStateWithDefaultStrategies() throws {
        let v = try Self.load()
        struct APNs: Decodable {
            struct APS: Decodable {
                var contentState: LiveLevelsState
                enum CodingKeys: String, CodingKey { case contentState = "content-state" }
            }
            var aps: APS
        }
        let decoded = try JSONDecoder().decode(APNs.self, from: Data(v.apnsBody.utf8))
        #expect(decoded.aps.contentState == Self.state)
        #expect(v.apnsBody.utf8.count < 4096)
    }
}
