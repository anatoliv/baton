import AVFoundation
import XCTest
import BatonDSP
@testable import BatonPlaybackKit

/// `EQTapContext.process(_:)` is the CoreAudio tap callback, and unlike
/// `EQCoefficients.refreshIfChanged` (fixed in PR #113 / S-F23), it runs on the render thread
/// for every buffer whether or not the band set just changed — `TapMeteringTests` already
/// relies on that ("processing audio must still publish levels"). So a debug build can glitch
/// under a steady, unchanging EQ where a release build never would, which is exactly the kind
/// of difference that makes an audio bug unreproducible.
final class EQTapContextAllocationTests: XCTestCase {
    private func makeBufferList(frames: Int, channels: Int, fill: (Int, Int) -> Float)
        -> (UnsafeMutablePointer<AudioBufferList>, [UnsafeMutablePointer<Float>]) {
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        var storage: [UnsafeMutablePointer<Float>] = []
        for c in 0 ..< channels {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            for i in 0 ..< frames { p[i] = fill(c, i) }
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

    /// A steady EQ — bands set once, never edited again — processing twenty buffers of a real
    /// stereo tone. `levels: nil` isolates the measurement to `process(_:)`'s own three loops
    /// (channel, sample, band): metering has its own allocation profile (`LevelAnalyzer.analyze`,
    /// a different package) that this card does not cover — see the PR description.
    func testProcessOnAFullBufferAllocatesNothing() throws {
        try XCTSkipUnless(AllocationCounter.isAvailable, "malloc_logger is not available here")

        let coefficients = EQCoefficients()
        coefficients.setBands([
            EQCoefficients.BandSpec(frequency: 100, q: 1, gainDB: 6),
            EQCoefficients.BandSpec(frequency: 1_000, q: 1.2, gainDB: -4),
            EQCoefficients.BandSpec(frequency: 8_000, q: 0.8, gainDB: 3),
        ], reference: [])

        let context = EQTapContext(coefficients: coefficients, levels: nil)
        context.prepare(channels: 2, sampleRate: 44_100)

        let frames = 1_024
        var phase = 0.0
        let (list, storage) = makeBufferList(frames: frames, channels: 2) { channel, _ in
            defer { phase += 2 * Double.pi * 220 / 44_100 }
            return (channel == 0 ? 0.6 : 0.4) * Float(sin(phase))
        }
        defer { free(list, storage) }

        // Warm up outside the measurement: the first call does a real, one-time coefficient
        // refresh (the band set was just published) that this test does not care about — the
        // steady-state render path is every call after.
        context.process(list)

        var total = 0
        for _ in 0 ..< 20 {
            total += AllocationCounter.measure { context.process(list) }
        }

        XCTAssertEqual(
            total, 0,
            "process(_:) allocated \(total) times across 20 buffers on the render thread"
        )
    }
}
