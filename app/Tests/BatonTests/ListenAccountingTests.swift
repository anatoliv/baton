import XCTest
@testable import Baton

/// Covers the two signals the listening pipeline could not previously get.
///
/// **Why they were needed.** The pipeline derived "did you listen to this" from the server's
/// access log, as `min(1.0, bytes_sent / file_size)`, and forced it to `1.0` whenever a scrobble
/// had been submitted. Baton scrobbles after `min(duration/2, 240)` seconds, so **four minutes of
/// a seventy-five minute set recorded as a complete listen** — and every long-form playlist
/// scored ✓ POSITIVE at average completion 1.00, by construction rather than by observation.
///
/// Two things were invisible from the server side and both are fixed here: a prefetch downloads a
/// whole track nobody has heard, and only the client knows how much actually played.
final class ListenAccountingTests: XCTestCase {

    // MARK: - Telling a prefetch from a play

    private let stream = URL(string: "https://n.example/rest/stream.view?id=abc&format=mp3&playedFrom=playlist:x")!

    func testPrefetchIsMarked() {
        let url = StreamingPlaybackController.markPrefetch(stream)
        XCTAssertTrue(url.absoluteString.contains("prefetch=1"), url.absoluteString)
    }

    func testMarkingAPrefetchKeepsEverythingElse() {
        // Provenance must survive: it is how a play is attributed to a playlist at all.
        let url = StreamingPlaybackController.markPrefetch(stream)
        XCTAssertTrue(url.absoluteString.contains("playedFrom=playlist:x"))
        XCTAssertTrue(url.absoluteString.contains("id=abc"))
        XCTAssertTrue(url.absoluteString.contains("format=mp3"))
    }

    func testMarkingIsIdempotent() {
        // Re-marking must not accumulate duplicates — Subsonic reads the first occurrence, so a
        // second one is silently ignored and the log line becomes ambiguous.
        let once = StreamingPlaybackController.markPrefetch(stream)
        let twice = StreamingPlaybackController.markPrefetch(once)
        XCTAssertEqual(twice.absoluteString.components(separatedBy: "prefetch=").count - 1, 1)
    }

    func testAPlayIsNotMarked() {
        // The distinction only works if ordinary playback stays unmarked.
        XCTAssertFalse(stream.absoluteString.contains("prefetch"))
    }

    // MARK: - Measuring what actually played

    private let suiteName = "io.tonebox.tests.listenaccounting"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()

    @MainActor
    private func makeController() -> StreamingPlaybackController {
        StreamingPlaybackController(
            streamURLProvider: { URL(string: "file:///dev/null?id=\($0)")! },
            defaults: suite,
            systemNowPlaying: false
        )
    }

    @MainActor
    private func longSet(_ id: String) -> NavidromeSong {
        NavidromeSong(id: id, title: "Set \(id)", artist: "A", album: nil,
                      duration: 4524, coverArtID: nil)
    }

    @MainActor
    func testLeavingATrackReportsWhatPlayed() {
        let c = makeController()
        var reports: [(String, TimeInterval, TimeInterval)] = []
        c.onListenFinished = { song, listened, duration in reports.append((song.id, listened, duration)) }

        c.play([longSet("a"), longSet("b")])
        c.accumulateListeningForTesting(240) // four minutes — exactly the scrobble threshold
        c.next()

        XCTAssertEqual(reports.count, 1, "leaving a track must report the listen")
        XCTAssertEqual(reports.first?.0, "a")
        XCTAssertEqual(reports.first?.1 ?? 0, 240, accuracy: 1)
        XCTAssertEqual(reports.first?.2 ?? 0, 4524, accuracy: 1,
                       "the report must carry the track's length, or the ratio can't be computed")
    }

    @MainActor
    func testTheReportIsNotAClaimOfCompletion() {
        // The whole point. Four minutes of a 75-minute set is 5%, not 100% — the old pipeline
        // recorded exactly this case as a complete listen.
        let c = makeController()
        var ratio: Double?
        c.onListenFinished = { _, listened, duration in ratio = listened / duration }
        c.play([longSet("a"), longSet("b")])
        c.accumulateListeningForTesting(240)
        c.next()
        XCTAssertNotNil(ratio)
        XCTAssertLessThan(ratio ?? 1, 0.10, "a four-minute listen must not read as complete")
    }

    @MainActor
    func testATrackNeverPlayedIsNotReported() {
        // Skipping straight past a track must leave no trace — a report of zero would still be
        // counted as a play by anything downstream.
        let c = makeController()
        var reports = 0
        c.onListenFinished = { _, _, _ in reports += 1 }
        c.play([longSet("a"), longSet("b")])
        c.next()
        XCTAssertEqual(reports, 0)
    }

    @MainActor
    func testSeekingIsNotListening() {
        // Jumping forward 30 minutes doesn't listen to the 30 minutes it skipped. Only real
        // playback counts, or a few clicks on the playbar would "listen" to a whole set.
        let c = makeController()
        var listened: TimeInterval?
        c.onListenFinished = { _, seconds, _ in listened = seconds }
        c.play([longSet("a"), longSet("b")])
        c.accumulateListeningForTesting(30)
        c.seek(to: 1800)
        c.accumulateListeningForTesting(30)
        c.next()
        XCTAssertEqual(listened ?? 0, 60, accuracy: 2, "the seek was counted as listening")
    }
}
