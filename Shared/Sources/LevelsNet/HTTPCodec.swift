import Foundation

// The small HTTP/1.1 subset of NET-001 R6: request line, headers up to 8 KB,
// `Content-Length` bodies up to 64 KB, keep-alive. No chunking, no compression,
// no pipelining. Pure value code, used by the Mac server and the clients.

/// One request. Header names are lowercase.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, b in b })
        self.body = body
    }

    /// The value of a header, by case-insensitive name.
    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// One response. Header names are lowercase.
public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, b in b })
        self.body = body
    }

    /// The value of a header, by case-insensitive name.
    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Why bytes could not be parsed (NET-001 R6).
public enum HTTPError: Error, Equatable, Sendable {
    /// Not the subset: bad request line, bad header, chunked body, bad `Content-Length`.
    case malformed
    /// The header block is over 8 KB.
    case headersTooLarge
    /// `Content-Length` is over 64 KB.
    case bodyTooLarge

    /// The status the server answers with before it closes the connection.
    public var status: Int {
        switch self {
        case .malformed, .headersTooLarge: 400
        case .bodyTooLarge: 413
        }
    }
}

public enum HTTPCodec {
    private static let crlf2 = Data("\r\n\r\n".utf8)

    // MARK: Server side

    /// Takes one complete request off the front of `buffer`. Returns `nil` when more bytes
    /// are needed (and the buffer is left as it is).
    public static func parseRequest(_ buffer: inout Data) throws(HTTPError) -> HTTPRequest? {
        guard let head = try parseHead(buffer) else { return nil }
        let line = head.startLine.split(separator: " ", omittingEmptySubsequences: false)
        guard line.count == 3, line[2] == "HTTP/1.1", !line[0].isEmpty,
              line[0].allSatisfy({ $0.isASCII && $0.isUppercase }), line[1].hasPrefix("/")
        else { throw .malformed }
        let (path, query) = try splitTarget(String(line[1]))
        guard let body = take(&buffer, head: head) else { return nil }
        return HTTPRequest(method: String(line[0]), path: path, query: query, headers: head.headers, body: body)
    }

    /// The bytes of a response. Adds `Content-Length` (and leaves other headers as given).
    public static func serialize(_ response: HTTPResponse) -> Data {
        var text = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) where name != "content-length" {
            text += "\(name): \(value)\r\n"
        }
        text += "content-length: \(response.body.count)\r\n\r\n"
        var data = Data(text.utf8)
        data.append(response.body)
        return data
    }

    // MARK: Client side

    /// The bytes of a request. Adds `Host` and `Content-Length`.
    public static func serialize(_ request: HTTPRequest) -> Data {
        var target = request.path
        if !request.query.isEmpty {
            target += "?" + request.query.sorted(by: { $0.key < $1.key })
                .map { "\(escape($0.key))=\(escape($0.value))" }.joined(separator: "&")
        }
        var text = "\(request.method) \(target) HTTP/1.1\r\nhost: levels\r\n"
        for (name, value) in request.headers.sorted(by: { $0.key < $1.key }) where name != "content-length" && name != "host" {
            text += "\(name): \(value)\r\n"
        }
        text += "content-length: \(request.body.count)\r\n\r\n"
        var data = Data(text.utf8)
        data.append(request.body)
        return data
    }

    /// Takes one complete response off the front of `buffer`; `nil` = need more bytes.
    public static func parseResponse(_ buffer: inout Data) throws(HTTPError) -> HTTPResponse? {
        guard let head = try parseHead(buffer) else { return nil }
        let line = head.startLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard line.count >= 2, line[0] == "HTTP/1.1", let status = Int(line[1]), (100...599).contains(status)
        else { throw .malformed }
        guard let body = take(&buffer, head: head) else { return nil }
        return HTTPResponse(status: status, headers: head.headers, body: body)
    }

    // MARK: Shared

    private struct Head {
        var startLine: Substring
        var headers: [String: String]
        var headerLength: Int
        var bodyLength: Int
    }

    private static func parseHead(_ buffer: Data) throws(HTTPError) -> Head? {
        guard let end = buffer.range(of: crlf2) else {
            if buffer.count > HubProtocol.maxHeader { throw .headersTooLarge }
            return nil
        }
        let headerLength = end.upperBound - buffer.startIndex
        guard headerLength <= HubProtocol.maxHeader else { throw .headersTooLarge }
        guard let text = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { throw .malformed }
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let first = lines.first, !first.isEmpty else { throw .malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw .malformed }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, !name.contains(" ") else { throw .malformed }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil || headers["content-encoding"] != nil { throw .malformed }
        var bodyLength = 0
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else { throw .malformed }
            guard n <= HubProtocol.maxBody else { throw .bodyTooLarge }
            bodyLength = n
        }
        return Head(startLine: first, headers: headers, headerLength: headerLength, bodyLength: bodyLength)
    }

    /// Removes head and body from `buffer` and returns the body, or `nil` if the body is incomplete.
    private static func take(_ buffer: inout Data, head: Head) -> Data? {
        let total = head.headerLength + head.bodyLength
        guard buffer.count >= total else { return nil }
        let start = buffer.startIndex
        let body = Data(buffer[(start + head.headerLength)..<(start + total)])
        buffer = Data(buffer[(start + total)...])
        return body
    }

    private static func splitTarget(_ target: String) throws(HTTPError) -> (String, [String: String]) {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let path = parts[0].removingPercentEncoding else { throw .malformed }
        var query: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = kv[0].removingPercentEncoding,
                      let value = (kv.count == 2 ? kv[1] : "").removingPercentEncoding
                else { throw .malformed }
                query[key] = value
            }
        }
        return (path, query)
    }

    private static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Content Too Large"
        case 429: "Too Many Requests"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}
