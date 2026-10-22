import XCTest
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// Review follow-ups on the host transport (findings C1-8, C1-11, C1-17,
/// C1-18 and C1-23 of the 2026-10-21 full code review). Each test drives real
/// local files through the AVPlayer deck.
@MainActor
final class TransportFollowUpTests: XCTestCase {
    private let suiteName = "io.tonebox.tests.transportfollowup"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()
    private var dir: URL?

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        super.tearDown()
    }

    private func makeController() -> StreamingPlaybackController {
        let c = StreamingPlaybackController(streamURLProvider: { URL(string: $0)! }, defaults: suite, systemNowPlaying: false)
        c.gaplessEnabled = false
        c.crossfadeSeconds = 0
        c.setVolume(percent: 0)
        return c
    }

    /// Plain local tracks named by `ids`, each `seconds` long.
    private func tracks(_ ids: [String], seconds: Double = 12) throws -> [NavidromeSong] {
        let dir = self.dir ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("transport-\(UUID().uuidString)")
        self.dir = dir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try ids.enumerated().map { n, id in
            let url = dir.appendingPathComponent("\(id).wav")
            if !FileManager.default.fileExists(atPath: url.path) {
                try EngineTestSignals.sineWAV(frequency: 220 + 110 * Double(n), seconds: seconds).write(to: url)
            }
            return NavidromeSong(id: url.absoluteString, title: id, artist: "Artist", album: nil,
                                 duration: Int(seconds), coverArtID: nil)
        }
    }

    private func wait(_ seconds: Double, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    // MARK: - C1-17

    /// Pause during the backoff before a same-track retry. The pause cancels the retry, and
    /// used to leave the state at `.loading`, a spinner over a paused player for good.
    func testPauseDuringARetryBackoffShowsPausedAndResumeReloads() async throws {
        let c = makeController()
        defer { c.stop() }
        c.play(try tracks(["a", "b"]))
        try await wait(5) { c.duration > 1 }
        c.simulateLoadFailureForTesting()
        XCTAssertEqual(c.state, .loading, "precondition: waiting out the retry backoff")

        c.pause()
        XCTAssertEqual(c.state, .paused, "a paused player showed the loading spinner")
        try await Task.sleep(for: .milliseconds(1_300))   // past the first backoff
        XCTAssertEqual(c.state, .paused, "the cancelled retry started playback anyway")

        let loads = c.loadCurrentCountForTesting
        c.resume()
        XCTAssertEqual(c.loadCurrentCountForTesting, loads + 1, "Play after a failed load reloads the track")
        XCTAssertEqual(c.state, .playing)
        XCTAssertEqual(c.nowPlaying?.title, "a")
    }

    /// Play on a track whose load failed for good resumed the dead item and showed Playing
    /// over silence. It reloads the track instead.
    func testPlayFromAnErrorReloadsTheTrack() async throws {
        let c = makeController()
        defer { c.stop() }
        c.play(try tracks(["only"]))
        try await wait(5) { c.duration > 1 }
        c.simulateLoadFailureForTesting(afterEngineLadder: true)
        guard case .error = c.state else { return XCTFail("precondition: the track failed, got \(c.state)") }

        let loads = c.loadCurrentCountForTesting
        c.resume()
        XCTAssertEqual(c.loadCurrentCountForTesting, loads + 1, "Play resumed a failed item instead of reloading it")
        XCTAssertEqual(c.state, .playing)
    }

    // MARK: - C1-23

    /// Next while a retry is pending meant to play: the track it moves to plays too.
    func testNextDuringARetryBackoffPlaysTheNextTrack() async throws {
        let c = makeController()
        defer { c.stop() }
        c.play(try tracks(["a", "b", "c"]))
        try await wait(5) { c.duration > 1 }
        c.simulateLoadFailureForTesting()
        XCTAssertEqual(c.state, .loading, "precondition: waiting out the retry backoff")

        c.next()
        XCTAssertEqual(c.nowPlaying?.title, "b")
        XCTAssertEqual(c.state, .playing, "Next during a retry loaded the next track paused")
    }

    // MARK: - C1-8

    /// Play Next during a crossfade inserts after the outgoing track, so the index the blend
    /// was aimed at now holds the inserted song. The blend used to land on that index: the
    /// queue said the inserted song was playing while the blended-in track sounded.
    func testPlayNextDuringACrossfadeLandsOnTheTrackBeingBlendedIn() async throws {
        let c = makeController()
        defer { c.stop() }
        // A short first track to reach its blend quickly; long ones after it, so the blend into
        // b is not followed at once by another into c.
        let songs = try tracks(["a"], seconds: 4) + tracks(["b", "c"], seconds: 30)
        c.crossfadeSeconds = 1.5
        c.play(Array(songs.prefix(2)))
        try await wait(10) { c.isCrossfadingForTesting }
        XCTAssertTrue(c.isCrossfadingForTesting, "precondition: the blend into b began")

        c.playNext([songs[2]])
        try await wait(10) { !c.isCrossfadingForTesting }
        XCTAssertEqual(c.nowPlaying?.title, "b", "the queue named a track other than the one blended in")
        XCTAssertEqual(c.currentItemURLForTesting?.lastPathComponent, "b.wav")
        XCTAssertEqual(c.queue.map(\.title), ["a", "b", "c"], "the inserted song plays after b")
        XCTAssertEqual(c.currentIndex, 1)
    }

    // MARK: - C1-11 (the remainder)

    /// A seek during a spoken summary's duck bumped the transport generation, so the release
    /// was refused and the music stayed ducked for good. Only a volume change of the listener's
    /// own takes the level from the duck.
    func testASeekDuringADuckStillRestoresTheVolume() async throws {
        let c = makeController()
        defer { c.stop() }
        c.setVolume(percent: 70)
        c.play(try tracks(["a"]))
        try await wait(5) { c.duration > 1 }
        let token = c.acquireAudioFocusDuck(owner: "summary", toPercent: 20)
        XCTAssertEqual(c.volumePercent, 20, "precondition: ducked")

        c.seek(to: 5)
        XCTAssertTrue(c.releaseAudioFocus(token), "the release was refused after a seek")
        XCTAssertEqual(c.volumePercent, 70, "the volume stayed ducked after a seek")
    }

    func testAVolumeChangeDuringADuckStillWins() async throws {
        let c = makeController()
        defer { c.stop() }
        c.setVolume(percent: 70)
        c.play(try tracks(["a"]))
        try await wait(5) { c.duration > 1 }
        let token = c.acquireAudioFocusDuck(owner: "summary", toPercent: 20)
        c.setVolume(percent: 35)
        XCTAssertFalse(c.releaseAudioFocus(token))
        XCTAssertEqual(c.volumePercent, 35, "the listener's own level stands")
    }

    // MARK: - C1-18

    /// A shuffled queue restored at launch kept no order to return to, so turning shuffle off
    /// afterwards left the shuffled order in place.
    func testAShuffledQueueRestoredAtLaunchStillUnshufflesToItsOrder() async throws {
        let songs = try tracks((1...12).map { "t\($0)" }, seconds: 2)
        let before = makeController()
        before.play(songs)
        before.toggleShuffle()
        XCTAssertTrue(before.isShuffled)
        XCTAssertNotEqual(before.queue.map(\.title), songs.map(\.title), "precondition: the order changed")
        before.pause()
        before.persistQueueForTesting()
        before.stop()

        let after = makeController()
        after.restoreQueue()
        defer { after.stop() }
        XCTAssertTrue(after.isShuffled)
        let playing = after.nowPlaying?.title
        after.toggleShuffle()
        XCTAssertEqual(after.queue.map(\.title), songs.map(\.title), "shuffle off kept the shuffled order")
        XCTAssertEqual(after.nowPlaying?.title, playing, "and moved off the track that was playing")
    }

    // MARK: - C1-22

    /// A podcast enclosure goes to a third party. It was sent the listener's playlist as
    /// `playedFrom`; only our own server is told where a play came from.
    func testAnEnclosureIsFetchedExactlyAsTheFeedGaveIt() {
        let enclosure = "https://cdn.podcast.example/show/ep1.mp3?format=mp3&key=feed-token"
        let c = StreamingPlaybackController(
            streamURLProvider: { id in
                id.hasPrefix("https://") ? URL(string: id)! : URL(string: "https://music.example/rest/stream.view?id=\(id)&format=mp3")!
            },
            defaults: suite, systemNowPlaying: false)
        defer { c.stop() }
        c.setVolume(percent: 0)
        let source = StreamingPlaybackController.QueueSource(label: "Mine", kind: .playlist, id: "p-secret")
        c.play([NavidromeSong(id: enclosure, title: "Ep", artist: "Show", album: nil, duration: 60, coverArtID: nil)], source: source)
        XCTAssertEqual(c.lastStreamURLForTesting?.absoluteString, enclosure, "the enclosure URL was rewritten")

        var song = NavidromeSong(id: "lib-1", title: "Song", artist: "A", album: nil, duration: 60, coverArtID: nil)
        song.suffix = "opus"
        c.play([song], source: source)
        XCTAssertTrue(c.lastStreamURLForTesting?.query?.contains("playedFrom=playlist:p-secret") ?? false,
                      "our own server still hears where the play came from")
    }
}
