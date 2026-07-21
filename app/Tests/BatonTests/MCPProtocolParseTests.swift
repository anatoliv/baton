import XCTest
@testable import Baton

/// : the MCP HTTP parser must never trap on malformed input — it runs in
/// `receive()` BEFORE the bearer-token check, so any local process can reach it.
/// These cases pin the previously-crashing inputs (bare "=" query, negative
/// Content-Length) plus the general robustness surface.
final class MCPProtocolParseTests: XCTestCase {
    private func raw(_ s: String) -> Data { Data(s.utf8) }

    // MARK: query parsing (previously trapped on kv[0])

    func testBareEqualsQueryDoesNotTrap() {
        guard case .complete(let m) = HTTPRequestMessage.parse(raw("GET /mcp?= HTTP/1.1\r\nHost: x\r\n\r\n")) else {
            return XCTFail("expected complete")
        }
        XCTAssertEqual(m.path, "/mcp")
        XCTAssertTrue(m.query.isEmpty)
    }

    func testMessyQueryPairs() {
        guard case .complete(let m) = HTTPRequestMessage.parse(raw("GET /mcp?a&=&b=2&token= HTTP/1.1\r\nHost: x\r\n\r\n")) else {
            return XCTFail("expected complete")
        }
        XCTAssertEqual(m.query["a"], "")
        XCTAssertEqual(m.query["b"], "2")
        XCTAssertEqual(m.query["token"], "")
        XCTAssertNil(m.query[""])
    }

    // MARK: Content-Length validation (previously trapped on negative length)

    func testNegativeContentLengthIsMalformed() {
        guard case .malformed = HTTPRequestMessage.parse(raw("POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n")) else {
            return XCTFail("expected malformed")
        }
    }

    func testNonNumericContentLengthIsMalformed() {
        guard case .malformed = HTTPRequestMessage.parse(raw("POST /mcp HTTP/1.1\r\nContent-Length: abc\r\n\r\n")) else {
            return XCTFail("expected malformed")
        }
    }

    func testHugeContentLengthIsTooLarge() {
        guard case .tooLarge = HTTPRequestMessage.parse(raw("POST /mcp HTTP/1.1\r\nContent-Length: 99999999\r\n\r\nx")) else {
            return XCTFail("expected tooLarge")
        }
    }

    func testMissingContentLengthTreatedAsEmptyBody() {
        guard case .complete(let m) = HTTPRequestMessage.parse(raw("POST /mcp HTTP/1.1\r\nHost: x\r\n\r\n")) else {
            return XCTFail("expected complete")
        }
        XCTAssertTrue(m.body.isEmpty)
    }

    // MARK: transfer-encoding

    func testChunkedIsMalformed() {
        guard case .malformed = HTTPRequestMessage.parse(raw("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n")) else {
            return XCTFail("expected malformed")
        }
    }

    // MARK: fragmented delivery

    func testIncompleteHeaders() {
        guard case .incomplete = HTTPRequestMessage.parse(raw("POST /mcp HTTP/1.1\r\nContent-Len")) else {
            return XCTFail("expected incomplete (no CRLFCRLF yet)")
        }
    }

    func testIncompleteBody() {
        guard case .incomplete = HTTPRequestMessage.parse(raw("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\nshort")) else {
            return XCTFail("expected incomplete (5 of 10 body bytes)")
        }
    }

    // MARK: the happy path still works

    func testValidPostWithBody() {
        let body = "{\"jsonrpc\":\"2.0\"}"
        let req = raw("POST /mcp HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\nAuthorization: Bearer abc\r\n\r\n\(body)")
        guard case .complete(let m) = HTTPRequestMessage.parse(req) else {
            return XCTFail("expected complete")
        }
        XCTAssertEqual(m.method, "POST")
        XCTAssertEqual(m.bearerToken, "abc")
        XCTAssertEqual(String(data: m.body, encoding: .utf8), body)
    }
}
