import AVFoundation
import XCTest
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// The staged seam, end to end: `StreamingPlaybackController` — with ALL its policy —
/// routing library streams to the engine deck, and everything else past it.
///
/// This is the arrangement the app actually ships behind the developer setting, so the
/// tests drive the OLD controller's public API and assert on the OLD controller's state:
/// if the seam leaks (both players sounding, a verb going to the wrong deck, the queue
/// not advancing at an engine track's end), it shows up here and not in a hand-test.
@MainActor
final class EngineDeckBridgeTests: XCTestCase {

    private let suiteName = "io.tonebox.tests.enginedeck"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()

    private func song(_ id: String, duration: Int) -> NavidromeSong {
        NavidromeSong(id: id, title: "Song \(id)", artist: "Artist", album: nil,
                      duration: duration, coverArtID: nil)
    }

    private struct Rig {
        let controller: StreamingPlaybackController
        let bridge: EngineDeckBridge
        let pipeline: EngineAudioPipeline
        let server: EngineHTTPServer

        @MainActor func shutdown() {
            controller.stop()
            bridge.stop()
            pipeline.shutdown()
            server.stop()
        }

        /// Render paced so the deck's audio advances against the wall clock the bridge's
        /// 4 Hz push runs on.
        @MainActor func renderPaced(seconds: Double) async throws {
            let block: AVAudioFrameCount = 1024
            let format = pipeline.manualRenderingFormat
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block)!
            let blockSeconds = Double(block) / format.sampleRate
            let start = Date()
            while Date().timeIntervalSince(start) < seconds {
                _ = try pipeline.renderOffline(frames: block, into: buffer)
                try await Task.sleep(for: .seconds(blockSeconds))
            }
        }
    }

    private func makeRig(payload: Data, contentType: String = "audio/wav",
                         delivery: EngineHTTPServer.Delivery = .wholeFile) throws -> Rig {
        let server = try EngineHTTPServer(payload: payload, delivery: delivery, contentType: contentType)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                   channels: 2, interleaved: false)!
        let pipeline = try EngineAudioPipeline(outputMode: .offline(format: format, maxFrames: 4096))
        let bridge = EngineDeckBridge(pipeline: pipeline)
        let controller = StreamingPlaybackController(
            streamURLProvider: { _ in server.url },
            defaults: suite,
            systemNowPlaying: false
        )
        controller.attachEngineDeck(bridge)
        return Rig(controller: controller, bridge: bridge, pipeline: pipeline, server: server)
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("timed out"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A library track routes to the deck; the AVPlayer side stays empty; the transport
    /// verbs land on the engine; the host's clock follows the engine's.
    func testLibraryStreamRoutesToDeckAndTransportForwards() async throws {
        let rig = try makeRig(payload: EngineTestSignals.sineWAV(frequency: 440, seconds: 6))
        defer { rig.shutdown() }
        let c = rig.controller

        c.play([song("lib1", duration: 6)])
        XCTAssertTrue(c.engineOwnsPlaybackForTesting, "a library stream must route to the engine deck")
        XCTAssertEqual(c.state, .playing)

        try await waitUntil {
            rig.pipeline.scheduledSeconds(on: rig.bridge.engine.activeDeckForTesting) > 2.0
        }
        try await rig.renderPaced(seconds: 1.6)
        XCTAssertGreaterThan(c.currentTime, 0.5, "the host clock must follow the engine's playhead")

        c.pause()
        XCTAssertEqual(c.state, .paused)
        XCTAssertEqual(rig.bridge.engine.state, .paused, "pause must land on the deck")

        c.resume()
        XCTAssertEqual(c.state, .playing)
        XCTAssertEqual(rig.bridge.engine.state, .playing, "resume must land on the deck")
    }

    /// A dead track costs ONE ladder before the queue moves on, not two multiplied together.
    ///
    /// The engine retries the same track three times at the playhead and only then reports
    /// `.error`; the host used to answer that by running its own identical ladder, each
    /// attempt reloading the deck and re-arming the engine's ladder underneath it. Counting
    /// connections is what makes this provable rather than a matter of opinion — the server
    /// sees every fetch, so the multiplication has nowhere to hide. (§2.6 / TBX-2885)
    func testADeadTrackCostsOneLadderNotTwoBeforeTheQueueMovesOn() async throws {
        let rig = try makeRig(
            payload: EngineTestSignals.sineWAV(frequency: 440, seconds: 30),
            delivery: .truncateAfter(bytes: 44 + 44_100 * 2, connections: .max)
        )
        defer { rig.shutdown() }
        let c = rig.controller

        c.play([song("dead", duration: 30), song("next", duration: 30)])
        XCTAssertTrue(c.engineOwnsPlaybackForTesting, "a library stream must route to the engine deck")

        // Engine backoff is 1 s + 2 s + 3 s, then the host waits 1.5 s before skipping — about
        // 8 s, and that is what it takes when this runs alone. The timeout is far longer
        // because it once failed at 40 s inside the full gate while passing everywhere else,
        // and a gate that goes red at random is worse than a slow test. If it ever exhausts
        // *this* budget the run is genuinely stuck, and the engine now logs its give-up, so
        // the log says whether `.error` was reached and the notification lost.
        try await waitUntil(timeout: 90) { c.currentIndex == 1 }
        XCTAssertEqual(c.nowPlaying?.id, "next", "the host owns the skip, and it must still happen")

        // Four fetches for the dead track (the load plus three retries), then the next
        // track's. One spare, because the poll above can notice the advance a beat after a
        // retry of the *new* track has already gone out. Before the fix this was ~17.
        XCTAssertLessThanOrEqual(
            rig.server.acceptedConnections, StreamingPlaybackController.maxSameTrackRetries + 3,
            "the host is laddering on top of the engine's ladder again"
        )
    }

    /// The same rule without the network or the wall clock: a failure the engine has already
    /// laddered goes straight to `.error` and the skip, and adds no rung of its own. The test
    /// above proves it end to end and pays eight seconds for it; this one is the tripwire
    /// that fails in milliseconds if the decision itself regresses.
    func testAnEngineLadderedFailureAddsNoHostRetry() async throws {
        let rig = try makeRig(payload: EngineTestSignals.sineWAV(frequency: 440, seconds: 6))
        defer { rig.shutdown() }
        let c = rig.controller

        c.play([song("lib1", duration: 6), song("lib2", duration: 6)])
        c.simulateLoadFailureForTesting("dead", afterEngineLadder: true)

        XCTAssertEqual(c.sameTrackRetriesForTesting, 0, "the host must not start a ladder of its own")
        guard case .error = c.state else {
            return XCTFail("a laddered failure must surface as an error, not another retry")
        }
        // And the host still contributes the part the engine cannot: moving on.
        try await waitUntil(timeout: 10) { c.currentIndex == 1 }
        XCTAssertEqual(c.nowPlaying?.id, "lib2")
    }

    /// The other side of the same rule: a failure that no engine has retried keeps the
    /// host's ladder. The AVPlayer path has nothing underneath it, so removing its retries
    /// would turn a Wi-Fi blip into a skipped track.
    func testTheHostStillRetriesAFailureNothingElseHasLaddered() async throws {
        let rig = try makeRig(payload: EngineTestSignals.sineWAV(frequency: 440, seconds: 6))
        defer { rig.shutdown() }
        let c = rig.controller

        c.play([song("lib1", duration: 6), song("lib2", duration: 6)])
        c.simulateLoadFailureForTesting("blip")

        XCTAssertEqual(c.state, .loading, "an un-laddered failure must retry in place, not error out")
        XCTAssertEqual(c.sameTrackRetriesForTesting, 1)
        XCTAssertEqual(c.currentIndex, 0, "and it must not skip the track on a first failure")
    }

    /// The end of an engine-owned track runs the HOST's advance policy: next track loads
    /// (also on the deck), queue index moves, nothing reports an error.
    func testEngineTrackEndAdvancesHostQueue() async throws {
        let rig = try makeRig(payload: EngineTestSignals.sineWAV(frequency: 440, seconds: 2))
        defer { rig.shutdown() }
        let c = rig.controller

        c.play([song("lib1", duration: 2), song("lib2", duration: 2)])
        XCTAssertTrue(c.engineOwnsPlaybackForTesting)
        try await waitUntil {
            rig.pipeline.scheduledSeconds(on: rig.bridge.engine.activeDeckForTesting) > 1.5
        }
        // Render past the first track's end; the deck reports it, the host advances.
        try await rig.renderPaced(seconds: 3.0)
        try await waitUntil(timeout: 5) { c.currentIndex == 1 }
        XCTAssertEqual(c.nowPlaying?.id, "lib2")
        XCTAssertEqual(c.state, .playing)
        XCTAssertTrue(c.engineOwnsPlaybackForTesting, "the next library track must route to the deck too")
    }

    /// A podcast episode (enclosure-URL id) must BYPASS the deck — that media stays on
    /// AVPlayer by design, and the deck must fall silent when it loses ownership.
    func testPodcastBypassesDeck() async throws {
        let rig = try makeRig(payload: EngineTestSignals.sineWAV(frequency: 440, seconds: 3))
        defer { rig.shutdown() }
        let c = rig.controller

        c.play([song("lib1", duration: 3)])
        XCTAssertTrue(c.engineOwnsPlaybackForTesting)

        // An enclosure-URL id is a podcast episode by definition (`MediaKind`).
        c.play([song("https://example.com/episode.mp3", duration: 3)])
        XCTAssertFalse(c.engineOwnsPlaybackForTesting, "podcasts must stay on the AVPlayer path")
        XCTAssertNotEqual(rig.bridge.engine.state, .playing, "losing ownership must silence the deck")
    }

    /// Seek on an engine-owned track goes to the deck (the engine runs its own
    /// in-spool / timeOffset decision), and the host scrubber holds the target rather
    /// than snapping back to the pre-seek clock.
    func testSeekForwardsToDeckAndScrubberHolds() async throws {
        let rig = try makeRig(payload: EngineTestSignals.twoToneWAV(firstHz: 440, secondHz: 880, secondsEach: 3))
        defer { rig.shutdown() }
        let c = rig.controller

        c.play([song("lib1", duration: 6)])
        try await waitUntil {
            rig.pipeline.scheduledSeconds(on: rig.bridge.engine.activeDeckForTesting) > 5.5
        }
        try await rig.renderPaced(seconds: 0.6)
        c.seek(to: 4.0)
        XCTAssertEqual(c.currentTime, 4.0, accuracy: 0.01, "the scrubber must hold the target immediately")
        try await rig.renderPaced(seconds: 1.2)
        XCTAssertEqual(c.currentTime, 4.0 + 1.2, accuracy: 0.8,
                       "after the seek lands, the clock must advance from the target")
        XCTAssertEqual(c.currentIndex, 0, "a seek must never advance the queue")
    }

    // MARK: Mute (§3.4 of docs/audio-engine-optimization-plan.md)

    /// Mute must reach the deck, not just the AVPlayer that isn't playing.
    ///
    /// `toggleMute()` set `isMuted` and `player.isMuted` and returned. The only path to the
    /// deck is `applyVolume()`, and `isMuted` has no `didSet`, so with the engine owning
    /// playback the button did nothing audible until an unrelated volume event happened to
    /// run. Four UI sites drive it and no test noticed.
    func testMuteReachesTheEngineDeck() async throws {
        let rig = try makeRig(payload: EngineTestSignals.sineWAV(frequency: 440, seconds: 6))
        defer { rig.shutdown() }
        let c = rig.controller

        c.play([song("lib1", duration: 6)])
        XCTAssertTrue(c.engineOwnsPlaybackForTesting)
        XCTAssertFalse(rig.bridge.engine.isMuted)

        c.toggleMute()
        XCTAssertTrue(c.isMuted)
        XCTAssertTrue(rig.bridge.engine.isMuted, "the deck is where the audio is — it has to be told")

        c.toggleMute()
        XCTAssertFalse(c.isMuted)
        XCTAssertFalse(rig.bridge.engine.isMuted, "unmuting has to reach it too")
    }

    /// Unmuting with the volume slider must not leave the deck muted.
    ///
    /// `setVolume` assigned `volumePercent` first, and that property's `didSet` runs
    /// `applyVolume()` — which read the *old* `isMuted`. The mute was then cleared on the
    /// host with nothing pushing the correction down, so the track stayed silent while
    /// every control claimed otherwise.
    func testMovingTheVolumeSliderUnmutesTheDeckToo() async throws {
        let rig = try makeRig(payload: EngineTestSignals.sineWAV(frequency: 440, seconds: 6))
        defer { rig.shutdown() }
        let c = rig.controller

        c.play([song("lib1", duration: 6)])
        c.toggleMute()
        XCTAssertTrue(rig.bridge.engine.isMuted)

        c.setVolume(percent: 55)
        XCTAssertFalse(c.isMuted, "moving the slider up unmutes")
        XCTAssertFalse(rig.bridge.engine.isMuted,
                       "the deck must hear the unmute, not the stale mute that preceded it")
        XCTAssertEqual(rig.bridge.engine.volumePercent, 55, "and the new level")
    }

    // MARK: Skip blend and deck attachment (§3.3)

    /// Attaching a deck must not disable the blend for media the deck never touches.
    ///
    /// The guard tested attachment rather than ownership, so from the moment a deck existed
    /// — on the Mac, at launch with the toggle on — Next hard-cut for media that is pure
    /// AVPlayer and blended perfectly well before.
    ///
    /// **Downloads are that media, not podcasts.** The first version of this test used
    /// podcast episodes and failed: `beginSkipBlend` has always refused those through a
    /// separate `isPodcastEpisode` guard, so they lost nothing. A downloaded library track
    /// is the real case — a library id (so not a podcast) served from a `file://` URL (so
    /// `canPlay` refuses it and the engine never owns it).
    func testSkipBlendStillRunsForDownloadsWhileADeckIsAttached() async throws {
        let wav = EngineTestSignals.sineWAV(frequency: 440, seconds: 2)
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("blend-\(UUID().uuidString).wav")
        try wav.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                   channels: 2, interleaved: false)!
        let pipeline = try EngineAudioPipeline(outputMode: .offline(format: format, maxFrames: 4096))
        let bridge = EngineDeckBridge(pipeline: pipeline)
        let c = StreamingPlaybackController(
            streamURLProvider: { _ in file }, defaults: suite, systemNowPlaying: false
        )
        c.attachEngineDeck(bridge)
        defer { c.stop(); bridge.stop(); pipeline.shutdown() }

        c.play([song("lib1", duration: 2), song("lib2", duration: 2)])
        XCTAssertFalse(c.engineOwnsPlaybackForTesting, "a file URL never routes to the deck")
        XCTAssertTrue(c.beginSkipBlendForTesting(to: 1),
                      "a deck being attached must not cost downloads their blend")
    }

    /// ...and it must still refuse when the incoming track belongs on the deck.
    ///
    /// The narrower guard has to keep the property the broad one had: never blend into an
    /// AVPlayer item for a track that should be rendered by the engine.
    func testSkipBlendRefusesWhenTheIncomingTrackBelongsOnTheDeck() async throws {
        let rig = try makeRig(payload: EngineTestSignals.sineWAV(frequency: 440, seconds: 6))
        defer { rig.shutdown() }
        let c = rig.controller

        c.play([song("https://example.com/one.mp3", duration: 6), song("lib1", duration: 6)])
        XCTAssertFalse(c.engineOwnsPlaybackForTesting)
        XCTAssertFalse(c.beginSkipBlendForTesting(to: 1),
                       "blending into an AVPlayer item for an engine-routable track would "
                       + "leave the wrong renderer playing it")
    }

    // MARK: Output-device change while paused (§2.5)

    /// A device change while **paused** must re-anchor too.
    ///
    /// The handler guarded on `isPlaying`, so it did nothing here — while the engine had
    /// already been stopped to re-point its output unit, which drops the scheduled buffers.
    /// Resume then had nothing to render and the playhead froze, without even raising
    /// `isBuffering`, because the deck's stale `aheadSeconds` hid it from dry-detection.
    func testDeviceChangeWhilePausedReAnchorsWithoutStartingPlayback() async throws {
        let rig = try makeRig(payload: EngineTestSignals.sineWAV(frequency: 440, seconds: 6))
        defer { rig.shutdown() }
        let c = rig.controller

        c.play([song("lib1", duration: 6)])
        try await waitUntil {
            rig.pipeline.scheduledSeconds(on: rig.bridge.engine.activeDeckForTesting) > 1.0
        }
        try await rig.renderPaced(seconds: 0.6)
        c.pause()
        let at = c.currentTime
        XCTAssertEqual(c.state, .paused)

        // The re-anchor is what makes this observable. Asserting "still paused, still has a
        // track" would pass just as happily against a handler that returned immediately —
        // the first version of this test did exactly that, and caught nothing.
        //
        // Since Stage 4 the observable is a *re-feed*, not a re-fetch: the bytes are already
        // spooled, so re-anchoring must not touch the network.
        let connectionsBefore = rig.server.acceptedConnections
        let loadsBefore = rig.bridge.engine.loadCountForTesting
        let refeedsBefore = rig.bridge.engine.refeedCountForTesting

        // What the pipeline does to the controller on a device/rate change.
        rig.pipeline.onConfigurationChange?()

        try await waitUntil { rig.bridge.engine.refeedCountForTesting > refeedsBefore }
        XCTAssertEqual(c.state, .paused, "re-anchoring must not start playback")
        XCTAssertNotNil(c.nowPlaying, "the track must survive the re-anchor")
        XCTAssertEqual(c.currentTime, at, accuracy: 1.0, "and stay at the playhead")
        XCTAssertEqual(rig.bridge.engine.loadCountForTesting, loadsBefore,
                       "a spooled position must not be re-requested")
        XCTAssertEqual(rig.server.acceptedConnections, connectionsBefore,
                       "and must not open a new connection")
    }

    // MARK: Route change re-feeds instead of re-downloading (Stage 4)

    /// A device or route change while **playing** must reuse the spool.
    ///
    /// It used to call `load()`, which tears down both decks *and their sources*, destroying
    /// the spool that already holds the audio, and then opens a fresh request. On a cold
    /// transcode that is seconds of silence; on a stream without `timeOffset` it refetches
    /// from byte zero and decode-discards to the playhead, so a route change mid-song
    /// re-downloads the whole prefix. AirPods in or out of an ear does this.
    func testRouteChangeWhilePlayingRefeedsFromTheSpoolInsteadOfRefetching() async throws {
        let rig = try makeRig(payload: EngineTestSignals.sineWAV(frequency: 440, seconds: 6))
        defer { rig.shutdown() }
        let c = rig.controller

        c.play([song("lib1", duration: 6)])
        try await waitUntil {
            rig.pipeline.scheduledSeconds(on: rig.bridge.engine.activeDeckForTesting) > 1.0
        }
        try await rig.renderPaced(seconds: 0.6)

        let connectionsBefore = rig.server.acceptedConnections
        let loadsBefore = rig.bridge.engine.loadCountForTesting
        let refeedsBefore = rig.bridge.engine.refeedCountForTesting

        rig.pipeline.onConfigurationChange?()

        try await waitUntil { rig.bridge.engine.refeedCountForTesting > refeedsBefore }
        XCTAssertEqual(rig.bridge.engine.loadCountForTesting, loadsBefore,
                       "the bytes were already spooled — this must not be a reload")
        XCTAssertEqual(rig.server.acceptedConnections, connectionsBefore,
                       "and no new HTTP request may be made for audio already on disk")

        // The re-feed has to reconnect the deck, not just reposition the decoder: a
        // configuration change invalidates the engine's node connections, and PCM scheduled
        // into a disconnected deck plays nothing at all.
        try await waitUntil {
            rig.pipeline.scheduledSeconds(on: rig.bridge.engine.activeDeckForTesting) > 0.1
        }
        XCTAssertEqual(c.state, .playing, "playback must continue across the route change")
    }
}
