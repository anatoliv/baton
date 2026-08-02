import AVFoundation
import XCTest
@testable import Baton

/// Controller-level coverage for seeking a stream the server can't seek — the wiring around
/// `StreamSeek`, which the pure tests in `StreamSeekTests` deliberately don't reach.
///
/// The reported bug: clicking the playbar partway into a long set skipped to the next track.
/// Navidrome serves a transcode as it encodes it, so until encoding finishes the stream reports
/// `Accept-Ranges: none` and an AVPlayer seek past the buffer makes the item report end-of-stream
/// — which `handleEnded()` treated as the track finishing.
///
/// **Why this file exists separately from the existing end-of-track tests:** those pass a fixture
/// song with `duration: nil`, so every end is "at the end" of a zero-length track and the guard is
/// never exercised. A regression here would have been invisible to them.
@MainActor
final class StreamSeekControllerTests: XCTestCase {
    private let suiteName = "io.tonebox.tests.streamseek"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()

    /// Mirrors the shape of a real Navidrome stream URL so the `StreamSeek` rewrite has query
    /// items to act on, while staying a local URL that never touches the network.
    private func makeController() -> StreamingPlaybackController {
        StreamingPlaybackController(
            streamURLProvider: { URL(string: "file:///dev/null?id=\($0)&format=mp3")! },
            defaults: suite,
            systemNowPlaying: false
        )
    }

    /// A 75-minute Opus set — the case that fails. Long enough that the server is still encoding
    /// it well after playback starts.
    private func longSet(_ id: String) -> NavidromeSong {
        var s = NavidromeSong(id: id, title: "Set \(id)", artist: "Artist", album: nil,
                              duration: 4524, coverArtID: nil)
        s.suffix = "opus"
        return s
    }

    private func mp3Track(_ id: String) -> NavidromeSong {
        var s = NavidromeSong(id: id, title: "Track \(id)", artist: "Artist", album: nil,
                              duration: 240, coverArtID: nil)
        s.suffix = "mp3"
        return s
    }

    // MARK: - The bug

    func testEndReportedPartwayThroughALongSetDoesNotSkipTheTrack() {
        let c = makeController()
        c.play([longSet("a"), longSet("b")])
        c.seek(to: 2400) // 40 minutes into a 75-minute set
        XCTAssertEqual(c.currentTime, 2400, accuracy: 2)

        c.simulateTrackEndedForTesting() // the unseekable stream reports EOF

        XCTAssertEqual(c.nowPlaying?.id, "a",
                       "an end reported 40 min into a 75 min track must not advance the queue")
    }

    func testSeekingIntoAnUnreachablePositionRequestsTheStreamFromThere() {
        let c = makeController()
        c.play([longSet("a")])
        c.seek(to: 2400)

        // No seekable range covers 2400 s, so the only way to get there is to re-request.
        XCTAssertTrue(c.lastStreamURLForTesting?.absoluteString.contains("timeOffset=2400") == true,
                      "expected a timeOffset re-request, got \(c.lastStreamURLForTesting?.absoluteString ?? "nil")")
        XCTAssertEqual(c.streamStartOffsetForTesting, 2400, accuracy: 1)
    }

    func testPlayheadStaysTrackLogicalAcrossAnOffsetStream() {
        // The offset stream's own clock restarts at zero. If the controller reported that
        // directly, the scrubber would snap back to the start and every later seek would be
        // computed against the wrong origin.
        let c = makeController()
        c.play([longSet("a")])
        c.seek(to: 2400)
        XCTAssertEqual(c.currentTime, 2400, accuracy: 2)
        XCTAssertEqual(c.duration, 4524, accuracy: 1, "the logical track length must not shrink")
    }

    // MARK: - The guard must not break real endings

    func testEndAtTheActualEndStillAdvances() {
        let c = makeController()
        c.play([longSet("a"), longSet("b")])
        c.seek(to: 4524)
        c.simulateTrackEndedForTesting()
        XCTAssertEqual(c.nowPlaying?.id, "b", "a genuine end must still advance")
    }

    func testRepeatedEarlyEndsEventuallyGiveUpAndAdvance() {
        // A genuinely truncated or unreadable file also ends early. Refusing forever would wedge
        // the queue on it, which is worse than the bug being guarded against.
        let c = makeController()
        c.play([longSet("a"), longSet("b")])
        c.seek(to: 2400)
        for _ in 0...StreamingPlaybackController.maxSpuriousEndRecoveries {
            c.simulateTrackEndedForTesting()
        }
        XCTAssertEqual(c.nowPlaying?.id, "b",
                       "recovery must be bounded — a truly broken stream has to move on")
    }

    func testEverySeekGetsAFreshRecoveryBudget() {
        // The 0.11.3 regression, straight from the live log: four seeks into one long set within
        // eight seconds. Each of the first three correctly refused a spurious end — which used up
        // a per-track budget of 3 — so the fourth seek skipped the track. A seek is a fresh
        // intent, not a retry of the previous one.
        let c = makeController()
        c.play([longSet("a"), longSet("b")])
        for target in [704.0, 1527, 3591, 4000] {
            c.seek(to: target)
            c.simulateTrackEndedForTesting()
            XCTAssertEqual(c.nowPlaying?.id, "a",
                           "seek to \(target)s skipped the track")
        }
    }

    func testAStuckStreamIsStillBounded() {
        // The bound must survive the reset above: repeated early ends with NO new seek between
        // them still have to give up, or a genuinely truncated file wedges the queue.
        let c = makeController()
        c.play([longSet("a"), longSet("b")])
        c.seek(to: 2400)
        for _ in 0...StreamingPlaybackController.maxSpuriousEndRecoveries {
            c.simulateTrackEndedForTesting()
        }
        XCTAssertEqual(c.nowPlaying?.id, "b")
    }

    func testSeekingDoesNotChangeTheTrackLength() {
        // A scrubber that rescales under the listener sends the next click somewhere they didn't
        // aim at. Observed live: 4831s → 5502s → 6325s across three seeks.
        let c = makeController()
        c.play([longSet("a")])
        for target in [704.0, 1527, 3591] {
            c.seek(to: target)
            XCTAssertEqual(c.duration, 4524, accuracy: 1,
                           "seeking to \(target)s changed the reported track length")
        }
    }

    func testANewTrackGetsAFreshRecoveryBudget() {
        let c = makeController()
        c.play([longSet("a"), longSet("b")])
        c.seek(to: 2400)
        for _ in 0...StreamingPlaybackController.maxSpuriousEndRecoveries {
            c.simulateTrackEndedForTesting()
        }
        XCTAssertEqual(c.nowPlaying?.id, "b")
        // "b" is a different track; its own early end must be refused, not inherit "a"'s budget.
        c.seek(to: 2400)
        c.simulateTrackEndedForTesting()
        XCTAssertEqual(c.nowPlaying?.id, "b")
    }

    // MARK: - Skipping the transcode where it isn't needed

    func testNativeFormatStreamsWithoutTheTranscode() {
        // 28% of this library is MP3. Streaming it as stored makes it byte-range seekable from
        // the first play, so it never enters the failure window at all.
        let c = makeController()
        c.play([mp3Track("m")])
        XCTAssertFalse(c.lastStreamURLForTesting?.absoluteString.contains("format=") == true,
                       "an MP3 must stream as stored, not through the transcoder")
    }

    func testOpusStillTranscodes() {
        // AVFoundation can't decode Opus, and the failure is silence rather than an error.
        let c = makeController()
        c.play([longSet("a")])
        XCTAssertTrue(c.lastStreamURLForTesting?.absoluteString.contains("format=mp3") == true)
    }

    // MARK: - Resume

    func testRestoreResumesByRequestingTheStreamFromTheSavedPosition() {
        let c = makeController()
        c.play([longSet("a")])
        c.seek(to: 3000)
        c.persistQueueForTesting()

        let restored = makeController()
        restored.restoreQueue()

        XCTAssertEqual(restored.nowPlaying?.id, "a")
        XCTAssertEqual(restored.state, .paused, "restore must never auto-play")
        XCTAssertTrue(restored.lastStreamURLForTesting?.absoluteString.contains("timeOffset=3000") == true,
                      "a long set must resume from the saved position, which a cold transcode "
                      + "cannot be seeked to — got \(restored.lastStreamURLForTesting?.absoluteString ?? "nil")")
    }
}
