import Foundation
import LevelsModel
import os

// The Mac's client of the push relay (relay/, ADR-0023, PUSH-001 R10–R19).
// `POST <relayURL>/v1/widget-push`, JSON
// `{"tokens":[{"token":"<hex>","env":"development"|"production","kind":"widget"|"liveActivity"}],"payload":{…}}`
// with the `Levels-Grant`, `Levels-Timestamp` and `Levels-Signature` headers (``PushRelayAuth``).
// → 202 `{"results":[…],"invalidTokens":[…]}`, 400, 401 `{"error":"<code>"}`, 410 all invalid,
// 429 with Retry-After, 500.

/// The payload the relay forwards to APNs. For widgets the relay builds
/// `{"aps":{"content-changed":true}}` itself and ignores this; it is sent for clarity.
public struct PushPayload: Codable, Sendable, Equatable {
    public struct APS: Codable, Sendable, Equatable {
        public var contentChanged: Bool
        enum CodingKeys: String, CodingKey { case contentChanged = "content-changed" }
        public init(contentChanged: Bool) { self.contentChanged = contentChanged }
    }
    public var aps: APS
    public init(aps: APS) { self.aps = aps }

    public static let widgetContentChanged = PushPayload(aps: APS(contentChanged: true))
}

/// `POST /v1/widget-push` body.
public struct PushRelayBody: Codable, Sendable, Equatable {
    public var tokens: [PushToken]
    public var payload: PushPayload
    public init(tokens: [PushToken], payload: PushPayload) {
        self.tokens = tokens
        self.payload = payload
    }

    /// Sorted keys. The signature covers these exact bytes, and the same bytes are sent.
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}

/// The `payload` of a Live Activity request (PUSH-001 R10, LIVE-001 R30): the relay copies
/// these fields into `aps` and sends them with `apns-push-type: liveactivity`. `priority` is
/// 5 (default, not budgeted by iOS) or 10 (urgent, budgeted). Never `start`, never an alert.
public struct LiveActivityPushPayload: Codable, Sendable, Equatable {
    public enum Event: String, Codable, Sendable { case update, end }
    public var contentState: LiveLevelsState
    public var event: Event
    /// Unix seconds. iOS ignores a push older than the content it shows.
    public var timestamp: Int64
    public var staleDate: Int64?
    /// Only with `end`.
    public var dismissalDate: Int64?
    public var priority: Int

    enum CodingKeys: String, CodingKey {
        case contentState = "content-state"
        case event, timestamp
        case staleDate = "stale-date"
        case dismissalDate = "dismissal-date"
        case priority
    }

    public init(contentState: LiveLevelsState, event: Event = .update, timestamp: Int64, staleDate: Int64? = nil,
                dismissalDate: Int64? = nil, priority: Int = 5) {
        self.contentState = contentState
        self.event = event
        self.timestamp = timestamp
        self.staleDate = staleDate
        self.dismissalDate = dismissalDate
        self.priority = priority
    }
}

/// `POST /v1/widget-push` body for Live Activity tokens. Shared vector:
/// `relay/test/vectors/live-activity-v1.json`.
public struct LiveActivityRelayBody: Codable, Sendable, Equatable {
    public var tokens: [PushToken]
    public var payload: LiveActivityPushPayload
    public init(tokens: [PushToken], payload: LiveActivityPushPayload) {
        self.tokens = tokens
        self.payload = payload
    }

    /// Sorted keys, like ``PushRelayBody/encoded()``.
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}

/// What the relay said.
public enum PushRelayResult: Sendable, Equatable {
    /// 202. `invalidTokens`: tokens APNs rejected for good (410 or BadDeviceToken); drop them.
    case accepted(invalidTokens: Set<String>)
    /// 429: try again no sooner than `retryAfter` seconds (`nil` = header not sent).
    case rateLimited(retryAfter: TimeInterval?)
    /// 410: every token of the request is gone; drop them.
    case tokensGone
    /// 401 with the R19 code (`grant_expired`, `token_not_granted`, `timestamp_skew`, …).
    case unauthorized(code: String)
    /// 400 and other 4xx: a bug. Not retried before the next change.
    case rejected(status: Int)
    /// 5xx: the relay is misconfigured or failed; back off.
    case serverError(status: Int)
    /// No answer (network down, DNS, TLS, timeout).
    case unreachable
}

/// One HTTP POST. URLSession in the app; a fake in tests.
public protocol PushRelayTransport: Sendable {
    func post(url: URL, headers: [String: String], body: Data) async throws -> (status: Int, headers: [String: String], body: Data)
}

public struct URLSessionPushRelayTransport: PushRelayTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func post(url: URL, headers: [String: String], body: Data) async throws -> (status: Int, headers: [String: String], body: Data) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = body  // URLSession sends Content-Length, which the relay requires
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return (0, [:], data) }
        var out: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { out[k.lowercased()] = v }
        }
        return (http.statusCode, out, data)
    }
}

/// Parses and checks the relay base URL. `nil` when empty or not a plain `https` URL.
enum RelayBaseURL {
    static func make(_ relayURL: String, path: String) -> URL? {
        var trimmed = relayURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let base = URL(string: trimmed), base.scheme?.lowercased() == "https",
              base.host()?.isEmpty == false, base.query() == nil, base.user() == nil
        else { return nil }
        return URL(string: trimmed + path)
    }
}

/// Sends one push request to the relay.
public struct PushRelayClient: Sendable {
    static let logger = Logger(subsystem: LevelsLog.subsystem, category: "push")
    public static let path = "/v1/widget-push"
    /// Relay limit per request (PUSH-001 R10).
    public static let maxTokensPerRequest = 8

    public let endpoint: URL
    private let auth: any PushRelayAuth
    private let transport: any PushRelayTransport
    private let now: @Sendable () -> Date

    /// `nil` when `relayURL` is empty or not an `https` URL (push off).
    public init?(relayURL: String, auth: any PushRelayAuth, transport: any PushRelayTransport = URLSessionPushRelayTransport(),
                 now: @escaping @Sendable () -> Date = Date.init) {
        guard let endpoint = RelayBaseURL.make(relayURL, path: Self.path) else { return nil }
        self.endpoint = endpoint
        self.auth = auth
        self.transport = transport
        self.now = now
    }

    /// Pushes `tokens` (1…8), each covered by one of `grants` (1…4).
    public func send(_ tokens: [PushToken], grants: [String], payload: PushPayload = .widgetContentChanged) async -> PushRelayResult {
        await send(count: tokens.count, grants: grants) { try PushRelayBody(tokens: tokens, payload: payload).encoded() }
    }

    /// Pushes a Live Activity `payload` to `tokens` (all `.liveActivity`), LIVE-001 R30.
    public func sendLiveActivity(_ tokens: [PushToken], grants: [String], payload: LiveActivityPushPayload) async -> PushRelayResult {
        await send(count: tokens.count, grants: grants) { try LiveActivityRelayBody(tokens: tokens, payload: payload).encoded() }
    }

    private func send(count: Int, grants: [String], body makeBody: () throws -> Data) async -> PushRelayResult {
        guard count > 0 else { return .accepted(invalidTokens: []) }
        let body: Data
        var headers = ["content-type": "application/json"]
        do {
            guard count <= Self.maxTokensPerRequest else { throw PushAuthError.grantCount(count) }
            body = try makeBody()
            for (k, v) in try auth.headers(for: body, path: Self.path, at: now(), grants: grants) { headers[k.lowercased()] = v }
        } catch {
            Self.logger.error("Push relay: could not build the request: \(String(describing: error), privacy: .public)")
            return .rejected(status: 0)
        }
        let answer: (status: Int, headers: [String: String], body: Data)
        do { answer = try await transport.post(url: endpoint, headers: headers, body: body) } catch {
            Self.logger.notice("Push relay not reached: \(String(describing: error), privacy: .public)")
            return .unreachable
        }
        // Tokens and grants are never logged.
        Self.logger.notice("Push relay answered \(answer.status, privacy: .public) for \(count, privacy: .public) token(s)")
        return Self.result(status: answer.status, headers: answer.headers, body: answer.body)
    }

    /// Pure; unit-tested.
    static func result(status: Int, headers: [String: String], body: Data) -> PushRelayResult {
        struct Answer: Decodable { var invalidTokens: [String]?; var error: String? }
        let decoded = try? JSONDecoder().decode(Answer.self, from: body)
        switch status {
        case 200...299:
            return .accepted(invalidTokens: Set((decoded?.invalidTokens ?? []).map { $0.lowercased() }))
        case 410:
            return .tokensGone
        case 401:
            return .unauthorized(code: decoded?.error ?? "")
        case 429:
            let raw = headers.first { $0.key.lowercased() == "retry-after" }?.value
            return .rateLimited(retryAfter: raw.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) })
        case 500...599:
            return .serverError(status: status)
        default:
            return .rejected(status: status)
        }
    }
}
