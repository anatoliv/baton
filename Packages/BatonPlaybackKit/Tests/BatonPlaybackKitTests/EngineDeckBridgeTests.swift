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

    private func makeRig(payload: Data, contentType: String = "audio/wav") throws -> Rig {
        let server = try EngineHTTPServer(payload: payload, contentType: contentType)
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
}
