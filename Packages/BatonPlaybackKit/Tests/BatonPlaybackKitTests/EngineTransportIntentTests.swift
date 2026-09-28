import AVFoundation
import XCTest
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// Two windows in which the engine did the opposite of what it was asked.
///
/// Both are reachable by ordinary tapping, and both were invisible to the existing suite —
/// `EnginePauseSilenceTests` sleeps 600 ms past the fade before asserting anything, which
/// is exactly the window where these live.
@MainActor
final class EngineTransportIntentTests: XCTestCase {

    private func makeEngine() throws -> (EnginePlaybackController, EngineAudioPipeline, EngineHTTPServer) {
        let server = try EngineHTTPServer(payload: EngineTestSignals.sineWAV(frequency: 440, seconds: 30))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                   channels: 2, interleaved: false)!
        let pipeline = try EngineAudioPipeline(outputMode: .offline(format: format, maxFrames: 4096))
        return (EnginePlaybackController(pipeline: pipeline), pipeline, server)
    }

    private func track(_ id: String, _ server: EngineHTTPServer) -> EnginePlaybackController.Track {
        let song = NavidromeSong(id: id, title: "T\(id)", artist: "A", album: nil,
                                 duration: 30, coverArtID: nil)
        return .init(id: id, url: server.url, duration: 30, song: song, supportsTimeOffset: false)
    }

    /// Getting to `.playing` is this suite's precondition, not its claim, so the deadline is
    /// set by how starved the test process can get rather than by how long a load takes.
    ///
    /// A healthy load of this local WAV lands in milliseconds and the loop exits at once, so
    /// the long deadline costs nothing. In the gate on 2026-09-25 the first load
    /// did not even create its download for 24 s: the hop onto the `TrackStreamSource` actor
    /// waited on a starved cooperative pool while the main actor polled on schedule, every
    /// streaming test after the live seek test paid 1–3 s the same way, and the engine logged
    /// no retry at all. Fifteen seconds read that as a broken engine. A load that never lands
    /// still fails, and the message says whether the engine was retrying (loads and
    /// connections above what the test asked for) or never got to run.
    private func waitUntilPlaying(_ engine: EnginePlaybackController, _ server: EngineHTTPServer,
                                  _ step: String, timeout: TimeInterval = 60,
                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        // The longest the main actor went between polls meant 50 ms apart. Near 50 ms with a
        // load still pending means the main actor was free and the load was stuck elsewhere
        // (the cooperative pool, as in TBX-7480); seconds means the main actor itself starved.
        var lastPoll = started
        var longestGap: TimeInterval = 0
        while engine.state != .playing {
            let now = Date()
            longestGap = max(longestGap, now.timeIntervalSince(lastPoll))
            lastPoll = now
            guard now < deadline else {
                return XCTFail("""
                    \(step): never started playing after \(String(format: "%.1f", now.timeIntervalSince(started))) s \
                    (state: \(engine.state), buffering: \(engine.isBuffering), \
                    loads: \(engine.loadCountForTesting), retries: \(engine.sameTrackRetriesForTesting) \
                    of episode \(engine.episodeRetriesForTesting), connections: \(server.acceptedConnections), \
                    longest poll gap: \(Int(longestGap * 1000)) ms)
                    """, file: file, line: line)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Pause, then pick a different track before the fade finishes.
    ///
    /// The fade owes a pause for ~280 ms after `pause()` returns. Loading inside that window
    /// handed the *new* track the old track's pause: silenced and paused, while the engine
    /// reported `.playing`. Silent music that says it is playing, until you pause and
    /// resume to clear it.
    func testANewTrackIsNotPausedByTheOutgoingTracksFade() async throws {
        let (engine, pipeline, server) = try makeEngine()
        defer { pipeline.shutdown(); server.stop() }

        engine.volumePercent = 100
        engine.play(track("1", server), atTime: 0, autoplay: true)
        try await waitUntilPlaying(engine, server, "first track")

        engine.pause()
        // Well inside the 280 ms the fade owes its pause.
        try await Task.sleep(for: .milliseconds(60))
        engine.play(track("2", server), atTime: 0, autoplay: true)
        try await waitUntilPlaying(engine, server, "second track, inside the fade")

        // Past where the old owed pause would have landed.
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(engine.state, .playing,
                       "the new track was paused by the previous track's fade")
        XCTAssertGreaterThan(
            pipeline.masterVolume, 0.5,
            """
            the new track is silent: the outgoing track's owed pause silenced the graph \
            underneath it while the engine reported playing.
            """
        )
    }

    /// Pause while a track is still loading.
    ///
    /// The guard refused it, the load completed `autoplay: true` and started sounding — but
    /// the host had already moved its state, the lock screen and the button to "paused". The
    /// app showed paused and played at the same time.
    func testAPauseDuringLoadingIsHonouredWhenTheLoadLands() async throws {
        let (engine, pipeline, server) = try makeEngine()
        defer { pipeline.shutdown(); server.stop() }

        engine.volumePercent = 100
        engine.play(track("1", server), atTime: 0, autoplay: true)

        // Immediately — the load has not landed yet.
        XCTAssertEqual(engine.state, .loading, "precondition: still loading")
        engine.pause()

        try await Task.sleep(for: .milliseconds(2500))

        XCTAssertNotEqual(
            engine.state, .playing,
            "a pause asked for during loading was dropped, so the track started anyway while the UI said paused"
        )
    }

    /// …and asking to resume during the same load withdraws it, or the latch would pause
    /// a track the user has since asked for.
    func testResumingDuringLoadingWithdrawsTheLatchedPause() async throws {
        let (engine, pipeline, server) = try makeEngine()
        defer { pipeline.shutdown(); server.stop() }

        engine.volumePercent = 100
        engine.play(track("1", server), atTime: 0, autoplay: true)
        XCTAssertEqual(engine.state, .loading, "precondition: still loading")

        engine.pause()
        engine.resume()

        try await waitUntilPlaying(engine, server, "resume during load")
        XCTAssertEqual(engine.state, .playing,
                       "resume during the load did not withdraw the latched pause")
    }
}
