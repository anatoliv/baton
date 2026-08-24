import AVFoundation
import XCTest
@testable import BatonPlaybackKit

/// `restartIO()` — the unconditional restart that exists because the conditional ones
/// cannot reach a wedged engine.
///
/// `play(_:)` already restarts an engine that *stopped*, and `EngineRestartAfterInterruption\
/// Tests` pins that. The case it cannot reach is an engine that is wedged rather than
/// stopped: a stalled AUHAL keeps reporting `isRunning == true` while its I/O proc never
/// cycles, so every `if !engine.isRunning` in the pipeline is a no-op against it. Measured
/// on a wedged 0.16.23 after an overnight sleep — pause/resume built a fresh I/O thread and
/// still rendered nothing, and skipping to a freshly loaded track did not help either.
///
/// These run against a real output device, because that is the only mode the call applies
/// to at all.
@MainActor
final class EngineForcedIORestartTests: XCTestCase {

    private func deviceOutputIsAvailable() -> Bool {
        AudioOutputDevices.defaultOutputDeviceID() != 0
    }

    private func offlinePipeline() throws -> EngineAudioPipeline {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                   channels: 2, interleaved: false)!
        return try EngineAudioPipeline(outputMode: .offline(format: format, maxFrames: 4096))
    }

    // MARK: - Which mode the question is even well-posed in

    /// A manual-rendering graph advances its playhead only when a caller pulls frames, so
    /// "the playhead is not moving" is its resting state. Detecting stalls there would fire
    /// on every offline test in this suite.
    func testOfflineRenderingIsNotSelfDriven() throws {
        let pipeline = try offlinePipeline()
        defer { pipeline.shutdown() }
        XCTAssertFalse(pipeline.isSelfDriven,
                       "offline rendering must not be watched for a frozen playhead — it is always frozen")
    }

    func testADeviceGraphIsSelfDriven() throws {
        try XCTSkipUnless(deviceOutputIsAvailable(), "no audio output device on this machine")
        let pipeline = try EngineAudioPipeline(outputMode: .device)
        defer { pipeline.shutdown() }
        XCTAssertTrue(pipeline.isSelfDriven,
                      "a device graph drives its own I/O, so a frozen playhead means something")
    }

    /// Restarting a manual-rendering graph would tear down the mode the caller is rendering
    /// through. It must refuse rather than half-do it.
    func testItRefusesToRestartAnOfflineGraph() throws {
        let pipeline = try offlinePipeline()
        defer { pipeline.shutdown() }
        XCTAssertFalse(pipeline.restartIO(),
                       "restarting an offline graph would break the manual rendering mode it is in")
    }

    // MARK: - The restart itself

    func testItRestartsAStoppedEngine() throws {
        try XCTSkipUnless(deviceOutputIsAvailable(), "no audio output device on this machine")
        let pipeline = try EngineAudioPipeline(outputMode: .device)
        defer { pipeline.shutdown() }

        pipeline.stopEngineForTesting()
        XCTAssertFalse(pipeline.isEngineRunningForTesting, "precondition: the engine is stopped")

        XCTAssertTrue(pipeline.restartIO(), "restartIO() reported failure on a healthy device")
        XCTAssertTrue(pipeline.isEngineRunningForTesting,
                      "restartIO() left the engine stopped — the recovery it exists for cannot work")
    }

    /// The load-bearing difference from `play(_:)`: no `isRunning` guard. An engine that
    /// already claims to be running must still be restarted, because that claim is exactly
    /// what a wedged AUHAL makes.
    func testItRestartsAnEngineThatAlreadyClaimsToBeRunning() throws {
        try XCTSkipUnless(deviceOutputIsAvailable(), "no audio output device on this machine")
        let pipeline = try EngineAudioPipeline(outputMode: .device)
        defer { pipeline.shutdown() }

        XCTAssertTrue(pipeline.isEngineRunningForTesting, "precondition: the engine starts running")
        XCTAssertTrue(pipeline.restartIO(),
                      "restartIO() declined to restart a 'running' engine — a wedged one always says that")
        XCTAssertTrue(pipeline.isEngineRunningForTesting)
    }

    /// Stopping drops whatever the decks had scheduled (`EngineStopFlushTests` measured it
    /// both ways), so the bookkeeping must say so — otherwise `aheadSeconds` stays
    /// stale-positive and the dry-detector reads a starved deck as healthy, which is the
    /// bug that put the same reset into `setOutputDevice` and `handleConfigurationChange`.
    func testItForgetsSchedulingSoTheDryDetectorIsNotBlinded() throws {
        try XCTSkipUnless(deviceOutputIsAvailable(), "no audio output device on this machine")
        let pipeline = try EngineAudioPipeline(outputMode: .device)
        defer { pipeline.shutdown() }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                   channels: 2, interleaved: false)!
        pipeline.prepareDeck(.a, format: format)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        pipeline.schedule(buffer, on: .a)
        XCTAssertGreaterThan(pipeline.aheadSeconds(on: .a), 0, "precondition: a second of audio is queued")

        pipeline.restartIO()

        XCTAssertEqual(pipeline.aheadSeconds(on: .a), 0, accuracy: 0.0001,
                       "the restart dropped the buffers but still reports them queued")
    }
}
