#if os(macOS)
import AVFoundation
import CoreAudio
import XCTest
@testable import BatonPlaybackKit

/// §1.5 of docs/audio-engine-optimization-plan.md — the render quantum, and the borrowing
/// policy around it.
///
/// These drive the **real** HAL rather than a fake, because the thing worth testing is
/// exactly the part a fake would invent: what a device advertises, what it accepts, and
/// what it does with a value out of range. The probe that motivated this found the built-in
/// output tops out at 1024 frames, not the 4096 the plan assumed — a mock would happily have
/// accepted 4096 and proved nothing.
///
/// Every test restores whatever it changed, and skips rather than fails when there is no
/// usable output device (CI without audio hardware): an absent device is not measurable,
/// which is a skip, not a broken feature.
@MainActor
final class RenderQuantumTests: XCTestCase {

    private func usableDevice() throws -> (id: AudioDeviceID, original: UInt32, range: ClosedRange<UInt32>) {
        let id = AudioOutputDevices.defaultOutputDeviceID()
        try XCTSkipIf(id == 0, "no default output device — nothing to measure")
        guard let original = AudioOutputDevices.bufferFrameSize(of: id),
              let range = AudioOutputDevices.bufferFrameSizeRange(of: id)
        else { throw XCTSkip("device \(id) does not publish a buffer size or range") }
        return (id, original, range)
    }

    // MARK: The device's own limits

    func testDeviceAdvertisesAUsableRangeContainingItsCurrentSize() throws {
        let device = try usableDevice()
        XCTAssertLessThanOrEqual(device.range.lowerBound, device.range.upperBound)
        XCTAssertTrue(device.range.contains(device.original),
                      "a device running at \(device.original) must advertise it as allowed: \(device.range)")
    }

    /// The fact the plan got wrong, pinned so nobody re-derives it from the doc.
    ///
    /// Asserted as "the ceiling is real and may be below 4096" rather than "the ceiling is
    /// 1024": that number is this hardware's, and hard-coding it would make the suite fail
    /// on a USB interface that allows more.
    func testAskingBeyondTheCeilingIsClampedRatherThanApplied() throws {
        let device = try usableDevice()
        defer { AudioOutputDevices.setBufferFrameSize(device.original, on: device.id) }

        let beyond = device.range.upperBound == UInt32.max ? UInt32.max : device.range.upperBound * 2
        _ = AudioOutputDevices.setBufferFrameSize(beyond, on: device.id)

        let after = AudioOutputDevices.bufferFrameSize(of: device.id) ?? 0
        XCTAssertLessThanOrEqual(after, device.range.upperBound,
                                 "a device must never end up above the size it advertises")
    }

    // MARK: The borrowing policy

    /// Raising is allowed, and the original comes back on shutdown.
    ///
    /// The restore is the whole reason this is safe to do at all: the buffer size belongs to
    /// the device, so every other app on that output renders at whatever Baton left behind.
    func testPipelineRaisesTheQuantumAndGivesItBackOnShutdown() throws {
        let device = try usableDevice()
        // Nothing to prove on a device already at its ceiling — and forcing it lower first
        // would be the exact rudeness the policy forbids.
        try XCTSkipIf(device.original >= device.range.upperBound,
                      "device already at its ceiling (\(device.original)) — no headroom to test")

        let pipeline: EngineAudioPipeline
        do {
            pipeline = try EngineAudioPipeline(outputMode: .device)
        } catch {
            throw XCTSkip("engine would not start on this machine: \(error)")
        }

        let raised = AudioOutputDevices.bufferFrameSize(of: device.id) ?? 0
        XCTAssertGreaterThan(raised, device.original,
                             "the engine should have raised the render quantum")
        XCTAssertLessThanOrEqual(raised, device.range.upperBound, "and stayed inside the range")

        pipeline.shutdown()
        XCTAssertEqual(AudioOutputDevices.bufferFrameSize(of: device.id), device.original,
                       "the device must be handed back exactly what it had")
    }

    /// A device already running larger than we want is left alone.
    ///
    /// Someone else asked for that size. Shrinking it to "our" number would be the same
    /// mistake as re-pointing every app's output from a button in a transport bar.
    func testAnAlreadyLargerQuantumIsNotShrunk() throws {
        let device = try usableDevice()
        let ceiling = device.range.upperBound
        try XCTSkipIf(ceiling <= device.range.lowerBound, "no headroom on this device")
        defer { AudioOutputDevices.setBufferFrameSize(device.original, on: device.id) }

        // Stand in for another app having raised it to the device's maximum.
        guard AudioOutputDevices.setBufferFrameSize(ceiling, on: device.id),
              AudioOutputDevices.bufferFrameSize(of: device.id) == ceiling
        else { throw XCTSkip("device would not accept its own advertised ceiling") }

        let pipeline: EngineAudioPipeline
        do {
            pipeline = try EngineAudioPipeline(outputMode: .device)
        } catch {
            throw XCTSkip("engine would not start on this machine: \(error)")
        }
        defer { pipeline.shutdown() }

        XCTAssertEqual(AudioOutputDevices.bufferFrameSize(of: device.id), ceiling,
                       "a device another app already raised must be left where it is")
    }

    /// Offline rendering has no device, so none of this may run — and must not crash.
    func testOfflinePipelineTouchesNoDevice() throws {
        let device = try usableDevice()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                   channels: 2, interleaved: false)!
        let pipeline = try EngineAudioPipeline(outputMode: .offline(format: format, maxFrames: 4096))
        defer { pipeline.shutdown() }

        XCTAssertEqual(AudioOutputDevices.bufferFrameSize(of: device.id), device.original,
                       "an offline render must leave the hardware entirely alone")
    }
}
#endif
