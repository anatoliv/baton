import AVFoundation
import XCTest
@testable import BatonPlaybackKit

/// The recovery ladder: retry the same track a bounded number of times, then give up with
/// `.error` — which is the only way the *host* ever hears about a dead track, since it owns
/// the skip in deck mode.
///
/// Both tests drive a real connection that dies mid-track, because that is the shape the
/// bug had: a stream reaches `.playing` (the download starts without waiting for bytes, so
/// it always does) and only then fails. Clearing the ladder on that transition meant every
/// cycle read "retry 1" and the ladder could never climb — the engine re-fetched forever
/// and the user's music simply stopped.
@MainActor
final class EngineRetryLadderTests: XCTestCase {

    /// One second of audio, then the socket closes against a declared `Content-Length`.
    private static let bytesForOneSecond = 44 + 44_100 * 2

    /// A stream that dies the same way on every attempt must reach `.error`, not loop.
    ///
    /// No rendering here on purpose: the failure arrives from the feeder, not from the
    /// transport clock, so this is the ladder on its own. It also means nothing plays, which
    /// is what the dwell-gated reset is there to notice.
    func testAStreamThatDiesEveryAttemptGivesUpInsteadOfRetryingForever() async throws {
        let wav = EngineTestSignals.sineWAV(frequency: 440, seconds: 30)
        let server = try EngineHTTPServer(
            payload: wav,
            delivery: .truncateAfter(bytes: Self.bytesForOneSecond, connections: .max),
            contentType: "audio/wav"
        )
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: 44_100)
        defer { harness.shutdown() }
        harness.controller.stallTimeoutSeconds = 120 // the watchdog is not the subject here

        let track = EnginePlaybackController.Track(
            id: "dies", url: server.url, duration: 30, supportsTimeOffset: false
        )
        harness.controller.play(track)

        // Backoff is 1 s + 2 s + 3 s between attempts, so the ladder needs ~6 s to run out.
        try await harness.waitUntil(timeout: 40) {
            if case .error = harness.controller.state { return true }
            return false
        }
        XCTAssertLessThanOrEqual(
            server.acceptedConnections, StreamingPlaybackController.maxSameTrackRetries + 1,
            "the engine kept re-fetching a dead stream past its own retry cap"
        )
    }

    /// The other half: a track that fails once and then genuinely plays must clear the
    /// ladder, so an evening of occasional hiccups doesn't accumulate into an early give-up.
    /// The reset is real, it just costs `retryResetDwellSeconds` of rendered audio now.
    func testATrackThatRecoversAndPlaysOnClearsTheLadder() async throws {
        let wav = EngineTestSignals.sineWAV(frequency: 440, seconds: 40)
        let server = try EngineHTTPServer(
            payload: wav,
            delivery: .truncateAfter(bytes: Self.bytesForOneSecond, connections: 1),
            contentType: "audio/wav"
        )
        defer { server.stop() }
        let harness = try EngineRenderHarness(sampleRate: 44_100)
        defer { harness.shutdown() }
        harness.controller.stallTimeoutSeconds = 120

        let track = EnginePlaybackController.Track(
            id: "recovers", url: server.url, duration: 40, supportsTimeOffset: false
        )
        harness.controller.play(track)

        // The first connection dies; the retry (second connection) gets the whole file.
        try await harness.waitUntil(timeout: 30) { harness.controller.loadCountForTesting >= 2 }
        try await harness.waitUntil(timeout: 30) { harness.controller.state == .playing }
        XCTAssertEqual(harness.controller.sameTrackRetriesForTesting, 1,
                       "the failure should have put one rung on the ladder")

        // Pull the audio through faster than realtime until the deck has genuinely played
        // past the dwell. The transport clock updates at 4 Hz, so the sleeps matter.
        let target = EnginePlaybackController.retryResetDwellSeconds + 2
        let deadline = Date().addingTimeInterval(60)
        while harness.controller.currentTime < target, Date() < deadline {
            _ = try await harness.renderSeconds(0.5)
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertGreaterThanOrEqual(harness.controller.currentTime, target,
                                    "the stream never played on, so the reset was never testable")
        XCTAssertEqual(harness.controller.sameTrackRetriesForTesting, 0,
                       "a track that recovered and played on must start its next failure run from zero")
        XCTAssertEqual(harness.controller.state, .playing)
    }

    /// A retry scheduled for one track must not run once another has been loaded
    /// (TBX-1000000480 C1-6). The rung only checked that the engine was still `.loading`, which
    /// the next track's own load is too, so it reloaded the old track under the new one's name.
    func testARetryForTheOldTrackDoesNotReplaceANewlyLoadedOne() async throws {
        let wav = EngineTestSignals.sineWAV(frequency: 440, seconds: 30)
        let serverA = try EngineHTTPServer(
            payload: wav,
            delivery: .truncateAfter(bytes: Self.bytesForOneSecond, connections: .max),
            contentType: "audio/wav"
        )
        defer { serverA.stop() }
        let harness = try EngineRenderHarness(sampleRate: 44_100)
        defer { harness.shutdown() }
        harness.controller.stallTimeoutSeconds = 120

        let a = EnginePlaybackController.Track(id: "A", url: serverA.url, duration: 30, supportsTimeOffset: false)
        harness.controller.play(a)
        try await harness.waitUntil(timeout: 20) { harness.controller.sameTrackRetriesForTesting == 1 }
        let connectionsAtNext = serverA.acceptedConnections

        // Next, onto a track whose server is not there (a closed port), so it is still
        // `.loading` when A's retry wakes.
        let b = EnginePlaybackController.Track(id: "B", url: URL(string: "http://127.0.0.1:9/b")!,
                                               duration: 30, supportsTimeOffset: false)
        harness.controller.play(b)
        _ = await harness.waitUntilOrTimeout(seconds: 3.5) { serverA.acceptedConnections > connectionsAtNext }

        XCTAssertEqual(serverA.acceptedConnections, connectionsAtNext, "the old track was fetched again after the new one was loaded")
        XCTAssertEqual(harness.controller.nowPlaying?.id, "B")
    }
}
