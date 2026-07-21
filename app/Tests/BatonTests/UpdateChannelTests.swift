import XCTest
@testable import Baton

/// W-09: the update-channel liveness gate must be precise. A placeholder/empty key,
/// an http (non-TLS) feed, or a hostless URL is "not configured"; only a real https
/// channel with automatic checks enabled counts as live.
final class UpdateChannelTests: XCTestCase {
    private let key = "pDgN5Ibe6Q9QY5cxRpXmXLm/S2lBGbVLy/eBVEW1nTo="
    private let feed = "https://baton.tonebox.io/appcast.xml"

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
        XCTAssertFalse(UpdateChannel.isConfigured(publicKey: key, feedURL: "http://baton.tonebox.io/appcast.xml", autoChecksEnabled: true))
    }
    func testHostlessOrEmptyFeedNotConfigured() {
        XCTAssertFalse(UpdateChannel.isConfigured(publicKey: key, feedURL: "https://", autoChecksEnabled: true))
        XCTAssertFalse(UpdateChannel.isConfigured(publicKey: key, feedURL: "", autoChecksEnabled: true))
    }
    func testAutoChecksOffNotConfigured() {
        XCTAssertFalse(UpdateChannel.isConfigured(publicKey: key, feedURL: feed, autoChecksEnabled: false))
    }
}
