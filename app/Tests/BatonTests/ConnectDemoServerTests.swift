import XCTest
@testable import Baton

/// The connect sheet offers a one-click "Try the demo server" so someone without a Navidrome
/// server can still evaluate Baton. That demo is **third-party infrastructure** the Navidrome
/// project runs, so a failure against it must be attributed to the demo rather than reading as a
/// bug in Baton — which makes recognising the demo host part of the user-facing behaviour.
final class ConnectDemoServerTests: XCTestCase {
    func testRecognisesTheDemoHost() {
        XCTAssertTrue(BatonConnectSheet.isDemoServer("https://demo.navidrome.org"))
        XCTAssertTrue(BatonConnectSheet.isDemoServer("https://demo.navidrome.org/"))
    }

    /// Matching on host (not the whole string) means an edited scheme, port, or path still gets
    /// the demo-specific message.
    func testMatchesOnHostNotExactString() {
        XCTAssertTrue(BatonConnectSheet.isDemoServer("http://demo.navidrome.org"))
        XCTAssertTrue(BatonConnectSheet.isDemoServer("https://demo.navidrome.org:443/music"))
        XCTAssertTrue(BatonConnectSheet.isDemoServer("https://DEMO.Navidrome.ORG"))
    }

    /// A real server must never be blamed on the demo — the message would be actively misleading.
    func testDoesNotMatchOtherServers() {
        XCTAssertFalse(BatonConnectSheet.isDemoServer("https://music.example.com"))
        XCTAssertFalse(BatonConnectSheet.isDemoServer("https://navidrome.org"))
        XCTAssertFalse(BatonConnectSheet.isDemoServer("https://demo.navidrome.org.evil.test"))
        XCTAssertFalse(BatonConnectSheet.isDemoServer(""))
        XCTAssertFalse(BatonConnectSheet.isDemoServer("not a url"))
    }
}
