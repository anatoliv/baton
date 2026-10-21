import XCTest
@testable import BatonPlaybackKit

/// `<itunes:duration>` comes from whoever wrote the feed. A value that doesn't fit is no
/// duration, not a crash on every refresh of that feed.
final class PodcastFeedDurationTests: XCTestCase {
    func testOrdinaryDurationsAreUnchanged() {
        XCTAssertEqual(PodcastFeedParser.parseDuration("1830"), 1830)
        XCTAssertEqual(PodcastFeedParser.parseDuration("30:30"), 1830)
        XCTAssertEqual(PodcastFeedParser.parseDuration(" 1:02:03 "), 3723)
        XCTAssertNil(PodcastFeedParser.parseDuration(""))
        XCTAssertNil(PodcastFeedParser.parseDuration("about an hour"))
    }

    func testADurationTooLargeForAnIntIsNoDuration() {
        XCTAssertNil(PodcastFeedParser.parseDuration("1:1:1:1:1:1:1:1:1:1:1:1"))
        XCTAssertNil(PodcastFeedParser.parseDuration("9223372036854775807:00"))
        XCTAssertNil(PodcastFeedParser.parseDuration("153722867280912930:08"))
    }
}
