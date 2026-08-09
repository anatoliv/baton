import AVFoundation
import XCTest
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// Pausing must not make a noise on the way out.
///
/// `TransportFade` ends every fade-out by restoring the envelope to 1 and re-applying it,
/// on the stated grounds that "the player is paused now, so restoring is silent". That is
/// true of `AVPlayer`, whose `pause()` stops the audio outright, and it was true for as
/// long as AVPlayer was the only thing being faded.
///
/// It is not true of `AVAudioPlayerNode`. Pausing stops scheduling, but the render pipeline
/// still holds buffered audio — so putting the level back to full is heard: the sound
/// stops, briefly returns at full volume, and stops again. Reported from the phone, in
/// those words.
///
/// The interesting part is that nothing was broken. A correct assumption quietly stopped
/// being correct when a second engine arrived underneath it, and the comment asserting it
/// went on reading as true.
@MainActor
final class EnginePauseSilenceTests: XCTestCase {

    /// A real local stream. The first version of this pointed at a dead port, so the track
    /// never reached `.playing`, `pause()` returned at its own guard, and all three tests
    /// failed while reporting the very symptom they were written to detect. A test that
    /// fails for the wrong reason is only luckier than one that passes for the wrong one.
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

    /// Playback is asynchronous: the deck has to fetch and decode before it is `.playing`,
    /// and `pause()` refuses to do anything until it is.
    private func waitUntilPlaying(_ engine: EnginePlaybackController,
                                  timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while engine.state != .playing {
            guard Date() < deadline else {
                XCTFail("the engine never started playing (state: \(engine.state))")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The load-bearing assertion: once the pause fade has run to completion, the graph is
    /// silent and *stays* silent — including after TransportFade hands the envelope back.
    func testTheGraphStaysSilentAfterAPauseFadeCompletes() async throws {
        let (engine, pipeline, server) = try makeEngine()
        defer { pipeline.shutdown(); server.stop() }

        engine.volumePercent = 100
        engine.play([track("1", server)], atTime: 0, autoplay: true)
        try await waitUntilPlaying(engine)

        engine.pause()

        // Longer than the fade (0.28s) plus the envelope restore that follows it. The blip
        // lives in exactly that window, after `pipeline.pause` and before anyone looks.
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(
            pipeline.masterVolume, 0, accuracy: 0.0001,
            """
            the graph went back to full level after the pause fade finished. On AVPlayer \
            that is silent because the player really has stopped; on AVAudioPlayerNode the \
            buffered tail is still audible, which is the blip heard on pause.
            """
        )
    }

    /// And the gate must not outlive its purpose: the next thing that plays has to be heard.
    /// Silencing the deck is only correct while there is nothing to hear.
    func testAudioIsAudibleAgainAfterResume() async throws {
        let (engine, pipeline, server) = try makeEngine()
        defer { pipeline.shutdown(); server.stop() }

        engine.volumePercent = 100
        engine.play([track("1", server)], atTime: 0, autoplay: true)
        try await waitUntilPlaying(engine)
        engine.pause()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(pipeline.masterVolume, 0, accuracy: 0.0001, "precondition: paused and silent")

        engine.resume()
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertGreaterThan(
            pipeline.masterVolume, 0.5,
            "resume left the graph muted — silencing on pause must never survive the resume"
        )
    }

    /// A new track after a stop must be audible too. A gate that persisted across a load
    /// would render a perfectly good track into a muted graph: no sound, no error, nothing
    /// to see. That is a far worse bug than the blip it was added to remove.
    func testANewTrackAfterStopIsAudible() async throws {
        let (engine, pipeline, server) = try makeEngine()
        defer { pipeline.shutdown(); server.stop() }

        engine.volumePercent = 100
        engine.play([track("1", server)], atTime: 0, autoplay: true)
        try await waitUntilPlaying(engine)
        engine.stop()
        try await Task.sleep(for: .milliseconds(600))

        engine.play([track("2", server)], atTime: 0, autoplay: true)
        try await waitUntilPlaying(engine)

        XCTAssertGreaterThan(
            pipeline.masterVolume, 0.5,
            "a track loaded after Stop rendered into a muted graph"
        )
    }
}
