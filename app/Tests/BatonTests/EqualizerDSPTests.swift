import Foundation
import Testing
@testable import Baton

/// DSP-level tests for the parametric equalizer: biquad coefficient math against
/// hand-computed reference values, magnitude-response sanity, parametric→biquad recompute
/// stability, and that the legacy graphic gain API still targets the right band.
@Suite("Equalizer DSP")
struct EqualizerDSPTests {
    // MARK: - Biquad coefficient math

    @Test("Peaking biquad matches hand-computed RBJ coefficients (1kHz, Q=1, +6dB @ 44.1k)")
    func peakingCoefficientsAreCorrect() {
        // Reference values computed independently from the RBJ cookbook formulas.
        let b = Biquad.peaking(frequency: 1000, sampleRate: 44100, q: 1, gainDB: 6)
        let tol: Float = 1e-4
        #expect(abs(b.b0 - 1.0476300) < tol)
        #expect(abs(b.b1 - (-1.8849913)) < tol)
        #expect(abs(b.b2 - 0.8566565) < tol)
        #expect(abs(b.a1 - (-1.8849913)) < tol)
        #expect(abs(b.a2 - 0.9042865) < tol)
    }

    @Test("0 dB gain is exactly the identity filter")
    func zeroGainIsIdentity() {
        let b = Biquad.peaking(frequency: 1000, sampleRate: 44100, q: 1, gainDB: 0)
        #expect(b.b0 == 1 && b.b1 == 0 && b.b2 == 0 && b.a1 == 0 && b.a2 == 0)
    }

    @Test("Magnitude at the centre frequency equals the linear gain")
    func magnitudeAtCentreMatchesGain() {
        // A +6 dB peak has magnitude 10^(6/20) ≈ 1.9953 at its centre frequency.
        let b = Biquad.peaking(frequency: 1000, sampleRate: 44100, q: 1, gainDB: 6)
        let mag = b.magnitude(atFrequency: 1000, sampleRate: 44100)
        #expect(abs(mag - pow(10.0, 6.0 / 20.0)) < 1e-3)

        // A −6 dB cut is the reciprocal at its centre.
        let cut = Biquad.peaking(frequency: 1000, sampleRate: 44100, q: 1, gainDB: -6)
        let cutMag = cut.magnitude(atFrequency: 1000, sampleRate: 44100)
        #expect(abs(cutMag - pow(10.0, -6.0 / 20.0)) < 1e-3)
    }

    @Test("A narrower Q makes a tighter peak (less gain one octave away)")
    func higherQIsNarrower() {
        let wide = Biquad.peaking(frequency: 1000, sampleRate: 44100, q: 0.7, gainDB: 6)
        let narrow = Biquad.peaking(frequency: 1000, sampleRate: 44100, q: 4, gainDB: 6)
        // One octave up (2 kHz): the wide filter still boosts more than the narrow one.
        let wideAt2k = wide.magnitude(atFrequency: 2000, sampleRate: 44100)
        let narrowAt2k = narrow.magnitude(atFrequency: 2000, sampleRate: 44100)
        #expect(wideAt2k > narrowAt2k)
    }

    // MARK: - Parametric → biquad recompute

    @MainActor
    @Test("Parametric recompute is stable and reflects each band's params")
    func recomputeReflectsBands() {
        let eq = MusicEqualizer()
        eq.reset()
        eq.isEnabled = true

        // Editing a band's frequency/Q/gain recomputes and publishes that band's biquad.
        eq.setGain(6, band: 3)
        eq.setFrequency(500, band: 3)
        eq.setQ(2.0, band: 3)

        let published = eq.coefficients.snapshot()
        #expect(published.count == eq.bands.count)
        let expected = Biquad.peaking(frequency: 500, sampleRate: 44100, q: 2.0, gainDB: 6)
        #expect(abs(published[3].b0 - expected.b0) < 1e-5)
        #expect(abs(published[3].a2 - expected.a2) < 1e-5)

        // Recomputing again with identical params yields identical coefficients (stable).
        eq.setQ(2.0, band: 3)
        let again = eq.coefficients.snapshot()
        #expect(again[3].b0 == published[3].b0)
        #expect(again[3].a2 == published[3].a2)
    }

    @MainActor
    @Test("Disabled equalizer publishes an all-flat pass-through")
    func disabledIsFlat() {
        let eq = MusicEqualizer()
        eq.reset()
        eq.isEnabled = true
        eq.setGain(9, band: 2)
        eq.isEnabled = false
        let flat = eq.coefficients.snapshot()
        for b in flat {
            #expect(b.b0 == 1 && b.b1 == 0 && b.b2 == 0 && b.a1 == 0 && b.a2 == 0)
        }
    }

    // MARK: - Legacy API compatibility

    @MainActor
    @Test("Legacy setGain(band:) adjusts the correct band and keeps default freq/Q")
    func legacyGainAPITargetsRightBand() {
        let eq = MusicEqualizer()
        eq.reset()
        eq.setGain(4.5, band: 5)

        // gains reads back per-band gains in band order.
        #expect(eq.gains.count == 10)
        #expect(eq.gains[5] == 4.5)
        #expect(eq.gains[4] == 0)

        // The band keeps its default centre frequency and Q.
        #expect(eq.bands[5].frequency == MusicEqualizer.frequencies[5])
        #expect(eq.bands[5].q == MusicEqualizer.defaultQ)
        #expect(eq.bands[5].gainDB == 4.5)

        // Gains are clamped to ±12 dB.
        eq.setGain(99, band: 0)
        #expect(eq.gains[0] == 12)
        eq.setGain(-99, band: 0)
        #expect(eq.gains[0] == -12)
    }

    @MainActor
    @Test("Legacy apply(preset:) still maps a named graphic preset onto the bands")
    func legacyPresetStillWorks() {
        let eq = MusicEqualizer()
        eq.apply(preset: "Bass Boost")
        #expect(eq.preset == "Bass Boost")
        // Bass Boost lifts the low bands and leaves the highs flat.
        #expect(eq.gains[0] == 6)
        #expect(eq.gains[9] == 0)
    }

    @MainActor
    @Test("Parametric presets set explicit frequency/Q/gain bands")
    func parametricPresetShapesBands() {
        let eq = MusicEqualizer()
        eq.apply(preset: "Vocal Boost")
        #expect(eq.preset == "Vocal Boost")
        // The 3 kHz presence band is boosted with a focused Q.
        let presence = eq.bands.first { abs($0.frequency - 3000) < 1 }
        #expect(presence != nil)
        #expect((presence?.gainDB ?? 0) > 0)
    }
}
