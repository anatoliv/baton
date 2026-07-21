import AVFoundation
import XCTest
@testable import Baton

/// State-machine coverage for `StreamingPlaybackController` — queue navigation,
/// next-past-end, volume clamping, capture suspend/resume, and queue persistence.
/// No real streaming: an injected URL provider returns a throwaway file URL, and
/// the controller sets its transport state synchronously.
@MainActor
final class StreamingPlaybackControllerTests: XCTestCase {
    /// Isolated persistence store — a fresh XCTestCase instance is created per test
    /// method, so this lazily clears + provides a clean suite per test, and nothing
    /// ever touches the real app's `.standard` domain.
    private let suiteName = "io.tonebox.tests.streamingplayback"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()

    private func makeController() -> StreamingPlaybackController {
        StreamingPlaybackController(
            streamURLProvider: { _ in URL(string: "file:///dev/null")! },
            defaults: suite,
            systemNowPlaying: false
        )
    }

    private func song(_ id: String) -> NavidromeSong {
        NavidromeSong(id: id, title: "Song \(id)", artist: "Artist", album: nil, duration: nil, coverArtID: nil)
    }

    func testPlaySetsQueueAndNowPlaying() {
        let c = makeController()
        c.play([song("a"), song("b")])
        XCTAssertEqual(c.state, .playing)
        XCTAssertEqual(c.nowPlaying?.id, "a")
        XCTAssertEqual(c.queue.count, 2)
    }

    func testNextAdvancesAndStopsPastEnd() {
        let c = makeController()
        c.play([song("a"), song("b")])
        c.next()
        XCTAssertEqual(c.nowPlaying?.id, "b")
        XCTAssertEqual(c.state, .playing)
        c.next() // past the end
        XCTAssertEqual(c.state, .idle)
    }

    func testPreviousGoesBackWhenEarlyInTrack() {
        let c = makeController()
        c.play([song("a"), song("b"), song("c")], startAt: 1)
        XCTAssertEqual(c.nowPlaying?.id, "b")
        c.previous() // currentTime 0, index 1 → previous track
        XCTAssertEqual(c.nowPlaying?.id, "a")
    }

    func testPreviousAtStartRestartsCurrent() {
        let c = makeController()
        c.play([song("a"), song("b")])
        c.previous() // index 0 → restart, stay on a
        XCTAssertEqual(c.nowPlaying?.id, "a")
        XCTAssertEqual(c.currentIndex, 0)
    }

    func testEnqueueOnEmptyStartsPlayback() {
        let c = makeController()
        c.enqueue([song("x")])
        XCTAssertEqual(c.state, .playing)
        XCTAssertEqual(c.nowPlaying?.id, "x")
    }

    func testEnqueueWhilePlayingAppendsOnly() {
        let c = makeController()
        c.play([song("a")])
        c.enqueue([song("b")])
        XCTAssertEqual(c.queue.map(\.id), ["a", "b"])
        XCTAssertEqual(c.nowPlaying?.id, "a") // didn't jump
    }

    func testPlayNextInsertsAfterCurrentNotAtEnd() {
        let c = makeController()
        c.play([song("a"), song("b"), song("c")]) // current = a (index 0)
        c.playNext([song("x")])
        XCTAssertEqual(c.queue.map(\.id), ["a", "x", "b", "c"]) // right after current
        XCTAssertEqual(c.nowPlaying?.id, "a") // current unchanged
    }

    func testPlayNextOnEmptyQueueStartsPlayback() {
        let c = makeController()
        c.playNext([song("x")])
        XCTAssertEqual(c.state, .playing)
        XCTAssertEqual(c.nowPlaying?.id, "x")
    }

    func testClearQueueStopsAndEmpties() {
        let c = makeController()
        c.play([song("a"), song("b")])
        c.clearQueue()
        XCTAssertTrue(c.queue.isEmpty)
        XCTAssertNil(c.nowPlaying)
        XCTAssertEqual(c.state, .idle)
    }

    // MARK: - Queue source

    func testPlaySetsAndClearResetsQueueSource() {
        let c = makeController()
        let src = StreamingPlaybackController.QueueSource(label: "My Playlist", kind: .playlist, id: "pl1")
        c.play([song("a")], source: src)
        XCTAssertEqual(c.queueSource, src)
        c.clearQueue()
        XCTAssertNil(c.queueSource)
    }

    func testQueueSourcePersistsAndRestores() {
        let c1 = makeController()
        c1.play([song("a"), song("b")], source: .init(label: "Radio X", kind: .radio, id: nil))
        let c2 = makeController()
        c2.restoreQueue()
        XCTAssertEqual(c2.queueSource?.label, "Radio X")
        XCTAssertEqual(c2.queueSource?.kind, .radio)
    }

    // MARK: - Mute

    func testToggleMuteIsIndependentOfVolume() {
        let c = makeController()
        c.setVolume(percent: 60)
        c.toggleMute()
        XCTAssertTrue(c.isMuted)
        XCTAssertEqual(c.volumePercent, 60) // volume level preserved
        c.toggleMute()
        XCTAssertFalse(c.isMuted)
    }

    func testRaisingVolumeUnmutes() {
        let c = makeController()
        c.toggleMute()
        XCTAssertTrue(c.isMuted)
        c.setVolume(percent: 30)
        XCTAssertFalse(c.isMuted) // a positive volume unmutes
    }

    // MARK: - Gapless real-playback integration

    /// Synthesize a short mono sine-tone WAV to a temp file — a real, decodable asset the
    /// `AVQueuePlayer` can preload and auto-advance through, so the boundary is exercised by
    /// the real audio stack rather than a mock.
    private func makeToneFile(frequency: Double, seconds: Double, name: String) throws -> URL {
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for i in 0 ..< Int(frames) {
            samples[i] = Float(sin(2.0 * .pi * frequency * Double(i) / sampleRate)) * 0.2
        }
        try file.write(from: buffer)
        return url
    }

    /// Real-hardware gapless pass: play two real tone files through the actual
    /// `AVQueuePlayer` and prove the track boundary was crossed by the **gapless**
    /// auto-advance (state reconciled onto the preloaded item) and **not** a reload — the
    /// exact behavior a mock-URL test can't reach. Plays audibly for ~2s.
    func testGaplessBoundaryUsesPreloadedItemNotReload() throws {
        let a = try makeToneFile(frequency: 440, seconds: 1.0, name: "gapless-a")
        let b = try makeToneFile(frequency: 660, seconds: 1.0, name: "gapless-b")
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let urls = ["a": a, "b": b]

        let c = StreamingPlaybackController(
            streamURLProvider: { urls[$0]! },
            defaults: suite,
            systemNowPlaying: false
        )
        c.gaplessEnabled = true
        c.crossfadeSeconds = 0
        c.play([song("a"), song("b")])
        XCTAssertEqual(c.state, .playing)
        // Exactly one load for the first track; the second is preloaded, not loaded.
        XCTAssertEqual(c.loadCurrentCountForTesting, 1)

        // Let the first tone play out and the OS auto-advance to the preloaded second tone.
        let deadline = Date().addingTimeInterval(8)
        while c.currentIndex == 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(c.currentIndex, 1, "did not advance to the second track")
        XCTAssertEqual(c.nowPlaying?.id, "b")
        XCTAssertEqual(c.state, .playing, "playback stalled across the boundary")
        XCTAssertEqual(c.gaplessAdvanceCountForTesting, 1, "boundary was not a gapless advance")
        XCTAssertEqual(c.loadCurrentCountForTesting, 1, "boundary triggered a reload (gap), not gapless")
        c.stop()
    }

    /// A queue restored on launch loads **paused**, so the initial preload is skipped.
    /// Pressing play (`resume`) must buffer the next track, or the first boundary after
    /// launch reloads (gap) instead of gapless-advancing. Regression guard for that path.
    func testResumeAfterRestorePreloadsForGapless() {
        // Seed a persisted queue, then restore it in a fresh (paused) controller.
        let seed = makeController()
        seed.play([song("a"), song("b")])

        let c = makeController()
        c.gaplessEnabled = true
        c.crossfadeSeconds = 0
        c.restoreQueue()
        XCTAssertEqual(c.state, .paused)
        XCTAssertEqual(c.nowPlaying?.id, "a")

        c.resume()
        c.simulateTrackEndedForTesting() // end of "a" with the (now) preloaded "b" queued
        XCTAssertEqual(c.nowPlaying?.id, "b")
        XCTAssertEqual(c.gaplessAdvanceCountForTesting, 1, "resume did not preload → boundary was a reload")
    }

    /// W-53 / PROD-01: with offline mode on, a non-downloaded track must NOT fall back to
    /// streaming — the previously-no-op toggle now actually suppresses the network.
    func testOfflineModeSuppressesStreaming() {
        UserDefaults.standard.set(true, forKey: StreamingPlaybackController.offlineModeKey)
        defer { UserDefaults.standard.removeObject(forKey: StreamingPlaybackController.offlineModeKey) }
        XCTAssertThrowsError(try StreamingPlaybackController.resolveStreamURL(songID: "https://cdn.example.com/ep.mp3"))
    }

    func testOnlineModePlaysPodcastEnclosure() throws {
        UserDefaults.standard.removeObject(forKey: StreamingPlaybackController.offlineModeKey)
        let u = try StreamingPlaybackController.resolveStreamURL(songID: "https://cdn.example.com/ep.mp3")
        XCTAssertEqual(u.absoluteString, "https://cdn.example.com/ep.mp3")
    }

    /// W-29 / AUDIO-05: a media-key play while radio is on air must drive the radio, not resume
    /// the library player over the live stream (double audio).
    func testRemotePlayRoutesToRadioWhenOnAir() {
        let c = makeController()
        c.play([song("a")])
        c.pause()
        var radioPlayed = false
        c.radioIsOnAir = { true }
        c.radioRemote = .init(play: { radioPlayed = true }, pause: {}, toggle: {}, next: {}, previous: {})
        c.handleRemotePlay()
        XCTAssertTrue(radioPlayed, "play key should drive radio when on air")
        XCTAssertEqual(c.state, .paused, "library player must NOT resume over the radio")
    }

    /// With no radio on air, remote play resumes the library player as normal.
    func testRemotePlayResumesLibraryWhenNoRadio() {
        let c = makeController()
        c.play([song("a")]); c.pause()
        c.radioIsOnAir = { false }
        c.handleRemotePlay()
        XCTAssertEqual(c.state, .playing)
    }

    /// W-26 / AUDIO-06: a stream-load failure retries the SAME track first (preserving place)
    /// instead of immediately skipping and cascade-skipping the queue on a brief outage.
    func testLoadFailureRetriesSameTrackBeforeSkipping() {
        let c = makeController()
        c.play([song("a"), song("b"), song("c")])
        XCTAssertEqual(c.nowPlaying?.id, "a")
        c.simulateLoadFailureForTesting()
        XCTAssertEqual(c.nowPlaying?.id, "a", "first failure must retry the same track, not skip")
        XCTAssertEqual(c.sameTrackRetriesForTesting, 1)
        c.stop()
    }

    /// W-24 / AUDIO-11: removing a selection that spans items BEFORE and including the current
    /// track must land on the current track's true successor, not skip past it.
    func testRemoveSpanningCurrentLandsOnSuccessor() {
        let c = makeController()
        c.play([song("a"), song("b"), song("c"), song("d"), song("e")], startAt: 2) // current = c
        XCTAssertEqual(c.nowPlaying?.id, "c")
        c.removeFromQueue(at: IndexSet([0, 2])) // remove a (before) and c (current)
        XCTAssertEqual(c.queue.map(\.id), ["b", "d", "e"])
        XCTAssertEqual(c.nowPlaying?.id, "d", "should play c's successor d, not skip to e")
    }

    /// Releasable gate so a test can hold an async related-fetch open, act, then let it finish.
    private final class TestGate: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async { if opened { return }; await withCheckedContinuation { continuation = $0 } }
        func open() { opened = true; continuation?.resume(); continuation = nil }
    }

    /// W-23: a related-track fetch that completes AFTER the user cleared the queue must not
    /// append its stale result onto the now-empty queue (AUDIO-16).
    func testStaleAutoplayFetchDoesNotAppendToAClearedQueue() async {
        let c = makeController()
        let gate = TestGate()
        c.relatedProvider = { _ in await gate.wait(); return [self.song("x"), self.song("y")] }
        c.play([song("a"), song("b")])
        c.autoplayEnabled = true // setter triggers extendQueueIfNeeded → the gated fetch
        c.clearQueue()           // user clears while the fetch is pending
        gate.open()              // fetch now resolves
        for _ in 0 ..< 20 { await Task.yield() }
        XCTAssertTrue(c.queue.isEmpty, "a stale top-up must not repopulate a cleared queue")
    }

    /// W-22: the EQ tap must be attached to the gapless PRELOAD item (before it plays), not
    /// only the current item — otherwise the EQ silently switches off at the boundary (AUDIO-28).
    func testEQAttachesToGaplessPreloadItem() {
        let c = makeController()
        c.gaplessEnabled = true
        c.crossfadeSeconds = 0
        var attachCount = 0
        c.configureAudioMix = { _ in attachCount += 1 }
        c.play([song("a"), song("b")])
        XCTAssertGreaterThanOrEqual(attachCount, 2, "EQ was not attached to the gapless preload item")
        c.stop()
    }

    /// When the next track is a network stream, the player prefetches it to disk and swaps
    /// the queued streaming item for the local file — so the boundary hands off from a local
    /// file (zero-gap) even on transcoded streams. Uses an injected downloader (no network).
    func testGaplessPrefetchSwapsStreamForLocalFile() throws {
        let local = try makeToneFile(frequency: 440, seconds: 0.5, name: "prefetch")
        defer { try? FileManager.default.removeItem(at: local) }
        let c = StreamingPlaybackController(
            streamURLProvider: { URL(string: "https://example.invalid/\($0)")! }, // non-file → stream
            defaults: suite,
            systemNowPlaying: false,
            gaplessPrefetchDownloader: { _, _ in local }
        )
        c.gaplessEnabled = true
        c.crossfadeSeconds = 0
        c.play([song("a"), song("b")])

        let deadline = Date().addingTimeInterval(4)
        while c.gaplessLocalSwapCountForTesting == 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(c.gaplessLocalSwapCountForTesting, 1, "stream preload was not swapped to the local prefetch")
        c.stop()
    }

    /// With "prefetch on Wi-Fi only" on and a metered connection, the prefetch download must
    /// not run (playback still works via the live stream).
    func testGaplessPrefetchSkippedOnMeteredWhenWifiOnly() throws {
        let local = try makeToneFile(frequency: 440, seconds: 0.5, name: "metered")
        defer { try? FileManager.default.removeItem(at: local) }
        var downloaderCalled = false
        let c = StreamingPlaybackController(
            streamURLProvider: { URL(string: "https://example.invalid/\($0)")! },
            defaults: suite,
            systemNowPlaying: false,
            gaplessPrefetchDownloader: { _, _ in downloaderCalled = true; return local },
            networkIsMetered: { true }
        )
        c.gaplessEnabled = true
        c.crossfadeSeconds = 0
        c.gaplessPrefetchWifiOnly = true
        c.play([song("a"), song("b")])

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(downloaderCalled, "prefetch ran on a metered connection despite Wi-Fi-only")
        XCTAssertEqual(c.gaplessLocalSwapCountForTesting, 0)
        c.stop()
    }

    /// Clearing the prefetch cache mid-playback empties it, leaves the queue intact, and
    /// doesn't strand playback (the queued preload is rebuilt from the stream).
    func testClearGaplessCacheEmptiesAndIsSafe() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clr-\(UUID().uuidString)")
        let cache = MusicGaplessCache(directory: dir)
        let local = try makeToneFile(frequency: 440, seconds: 0.5, name: "clear")
        defer { try? FileManager.default.removeItem(at: local); try? FileManager.default.removeItem(at: dir) }
        let c = StreamingPlaybackController(
            streamURLProvider: { URL(string: "https://example.invalid/\($0)")! },
            defaults: suite,
            systemNowPlaying: false,
            gaplessCache: cache,
            gaplessPrefetchDownloader: { _, songID in cache.store(tempFile: local, songID: songID) }
        )
        c.gaplessEnabled = true
        c.crossfadeSeconds = 0
        c.play([song("a"), song("b")])

        let deadline = Date().addingTimeInterval(3)
        while c.gaplessCacheSizeBytes == 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThan(c.gaplessCacheSizeBytes, 0, "prefetch did not populate the cache")

        c.clearGaplessCache()
        XCTAssertEqual(c.gaplessCacheSizeBytes, 0)
        XCTAssertEqual(c.nowPlaying?.id, "a")
        XCTAssertEqual(c.queue.count, 2)
        c.stop()
    }

    /// After a track (and thus the queue) plays to its end, the AVQueuePlayer drains its
    /// item. Pressing play again must **restart** it — not sit on an empty player. Regression
    /// for "play does not work" after a track finished.
    func testResumeAfterTrackEndRestartsPlayback() throws {
        let a = try makeToneFile(frequency: 440, seconds: 1.0, name: "resume-end")
        defer { try? FileManager.default.removeItem(at: a) }
        let c = StreamingPlaybackController(
            streamURLProvider: { _ in a },
            defaults: suite,
            systemNowPlaying: false
        )
        c.play([song("a")]) // single track → ends and stops (repeat off)

        // Let it play to the end (queue drains).
        let end = Date().addingTimeInterval(4)
        while c.state == .playing, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(c.state, .idle, "track did not finish")

        // Press play — must actually restart (currentTime advances), not stall on an empty player.
        c.resume()
        let progressed = Date().addingTimeInterval(3)
        while c.currentTime < 0.15, Date() < progressed { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(c.state, .playing)
        XCTAssertGreaterThan(c.currentTime, 0.1, "resume after end did not restart playback")
        c.stop()
    }

    // MARK: - Sleep timer

    func testSleepAtEndOfTrackPausesInsteadOfAdvancing() {
        let c = makeController()
        c.play([song("a"), song("b")])
        c.sleepAtEndOfTrack()
        XCTAssertTrue(c.sleepTimerArmed)
        c.simulateTrackEndedForTesting()
        XCTAssertEqual(c.state, .paused)
        XCTAssertEqual(c.nowPlaying?.id, "a") // did not advance to b
        XCTAssertFalse(c.sleepTimerArmed) // disarmed after firing
    }

    // MARK: - Gapless

    /// With gapless enabled, a simulated track-end must still advance the queue. In the
    /// test harness there's no real AVQueuePlayer auto-advancing the audio (no preloaded
    /// item is "current"), so `handleEnded` falls back to `advanceAfterEnd` and behaves
    /// exactly like the hard-cut path — a regression guard on the gapless gate.
    func testGaplessEnabledStillAdvancesOnTrackEnd() {
        let c = makeController()
        c.gaplessEnabled = true
        c.crossfadeSeconds = 0
        c.play([song("a"), song("b")])
        XCTAssertEqual(c.nowPlaying?.id, "a")
        c.simulateTrackEndedForTesting()
        XCTAssertEqual(c.nowPlaying?.id, "b")
        XCTAssertEqual(c.state, .playing)
        c.simulateTrackEndedForTesting() // off the end → stop (repeat off)
        XCTAssertEqual(c.state, .idle)
    }

    /// Toggling gapless mid-queue must not disturb the queue, current track, or state.
    func testTogglingGaplessIsQueueSafe() {
        let c = makeController()
        c.play([song("a"), song("b"), song("c")], startAt: 1)
        c.gaplessEnabled = true
        XCTAssertEqual(c.nowPlaying?.id, "b")
        XCTAssertEqual(c.queue.count, 3)
        c.gaplessEnabled = false
        XCTAssertEqual(c.nowPlaying?.id, "b")
        XCTAssertEqual(c.queue.count, 3)
        XCTAssertEqual(c.state, .playing)
    }

    func testCancelSleepTimerDisarms() {
        let c = makeController()
        c.play([song("a")])
        c.setSleepTimer(minutes: 30)
        XCTAssertTrue(c.sleepTimerArmed)
        c.cancelSleepTimer()
        XCTAssertFalse(c.sleepTimerArmed)
    }

    func testVolumeClamps() {
        let c = makeController()
        c.setVolume(percent: 150)
        XCTAssertEqual(c.volumePercent, 100)
        c.setVolume(percent: -5)
        XCTAssertEqual(c.volumePercent, 0)
        c.setVolume(percent: 42)
        XCTAssertEqual(c.volumePercent, 42)
    }

    // MARK: - Capture coordination (REQ-13)

    func testSuspendAndResumeAroundCapture() {
        let c = makeController()
        c.play([song("a")])
        c.suspendForCapture()
        XCTAssertEqual(c.state, .paused)
        c.resumeAfterCapture()
        XCTAssertEqual(c.state, .playing)
    }

    func testResumeDoesNotOverrideManualStop() {
        let c = makeController()
        c.play([song("a")])
        c.suspendForCapture()
        c.stop() // user stops while suspended
        XCTAssertEqual(c.state, .idle)
        c.resumeAfterCapture()
        XCTAssertEqual(c.state, .idle) // stays stopped
    }

    func testSuspendNoOpWhenNotPlaying() {
        let c = makeController()
        c.suspendForCapture() // nothing playing
        c.resumeAfterCapture()
        XCTAssertEqual(c.state, .idle)
    }

    // MARK: - Audio focus (owner-token)

    func testAudioFocusSuspendReleaseRestoresPlayback() {
        let c = makeController()
        c.play([song("a")])
        let token = c.acquireAudioFocusSuspend(owner: "ducker")
        XCTAssertEqual(c.state, .paused)
        c.releaseAudioFocus(token) // nothing intervened → resume
        XCTAssertEqual(c.state, .playing)
    }

    func testAudioFocusManualPauseCancelsAutoResume() {
        let c = makeController()
        c.play([song("a")])
        let token = c.acquireAudioFocusSuspend(owner: "ducker")
        XCTAssertEqual(c.state, .paused)
        c.pause() // user manually pauses while ducked (state stays .paused)
        c.releaseAudioFocus(token) // must NOT auto-resume — user intervened
        XCTAssertEqual(c.state, .paused)
    }

    func testAudioFocusManualNextCancelsAutoResume() {
        let c = makeController()
        c.play([song("a"), song("b")])
        let token = c.acquireAudioFocusSuspend(owner: "ducker")
        c.next() // user changes track while ducked
        XCTAssertEqual(c.nowPlaying?.id, "b")
        c.releaseAudioFocus(token) // no-op: intervention bumped the generation
        // next() resumed playback on "b"; release must leave it untouched, not re-resume.
        XCTAssertEqual(c.nowPlaying?.id, "b")
    }

    func testAudioFocusStaleTokenIsNoOp() {
        let c = makeController()
        c.play([song("a")])
        let stale = c.acquireAudioFocusSuspend(owner: "first")
        // A second acquire supersedes the first (last-writer-wins).
        _ = c.acquireAudioFocusSuspend(owner: "second")
        c.pause() // ensure paused; releasing the stale token must not resume
        c.releaseAudioFocus(stale) // stale holder → no-op
        XCTAssertEqual(c.state, .paused)
    }

    // MARK: - Persistence (REQ-14)

    func testQueuePersistsAndRestoresPaused() {
        // c1 and c2 share the isolated suite, so c2 restores what c1 persisted.
        let c1 = makeController()
        c1.play([song("a"), song("b"), song("c")], startAt: 1)

        let c2 = makeController()
        c2.restoreQueue()
        XCTAssertEqual(c2.queue.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(c2.currentIndex, 1)
        XCTAssertEqual(c2.nowPlaying?.id, "b")
        XCTAssertEqual(c2.state, .paused) // restored paused, not playing
    }

    // MARK: - Repeat / shuffle

    func testOnTrackEndOffStopsAtEnd() {
        typealias P = StreamingPlaybackController
        XCTAssertEqual(P.onTrackEnd(current: 0, count: 3, repeatMode: .off), .play(1))
        XCTAssertEqual(P.onTrackEnd(current: 2, count: 3, repeatMode: .off), .stop)
    }

    func testOnTrackEndAllWrapsAndOneReplays() {
        typealias P = StreamingPlaybackController
        XCTAssertEqual(P.onTrackEnd(current: 2, count: 3, repeatMode: .all), .play(0))
        XCTAssertEqual(P.onTrackEnd(current: 1, count: 3, repeatMode: .one), .replay)
    }

    func testOnManualNextWrapsWhenRepeating() {
        typealias P = StreamingPlaybackController
        XCTAssertEqual(P.onManualNext(current: 2, count: 3, repeatMode: .off), .stop)
        XCTAssertEqual(P.onManualNext(current: 2, count: 3, repeatMode: .all), .play(0))
        XCTAssertEqual(P.onManualNext(current: 2, count: 3, repeatMode: .one), .play(0))
    }

    func testCycleRepeatOrder() {
        let c = makeController()
        XCTAssertEqual(c.repeatMode, .off)
        c.cycleRepeat(); XCTAssertEqual(c.repeatMode, .all)
        c.cycleRepeat(); XCTAssertEqual(c.repeatMode, .one)
        c.cycleRepeat(); XCTAssertEqual(c.repeatMode, .off)
    }

    func testRepeatAllWrapsOnManualNext() {
        let c = makeController()
        c.play([song("a"), song("b")])
        c.cycleRepeat() // .all
        c.next() // a → b
        c.next() // b → wrap to a
        XCTAssertEqual(c.nowPlaying?.id, "a")
    }

    func testShuffleKeepsCurrentFirstAndUnshuffleRestores() {
        let c = makeController()
        let original = ["a", "b", "c", "d", "e"]
        c.play(original.map(song), startAt: 2) // current = "c"
        c.toggleShuffle()
        XCTAssertTrue(c.isShuffled)
        XCTAssertEqual(c.nowPlaying?.id, "c") // current stays selected
        XCTAssertEqual(c.queue.first?.id, "c") // current moved to front
        XCTAssertEqual(Set(c.queue.map(\.id)), Set(original)) // no tracks lost
        c.toggleShuffle()
        XCTAssertFalse(c.isShuffled)
        XCTAssertEqual(c.queue.map(\.id), original) // original order restored
        XCTAssertEqual(c.nowPlaying?.id, "c")
    }
}
