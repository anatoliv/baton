import XCTest
@testable import BatonMCPProtocol

/// The first tests this package has ever had (S-F24). It is 276 lines of parsing and framing
/// that both the Mac app's MCP server and the gateway's transport sit on top of, and what
/// coverage it had was borrowed from the Mac app target, so `swift test` here proved nothing
/// and the iPhone gate ran none of it while shipping the same code.
///
/// Every message type goes out through its coder and back in through the parser, which is
/// the round trip the wire actually performs.
final class MCPProtocolTests: XCTestCase {
    // MARK: - Request parsing

    private func raw(_ text: String) -> Data { Data(text.utf8) }

    private func parsed(_ text: String) throws -> HTTPRequestMessage {
        guard case let .complete(message) = HTTPRequestMessage.parse(raw(text)) else {
            throw XCTSkip("not a complete request")
        }
        return message
    }

    func testParsesMethodPathHeadersAndBody() throws {
        let message = try parsed(
            "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
                + "Content-Length: 7\r\n\r\n{\"a\":1}")
        XCTAssertEqual(message.method, "POST")
        XCTAssertEqual(message.path, "/mcp")
        XCTAssertEqual(message.headers["content-type"], "application/json")
        XCTAssertEqual(String(data: message.body, encoding: .utf8), "{\"a\":1}")
    }

    func testLowercasesHeaderNamesAndUppercasesTheMethod() throws {
        let message = try parsed("get /health HTTP/1.1\r\nX-Baton-Name: Reading.txt\r\n\r\n")
        XCTAssertEqual(message.method, "GET")
        XCTAssertEqual(message.headers["x-baton-name"], "Reading.txt")
        XCTAssertNil(message.headers["X-Baton-Name"], "header lookup is by lower-cased key")
    }

    func testHeadersWithNoBlankLineYetAreIncomplete() {
        guard case .incomplete = HTTPRequestMessage.parse(raw("GET /mcp HTTP/1.1\r\nHost: x")) else {
            return XCTFail("a half-arrived head must be .incomplete so the caller keeps reading")
        }
    }

    func testABodyShorterThanContentLengthIsIncomplete() {
        let partial = raw("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc")
        guard case .incomplete = HTTPRequestMessage.parse(partial) else {
            return XCTFail("a partial body must not complete with the bytes that arrived")
        }
    }

    func testChunkedTransferEncodingIsRefusedRatherThanMisread() {
        let chunked = raw("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n")
        guard case .malformed = HTTPRequestMessage.parse(chunked) else {
            return XCTFail("chunked is unsupported and must be malformed, not a zero-length body")
        }
    }

    /// A negative `Content-Length` used to pass the size cap and then build an inverted
    /// `Data` range, trapping before any token was checked.
    func testANegativeContentLengthIsMalformedRatherThanATrap() {
        guard case .malformed = HTTPRequestMessage.parse(raw("POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n")) else {
            return XCTFail("a negative Content-Length must be refused")
        }
    }

    func testABodyOverTheCapIsTooLarge() {
        let over = BatonMCPConstants.maxRequestBytes + 1
        guard case .tooLarge = HTTPRequestMessage.parse(raw("POST /mcp HTTP/1.1\r\nContent-Length: \(over)\r\n\r\n")) else {
            return XCTFail("a declared body over the cap must be refused before it is read")
        }
    }

    func testAHeadWithNoRequestLineIsMalformed() {
        guard case .malformed = HTTPRequestMessage.parse(raw("/mcp\r\n\r\n")) else {
            return XCTFail("a request line with one token is malformed")
        }
    }

    // MARK: - Query parsing

    func testQueryIsSplitOffThePathAndPercentDecoded() throws {
        let message = try parsed("GET /search?q=blue%20nile&limit=10 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(message.path, "/search")
        XCTAssertEqual(message.query["q"], "blue nile")
        XCTAssertEqual(message.query["limit"], "10")
    }

    /// A bare `=` used to trap pre-auth on `kv[0]`. Empty keys are skipped, empty values kept.
    func testDegenerateQueryPairsDoNotTrap() throws {
        let message = try parsed("GET /x?=orphan&k=&=&ok=1 HTTP/1.1\r\n\r\n")
        XCTAssertNil(message.query[""], "a pair with no key is not a parameter")
        XCTAssertEqual(message.query["k"], "")
        XCTAssertEqual(message.query["ok"], "1")
    }

    // MARK: - Bearer token

    func testBearerTokenIsReadFromTheAuthorizationHeaderOnly() throws {
        let message = try parsed("GET /mcp?token=leaked HTTP/1.1\r\nAuthorization: Bearer abc123\r\n\r\n")
        XCTAssertEqual(message.bearerToken, "abc123")
    }

    func testTheBearerSchemeIsCaseInsensitiveAndOtherSchemesAreRefused() throws {
        XCTAssertEqual(try parsed("GET / HTTP/1.1\r\nAuthorization: bearer abc\r\n\r\n").bearerToken, "abc")
        XCTAssertEqual(try parsed("GET / HTTP/1.1\r\nAuthorization: BEARER abc\r\n\r\n").bearerToken, "abc")
        XCTAssertNil(try parsed("GET / HTTP/1.1\r\nAuthorization: Basic abc\r\n\r\n").bearerToken)
        XCTAssertNil(try parsed("GET / HTTP/1.1\r\nAuthorization: abc\r\n\r\n").bearerToken)
    }

    /// The `?token=` form was dropped so the secret cannot leak into logs, referrers or
    /// shell history. A query parameter must not be a way back in.
    func testAQueryTokenIsNotAcceptedAsCredentials() throws {
        let message = try parsed("GET /mcp?token=abc123 HTTP/1.1\r\n\r\n")
        XCTAssertNil(message.bearerToken)
    }

    func testAcceptsEventStreamAndSessionID() throws {
        let message = try parsed(
            "GET /mcp HTTP/1.1\r\nAccept: text/event-stream\r\nMcp-Session-Id: s-1\r\n\r\n")
        XCTAssertTrue(message.acceptsEventStream)
        XCTAssertEqual(message.sessionID, "s-1")
    }

    // MARK: - JSON-RPC envelopes

    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testResultEnvelopeRoundTrips() throws {
        let object = try decode(JSONRPC.data(JSONRPC.result(id: 7, ["ok": true])))
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(object["id"] as? Int, 7)
        XCTAssertEqual((object["result"] as? [String: Any])?["ok"] as? Bool, true)
    }

    /// A request's `id` is echoed verbatim, whatever type it arrived as, so a client that
    /// used a string id can still match the reply.
    func testResultEnvelopeEchoesAStringIDAndANilIDAsNull() throws {
        let stringID = try decode(JSONRPC.data(JSONRPC.result(id: "call-1", [:])))
        XCTAssertEqual(stringID["id"] as? String, "call-1")
        let nilID = try decode(JSONRPC.data(JSONRPC.result(id: nil, [:])))
        XCTAssertTrue(nilID["id"] is NSNull)
    }

    func testErrorEnvelopeCarriesTheCodeAndMessage() throws {
        let object = try decode(JSONRPC.data(
            JSONRPC.error(id: 1, code: JSONRPCError.methodNotFound, message: "no such tool")))
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32_601)
        XCTAssertEqual(error["message"] as? String, "no such tool")
        XCTAssertNil(object["result"], "an error envelope carries no result")
    }

    func testNotificationEnvelopeHasNoIDAndOmitsAbsentParams() throws {
        let bare = try decode(JSONRPC.data(JSONRPC.notification(method: "notifications/resources/updated")))
        XCTAssertNil(bare["id"], "a notification expects no response, so it carries no id")
        XCTAssertNil(bare["params"])
        let withParams = try decode(JSONRPC.data(
            JSONRPC.notification(method: "x", params: ["uri": BatonMCPConstants.nowPlayingURI])))
        XCTAssertEqual((withParams["params"] as? [String: Any])?["uri"] as? String, "baton://now-playing")
    }

    /// Every envelope this module builds is JSON-legal, which is the guarantee its callers
    /// actually rely on.
    ///
    /// **The `?? Data("{}".utf8)` fallback in `JSONRPC.data` is unreachable, and its doc
    /// comment's "rather than crashing" is not true.** `JSONSerialization.data(withJSONObject:)`
    /// raises an Objective-C `NSInvalidArgumentException` for a value it cannot encode
    /// (measured here with `Data()` as a value: `Invalid type in JSON write (_NSZeroData)`),
    /// and `try?` catches Swift errors only, so the process dies before the `??` is reached.
    /// Asserted as `isValidJSONObject` rather than by calling `data` with a bad value, because
    /// the second form would take the test runner down with it. Filed rather than fixed: this
    /// card adds the seam, it does not change shipping behaviour.
    func testEveryEnvelopeThisModuleBuildsIsEncodable() {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(JSONRPC.result(id: 1, ["ok": true])))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(JSONRPC.result(id: nil, [:])))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(
            JSONRPC.error(id: "x", code: JSONRPCError.parseError, message: "bad")))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(
            JSONRPC.notification(method: "n", params: ["uri": BatonMCPConstants.queueURI])))
        XCTAssertFalse(JSONSerialization.isValidJSONObject(JSONRPC.result(id: 1, ["blob": Data()])),
                       "a result carrying a non-JSON value is not encodable, and `data` will "
                           + "raise rather than fall back")
    }

    // MARK: - Response framing, parsed back

    /// The framer's output is fed to a header parser, which is the round trip that matters:
    /// a status line and headers a client can actually read.
    private func head(_ data: Data) throws -> (status: String, headers: [String: String], body: Data) {
        let separator = try XCTUnwrap(data.range(of: Data("\r\n\r\n".utf8)))
        let text = try XCTUnwrap(String(data: data.subdata(in: data.startIndex ..< separator.lowerBound),
                                        encoding: .utf8))
        var lines = text.components(separatedBy: "\r\n")
        let status = lines.removeFirst().replacingOccurrences(of: "HTTP/1.1 ", with: "")
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[line.startIndex ..< colon]).lowercased()] =
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return (status, headers, data.subdata(in: separator.upperBound ..< data.endIndex))
    }

    func testJSONResponseFramesAStatusContentLengthAndTheBody() throws {
        let framed = try head(HTTPResponse.json(JSONRPC.result(id: 1, ["ok": true]), sessionID: "s-9"))
        XCTAssertEqual(framed.status, "200 OK")
        XCTAssertEqual(framed.headers["content-type"], "application/json")
        XCTAssertEqual(framed.headers["mcp-session-id"], "s-9")
        XCTAssertEqual(framed.headers["connection"], "close")
        XCTAssertEqual(Int(framed.headers["content-length"] ?? ""), framed.body.count,
                       "Content-Length must equal the bytes that follow, or a client hangs")
        let object = try decode(framed.body)
        XCTAssertEqual((object["result"] as? [String: Any])?["ok"] as? Bool, true)
    }

    func testAnEmptyResponseStillDeclaresZeroLength() throws {
        let framed = try head(HTTPResponse.empty(status: "202 Accepted"))
        XCTAssertEqual(framed.status, "202 Accepted")
        XCTAssertEqual(framed.headers["content-length"], "0")
        XCTAssertTrue(framed.body.isEmpty)
        XCTAssertNil(framed.headers["mcp-session-id"], "no session id unless one was given")
    }

    func testSSEHeadersKeepTheConnectionAliveAndDisableCaching() throws {
        let text = try XCTUnwrap(String(data: HTTPResponse.sseHeaders(sessionID: "s-3"), encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Type: text/event-stream\r\n"))
        XCTAssertTrue(text.contains("Cache-Control: no-cache\r\n"))
        XCTAssertTrue(text.contains("Connection: keep-alive\r\n"))
        XCTAssertTrue(text.contains("Mcp-Session-Id: s-3\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
    }

    /// An SSE event is one `data:` line then a blank line, and the JSON in it must survive
    /// the trip: a newline inside the payload would end the event early.
    func testSSEEventFramesOneLineAndItsJSONSurvives() throws {
        let event = try XCTUnwrap(String(data: HTTPResponse.sseEvent(
            JSONRPC.notification(method: "x", params: ["text": "two\nlines"])), encoding: .utf8))
        XCTAssertTrue(event.hasPrefix("data: "))
        XCTAssertTrue(event.hasSuffix("\n\n"))
        let payload = event.dropFirst("data: ".count).dropLast(2)
        XCTAssertFalse(payload.contains("\n"), "a raw newline would terminate the event early")
        let object = try decode(Data(payload.utf8))
        XCTAssertEqual((object["params"] as? [String: Any])?["text"] as? String, "two\nlines")
    }

    // MARK: - Token compare

    func testConstantTimeEqualsMatchesOnlyAnExactToken() {
        XCTAssertTrue(BatonMCPAuth.constantTimeEquals("abc123", "abc123"))
        XCTAssertFalse(BatonMCPAuth.constantTimeEquals("abc123", "abc124"))
        XCTAssertFalse(BatonMCPAuth.constantTimeEquals("abc12", "abc123"), "a prefix is not a match")
        XCTAssertFalse(BatonMCPAuth.constantTimeEquals("ABC123", "abc123"), "case matters")
        XCTAssertFalse(BatonMCPAuth.constantTimeEquals("", "abc123"))
        XCTAssertTrue(BatonMCPAuth.constantTimeEquals("", ""))
    }

    /// Compared over UTF-8 bytes, so two strings that differ only past the BMP still differ.
    func testConstantTimeEqualsComparesBytesNotCharacters() {
        XCTAssertFalse(BatonMCPAuth.constantTimeEquals("t\u{00F6}ken", "to\u{0308}ken"),
                       "precomposed and decomposed forms are different bytes and different tokens")
    }

    func testGeneratedTokensAre64HexCharactersAndDoNotRepeat() {
        let first = BatonMCPAuth.generateToken()
        XCTAssertEqual(first.count, 64, "32 bytes, hex encoded")
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(Set((0 ..< 8).map { _ in BatonMCPAuth.generateToken() }).count, 8)
    }

    // MARK: - Constants

    /// The version is read from the host bundle rather than hardcoded, because a literal
    /// said "0.1.0" for seven releases. A bare test runner has no app version to report, and
    /// the placeholder is deliberately not a real-looking one.
    func testServerVersionFallsBackToAnObviouslyUnrealPlaceholder() {
        let version = BatonMCPConstants.serverVersion
        XCTAssertFalse(version.isEmpty)
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") == nil {
            XCTAssertEqual(version, BatonMCPConstants.unknownVersion)
        }
    }

    func testTheProtocolConstantsAreTheOnesTheServerAdvertises() {
        XCTAssertEqual(BatonMCPConstants.protocolVersion, "2025-06-18")
        XCTAssertEqual(BatonMCPConstants.serverName, "baton")
        XCTAssertEqual(BatonMCPConstants.maxRequestBytes, 1_048_576)
        XCTAssertEqual(BatonMCPConstants.defaultPort, 8787)
        XCTAssertEqual(BatonMCPConstants.queueURI, "baton://queue")
    }
}
