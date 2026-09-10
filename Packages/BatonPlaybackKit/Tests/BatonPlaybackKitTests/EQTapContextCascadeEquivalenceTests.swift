import AVFoundation
import XCTest
import BatonDSP
@testable import BatonPlaybackKit

/// TBX-5360 rewrote `process(_:)`'s three nested loops (channel, sample, band) from
/// `for ... in 0 ..< n` to `while`, for the allocation reason `EQTapContextAllocationTests`
/// covers. A loop-shape change to the code that actually shapes the audio must not move a
/// single sample, so this recomputes the same Direct Form II Transposed cascade with plain
/// arrays and an ordinary `for` loop — deliberately the pre-rewrite shape, built from the
/// type's public API rather than by reaching into its private state — and checks the real
/// `EQTapContext.process(_:)` against it sample for sample, on two channels with different
/// content so the per-channel state offset is exercised too.
final class EQTapContextCascadeEquivalenceTests: XCTestCase {
    /// The cascade `process(_:)` implements, reproduced independently: plain `Float` arrays,
    /// an ordinary `for` loop, one cascade of biquads per sample. This is the "old" shape on
    /// purpose — the point is to prove the loop rewrite is a pure refactor of this same math.
    private func referenceCascade(_ input: [Float], bands: [Biquad], preGain: Float) -> [Float] {
        var z1 = [Float](repeating: 0, count: bands.count)
        var z2 = [Float](repeating: 0, count: bands.count)
        var output = [Float](repeating: 0, count: input.count)
        for i in 0 ..< input.count {
            var x = input[i] * preGain
            for b in 0 ..< bands.count {
                let c = bands[b]
                let y = c.b0 * x + z1[b]
                z1[b] = c.b1 * x - c.a1 * y + z2[b]
                z2[b] = c.b2 * x - c.a2 * y
                x = y
            }
            output[i] = x
        }
        return output
    }

    private func makeBufferList(frames: Int, channels: [[Float]])
        -> (UnsafeMutablePointer<AudioBufferList>, [UnsafeMutablePointer<Float>]) {
        let list = AudioBufferList.allocate(maximumBuffers: channels.count)
        var storage: [UnsafeMutablePointer<Float>] = []
        for (c, samples) in channels.enumerated() {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            for i in 0 ..< frames { p[i] = samples[i] }
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

    func testProcessMatchesTheReferenceCascadeWithinTolerance() throws {
        let specs = [
            EQCoefficients.BandSpec(frequency: 100, q: 1, gainDB: 6),
            EQCoefficients.BandSpec(frequency: 1_000, q: 1.2, gainDB: -4),
            EQCoefficients.BandSpec(frequency: 8_000, q: 0.8, gainDB: 3),
        ]
        let sampleRate = 44_100.0

        let coefficients = EQCoefficients()
        coefficients.setBands(specs, reference: [])

        // Resolve the exact Biquads and pre-gain `process(_:)` will use, through the same
        // public API it calls internally — so the reference is checked against what the tap
        // actually publishes, not a second, possibly-drifted derivation of the same math.
        let dest = UnsafeMutablePointer<Biquad>.allocate(capacity: specs.count)
        defer { dest.deallocate() }
        guard let refreshed = coefficients.refreshIfChanged(
            knownGeneration: .max, sampleRate: sampleRate, into: dest, capacity: specs.count
        ) else { return XCTFail("expected the first refresh to report a change") }
        let bands = (0 ..< refreshed.count).map { dest[$0] }

        let frames = 2_048
        func tone(_ amplitude: Float, _ frequency: Double) -> [Float] {
            (0 ..< frames).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
        }
        // Two different channels on purpose, so the per-channel `state + chIdx * maxBands`
        // offset in `process(_:)` is exercised rather than two identical, order-insensitive runs.
        let channelInput = [tone(0.6, 220), tone(0.35, 3_300)]
        let expected = channelInput.map { referenceCascade($0, bands: bands, preGain: refreshed.preGain) }

        let context = EQTapContext(coefficients: coefficients, levels: nil)
        context.prepare(channels: 2, sampleRate: sampleRate)
        let (list, storage) = makeBufferList(frames: frames, channels: channelInput)
        defer { free(list, storage) }
        context.process(list)

        for channel in 0 ..< 2 {
            for i in 0 ..< frames {
                XCTAssertEqual(
                    storage[channel][i], expected[channel][i], accuracy: 1e-6,
                    "channel \(channel) sample \(i) diverged from the reference cascade"
                )
            }
        }
    }
}
