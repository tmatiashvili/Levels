import Foundation
import LevelsModel
import Testing
@testable import LevelsNet

@Suite("NET-001 HTTPCodec (R6, AC10)")
struct HTTPCodecTests {
    @Test func requestRoundTrip() throws {
        let request = HTTPRequest(method: "POST", path: "/v1/readings", query: ["wait": "25", "a b": "c&d"],
                                  headers: ["Levels-Device": "abc", "If-None-Match": "\"x\""], body: Data("[1]".utf8))
        var buffer = HTTPCodec.serialize(request)
        let parsed = try #require(try HTTPCodec.parseRequest(&buffer))
        #expect(parsed.method == "POST")
        #expect(parsed.path == "/v1/readings")
        #expect(parsed.query == ["wait": "25", "a b": "c&d"])
        #expect(parsed.header("levels-device") == "abc")
        #expect(parsed.header("If-None-Match") == "\"x\"")
        #expect(parsed.body == Data("[1]".utf8))
        #expect(buffer.isEmpty)
    }

    @Test func responseRoundTrip() throws {
        let response = HTTPResponse(status: 304, headers: ["ETag": "\"abc\""])
        var buffer = HTTPCodec.serialize(response)
        let parsed = try #require(try HTTPCodec.parseResponse(&buffer))
        #expect(parsed.status == 304)
        #expect(parsed.header("etag") == "\"abc\"")
        #expect(parsed.body.isEmpty)
    }

    @Test func incompleteNeedsMoreBytesAndKeepsBuffer() throws {
        let full = HTTPCodec.serialize(HTTPRequest(method: "POST", path: "/x", body: Data(repeating: 1, count: 100)))
        for cut in [5, full.count - 101, full.count - 1] {
            var data = Data(full.prefix(cut))
            #expect(try HTTPCodec.parseRequest(&data) == nil)
            #expect(data.count == cut)
        }
    }

    @Test func twoRequestsInOneBufferComeOutOneAtATime() throws {
        var buffer = HTTPCodec.serialize(HTTPRequest(method: "GET", path: "/a"))
        buffer.append(HTTPCodec.serialize(HTTPRequest(method: "GET", path: "/b")))
        #expect(try HTTPCodec.parseRequest(&buffer)?.path == "/a")
        #expect(try HTTPCodec.parseRequest(&buffer)?.path == "/b")
        #expect(try HTTPCodec.parseRequest(&buffer) == nil)
    }

    @Test(arguments: [
        "GARBAGE\r\n\r\n",
        "GET /x HTTP/1.0\r\n\r\n",
        "get /x HTTP/1.1\r\n\r\n",
        "GET x HTTP/1.1\r\n\r\n",
        "GET /x HTTP/1.1\r\nno-colon\r\n\r\n",
        "POST /x HTTP/1.1\r\ntransfer-encoding: chunked\r\n\r\n",
        "POST /x HTTP/1.1\r\ncontent-length: -1\r\n\r\n",
        "POST /x HTTP/1.1\r\ncontent-length: abc\r\n\r\n",
    ])
    func AC10_malformedIs400(_ text: String) {
        var buffer = Data(text.utf8)
        #expect(throws: HTTPError.malformed) { try HTTPCodec.parseRequest(&buffer) }
        #expect(HTTPError.malformed.status == 400)
    }

    @Test func AC10_headerOver8KBIs400() {
        var buffer = Data("GET /x HTTP/1.1\r\nx-big: \(String(repeating: "a", count: 8 * 1024))\r\n\r\n".utf8)
        #expect(throws: HTTPError.headersTooLarge) { try HTTPCodec.parseRequest(&buffer) }
        // Also before the blank line arrives.
        var partial = Data("GET /x HTTP/1.1\r\nx-big: \(String(repeating: "a", count: 9 * 1024))".utf8)
        #expect(throws: HTTPError.headersTooLarge) { try HTTPCodec.parseRequest(&partial) }
        #expect(HTTPError.headersTooLarge.status == 400)
    }

    @Test func AC10_bodyOver64KBIs413() throws {
        var buffer = HTTPCodec.serialize(HTTPRequest(method: "POST", path: "/v1/readings", body: Data(repeating: 0, count: 65 * 1024)))
        #expect(throws: HTTPError.bodyTooLarge) { try HTTPCodec.parseRequest(&buffer) }
        #expect(HTTPError.bodyTooLarge.status == 413)
        var exact = HTTPCodec.serialize(HTTPRequest(method: "POST", path: "/v1/readings", body: Data(repeating: 0, count: 64 * 1024)))
        #expect(try HTTPCodec.parseRequest(&exact)?.body.count == 64 * 1024)
    }
}

@Suite("NET-001 HubWire (R2, R7, R8)")
struct HubWireTests {
    @Test func AC2_etagIsStableAndQuoted16Hex() {
        let devices = [macRecord(), airpodRecord(), phoneRecord()]
        let tag = HubWire.etag(for: devices)
        #expect(tag == HubWire.etag(for: devices))
        #expect(tag.wholeMatch(of: /"[0-9a-f]{16}"/) != nil)
        #expect(tag != HubWire.etag(for: [macRecord(level: 81), airpodRecord(), phoneRecord()]))
        #expect(tag != HubWire.etag(for: []))
    }

    @Test func R7_snapshotJSONUsesMillisecondsAndIgnoresUnknownFields() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000.123)
        let snapshot = HubSnapshot(hubID: hubID, hubDeviceID: macID, generatedAt: at, devices: [macRecord(at: at)])
        let data = try HubWire.encoder().encode(snapshot)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"generatedAt\":1800000000123"))
        #expect(json.hasPrefix("{\"devices\""))  // sorted keys
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["future"] = ["x": 1]
        let decoded = try HubWire.decoder().decode(HubSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == snapshot)
    }

    @Test func AC12_serviceNameAndTXT() {
        let tag = HubProtocol.tag(for: hubID)
        #expect(tag == "ab12")
        #expect(HubProtocol.serviceName(tag: tag).wholeMatch(of: /Levels-[0-9a-f]{4}/) != nil)
        #expect(HubProtocol.txtEntries(tag: tag, pairing: false) == ["v": "1", "hub": "ab12"])
        #expect(HubProtocol.txtEntries(tag: tag, pairing: true) == ["v": "1", "hub": "ab12", "pair": "1"])
        for _ in 0..<50 {
            #expect(HubProtocol.tag(for: UUID()).wholeMatch(of: /[0-9a-f]{4}/) != nil)
        }
    }
}
