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

    // MARK: - Does it actually shape audio?

    /// RMS of a sine at `frequency` after passing through a tap with `specs`.
    private func rms(_ frequency: Double, specs: [EQCoefficients.BandSpec],
                     sampleRate: Double = 44100, samples: Int = 8192) -> Double {
        let ctx = EQTapContext(coefficients: coeffs(specs))
        ctx.prepare(channels: 1)
        let input = (0 ..< samples).map {
            Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate))
        }
        // Drop the first block: a biquad's state starts at zero, so the opening samples are
        // the filter settling rather than its steady-state response.
        let out = Array(runProcess(ctx, input).dropFirst(1024)).map(Double.init)
        return (out.reduce(0) { $0 + $1 * $1 } / Double(out.count)).squareRoot()
    }

    private func dB(_ ratio: Double) -> Double { 20 * log10(ratio) }

    /// The claim the whole feature rests on, and the one nothing tested: a signal put
    /// through the tap comes out *shaped*.
    ///
    /// Everything else here checks the coefficients — that the maths describing the filter
    /// is right. None of it runs audio through `process`, so a render loop that computed
    /// perfect biquads and then forgot to apply them would pass the entire suite. Both apps
    /// share this path, so this is the equalizer working, or not, on the Mac and the phone
    /// at once.
    ///
    /// Measured as a *ratio between frequencies*, not an absolute level, because a boost is
    /// deliberately paired with an equal pre-gain attenuation for headroom — see
    /// `testClippingPreGainAttenuatesForABoost`. A +12 dB band therefore leaves its centre
    /// near unity and pushes everything else down; what you hear is the difference.
    func testABoostedBandIsAudiblyLouderThanAnUntouchedOne() {
        let boostAt1k = [spec(1000, 1, 12)]

        let centre = rms(1000, specs: boostAt1k)
        let away = rms(8000, specs: boostAt1k)

        XCTAssertGreaterThan(dB(centre / away), 9,
                             "a +12 dB band must leave its centre ~12 dB above an untouched "
                             + "frequency — if this fails the filter isn't being applied at all")
    }

    /// The other direction, so the test can't pass on a filter that merely attenuates
    /// everything except the band it was given.
    func testACutBandIsQuieterThanAnUntouchedOne() {
        let cutAt1k = [spec(1000, 1, -12)]

        let centre = rms(1000, specs: cutAt1k)
        let away = rms(8000, specs: cutAt1k)

        XCTAssertLessThan(dB(centre / away), -9, "a -12 dB band must sink its centre")
    }

    /// A flat curve must leave the signal alone. Guards the opposite failure: a tap that
    /// colours the sound even with every band at zero.
    func testAFlatCurveLeavesTheSignalUnchanged() {
        let flat = MusicEqualizer.frequencies.map { spec($0, 1, 0) }

        let level = rms(1000, specs: flat)
        let reference = (0 ..< 8192).map { sin(2 * Double.pi * 1000 * Double($0) / 44100) }
        let expected = (reference.dropFirst(1024).reduce(0) { $0 + $1 * $1 }
                        / Double(reference.count - 1024)).squareRoot()

        XCTAssertEqual(level, expected, accuracy: 0.01,
                       "a flat equalizer must be inaudible, not merely quiet")
    }
}
