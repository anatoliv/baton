import AVFoundation
import XCTest
@testable import BatonPlaybackKit

/// End-to-end recovery from "playing, but nothing is coming out", against real audio
/// hardware.
///
/// `PlayheadStallDetectorTests` pins the rules and `EngineForcedIORestartTests` pins the
/// restart; neither proves the two are wired together, and the wiring is where this bug
/// lived. Nothing was watching, so nothing recovered.
///
/// The wedge is induced the way production reaches it: **the engine is stopped and no
/// configuration change is posted.** That asymmetry is the whole cause — macOS stops the
/// AUHAL across sleep without reliably posting `AVAudioEngineConfigurationChange`, so
/// `onConfigurationChange` never fires and `reanchorAfterGraphRestart` never runs. Note
/// what `engine.stop()` leaves behind: the buffers are gone but `scheduledFrames` still
/// counts them, so `aheadSeconds` reads *positive* and the dry-detector sees a healthy
/// deck. That stale-positive reading is precisely why `isBuffering` never rose in the
/// field, and it is reproduced here rather than worked around.
///
/// Runs in `.device` mode because that is the only mode where a frozen playhead means
/// anything — at volume 0, so the gate stays silent.
@MainActor
final class EnginePlayheadStallRecoveryTests: XCTestCase {

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    func testAWedgedEngineRecoversWithoutAConfigurationChange() async throws {
        try XCTSkipUnless(AudioOutputDevices.defaultOutputDeviceID() != 0,
                          "no audio output device on this machine")

        let wav = EngineTestSignals.sineWAV(frequency: 440, seconds: 30)
        let server = try EngineHTTPServer(payload: wav, contentType: "audio/wav")
        defer { server.stop() }

        let pipeline = try EngineAudioPipeline(outputMode: .device)
        let controller = EnginePlaybackController(pipeline: pipeline)
        defer { controller.stop(); pipeline.shutdown() }
        controller.volumePercent = 0          // audible nothing; frames still render

        let track = EnginePlaybackController.Track(
            id: "wedge", url: server.url, duration: 30, supportsTimeOffset: false
        )
        controller.play(track)

        let started = await waitUntil(timeout: 20) {
            controller.state == .playing && !controller.isBuffering && controller.currentTime > 0.5
        }
        XCTAssertTrue(started, "precondition: the track never started playing at all")

        let beforeWedge = controller.currentTime

        // What sleep does to us, exactly: the engine stops and nobody is told.
        pipeline.stopEngineForTesting()

        // The deck still *claims* audio is queued — the stale-positive reading that blinded
        // the dry-detector in the field. Without it this test would prove a different bug.
        XCTAssertGreaterThan(pipeline.aheadSeconds(on: controller.activeDeckForTesting), 0,
                             "engine.stop() cleared the scheduling bookkeeping, so this is no longer the field's wedge")
        XCTAssertFalse(controller.isBuffering,
                       "the dry-detector spotted this, which means the wedge under test is not the one that shipped")

        // Recovery: the playhead has to start moving again, past where it froze.
        let recovered = await waitUntil(timeout: 25) { controller.currentTime > beforeWedge + 0.5 }
        XCTAssertTrue(recovered, """
            The playhead never moved again. This is the shipped bug: the transport still says \
            playing, the deck still says audio is queued, and nothing renders — silence with no \
            error, until the app is relaunched.
            """)
        XCTAssertEqual(controller.state, .playing, "recovery must resume playing, not surface an error")
        XCTAssertTrue(pipeline.isEngineRunningForTesting, "recovered with the engine still stopped")
    }

    /// Recovery must re-feed from the spool rather than re-download. The bytes are already
    /// on disk, and `reanchorAfterGraphRestart` exists to use them — a stall that costs a
    /// fresh HTTP request would make every sleep/wake a re-buffer on a slow connection.
    func testRecoveryRefeedsFromTheSpoolRatherThanReloading() async throws {
        try XCTSkipUnless(AudioOutputDevices.defaultOutputDeviceID() != 0,
                          "no audio output device on this machine")

        let wav = EngineTestSignals.sineWAV(frequency: 440, seconds: 30)
        let server = try EngineHTTPServer(payload: wav, contentType: "audio/wav")
        defer { server.stop() }

        let pipeline = try EngineAudioPipeline(outputMode: .device)
        let controller = EnginePlaybackController(pipeline: pipeline)
        defer { controller.stop(); pipeline.shutdown() }
        controller.volumePercent = 0

        let track = EnginePlaybackController.Track(
            id: "wedge-refeed", url: server.url, duration: 30, supportsTimeOffset: false
        )
        controller.play(track)
        let started = await waitUntil(timeout: 20) {
            controller.state == .playing && !controller.isBuffering && controller.currentTime > 0.5
        }
        XCTAssertTrue(started, "precondition: the track never started playing at all")

        let beforeWedge = controller.currentTime
        let loadsBefore = controller.loadCountForTesting
        let refeedsBefore = controller.refeedCountForTesting

        pipeline.stopEngineForTesting()

        let recovered = await waitUntil(timeout: 25) { controller.currentTime > beforeWedge + 0.5 }
        XCTAssertTrue(recovered, "the playhead never recovered, so there is nothing to say about how")
        XCTAssertGreaterThan(controller.refeedCountForTesting, refeedsBefore,
                             "recovery did not re-feed from the spool")
        XCTAssertEqual(controller.loadCountForTesting, loadsBefore,
                       "recovery re-requested the stream for bytes already on disk")
    }
}
