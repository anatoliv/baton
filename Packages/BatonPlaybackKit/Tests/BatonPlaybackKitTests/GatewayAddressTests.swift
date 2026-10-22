import XCTest
@testable import BatonPlaybackKit

/// The gateway address someone actually types.
///
/// This exists because a real user pointed the phone's music friend at
/// `http://<host>:8000/v1` and got "Reached the address, but it isn't a Baton gateway
/// (no /v1/agent)" — the probe had asked for `/v1/v1/agent`. The mistake is not careless:
/// the model-provider field directly above it *requires* a `/v1`, and its own default ends
/// in one. Two adjacent fields, opposite conventions, one of them silent about it.
final class GatewayAddressTests: XCTestCase {

    /// The case that prompted all of this.
    func testDropsATrailingV1() {
        XCTAssertEqual(GatewayAddress.root("http://gw.example:8788/v1")?.absoluteString,
                       "http://gw.example:8788")
    }

    func testDropsATrailingV1WithASlash() {
        XCTAssertEqual(GatewayAddress.root("http://gw.example:8788/v1/")?.absoluteString,
                       "http://gw.example:8788")
    }

    func testLeavesAPlainRootAlone() {
        XCTAssertEqual(GatewayAddress.root("http://gw.example:8788")?.absoluteString,
                       "http://gw.example:8788")
    }

    func testDropsTrailingSlashes() {
        XCTAssertEqual(GatewayAddress.root("https://baton.home.example///")?.absoluteString,
                       "https://baton.home.example")
    }

    /// A gateway hosted under a sub-path keeps it — only the `/v1` comes off.
    func testKeepsASubPath() {
        XCTAssertEqual(GatewayAddress.root("https://home.example/baton/v1")?.absoluteString,
                       "https://home.example/baton")
        XCTAssertEqual(GatewayAddress.root("https://home.example/baton")?.absoluteString,
                       "https://home.example/baton")
    }

    /// Whole segments only: `/v1x` is somebody's real path, not our convention.
    func testDoesNotEatASegmentThatMerelyStartsWithV1() {
        XCTAssertEqual(GatewayAddress.root("https://home.example/v1x")?.absoluteString,
                       "https://home.example/v1x")
    }

    /// Applying it twice must not strip a second segment — call sites normalize defensively
    /// and may be handed input that was already normalized upstream.
    func testIsIdempotent() throws {
        let once = try XCTUnwrap(GatewayAddress.root("http://gw.example:8788/v1"))
        XCTAssertEqual(GatewayAddress.root(once).absoluteString, once.absoluteString)
    }

    func testStripsPasteArtefacts() {
        XCTAssertEqual(GatewayAddress.root("  http://gw.example:8788/v1?token=x#frag  ")?.absoluteString,
                       "http://gw.example:8788")
    }

    func testRejectsWhatIsNotAnAddress() {
        XCTAssertNil(GatewayAddress.root(""))
        XCTAssertNil(GatewayAddress.root("   "))
        XCTAssertNil(GatewayAddress.root("gw.example:8788"), "no scheme is not a usable address")
    }

    /// The whole point, stated as the URL the probe will actually request.
    func testTheProbeURLIsRightForBothShapes() throws {
        for typed in ["http://gw.example:8788", "http://gw.example:8788/v1", "http://gw.example:8788/"] {
            let root = try XCTUnwrap(GatewayAddress.root(typed))
            XCTAssertEqual(root.appendingPathComponent("v1/agent").absoluteString,
                           "http://gw.example:8788/v1/agent",
                           "typed \(typed)")
        }
    }

    // MARK: - Where the gateway's bearer may go (TBX-1000000505 B-9)

    /// The caller's private-host rule, standing in for `RemoteNaturalLanguage.isPrivate`.
    private func isPrivate(_ host: String) -> Bool {
        ["127.0.0.1", "192.168.1.20", "10.0.0.5", "localhost", "nas.local"].contains(host)
    }

    private func allows(_ address: String) -> Bool {
        GatewayAddress.allowsBearer(to: URL(string: address)!, isPrivate: isPrivate)
    }

    /// ATS lets plain HTTP through to an IP literal, so a public address typed by mistake sent
    /// the household's token across the internet in the clear. Only HTTPS goes there.
    func testABearerNeverGoesOverPlainHTTPToAPublicAddress() {
        XCTAssertFalse(allows("http://203.0.113.7:8788"))
        XCTAssertFalse(allows("http://[2001:db8::1]:8788"))
        XCTAssertTrue(allows("https://203.0.113.7:8788"))
    }

    func testTheHomeNetworkStillWorksOverPlainHTTP() {
        XCTAssertTrue(allows("http://127.0.0.1:8788"))
        XCTAssertTrue(allows("http://192.168.1.20:8788"))
        XCTAssertTrue(allows("http://10.0.0.5:8788"))
        XCTAssertTrue(allows("http://localhost:8788"))
        XCTAssertTrue(allows("http://nas.local:8788"))
    }

    /// A name is ATS's to refuse (it blocks plain HTTP to a public name already), so a name the
    /// household's own DNS answers, `http://homeserver:8788`, keeps working.
    func testANameIsLeftToTheSystem() {
        XCTAssertTrue(allows("http://homeserver:8788"))
        XCTAssertTrue(allows("https://gw.example.com"))
    }

    /// Tailscale and the IPv6 link-local and unique-local ranges never cross the public internet,
    /// and gateway/README.md calls plain HTTP over Tailscale fine (TBX-1000000505 review).
    func testTailscaleAndLocalIPv6StillWorkOverPlainHTTP() {
        XCTAssertTrue(allows("http://100.101.102.103:8788"))
        XCTAssertTrue(allows("http://100.64.0.1:8788"))
        XCTAssertTrue(allows("http://[fd7a:115c:a1e0::1]:8788"))
        XCTAssertTrue(allows("http://[fe80::1]:8788"))
        XCTAssertFalse(allows("http://100.128.0.1:8788"), "just past 100.64/10 is public")
        XCTAssertFalse(allows("http://100.63.255.255:8788"))
        XCTAssertFalse(allows("http://[2600:1f18::1]:8788"))
    }

    func testAnythingElseIsRefused() {
        XCTAssertFalse(allows("ftp://192.168.1.20"))
        XCTAssertFalse(allows("file:///tmp/x"))
    }
}
