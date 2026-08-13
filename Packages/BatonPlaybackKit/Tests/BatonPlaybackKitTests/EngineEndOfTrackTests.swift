import AVFoundation
import XCTest
@testable import BatonPlaybackKit

/// The end of a track — the engine's **production** end path, and until now untested.
///
/// This suite exists because of what Stage 5 removed. Deleting the engine's
/// queue took `testGaplessBoundaryHasNoSilentGap` and
/// `testCrossfadeOverlapsAndNeverGoesSilent` with it, and those were the only tests that
/// ever drove a track to its natural end. What they were *asserting* was the dead half —
/// that the queue advanced — but on the way they exercised the live half underneath it:
/// the feeder finishing, `scheduleBoundary` placing the callback on the final buffer, the
/// §2.1 spurious-end guard deciding the end is genuine, and `onPlaybackEnded` firing so
/// the host can run its own advance policy.
///
/// Losing the dead assertions was the point. Losing the live coverage was not, and nothing
/// else covered it: a grep for `onPlaybackEnded` across this whole target found no test at
/// all, only a comment of mine claiming the deck tests covered it. They do not — they
/// assert on loads, seeks and ownership, never on a track running out.
///
/// So this is the coverage the deletion owed, written against the path that survived.
@MainActor
final class EngineEndOfTrackTests: XCTestCase {

    /// A track that plays to its end must end **once**, land on `.idle`, and tell the host.
    ///
    /// `onPlaybackEnded` is the entire contract between the engine and
    /// `StreamingPlaybackController` at a boundary: the host's `deck.onEnded` runs
    /// `handleEnded()` → `advanceAfterEnd()`, which is where repeat, next track, autoplay
    /// radio and stop are actually decided. If this hook stops firing, music silently stops
    /// at the end of every track and no test would have noticed.
    func testATrackThatPlaysOutFiresPlaybackEndedExactlyOnce() async throws {
        let rate = 44_100.0
        // Short, so the whole track fits inside the 8 s high-water mark and is fully
        // scheduled before a frame is rendered — no pacing, no wall-clock luck.
        let server = try EngineHTTPServer(
            payload: EngineTestSignals.sineWAV(frequency: 440, seconds: 2), contentType: "audio/wav")
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: rate)
        defer { harness.shutdown() }

        var endedCount = 0
        harness.controller.onPlaybackEnded = { endedCount += 1 }

        let track = EnginePlaybackController.Track(
            id: "playout", url: server.url, duration: 2, supportsTimeOffset: false
        )
        harness.controller.play(track)
        try await harness.waitUntil(timeout: 20) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 1.8
        }

        // Render past the end, then let the final buffer's completion callback make its
        // main-actor hop.
        _ = try await harness.renderSeconds(2.5)
        try await harness.waitUntil(timeout: 5) { endedCount == 1 }

        XCTAssertEqual(endedCount, 1, "the host was told about the end more than once, or not at all")
        XCTAssertEqual(harness.controller.state, .idle, "the engine did not settle at idle after the track ran out")
        XCTAssertEqual(harness.controller.loadCountForTesting, 1,
                       "the end of a track reloaded something — the host owns what plays next, not the engine")

        // Rendering further must not produce a second end. The boundary callback is armed
        // on a specific buffer and guarded by the load generation; a duplicate would double
        // the host's advance and skip a track.
        _ = try await harness.renderSeconds(1.0)
        XCTAssertEqual(endedCount, 1, "a second end fired after the track had already ended")
    }

    /// A stream that dies early must **not** be reported as the end of the track.
    ///
    /// This is §2.1, and it is the guard that survived the queue deletion inside
    /// `handleTrackAudioEnded`. A transcode that dies but closes its response cleanly —
    /// ffmpeg exits, the server closes the chunked stream properly — is indistinguishable
    /// from a finished track to everything downstream. Without the guard the engine calls
    /// it an end and the host advances mid-song; with it, the engine re-requests from the
    /// playhead under a bounded budget.
    ///
    /// Asserted as "did not end and did reload", which is the observable difference between
    /// the two outcomes.
    func testAStreamThatEndsEarlyRecoversInsteadOfEndingTheTrack() async throws {
        let rate = 44_100.0
        // The payload is 2 s of audio, but the track claims 30 s — the shape of a transcode
        // that gave up a long way from the end. `spuriousEndTolerance` is 5 s, so 2 ≪ 30
        // is unambiguously early.
        let server = try EngineHTTPServer(
            payload: EngineTestSignals.sineWAV(frequency: 440, seconds: 2), contentType: "audio/wav")
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: rate)
        defer { harness.shutdown() }

        var endedCount = 0
        harness.controller.onPlaybackEnded = { endedCount += 1 }

        let track = EnginePlaybackController.Track(
            id: "diedearly", url: server.url, duration: 30, supportsTimeOffset: false
        )
        harness.controller.play(track)
        try await harness.waitUntil(timeout: 20) {
            harness.pipeline.scheduledSeconds(on: harness.controller.activeDeckForTesting) > 1.5
        }

        _ = try await harness.renderSeconds(2.5)
        // The recovery is a fresh load, so wait on the load counter rather than on a clock.
        try await harness.waitUntil(timeout: 10) { harness.controller.loadCountForTesting > 1 }

        XCTAssertEqual(
            endedCount, 0,
            "a stream that stopped 28 s short of the track's duration was reported to the host as the end of the track — the host would advance mid-song, which is the failure class StreamSeek was written to kill"
        )
        XCTAssertGreaterThan(harness.controller.loadCountForTesting, 1,
                             "the engine did not re-request from the playhead after an early end")
    }
}
