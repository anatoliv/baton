import AVFoundation
import XCTest
import BatonDSP
@testable import BatonPlaybackKit

/// Does the tap actually publish levels?
///
/// Written after the indicator shipped looking reactive and measurably wasn't: on-screen the
/// bar heights matched the canned animation's constants exactly, in both the meter-on and
/// meter-off builds. Everything in isolation passed — the analyzer read bands correctly, the
/// snapshot round-tripped, the monitor started and stopped — because nothing tested the one
/// seam where they meet. This is that seam.
final class TapMeteringTests: XCTestCase {
    /// Build a deinterleaved stereo buffer list of a loud tone and hand it to the context the
    /// way `tapProcess` does.
    private func makeBufferList(frames: Int, channels: Int, fill: (Int) -> Float)
        -> (UnsafeMutablePointer<AudioBufferList>, [UnsafeMutablePointer<Float>]) {
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        var storage: [UnsafeMutablePointer<Float>] = []
        for c in 0 ..< channels {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            for i in 0 ..< frames { p[i] = fill(i) }
            storage.append(p)
            list[c] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(p)
            )
        }
        return (list.unsafeMutablePointer, storage)
    }

    private func free(_ list: UnsafeMutablePointer<AudioBufferList>, _ storage: [UnsafeMutablePointer<Float>]) {
        for p in storage { p.deallocate() }
        list.deallocate()
    }

    /// The headline: with the EQ **off** — which is the default, and how nearly everyone runs —
    /// processing audio must still publish levels. Gating the meter behind the equalizer is
    /// exactly the bug this guards.
    func testProcessPublishesLevelsWithNoEQBandsEnabled() {
        let snapshot = LevelSnapshot()
        let context = EQTapContext(coefficients: EQCoefficients(), levels: snapshot)
        context.prepare(channels: 2, sampleRate: 44_100)

        let frames = 1024
        var phase = 0.0
        let (list, storage) = makeBufferList(frames: frames, channels: 2) { _ in
            defer { phase += 2 * Double.pi * 220 / 44_100 }
            return 0.6 * Float(sin(phase))
        }
        defer { free(list, storage) }

        for _ in 0 ..< 30 { context.process(list) }

        let levels = snapshot.load()
        XCTAssertGreaterThan(levels.peak, 0,
                             "the tap ran but published silence — the meter is not wired to the render path")
        XCTAssertGreaterThan(levels.low + levels.lowMid, levels.high,
                             "a 220 Hz tone must weight the lower bands")
    }

    func testSilentAudioPublishesSilence() {
        let snapshot = LevelSnapshot()
        let context = EQTapContext(coefficients: EQCoefficients(), levels: snapshot)
        context.prepare(channels: 2, sampleRate: 44_100)
        let (list, storage) = makeBufferList(frames: 512, channels: 2) { _ in 0 }
        defer { free(list, storage) }

        for _ in 0 ..< 40 { context.process(list) }
        XCTAssertEqual(snapshot.load().peak, 0, accuracy: 0.01)
    }

    /// Metering must not alter a single sample — it is a read of the audio, not a stage in it.
    func testMeteringDoesNotChangeTheAudio() {
        let snapshot = LevelSnapshot()
        let context = EQTapContext(coefficients: EQCoefficients(), levels: snapshot)
        context.prepare(channels: 1, sampleRate: 44_100)

        let frames = 256
        let (list, storage) = makeBufferList(frames: frames, channels: 1) { i in
            Float(sin(Double(i) * 0.05)) * 0.5
        }
        defer { free(list, storage) }
        let before = (0 ..< frames).map { storage[0][$0] }

        context.process(list)

        for i in 0 ..< frames {
            XCTAssertEqual(storage[0][i], before[i], accuracy: 0, "metering rewrote the audio")
        }
    }

    /// A context built without a snapshot must be harmless — the EQ-only path still exists.
    func testNoSnapshotIsHarmless() {
        let context = EQTapContext(coefficients: EQCoefficients(), levels: nil)
        context.prepare(channels: 2, sampleRate: 48_000)
        let (list, storage) = makeBufferList(frames: 256, channels: 2) { _ in 0.3 }
        defer { free(list, storage) }
        context.process(list)   // must not crash
    }

    /// An interleaved single-buffer layout (some devices/formats) must still meter rather than
    /// silently reporting nothing.
    func testInterleavedLayoutStillMeters() {
        let snapshot = LevelSnapshot()
        let context = EQTapContext(coefficients: EQCoefficients(), levels: snapshot)
        context.prepare(channels: 2, sampleRate: 44_100)

        let frames = 1024
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        let p = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        for i in 0 ..< frames * 2 { p[i] = 0.5 * Float(sin(Double(i) * 0.02)) }
        list[0] = AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(p)
        )
        defer { p.deallocate(); list.unsafeMutablePointer.deallocate() }

        for _ in 0 ..< 30 { context.process(list.unsafeMutablePointer) }
        XCTAssertGreaterThan(snapshot.load().peak, 0, "interleaved audio published nothing")
    }
}
