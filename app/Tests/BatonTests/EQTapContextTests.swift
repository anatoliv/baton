import AVFoundation
import XCTest
@testable import Baton

///  + : each EQ tap owns its own filter state, coefficients are computed for the tap's
/// ACTUAL sample rate (not a hardcoded 44.1 kHz), a combined boost can't clip, and unstable
/// filter inputs are guarded.
final class EQTapContextTests: XCTestCase {
    private func spec(_ f: Double, _ q: Double, _ g: Double) -> EQCoefficients.BandSpec {
        EQCoefficients.BandSpec(frequency: f, q: q, gainDB: g)
    }
    private func coeffs(_ specs: [EQCoefficients.BandSpec]) -> EQCoefficients {
        let c = EQCoefficients(); c.setBands(specs, reference: []); return c
    }
    private func runProcess(_ ctx: EQTapContext, _ input: [Float]) -> [Float] {
        var samples = input
        samples.withUnsafeMutableBytes { raw in
            let buf = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: buf)
            withUnsafeMutablePointer(to: &abl) { ctx.process($0) }
        }
        return samples
    }
    /// The first recomputed biquad for a given rate (mirrors what a tap caches).
    private func firstBiquad(_ specs: [EQCoefficients.BandSpec], sampleRate: Double) -> Biquad {
        let buf = UnsafeMutablePointer<Biquad>.allocate(capacity: 10)
        buf.initialize(repeating: .identity, count: 10)
        defer { buf.deinitialize(count: 10); buf.deallocate() }
        _ = coeffs(specs).refreshIfChanged(knownGeneration: .max, sampleRate: sampleRate, into: buf, capacity: 10)
        return buf[0]
    }

    // MARK:  — per-tap state

    func testProcessProducesFiniteOutput() {
        let ctx = EQTapContext(coefficients: coeffs([spec(1000, 1, 6)]))
        ctx.prepare(channels: 1)
        let out = runProcess(ctx, (0 ..< 256).map { sin(Float($0) * 0.2) })
        XCTAssertTrue(out.allSatisfy { $0.isFinite })
    }

    func testIdentityPassThrough() {
        let ctx = EQTapContext(coefficients: coeffs([spec(1000, 1, 0)])) // 0 dB → identity
        ctx.prepare(channels: 1)
        let input = (0 ..< 64).map { Float($0) }
        for (a, b) in zip(input, runProcess(ctx, input)) { XCTAssertEqual(a, b, accuracy: 1e-4) }
    }

    func testTwoContextsHaveIndependentState() {
        let c = coeffs([spec(500, 1, 6)])
        let input = (0 ..< 128).map { sin(Float($0) * 0.3) }
        let a = EQTapContext(coefficients: c); a.prepare(channels: 1)
        _ = runProcess(a, input); _ = runProcess(a, input) // prime a's state
        let x = EQTapContext(coefficients: c); x.prepare(channels: 1)
        let y = EQTapContext(coefficients: c); y.prepare(channels: 1)
        for (p, q) in zip(runProcess(x, input), runProcess(y, input)) { XCTAssertEqual(p, q, accuracy: 1e-5) }
    }

    // MARK:  — sample rate, clipping, guards

    func testBandPeaksAtCentreForTheActualRate() {
        let b48 = firstBiquad([spec(1000, 1, 6)], sampleRate: 48000)
        let atCentre = b48.magnitude(atFrequency: 1000, sampleRate: 48000)
        let atShifted = b48.magnitude(atFrequency: 1000 * 48000 / 44100, sampleRate: 48000)
        XCTAssertGreaterThan(atCentre, atShifted, "peak must be at 1 kHz at 48 kHz, not the 44.1 kHz-shifted freq")
        XCTAssertEqual(atCentre, pow(10, 6.0 / 20), accuracy: 0.05, "≈ +6 dB at centre")
    }

    func testClippingPreGainAttenuatesForABoost() {
        let buf = UnsafeMutablePointer<Biquad>.allocate(capacity: 10); buf.initialize(repeating: .identity, count: 10)
        defer { buf.deinitialize(count: 10); buf.deallocate() }
        let r = coeffs([spec(1000, 1, 12)]).refreshIfChanged(knownGeneration: .max, sampleRate: 44100, into: buf, capacity: 10)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.preGain, Float(pow(10, -12.0 / 20)), accuracy: 1e-4)
        XCTAssertLessThan(r!.preGain, 1)
    }

    func testNyquistAndQGuardsStayFinite() {
        let overNyquist = Biquad.peaking(frequency: 20000, sampleRate: 8000, q: 1, gainDB: 6)
        XCTAssertTrue([overNyquist.b0, overNyquist.b1, overNyquist.b2, overNyquist.a1, overNyquist.a2].allSatisfy { $0.isFinite })
        let zeroQ = Biquad.peaking(frequency: 1000, sampleRate: 44100, q: 0, gainDB: 6)
        XCTAssertTrue([zeroQ.b0, zeroQ.b1, zeroQ.b2, zeroQ.a1, zeroQ.a2].allSatisfy { $0.isFinite })
    }
}
