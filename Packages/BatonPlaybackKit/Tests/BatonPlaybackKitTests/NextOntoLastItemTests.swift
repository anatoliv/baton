import AVFoundation
import XCTest
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// Next onto the last item, then that item ends: playback stops. It must not play the last item
/// a second time.
///
/// Found on the iPhone by the walk, with a three-chapter book: Next onto chapter 3,
/// seek to 0:49, and at the end chapter 3 started again. The log showed `gapless preloaded next
/// → queue index 2` while chapter 2 played, then `gapless advance → queue index 2 (no reload)`
/// at the end: the look-ahead made for chapter 3 was still queued behind chapter 2 after Next
/// had already made chapter 3 the current item.
@MainActor
final class NextOntoLastItemTests: XCTestCase {
    private let suiteName = "io.tonebox.tests.nextontolast"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()

    /// Each item is its own real, seekable 20 s file, so the item the player holds can be told
    /// apart and a seek lands on that item instead of reloading. The ends are simulated.
    private var files: [String: URL] = [:]

    override func tearDown() {
        for url in files.values { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    private func makeController() -> StreamingPlaybackController {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tbx-10987-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (n, id) in ["ch1", "ch2", "ch3"].enumerated() {
            let url = dir.appendingPathComponent("\(id).wav")
            try? EngineTestSignals.sineWAV(frequency: 220 * Double(n + 1), seconds: 20).write(to: url)
            files[id] = url
        }
        let urls = files
        let c = StreamingPlaybackController(
            streamURLProvider: { id in urls[id]! },
            defaults: suite,
            systemNowPlaying: false
        )
        c.gaplessEnabled = true
        c.crossfadeSeconds = 0
        return c
    }

    private func chapters() -> [NavidromeSong] {
        ["ch1", "ch2", "ch3"].map {
            NavidromeSong(id: $0, title: $0, artist: "Reader", album: nil, duration: 20, coverArtID: nil)
        }
    }

    /// Play the second of three, so the third is preloaded, then press Next onto it.
    /// `settle` lets the second item load first, as it had on the iPhone, so that a seek lands
    /// on the loaded item rather than being turned into a reload.
    private func playSecondThenNext(settle: Bool = false) async throws -> StreamingPlaybackController {
        let c = makeController()
        c.play(chapters(), startAt: 1)
        if settle { try await Task.sleep(for: .milliseconds(600)) }
        XCTAssertEqual(c.gaplessPreloadIndexForTesting, 2, "precondition: the last item is preloaded behind the second")
        c.next()
        XCTAssertEqual(c.nowPlaying?.id, "ch3")
        return c
    }

    /// The look-ahead stood for the item Next just made current. Once that item is playing it is
    /// nobody's "next", and leaving it queued is what replayed the chapter.
    func testNextDropsAPreloadOfTheItemItMadeCurrent() async throws {
        let c = try await playSecondThenNext()
        defer { c.stop() }
        XCTAssertNil(c.gaplessPreloadIndexForTesting, "Next left the preload of the item now playing queued")
    }

    /// The card's case: queue three, play the second, Next onto the last, the last ends. Stop.
    func testTheLastItemEndingAfterNextStops() async throws {
        let c = try await playSecondThenNext()
        defer { c.stop() }
        // Let the skip blend settle the way it does on a device (promotion or readiness timeout).
        let deadline = Date().addingTimeInterval(8)
        while c.isCrossfadingForTesting, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(c.isCrossfadingForTesting, "the skip blend never finished")
        c.seek(to: 19.6) // an end only counts at the end
        c.simulateTrackEndedForTesting()
        XCTAssertEqual(c.state, .idle, "the end of the last item did not stop playback")
        XCTAssertEqual(c.gaplessAdvanceCountForTesting, 0, "the end of the last item advanced onto a preload")
        XCTAssertEqual(c.nowPlaying?.id, "ch3")
    }

    /// The walk's own steps: Next, then a seek at once, while the skip blend is still running.
    /// The seek interrupted the blend, which dropped the incoming item and left the outgoing one
    /// sounding with the stale preload behind it.
    func testASeekRightAfterNextStillStopsAtTheEndOfTheLastItem() async throws {
        let c = try await playSecondThenNext(settle: true)
        defer { c.stop() }
        c.seek(to: 19.6) // the walk sought to 0:49 of a 0:51 chapter
        XCTAssertEqual(c.currentItemURLForTesting?.lastPathComponent, "ch3.wav",
                       "the app says chapter 3; the player must hold chapter 3, not chapter 2")
        c.simulateTrackEndedForTesting()
        XCTAssertEqual(c.state, .idle, "the last item replayed after its end")
        XCTAssertEqual(c.gaplessAdvanceCountForTesting, 0, "the end advanced onto the stale preload of the item already playing")
        XCTAssertEqual(c.nowPlaying?.id, "ch3")
    }

    /// Pause and resume inside the blend interrupt it the same way a seek does.
    func testPauseAndResumeRightAfterNextStillStopsAtTheEnd() async throws {
        let c = try await playSecondThenNext(settle: true)
        defer { c.stop() }
        c.pause()
        c.resume()
        XCTAssertEqual(c.currentItemURLForTesting?.lastPathComponent, "ch3.wav")
        c.seek(to: 19.6)
        c.simulateTrackEndedForTesting()
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(c.gaplessAdvanceCountForTesting, 0)
    }

    /// The other half of the rule still holds: Next onto a middle item preloads the item after it,
    /// and that item's end is a gapless advance onto a *different* item.
    func testNextOntoAMiddleItemStillAdvancesGaplesslyToTheFollowingOne() async throws {
        let c = makeController()
        defer { c.stop() }
        c.play(chapters(), startAt: 0)
        c.next()
        XCTAssertEqual(c.nowPlaying?.id, "ch2")
        let deadline = Date().addingTimeInterval(8)
        while c.isCrossfadingForTesting, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(c.gaplessPreloadIndexForTesting, 2, "after the blend the following item is preloaded, never the one playing")
        c.seek(to: 19.6)
        c.simulateTrackEndedForTesting()
        XCTAssertEqual(c.nowPlaying?.id, "ch3")
        XCTAssertEqual(c.state, .playing)
        XCTAssertEqual(c.gaplessAdvanceCountForTesting, 1, "the boundary onto a different item is still gapless")
        c.seek(to: 19.6)
        c.simulateTrackEndedForTesting()
        XCTAssertEqual(c.state, .idle)
    }

    // MARK: - The track that is left

    /// Stream URLs a test can change while it runs: a later retry or a later track can then
    /// fail on purpose.
    private final class Streams {
        var byID: [String: URL] = [:]
        var unresolvable: Set<String> = []
    }

    private struct URLUnavailable: Error {}

    /// Three real 20 s files behind a provider the test controls, played silently.
    private func makeController(streams: Streams) -> StreamingPlaybackController {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tbx-1000000480-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (n, id) in ["ch1", "ch2", "ch3"].enumerated() {
            let url = dir.appendingPathComponent("\(id).wav")
            try? EngineTestSignals.sineWAV(frequency: 220 * Double(n + 1), seconds: 20).write(to: url)
            files[id] = url
            streams.byID[id] = url
        }
        let c = StreamingPlaybackController(
            streamURLProvider: { id in
                if streams.unresolvable.contains(id) { throw URLUnavailable() }
                return streams.byID[id]!
            },
            defaults: suite,
            systemNowPlaying: false
        )
        c.gaplessEnabled = false
        c.crossfadeSeconds = 0
        c.setVolume(percent: 0)
        return c
    }

    private func wait(_ seconds: Double, until condition: () -> Bool = { false }) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// C1-1: the play-event log is what the music friend's recent plays read, and it recorded
    /// nothing: it closed the outgoing track after the queue had already moved on.
    func testATrackListenedToThenSkippedIsRecordedAsAPlayEvent() async throws {
        let c = makeController(streams: Streams())
        defer { c.stop() }
        c.play(chapters(), startAt: 0)
        await wait(8) { c.currentTime >= 2.5 }
        XCTAssertGreaterThanOrEqual(c.currentTime, 2.5, "precondition: the first item played")
        c.next()
        await wait(1)
        let events = c.playbackEvents.events
        XCTAssertEqual(events.count, 1, "2.5 s of listening and then Next recorded no play event")
        XCTAssertEqual(events.first?.songID, "ch1", "the event must name the track that was left")
        XCTAssertEqual(events.first?.reason, .skipped)
        XCTAssertGreaterThanOrEqual(events.first?.listenedSeconds ?? 0, 2)
    }

    /// C1-3: a retry parks the playhead to restore it once the item is ready. When the retry
    /// fails too and the listener moves on, the next track must not start at the old place.
    func testANewTrackDoesNotInheritAFailedRetrysPosition() async throws {
        let streams = Streams()
        let c = makeController(streams: streams)
        defer { c.stop() }
        c.play(chapters(), startAt: 0)
        await wait(8) { c.currentTime >= 3.2 }
        XCTAssertGreaterThanOrEqual(c.currentTime, 3.2, "precondition: the first item played")
        streams.byID["ch1"] = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID().uuidString).wav")
        c.simulateLoadFailureForTesting()
        await wait(1.6) // the first retry, a second later, parks the place and loads the missing file
        c.next()
        await wait(3) { c.nowPlaying?.id == "ch2" && c.duration > 1 }
        await wait(1.5)
        XCTAssertEqual(c.nowPlaying?.id, "ch2")
        XCTAssertLessThan(c.currentTime, 2.0, "the next track started at the failed track's position")
    }

    /// C1-10: when the next track's stream URL cannot be made (offline, not downloaded), the
    /// track that was playing must not go on sounding under the new track's name.
    func testANextTrackWhoseURLFailsSilencesTheOutgoingTrack() async throws {
        let streams = Streams()
        let c = makeController(streams: streams)
        defer { c.stop() }
        c.play(chapters(), startAt: 0)
        await wait(8) { c.currentTime >= 0.5 }
        XCTAssertEqual(c.currentItemURLForTesting?.lastPathComponent, "ch1.wav", "precondition: the first item is loaded")
        streams.unresolvable = ["ch2"]
        c.next()
        XCTAssertEqual(c.nowPlaying?.id, "ch2")
        XCTAssertNotEqual(c.state, .playing, "a track with no stream reads as playing")
        XCTAssertNil(c.currentItemURLForTesting, "the outgoing track is still loaded under the new track's name")
        // And the failure takes the ordinary path: the queue moves on to a track that can play.
        await wait(12) { c.nowPlaying?.id == "ch3" }
        XCTAssertEqual(c.nowPlaying?.id, "ch3", "a track whose URL failed did not skip on")
    }
}
