import XCTest
@testable import BatonPlaybackKit

/// The out-of-band MIME hint that lets AVFoundation *inspect* a Subsonic stream.
///
/// Without it, `loadTracks` fails ("Cannot Open") on extension-less stream URLs while
/// playback works — so the audio tap, and with it the equalizer and the level meter,
/// silently never attached to streamed audio. The hint must be exact: it is only ever
/// offered for URLs we built ourselves with `format=mp3`, where the payload is MPEG by
/// construction. A wrong hint doesn't break an indicator — it breaks playback.
@MainActor
final class StreamMimeHintTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

    func testOurStreamRequestGetsTheHint() {
        let stream = url("https://demo.example/rest/stream.view?id=123&format=mp3&u=x&t=y&s=z")
        XCTAssertEqual(StreamingPlaybackController.mimeHint(for: stream), "audio/mpeg")
    }

    /// The seek transform appends a timeOffset to the same URL — the hint must survive it.
    func testASeekOffsetURLKeepsTheHint() {
        let seeked = url("https://demo.example/rest/stream.view?id=123&format=mp3&timeOffset=93")
        XCTAssertEqual(StreamingPlaybackController.mimeHint(for: seeked), "audio/mpeg")
    }

    /// A podcast enclosure is someone else's file in someone else's format. Guessing MP3
    /// for an AAC feed would break playback of that episode — never hint.
    func testAPodcastEnclosureGetsNoHint() {
        XCTAssertNil(StreamingPlaybackController.mimeHint(for: url("https://cdn.podcast.example/ep/412.m4a")))
        XCTAssertNil(StreamingPlaybackController.mimeHint(for: url("https://cdn.podcast.example/audio.mp3?token=abc")))
    }

    /// `format=raw` asks for the original file — could be FLAC, Ogg, anything. No hint.
    func testARawFormatRequestGetsNoHint() {
        XCTAssertNil(StreamingPlaybackController.mimeHint(for: url("https://demo.example/rest/stream.view?id=1&format=raw")))
    }

    func testALocalFileGetsNoHint() {
        XCTAssertNil(StreamingPlaybackController.mimeHint(for: URL(fileURLWithPath: "/tmp/x.flac")))
    }
}
