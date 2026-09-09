import XCTest
@testable import Baton

/// : the update-channel liveness gate must be precise. A placeholder/empty key,
/// an http (non-TLS) feed, or a hostless URL is "not configured"; only a real https
/// channel with automatic checks enabled counts as live.
final class UpdateChannelTests: XCTestCase {
    private let key = "pDgN5Ibe6Q9QY5cxRpXmXLm/S2lBGbVLy/eBVEW1nTo="
    private let feed = "https://batonmusic.app/appcast.xml"

    func testLiveChannel() {
        XCTAssertTrue(UpdateChannel.isConfigured(publicKey: key, feedURL: feed, autoChecksEnabled: true))
    }
    func testPlaceholderKeyNotConfigured() {
        XCTAssertFalse(UpdateChannel.isConfigured(publicKey: UpdateChannel.publicKeyPlaceholder, feedURL: feed, autoChecksEnabled: true))
    }
    func testEmptyOrNilKeyNotConfigured() {
        XCTAssertFalse(UpdateChannel.isConfigured(publicKey: "", feedURL: feed, autoChecksEnabled: true))
        XCTAssertFalse(UpdateChannel.isConfigured(publicKey: nil, feedURL: feed, autoChecksEnabled: true))
    }
    func testHttpFeedNotConfigured() {
        XCTAssertFalse(UpdateChannel.isConfigured(publicKey: key, feedURL: "http://batonmusic.app/appcast.xml", autoChecksEnabled: true))
    }
    func testHostlessOrEmptyFeedNotConfigured() {
        XCTAssertFalse(UpdateChannel.isConfigured(publicKey: key, feedURL: "https://", autoChecksEnabled: true))
        XCTAssertFalse(UpdateChannel.isConfigured(publicKey: key, feedURL: "", autoChecksEnabled: true))
    }
    func testAutoChecksOffNotConfigured() {
        XCTAssertFalse(UpdateChannel.isConfigured(publicKey: key, feedURL: feed, autoChecksEnabled: false))
    }

    /// TBX-5306. Everything above uses a literal, so none of it would have noticed the
    /// shipped feed moving. This reads the value that is actually compiled into the app.
    ///
    /// The host is load-bearing in a way no other string here is: it is the only route to
    /// an installed copy. Builds up to 0.18.1 carry baton.tonebox.io and poll it forever,
    /// which is why that hostname keeps serving the appcast even though new builds have
    /// moved. scripts/check-release.sh asserts the two hosts agree byte for byte.
    func testShippedFeedIsTheCurrentHostOverTLS() throws {
        let shipped = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                                    "SUFeedURL is missing from the built app's Info.plist")
        XCTAssertEqual(shipped, "https://batonmusic.app/appcast.xml")
        XCTAssertTrue(UpdateChannel.isConfigured(publicKey: key, feedURL: shipped, autoChecksEnabled: true))
    }
}
