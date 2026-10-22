import XCTest
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// Which streams honour Subsonic `timeOffset`. The table in
/// `StreamSeek.honoursTimeOffset` was measured against demo.navidrome.org; these pin it.
@MainActor
final class StreamTimeOffsetSupportTests: XCTestCase {
    private func song(_ id: String = "lib-1", suffix: String? = nil, bitRate: Int? = nil) -> NavidromeSong {
        var s = NavidromeSong(id: id, title: "t", artist: "a", album: nil, duration: 200, coverArtID: nil)
        s.suffix = suffix
        s.bitRate = bitRate
        return s
    }

    private func honours(_ raw: String, _ song: NavidromeSong) -> Bool {
        StreamSeek.honoursTimeOffset(URL(string: raw)!, for: song)
    }

    func testOnlyAServerTranscodeHonoursTimeOffset() {
        let server = "https://music.example/rest/stream.view?id=lib-1"
        XCTAssertTrue(honours(server + "&format=mp3", song(suffix: "opus")), "an Opus file transcoded to MP3")
        XCTAssertTrue(honours(server + "&format=mp3", song(suffix: nil)), "an unknown format transcoded to MP3")
        XCTAssertFalse(honours(server, song(suffix: "mp3", bitRate: 320)), "a stored MP3 served as it is")
        XCTAssertFalse(honours(server + "&format=raw", song(suffix: "flac")), "format=raw is the stored file")
        XCTAssertFalse(honours(server + "&format=mp3", song(suffix: "mp3", bitRate: 320)),
                       "an MP3 asked for as MP3 with no cap is the stored file")
    }

    func testABitrateCapTranscodesOnlyAFileAboveIt() {
        let capped = "https://music.example/rest/stream.view?id=lib-1&maxBitRate=128"
        XCTAssertTrue(honours(capped, song(suffix: "mp3", bitRate: 320)), "320 kbps under a 128 cap is re-encoded")
        XCTAssertFalse(honours(capped, song(suffix: "mp3", bitRate: 128)), "a file at the cap is served as it is")
        XCTAssertTrue(honours(capped, song(suffix: "mp3", bitRate: nil)), "an unknown bitrate is taken as over the cap")
        XCTAssertTrue(honours(capped + "&format=mp3", song(suffix: "mp3", bitRate: 320)))
    }

    func testFilesAndPodcastEnclosuresNeverHonourIt() {
        XCTAssertFalse(honours("file:///Users/x/Music/a.mp3?format=mp3", song(suffix: "opus")),
                       "a download of a library track is a file")
        let enclosure = "https://cdn.podcast.example/ep.mp3?format=mp3"
        XCTAssertFalse(honours(enclosure, song(enclosure)), "a podcast enclosure has no Subsonic server")
        let chapter = "file:///tmp/book/ch1.m4a"
        XCTAssertFalse(honours(chapter, song(chapter)))
    }

    /// A seek the item cannot reach would ask the host to re-request the stream. For a stream
    /// that ignores `timeOffset` that is the same bytes from the top, and from the host's
    /// open-at-0-then-seek path it would ask again each time it became ready.
    func testTheDeckNeverAsksToReRequestAStreamThatIgnoresTimeOffset() {
        let deck = AVPlayerDeck()
        var reloads: [TimeInterval] = []
        deck.onReloadStream = { reloads.append($0) }
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("absent-\(UUID().uuidString).mp3")
        deck.load(song: song(missing.absoluteString), url: missing, startingAt: 0, autoplay: false,
                  headers: [:], supportsTimeOffset: false)
        deck.seek(to: 120)   // nothing loaded, so nothing is seekable
        XCTAssertEqual(reloads, [], "a file was asked to be re-requested from 120 s")

        let stream = URL(string: "http://127.0.0.1:9/rest/stream.view?id=lib-1&format=mp3")!
        deck.load(song: song(suffix: "opus"), url: stream, startingAt: 0, autoplay: false,
                  headers: [:], supportsTimeOffset: true)
        deck.seek(to: 120)
        XCTAssertEqual(reloads, [120], "a transcode still reaches an unbuffered place by re-requesting")
        deck.clear()
    }

    func testTheDeckOpensAStreamThatIgnoresTimeOffsetAtItsTopUnchanged() {
        let deck = AVPlayerDeck()
        let enclosure = URL(string: "https://cdn.podcast.example/ep.mp3?format=mp3&utm=x")!
        deck.load(song: song(enclosure.absoluteString), url: enclosure, startingAt: 30, autoplay: false,
                  headers: [:], supportsTimeOffset: false)
        XCTAssertEqual(deck.lastLoadedURL, enclosure, "the enclosure is fetched exactly as the feed gave it")
        XCTAssertEqual(deck.streamStartOffset, 0, "and its clock is its own")
        deck.clear()
    }
}
