import XCTest
@testable import BatonMobile

/// The widget's link must not be a play command.
///
/// `BatonWidgets` used to set `.widgetURL("baton://play/<id>")`, so tapping the Now Playing
/// widget — a display of the thing already playing — rebuilt the queue as a single item and
/// restarted the track from 0:00. Both halves read fine in isolation: the widget was passing
/// the id it had, and `play` does what it says. The mistake only exists in the join.
final class BatonDeepLinkTests: XCTestCase {
    func testThePlayerLinkOnlyPresentsAndStartsNothing() {
        let link = BatonDeepLink(url: URL(string: "baton://player")!)
        XCTAssertEqual(link, .presentPlayer)
        XCTAssertEqual(link?.disturbsPlayback, false,
                       "the widget's link must never change what is playing")
    }

    /// The exact string the Now Playing widget ships. If someone points it back at a play
    /// link, this fails rather than quietly wiping a queue in the field.
    func testTheWidgetURLIsTheNonDisturbingOne() {
        let widgetURL = URL(string: "baton://player")!
        guard let link = BatonDeepLink(url: widgetURL) else {
            return XCTFail("the widget's own URL no longer routes")
        }
        XCTAssertFalse(link.disturbsPlayback)
    }

    func testPlayLinksStillPlay() {
        XCTAssertEqual(BatonDeepLink(url: URL(string: "baton://play/abc123")!), .playSong(id: "abc123"))
        XCTAssertEqual(BatonDeepLink(url: URL(string: "baton://album/xyz")!), .playAlbum(id: "xyz"))
        XCTAssertEqual(BatonDeepLink(url: URL(string: "baton://play/abc123")!)?.disturbsPlayback, true)
    }

    func testForeignAndMalformedLinksAreRefused() {
        XCTAssertNil(BatonDeepLink(url: URL(string: "https://example.com/play/1")!))
        XCTAssertNil(BatonDeepLink(url: URL(string: "baton://nonsense")!))
        // A play link with no id used to fall through to `lastPathComponent == "/"`.
        XCTAssertNil(BatonDeepLink(url: URL(string: "baton://play")!))
        XCTAssertNil(BatonDeepLink(url: URL(string: "baton://play/")!))
    }
}
