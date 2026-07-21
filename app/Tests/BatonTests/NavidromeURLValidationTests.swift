import XCTest
@testable import Baton

/// : the server-URL validator accepts only http/https with a host — a `file://` would
/// otherwise make URLSession read local files, and a hostless URL is unusable.
@MainActor
final class NavidromeURLValidationTests: XCTestCase {
    func testHttpAndHttpsWithHostAreValid() {
        XCTAssertNotNil(NavidromeConfig.validatedURL("https://music.example.com"))
        XCTAssertNotNil(NavidromeConfig.validatedURL("http://192.168.1.5:4533"))
    }

    func testFileAndFtpSchemesRejected() {
        XCTAssertNil(NavidromeConfig.validatedURL("file:///etc/passwd"))
        XCTAssertNil(NavidromeConfig.validatedURL("ftp://host/x"))
    }

    func testHostlessOrEmptyRejected() {
        XCTAssertNil(NavidromeConfig.validatedURL("https://"))
        XCTAssertNil(NavidromeConfig.validatedURL(""))
    }

    // : the connect flow's cleartext-connection warning.
    func testIsInsecureFlagsHTTPButNotHTTPSOrInvalid() {
        XCTAssertTrue(NavidromeConfig.isInsecure("http://music.lan:4533"))
        XCTAssertFalse(NavidromeConfig.isInsecure("https://music.example.com"))
        XCTAssertFalse(NavidromeConfig.isInsecure("not a url"), "an invalid URL isn't flagged insecure")
        XCTAssertFalse(NavidromeConfig.isInsecure(""))
    }
}
