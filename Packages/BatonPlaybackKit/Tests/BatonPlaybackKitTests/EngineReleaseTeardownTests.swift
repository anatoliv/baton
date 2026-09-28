import AVFoundation
import XCTest
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// A controller that goes away takes its downloads with it.
///
/// `stop()` tears down inside the fade's completion, and the fade belongs to the controller.
/// Release the controller before the fade finishes and the completion never runs, so the
/// stream kept downloading in the background: a whole 128 MB file after the live seek test,
/// in the gate run where every streaming test afterwards started slowly.
@MainActor
final class EngineReleaseTeardownTests: XCTestCase {

    func testAReleasedControllerStopsItsDownload() async throws {
        // About 13 s to deliver at this pace, so a download still running seconds after the
        // release is the leak rather than a transfer that happened to finish.
        let server = try EngineHTTPServer(
            payload: EngineTestSignals.sineWAV(frequency: 440, seconds: 30),
            delivery: .rangeCapable(bytesPerSecond: 200_000)
        )
        defer { server.stop() }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                   channels: 2, interleaved: false)!
        var pipeline: EngineAudioPipeline? = try EngineAudioPipeline(
            outputMode: .offline(format: format, maxFrames: 4096))
        var engine: EnginePlaybackController? = EnginePlaybackController(pipeline: pipeline!)
        weak let released = engine

        let song = NavidromeSong(id: "1", title: "T1", artist: "A", album: nil,
                                 duration: 30, coverArtID: nil)
        engine!.play(.init(id: "1", url: server.url, duration: 30, song: song,
                           supportsTimeOffset: false), atTime: 0, autoplay: true)
        let connected = Date().addingTimeInterval(10)
        while server.openConnections == 0, Date() < connected {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(server.openConnections, 1, "precondition: the download is running")

        // What a test's `defer { harness.shutdown() }` does, then the harness goes away.
        engine!.stop()
        pipeline!.shutdown()
        engine = nil
        pipeline = nil

        let deadline = Date().addingTimeInterval(3)
        while server.openConnections > 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(released, "precondition: the controller was actually released")
        XCTAssertEqual(server.openConnections, 0,
                       "the released controller's stream is still downloading")
    }

    /// The live seek test ended here: a stream that will not parse, four loads, then `.error`.
    /// Giving up used to leave the last load's download running.
    func testGivingUpOnATrackStopsItsDownload() async throws {
        var noise = Data(count: 3_000_000)
        noise.withUnsafeMutableBytes { raw in
            for i in 0 ..< raw.count { raw[i] = UInt8(truncatingIfNeeded: i &* 2_654_435_761 >> 13) }
        }
        let server = try EngineHTTPServer(payload: noise, delivery: .rangeCapable(bytesPerSecond: 200_000))
        defer { server.stop() }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                   channels: 2, interleaved: false)!
        let pipeline = try EngineAudioPipeline(outputMode: .offline(format: format, maxFrames: 4096))
        defer { pipeline.shutdown() }
        let engine = EnginePlaybackController(pipeline: pipeline)
        let song = NavidromeSong(id: "1", title: "T1", artist: "A", album: nil,
                                 duration: 60, coverArtID: nil)
        engine.play(.init(id: "1", url: server.url, duration: 60, song: song,
                          supportsTimeOffset: false), atTime: 0, autoplay: true)

        let gaveUp = Date().addingTimeInterval(20)
        while Date() < gaveUp {
            if case .error = engine.state { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .error = engine.state else {
            return XCTFail("precondition: the engine should give up on noise (state: \(engine.state))")
        }
        XCTAssertGreaterThan(server.acceptedConnections, 1, "precondition: the ladder retried")

        let deadline = Date().addingTimeInterval(3)
        while server.openConnections > 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(server.openConnections, 0,
                       "a track the engine gave up on is still downloading")
    }
}
