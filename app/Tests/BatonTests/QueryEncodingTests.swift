import XCTest
@testable import Baton

/// `URLComponents` percent-encodes `&` and `=` inside query values but leaves `;` and
/// `+` alone — both are legal in a query component per RFC 3986. Servers disagree:
/// Navidrome is Go, and `url.ParseQuery` rejects a bare `;` with "invalid semicolon
/// separator in query"; `+` decodes as a space. A song title containing either breaks
/// the request or silently searches for something else.
final class QueryEncodingTests: XCTestCase {
    private func url(query value: String) throws -> String {
        let creds = NavidromeCredentials(
            baseURL: URL(string: "https://example.test")!,
            username: "u",
            secret: "p",
            authMode: .tokenSalt
        )
        let client = NavidromeClient(credentials: creds)
        return try client.makeURL("search3.view", query: [
            URLQueryItem(name: "query", value: value),
        ]).absoluteString
    }

    func testSemicolonIsEncoded() throws {
        let s = try url(query: "rock; roll")
        XCTAssertTrue(s.contains("%3B"), "semicolon must be encoded: \(s)")
        XCTAssertFalse(s.contains("roll") && s.contains("; "), "raw semicolon leaked: \(s)")
    }

    /// The exact string that produced "invalid semicolon separator in query" in the
    /// field — an HTML-escaped ampersand, whose trailing `;` broke Go's parser.
    func testHTMLEscapedAmpersandDoesNotBreakTheQuery() throws {
        let s = try url(query: "Melodic Techno &amp; Deep Progressive")
        XCTAssertFalse(s.contains(";"), "no raw semicolon may reach the server: \(s)")
        XCTAssertTrue(s.contains("%26"), "the ampersand itself should still be encoded: \(s)")
    }

    func testPlusIsEncodedSoItIsNotDecodedAsSpace() throws {
        let s = try url(query: "a+b")
        XCTAssertTrue(s.contains("%2B"), "plus must be encoded or it arrives as a space: \(s)")
    }

    func testAmpersandStillEncodedAndDoesNotSplitParameters() throws {
        let s = try url(query: "Simon & Garfunkel")
        XCTAssertTrue(s.contains("%26"))
        XCTAssertFalse(s.contains("&query=Simon & "), "value must not split the query string: \(s)")
    }

    func testNonASCIISurvivesEncoding() throws {
        let s = try url(query: "øneheart")
        XCTAssertTrue(s.contains("%C3%B8"), "UTF-8 percent-encoding expected: \(s)")
    }

    func testOrdinaryQueryIsUnaffected() throws {
        let s = try url(query: "jazz")
        XCTAssertTrue(s.contains("query=jazz"))
        XCTAssertFalse(s.contains("%3B"))
        XCTAssertFalse(s.contains("%2B"))
    }
}
