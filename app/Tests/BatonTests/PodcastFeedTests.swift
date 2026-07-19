import XCTest
@testable import Baton

/// Coverage for the client-side podcast engine: RSS feed parsing, the subscription store
/// (subscribe / unsubscribe / refresh / persistence), and episode→song mapping for playback.
final class PodcastFeedTests: XCTestCase {
    // MARK: - Feed parsing

    private let sampleFeed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
      <channel>
        <title>The Daily</title>
        <description>News, five days a week.</description>
        <itunes:image href="https://cdn.example/daily.jpg"/>
        <item>
          <title>Monday</title>
          <description><![CDATA[<p>Big <b>news</b> today.</p>]]></description>
          <pubDate>Mon, 13 Jul 2026 09:00:00 GMT</pubDate>
          <itunes:duration>30:30</itunes:duration>
          <guid>guid-mon</guid>
          <enclosure url="https://cdn.example/mon.mp3" length="1" type="audio/mpeg"/>
        </item>
        <item>
          <title>Tuesday</title>
          <itunes:summary>Follow-up.</itunes:summary>
          <pubDate>Tue, 14 Jul 2026 09:00:00 GMT</pubDate>
          <itunes:duration>1830</itunes:duration>
          <itunes:image href="https://cdn.example/tue.jpg"/>
          <enclosure url="https://cdn.example/tue.mp3" type="audio/mpeg"/>
        </item>
        <item>
          <title>No audio (dropped)</title>
          <pubDate>Wed, 15 Jul 2026 09:00:00 GMT</pubDate>
        </item>
      </channel>
    </rss>
    """

    func testParsesChannelAndEpisodes() throws {
        let feed = try PodcastFeedParser.parse(Data(sampleFeed.utf8))
        XCTAssertEqual(feed.title, "The Daily")
        XCTAssertEqual(feed.description, "News, five days a week.")
        XCTAssertEqual(feed.imageURL, URL(string: "https://cdn.example/daily.jpg"))

        // The item without an <enclosure> is dropped; the rest sort newest-first.
        XCTAssertEqual(feed.episodes.count, 2)
        XCTAssertEqual(feed.episodes[0].title, "Tuesday")
        XCTAssertEqual(feed.episodes[1].title, "Monday")

        let monday = feed.episodes[1]
        XCTAssertEqual(monday.id, "guid-mon")
        XCTAssertEqual(monday.enclosureURL, URL(string: "https://cdn.example/mon.mp3"))
        XCTAssertEqual(monday.duration, 30 * 60 + 30) // "30:30" → 1830s
        XCTAssertEqual(monday.description, "Big news today.") // CDATA + tags stripped

        let tuesday = feed.episodes[0]
        XCTAssertEqual(tuesday.duration, 1830) // bare seconds
        XCTAssertEqual(tuesday.description, "Follow-up.") // itunes:summary fallback
        XCTAssertEqual(tuesday.imageURL, URL(string: "https://cdn.example/tue.jpg"))
        // No <guid> → identity falls back to the enclosure URL.
        XCTAssertEqual(tuesday.id, "https://cdn.example/tue.mp3")
    }

    func testDurationAndURLHelpers() {
        XCTAssertEqual(PodcastFeedParser.parseDuration("1:02:03"), 3723)
        XCTAssertEqual(PodcastFeedParser.parseDuration("90"), 90)
        XCTAssertNil(PodcastFeedParser.parseDuration("abc"))
        XCTAssertNil(PodcastFeedParser.parseDuration(""))
        // Only http(s) enclosure/image URLs are accepted.
        XCTAssertNil(PodcastFeedParser.cleanURL("mailto:x@y.com"))
        XCTAssertEqual(PodcastFeedParser.cleanURL(" https://a.com/f.mp3 "), URL(string: "https://a.com/f.mp3"))
    }

    func testNonFeedThrows() {
        XCTAssertThrowsError(try PodcastFeedParser.parse(Data("not xml at all <".utf8)))
        // Valid XML but no <channel> is still not a feed.
        XCTAssertThrowsError(try PodcastFeedParser.parse(Data("<rss><nope/></rss>".utf8)))
    }

    // MARK: - Subscription store

    @MainActor
    func testSubscribePersistsAndMapsToSong() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let feedURL = URL(string: "https://example.com/daily.xml")!
        let feedData = Data(sampleFeed.utf8)

        let store = PodcastSubscriptionStore(directory: dir, fetch: { _ in feedData })
        let channel = try await store.subscribe(to: feedURL)
        XCTAssertEqual(channel.title, "The Daily")
        XCTAssertEqual(store.channels.count, 1)
        XCTAssertEqual(channel.id, feedURL.absoluteString) // identity = feed URL

        // Episode → song: id is the enclosure URL (what the player streams directly); art
        // rides along as a direct URL so the players show the show cover.
        let song = channel.episodes[1].asSong(channelTitle: channel.title, artwork: channel.imageURL)
        XCTAssertEqual(song.id, "https://cdn.example/mon.mp3")
        XCTAssertEqual(song.artist, "The Daily")
        XCTAssertNil(song.coverArtID)
        XCTAssertEqual(song.artworkURL, channel.imageURL)
        // displayArtworkURL prefers the direct URL and never calls the Subsonic resolver.
        XCTAssertEqual(song.displayArtworkURL(size: 96) { _, _ in URL(string: "https://wrong") }, channel.imageURL)

        // A fresh store over the same directory reads the persisted subscription (fetch here
        // returns the same feed for the background refresh loadIfNeeded kicks off).
        let reborn = PodcastSubscriptionStore(directory: dir, fetch: { _ in feedData })
        await reborn.loadIfNeeded()
        XCTAssertEqual(reborn.channels.map(\.id), [feedURL.absoluteString])
    }

    @MainActor
    func testSubscribeIsIdempotentAndUnsubscribeRemoves() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let feedURL = URL(string: "https://example.com/daily.xml")!
        let store = PodcastSubscriptionStore(directory: dir, fetch: { _ in Data(self.sampleFeed.utf8) })

        _ = try await store.subscribe(to: feedURL)
        _ = try await store.subscribe(to: feedURL) // same feed again
        XCTAssertEqual(store.channels.count, 1, "re-subscribing updates in place, no duplicate")

        store.unsubscribe(store.channels[0])
        XCTAssertTrue(store.channels.isEmpty)
    }

    @MainActor
    func testSubscribeToBadFeedThrowsAndReportsError() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PodcastSubscriptionStore(directory: dir, fetch: { _ in Data("<html>nope</html>".utf8) })
        do {
            _ = try await store.subscribe(to: URL(string: "https://example.com/bad")!)
            XCTFail("expected a parse error")
        } catch {
            XCTAssertTrue(store.channels.isEmpty)
            XCTAssertNotNil(store.lastError)
        }
    }

    // MARK: - Playback resolution

    @MainActor
    func testResolveStreamURLPassesThroughEnclosureURLs() throws {
        // An absolute http(s) id (a podcast enclosure) resolves straight to itself — no server.
        let url = try StreamingPlaybackController.resolveStreamURL(songID: "https://cdn.example/ep.mp3")
        XCTAssertEqual(url, URL(string: "https://cdn.example/ep.mp3"))
    }
}
