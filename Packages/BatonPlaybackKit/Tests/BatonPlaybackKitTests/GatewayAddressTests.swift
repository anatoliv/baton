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
}
