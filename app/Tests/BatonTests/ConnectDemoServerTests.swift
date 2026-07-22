import XCTest
@testable import Baton

/// Baton offers a one-click "try the demo server" from two places — the first-run connect sheet
/// and Settings → Add Server. That demo is **third-party infrastructure** the Navidrome project
/// runs, so a failure against it must be attributed to the demo rather than reading as a bug in
/// Baton — which makes recognising the demo host part of the user-facing behaviour.
final class ConnectDemoServerTests: XCTestCase {
    func testRecognisesTheDemoHost() {
        XCTAssertTrue(NavidromeDemoServer.matches("https://demo.navidrome.org"))
        XCTAssertTrue(NavidromeDemoServer.matches("https://demo.navidrome.org/"))
        // The canonical value the sheets fill in must itself match.
        XCTAssertTrue(NavidromeDemoServer.matches(NavidromeDemoServer.urlString))
    }

    /// Matching on host (not the whole string) means an edited scheme, port, or path still gets
    /// the demo-specific message.
    func testMatchesOnHostNotExactString() {
        XCTAssertTrue(NavidromeDemoServer.matches("http://demo.navidrome.org"))
        XCTAssertTrue(NavidromeDemoServer.matches("https://demo.navidrome.org:443/music"))
        XCTAssertTrue(NavidromeDemoServer.matches("https://DEMO.Navidrome.ORG"))
    }

    /// A real server must never be blamed on the demo — the message would be actively misleading.
    func testDoesNotMatchOtherServers() {
        XCTAssertFalse(NavidromeDemoServer.matches("https://music.example.com"))
        XCTAssertFalse(NavidromeDemoServer.matches("https://navidrome.org"))
        XCTAssertFalse(NavidromeDemoServer.matches("https://demo.navidrome.org.evil.test"))
        XCTAssertFalse(NavidromeDemoServer.matches(""))
        XCTAssertFalse(NavidromeDemoServer.matches("not a url"))
    }

    /// Error routing: demo URLs get the attribution copy (keeping the underlying detail), and
    /// everything else is passed through untouched.
    func testErrorTextRouting() {
        let demo = NavidromeDemoServer.errorText(forURL: NavidromeDemoServer.urlString,
                                                 detail: "Unauthorized")
        XCTAssertTrue(demo.contains("run by the Navidrome project"))
        XCTAssertTrue(demo.contains("Unauthorized"), "underlying error must survive as detail")

        let own = NavidromeDemoServer.errorText(forURL: "https://music.example.com",
                                                detail: "Unauthorized")
        XCTAssertEqual(own, "Unauthorized", "a real server's error must be passed through as-is")
    }

    /// The credentials the two sheets fill in are the documented public demo ones.
    func testDemoCredentials() {
        XCTAssertEqual(NavidromeDemoServer.username, "demo")
        XCTAssertEqual(NavidromeDemoServer.password, "demo")
        XCTAssertEqual(NavidromeDemoServer.authMode, .tokenSalt)
    }
}
