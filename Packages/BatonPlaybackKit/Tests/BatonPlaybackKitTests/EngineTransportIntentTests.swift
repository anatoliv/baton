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

    private func waitUntilPlaying(_ engine: EnginePlaybackController, timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while engine.state != .playing {
            guard Date() < deadline else { return XCTFail("never started playing (state: \(engine.state))") }
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
        try await waitUntilPlaying(engine)

        engine.pause()
        // Well inside the 280 ms the fade owes its pause.
        try await Task.sleep(for: .milliseconds(60))
        engine.play(track("2", server), atTime: 0, autoplay: true)
        try await waitUntilPlaying(engine)

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

        try await waitUntilPlaying(engine)
        XCTAssertEqual(engine.state, .playing,
                       "resume during the load did not withdraw the latched pause")
    }
}
