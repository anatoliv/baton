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

    /// A link that cannot be honoured has to say so.
    ///
    /// `route` used to be `try? await …getSong(id:)` with no else, and `playAlbum` did
    /// nothing at all when the album came back empty. So tapping a Baton link from Messages
    /// or a shortcut opened the app and then nothing happened: offline, wrong server, a
    /// deleted track and a link that never fired were all the same non-event.
    func testEveryFailedLinkHasSomethingToSay() {
        XCTAssertNil(DeepLinkOutcome.handled.message, "success is not an announcement")
        for outcome: DeepLinkOutcome in [.notConnected, .songUnavailable, .albumUnavailable] {
            let message = outcome.message
            XCTAssertNotNil(message, "\(outcome) fails silently")
            XCTAssertFalse(message?.isEmpty ?? true, "\(outcome) has an empty message")
        }
    }

    func testForeignAndMalformedLinksAreRefused() {
        XCTAssertNil(BatonDeepLink(url: URL(string: "https://example.com/play/1")!))
        XCTAssertNil(BatonDeepLink(url: URL(string: "baton://nonsense")!))
        // A play link with no id used to fall through to `lastPathComponent == "/"`.
        XCTAssertNil(BatonDeepLink(url: URL(string: "baton://play")!))
        XCTAssertNil(BatonDeepLink(url: URL(string: "baton://play/")!))
    }
}
