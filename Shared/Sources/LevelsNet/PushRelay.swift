import Foundation
import LevelsModel
import os

// The Mac's client of the push relay (Cloudflare Worker on feature/push-relay, ADR-0023).
// Contract: `POST <relayURL>/v1/widget-push`, JSON
// `{"tokens":[{"token":"<hex>","env":"development"|"production","kind":"widget"|"liveActivity"}],"payload":{…}}`
// → 202 accepted, 400 bad request, 401 unauthorized, 429 rate limited.

/// Signs a relay request. The relay agent defines the real headers (ADR-0023); until then
/// ``PlaceholderPushRelayAuth`` sends none and the relay answers 401.
public protocol PushRelayAuth: Sendable {
    /// Extra headers for one request with this exact `body`.
    func headers(for body: Data) async throws -> [String: String]
}

/// No auth headers. Replace when ADR-0023 fixes the scheme.
public struct PlaceholderPushRelayAuth: PushRelayAuth {
    public init() {}
    public func headers(for body: Data) async throws -> [String: String] { [:] }
}

/// The payload the relay forwards to APNs. For widgets Apple requires
/// `{"aps":{"content-changed":true}}` (WidgetKit, "Updating widgets with WidgetKit push notifications").
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

    /// Sorted keys, so the bytes the auth signs are stable.
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }
}

/// What the relay said.
public enum PushRelayResult: Sendable, Equatable {
    /// 202. `invalidTokens`: tokens the relay reports APNs rejected for good (410 or
    /// BadDeviceToken), from an optional `{"invalidTokens":["<hex>"]}` body; drop them.
    case accepted(invalidTokens: Set<String>)
    /// 429: try again no sooner than `retryAfter` seconds (the `Retry-After` header; `nil` = not sent).
    case rateLimited(retryAfter: TimeInterval?)
    /// 410: every token of the request is gone; drop them.
    case tokensGone
    /// 400, 401 and anything else: a bug or missing auth. Not retried before the next change.
    case rejected(status: Int)
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
        request.httpBody = body
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

/// Sends one push request to the relay.
public struct PushRelayClient: Sendable {
    static let logger = Logger(subsystem: LevelsLog.subsystem, category: "push")
    public static let path = "/v1/widget-push"

    public let endpoint: URL
    private let auth: any PushRelayAuth
    private let transport: any PushRelayTransport

    /// `nil` when `relayURL` is empty or not an `https` URL (push off).
    public init?(relayURL: String, auth: any PushRelayAuth = PlaceholderPushRelayAuth(),
                 transport: any PushRelayTransport = URLSessionPushRelayTransport()) {
        var trimmed = relayURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let base = URL(string: trimmed), base.scheme?.lowercased() == "https",
              base.host()?.isEmpty == false, base.query() == nil, let endpoint = URL(string: trimmed + Self.path)
        else { return nil }
        self.endpoint = endpoint
        self.auth = auth
        self.transport = transport
    }

    public func send(_ tokens: [PushToken], payload: PushPayload = .widgetContentChanged) async -> PushRelayResult {
        guard !tokens.isEmpty else { return .accepted(invalidTokens: []) }
        let body: Data
        var headers = ["content-type": "application/json"]
        do {
            body = try PushRelayBody(tokens: tokens, payload: payload).encoded()
            for (k, v) in try await auth.headers(for: body) { headers[k.lowercased()] = v }
        } catch {
            Self.logger.error("Push relay: could not build the request: \(String(describing: error), privacy: .public)")
            return .rejected(status: 0)
        }
        let answer: (status: Int, headers: [String: String], body: Data)
        do { answer = try await transport.post(url: endpoint, headers: headers, body: body) } catch {
            Self.logger.notice("Push relay not reached: \(String(describing: error), privacy: .public)")
            return .unreachable
        }
        // Token values are not logged.
        Self.logger.notice("Push relay answered \(answer.status, privacy: .public) for \(tokens.count, privacy: .public) token(s)")
        return Self.result(status: answer.status, headers: answer.headers, body: answer.body)
    }

    /// Pure; unit-tested.
    static func result(status: Int, headers: [String: String], body: Data) -> PushRelayResult {
        switch status {
        case 200...299:
            struct Answer: Decodable { var invalidTokens: [String]? }
            let invalid = (try? JSONDecoder().decode(Answer.self, from: body))?.invalidTokens ?? []
            return .accepted(invalidTokens: Set(invalid.map { $0.lowercased() }))
        case 410:
            return .tokensGone
        case 429:
            let raw = headers.first { $0.key.lowercased() == "retry-after" }?.value
            return .rateLimited(retryAfter: raw.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) })
        default:
            return .rejected(status: status)
        }
    }
}
