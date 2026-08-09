import AVFoundation
import XCTest
@testable import BatonPlaybackKit

/// Shared scaffolding for the engine tests: an offline (manual-rendering) pipeline + a
/// controller, and render loops that pull deterministic audio out of the graph.
///
/// The offline mode is what makes these tests *proof* rather than vibes: the engine
/// renders the same graph it uses live, but the tests pull the frames and measure them —
/// no audio hardware, no timing luck, CI-safe.
@MainActor
final class EngineRenderHarness {
    let pipeline: EngineAudioPipeline
    let controller: EnginePlaybackController
    let format: AVAudioFormat

    init(sampleRate: Double, channels: AVAudioChannelCount = 2) throws {
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: channels, interleaved: false
        )!
        pipeline = try EngineAudioPipeline(outputMode: .offline(format: format, maxFrames: 4096))
        controller = EnginePlaybackController(pipeline: pipeline)
    }

    func shutdown() {
        controller.stop()
        pipeline.shutdown()
    }

    /// Wait (with timeout) until `condition` holds, yielding so main-actor work — the
    /// feeder's scheduling hops, boundary callbacks, the clock — can run.
    func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                throw HarnessError.timeout
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    enum HarnessError: Error { case timeout, renderFailed }

    /// Render `seconds` of output as fast as the graph allows, returning channel 0.
    /// Call only once everything to be rendered is already scheduled (deterministic; a
    /// dry deck renders silence, which is exactly what gap assertions must be able to
    /// see, so this loop never waits for buffers).
    func renderSeconds(_ seconds: Double) async throws -> [Float] {
        let totalFrames = Int(seconds * format.sampleRate)
        var collected: [Float] = []
        collected.reserveCapacity(totalFrames)
        let block = AVAudioFrameCount(1024)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block) else {
            throw HarnessError.renderFailed
        }
        var rendered = 0
        while rendered < totalFrames {
            let frames = min(Int(block), totalFrames - rendered)
            let status = try pipeline.renderOffline(frames: AVAudioFrameCount(frames), into: buffer)
            guard status == .success else { throw HarnessError.renderFailed }
            appendChannelZero(of: buffer, to: &collected)
            rendered += frames
            // Let scheduled main-actor work (boundary callbacks, feeder hops) land.
            if rendered % (1024 * 8) == 0 { await Task.yield() }
        }
        return collected
    }

    /// Render paced roughly to the wall clock — for behaviours driven by real time (the
    /// crossfade ramp, the stall watchdog, the 4 Hz transport clock). `while` keeps
    /// rendering until it returns false or `maxSeconds` elapses.
    @discardableResult
    func renderPaced(maxSeconds: Double, while shouldContinue: () -> Bool = { true }) async throws -> [Float] {
        let block = 1024
        let blockSeconds = Double(block) / format.sampleRate
        var collected: [Float] = []
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)) else {
            throw HarnessError.renderFailed
        }
        let start = Date()
        while Date().timeIntervalSince(start) < maxSeconds, shouldContinue() {
            let status = try pipeline.renderOffline(frames: AVAudioFrameCount(block), into: buffer)
            guard status == .success else { throw HarnessError.renderFailed }
            appendChannelZero(of: buffer, to: &collected)
            try await Task.sleep(for: .seconds(blockSeconds))
        }
        return collected
    }

    private func appendChannelZero(of buffer: AVAudioPCMBuffer, to array: inout [Float]) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        array.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
    }
}

/// Loads the bundled MP3 fixture (68 s, 48 kHz stereo — a real music file from the demo
/// library, the same payload shape a `format=mp3` transcode delivers).
func mp3FixtureData() throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(
        forResource: "stream-fixture", withExtension: "mp3", subdirectory: "Fixtures"
    ))
    return try Data(contentsOf: url)
}
