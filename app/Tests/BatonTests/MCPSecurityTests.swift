import XCTest
@testable import Baton

/// W-14: DNS-rebinding defense (Host/Origin) and header-only auth (no `?token=`).
@MainActor
final class MCPSecurityTests: XCTestCase {
    func testLoopbackHostAccepted() {
        XCTAssertTrue(BatonMCPServer.isLoopbackHost("127.0.0.1:8787"))
        XCTAssertTrue(BatonMCPServer.isLoopbackHost("localhost"))
        XCTAssertTrue(BatonMCPServer.isLoopbackHost("[::1]:8787"))
        XCTAssertTrue(BatonMCPServer.isLoopbackHost(nil)) // HTTP/1.0, loopback-bound anyway
    }

    func testNonLoopbackHostRejected() {
        XCTAssertFalse(BatonMCPServer.isLoopbackHost("evil.com"))
        XCTAssertFalse(BatonMCPServer.isLoopbackHost("attacker.example:8787"))
    }

    func testOriginPolicy() {
        XCTAssertTrue(BatonMCPServer.isAllowedOrigin(nil))
        XCTAssertTrue(BatonMCPServer.isAllowedOrigin("null"))
        XCTAssertTrue(BatonMCPServer.isAllowedOrigin("http://localhost:3000"))
        XCTAssertFalse(BatonMCPServer.isAllowedOrigin("https://evil.com"))
    }

    func testQueryTokenIsIgnored() {
        guard case .complete(let m) = HTTPRequestMessage.parse(Data("GET /mcp?token=abc HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)) else {
            return XCTFail("expected complete")
        }
        XCTAssertNil(m.bearerToken, "?token= must not be honored")
    }

    func testAuthorizationHeaderIsHonored() {
        guard case .complete(let m) = HTTPRequestMessage.parse(Data("GET /mcp HTTP/1.1\r\nAuthorization: Bearer xyz\r\n\r\n".utf8)) else {
            return XCTFail("expected complete")
        }
        XCTAssertEqual(m.bearerToken, "xyz")
    }
}
