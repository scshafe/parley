import XCTest
@testable import ParleyKit

/// A URLProtocol stub: answers the client's requests from a handler, so the
/// client is tested without a network.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var req = request
        if req.httpBody == nil, let stream = req.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
            req.httpBody = data
        }
        StubProtocol.seen.append(req)
        let (status, headers, body) = StubProtocol.handler?(req) ?? (500, [:], Data())
        let response = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

let turnJSON = """
{"id":"t_1","conversation_id":"c_1","seq":1,"client_turn_id":"ios-1","state":"ready","user_text":"Hi",
 "reply_text":"Good morning, friend. The plan is simple.","attachment":null,"style_version":"style-v1",
 "audio":{"url":"/api/v1/conversations/c_1/turns/t_1/audio","content_type":"audio/wav","duration_ms":4000,
          "available":true},
 "timings_url":"/api/v1/conversations/c_1/turns/t_1/timings.json","timings_exact_sentences":true,"cleanup":[],
 "error":null,"created_at":"2026-10-15T00:00:00Z","updated_at":"2026-10-15T00:00:01Z","ready_at":null}
"""

final class RelayClientTests: XCTestCase {
    var client: RelayClient!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.seen = []
        client = RelayClient(baseURL: URL(string: "http://relay.test")!, auth: StaticBearer(token: "test-token"),
                             session: URLSession(configuration: config))
    }

    func testDecodesTurnsAndSendsTheToken() async throws {
        StubProtocol.handler = { _ in (200, ["Content-Type": "application/json"], Data(turnJSON.utf8)) }
        let turn = try await client.turn(conversationID: "c_1", turnID: "t_1")
        XCTAssertEqual(turn.state, .ready)
        XCTAssertEqual(turn.audio?.durationMs, 4000)
        XCTAssertEqual(turn.timingsUrl, "/api/v1/conversations/c_1/turns/t_1/timings.json")
        let req = try XCTUnwrap(StubProtocol.seen.last)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(req.url?.absoluteString, "http://relay.test/api/v1/conversations/c_1/turns/t_1")
    }

    func testSendTurnPostsTextAndClientTurnID() async throws {
        StubProtocol.handler = { _ in (202, [:], Data(turnJSON.utf8)) }
        _ = try await client.sendTurn(conversationID: "c_1", text: "Hello", clientTurnID: "ios-abc")
        let req = try XCTUnwrap(StubProtocol.seen.last)
        XCTAssertEqual(req.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: String])
        XCTAssertEqual(body, ["text": "Hello", "client_turn_id": "ios-abc"])
    }

    func testErrorsCarryTheRelaysCode() async {
        StubProtocol.handler = { _ in (409, [:], Data(#"{"error":{"code":"client_turn_conflict","detail":"no"}}"#.utf8)) }
        do {
            _ = try await client.sendTurn(conversationID: "c_1", text: "x", clientTurnID: "a")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RelayError, .http(status: 409, code: "client_turn_conflict", detail: "no"))
        }
        StubProtocol.handler = { _ in (401, [:], Data()) }
        do {
            _ = try await client.listConversations()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RelayError, .unauthorized)
        }
    }

    func testRegisterDevicePostsTheTokenAndEnvironment() async throws {
        StubProtocol.handler = { _ in
            (201, [:], Data(#"{"id":"d_1","environment":"sandbox","created_at":"a","updated_at":"a","last_push_at":null,"push":false}"#.utf8))
        }
        let device = try await client.registerDevice(token: "ab01", environment: "sandbox")
        XCTAssertEqual(device, DeviceRegistration(id: "d_1", environment: "sandbox", push: false))
        let req = try XCTUnwrap(StubProtocol.seen.last)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/api/v1/devices")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: String])
        XCTAssertEqual(body, ["token": "ab01", "environment": "sandbox"])
    }

    func testUnregisterDeviceDeletesAndTreatsAnUnknownIdAsDone() async throws {
        StubProtocol.handler = { _ in (204, [:], Data()) }
        try await client.unregisterDevice(id: "d_1")
        XCTAssertEqual(StubProtocol.seen.last?.httpMethod, "DELETE")
        XCTAssertEqual(StubProtocol.seen.last?.url?.path, "/api/v1/devices/d_1")
        StubProtocol.handler = { _ in (404, [:], Data(#"{"error":{"code":"not_found","detail":""}}"#.utf8)) }
        try await client.unregisterDevice(id: "d_gone")
    }

    func testTheAPNsEnvironmentComesFromTheProvisioningProfile() {
        func profile(_ aps: String?) -> Data {
            let ent = aps.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Name</key><string>x</string>\
            <key>Entitlements</key><dict>\(ent)</dict></dict></plist>
            """
            return Data([0x30, 0x82, 0x01]) + Data(plist.utf8) + Data([0x00, 0xA0])  // inside a CMS envelope
        }
        XCTAssertEqual(APSEnvironment.relayName(profile: profile("development")), "sandbox")
        XCTAssertEqual(APSEnvironment.relayName(profile: profile("production")), "production")
        XCTAssertEqual(APSEnvironment.relayName(profile: nil), "production")
        XCTAssertNil(APSEnvironment.apsEnvironment(inProfile: profile(nil)))
        XCTAssertNil(APSEnvironment.apsEnvironment(inProfile: Data("garbage".utf8)))
    }

    func testUnknownStatesDecodeAsThinking() throws {
        let json = turnJSON.replacingOccurrences(of: "\"state\":\"ready\"", with: "\"state\":\"aligning\"")
        let turn = try ParleyJSON.decoder.decode(Turn.self, from: Data(json.utf8))
        XCTAssertEqual(turn.state, .thinking)
    }

    func testConversationListDecodes() async throws {
        let json = """
        {"conversations":[{"id":"c_1","title":null,"created_at":"a","updated_at":"b","turn_count":0,
          "last_event_id":0,"last_turn":null}]}
        """
        StubProtocol.handler = { _ in (200, [:], Data(json.utf8)) }
        let list = try await client.listConversations()
        XCTAssertEqual(list.map(\.id), ["c_1"])
        XCTAssertEqual(list[0].displayTitle, "New conversation")
        XCTAssertNil(list[0].turns)
    }

    func testRelayURLParsing() {
        XCTAssertEqual(RelayConfiguration.parseURL("relay.example.ts.net/")?.absoluteString,
                       "https://relay.example.ts.net")
        XCTAssertEqual(RelayConfiguration.parseURL(" http://127.0.0.1:8765 ")?.absoluteString,
                       "http://127.0.0.1:8765")
        XCTAssertNil(RelayConfiguration.parseURL("ftp://x"))
        XCTAssertNil(RelayConfiguration.parseURL(""))
    }
}

final class SSEParserTests: XCTestCase {
    func testParsesRelayEvents() throws {
        var parser = SSEParser()
        var messages: [SSEParser.Message] = []
        let stream = "retry: 2000\n\nid: 7\nevent: turn.updated\ndata: \(turnJSON.replacingOccurrences(of: "\n", with: ""))\n\n: keep-alive\n\n"
        var buffer: [UInt8] = []
        for line in SSEParser.lines(from: Array(stream.utf8), buffer: &buffer) {
            if let m = parser.feed(line: line) { messages.append(m) }
        }
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(parser.retryMs, 2000)
        XCTAssertEqual(parser.lastEventID, "7")
        let event = try XCTUnwrap(RelayEvent(message: messages[0]))
        XCTAssertEqual(event.id, 7)
        XCTAssertEqual(event.turn?.id, "t_1")
    }

    func testMultilineDataAndCRLF() {
        var parser = SSEParser()
        XCTAssertNil(parser.feed(line: "data: one\r"))
        XCTAssertNil(parser.feed(line: "data:two"))
        let m = parser.feed(line: "")
        XCTAssertEqual(m, SSEParser.Message(id: nil, event: "message", data: "one\ntwo"))
        XCTAssertNil(parser.feed(line: ""))
    }

    func testPartialLinesWaitInTheBuffer() {
        var buffer: [UInt8] = []
        XCTAssertEqual(SSEParser.lines(from: Array("data: a".utf8), buffer: &buffer), [])
        XCTAssertEqual(SSEParser.lines(from: Array("bc\n\n".utf8), buffer: &buffer), ["data: abc", ""])
    }
}
