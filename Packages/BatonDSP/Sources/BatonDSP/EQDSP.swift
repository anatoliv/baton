import Foundation
import os

// Pure equalizer DSP — parametric bands, RBJ peaking biquads, and the lock-protected coefficient
// set the audio-thread tap reads. Foundation + os only, no app/UI/state dependencies. Extracted
// from the Baton target as the first SPM module of the W-51 boundary split; the app re-exports it
// (`@_exported import BatonDSP`) so existing `EQBand`/`Biquad`/… call sites are unchanged.

/// Equalizer parameter limits + the default band layout — pure config the DSP and the store share.
/// Lives with the DSP (not the store) so the DSP has no back-reference to `MusicEqualizer`. (W-51)
public enum EQLimits {
    /// ISO-ish 10-band centre frequencies (Hz) — the default band layout.
    public static let frequencies: [Double] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    /// Default Q for the graphic-style bands (moderately wide, so neighbours overlap).
    public static let defaultQ: Double = 1.0
    public static let minGain: Double = -12
    public static let maxGain: Double = 12
    public static let minQ: Double = 0.3
    public static let maxQ: Double = 10
    public static let minFrequency: Double = 20
    public static let maxFrequency: Double = 20_000
}

/// One parametric peaking band: centre frequency (Hz), Q (bandwidth), and gain (dB).
public struct EQBand: Codable, Equatable, Sendable, Identifiable {
    public var frequency: Double
    public var q: Double
    public var gainDB: Double
    /// Stable identity for `ForEach` in the editor — derived from the centre frequency
    /// at construction so reorders don't churn identities during a drag.
    public let id: UUID

    public init(frequency: Double, q: Double, gainDB: Double, id: UUID = UUID()) {
        self.frequency = frequency
        self.q = q
        self.gainDB = gainDB
        self.id = id
    }

    private enum CodingKeys: String, CodingKey { case frequency, q, gainDB }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try c.decode(Double.self, forKey: .frequency)
        q = try c.decode(Double.self, forKey: .q)
        gainDB = try c.decode(Double.self, forKey: .gainDB)
        id = UUID()
    }

    /// Clamp all parameters into the equalizer's supported ranges.
    public func clamped() -> EQBand {
        EQBand(
            frequency: min(EQLimits.maxFrequency, max(EQLimits.minFrequency, frequency)),
            q: min(EQLimits.maxQ, max(EQLimits.minQ, q)),
            gainDB: min(EQLimits.maxGain, max(EQLimits.minGain, gainDB)),
            id: id
        )
    }
}

/// A named preset — either a graphic preset (gains on the default band layout) or a
/// parametric one (explicit frequency/Q/gain bands).
public struct EQPreset: Sendable {
    public let name: String
    public let bands: [EQBand]

    public init(name: String, bands: [EQBand]) {
        self.name = name
        self.bands = bands
    }

    public static func graphic(_ name: String, _ gains: [Double]) -> EQPreset {
        EQPreset(name: name, bands: zip(EQLimits.frequencies, gains).map {
            EQBand(frequency: $0, q: EQLimits.defaultQ, gainDB: $1)
        })
    }

    public static func parametric(_ name: String, _ bands: [EQBand]) -> EQPreset {
        EQPreset(name: name, bands: bands)
    }
}

/// A single peaking-EQ biquad (RBJ cookbook), normalized by a0.
public struct Biquad: Sendable {
    public var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float

    public init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    public static let identity = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public static func peaking(frequency f0: Double, sampleRate fs: Double, q: Double, gainDB: Double) -> Biquad {
        guard gainDB != 0, fs > 0 else { return .identity }
        // Clamp against a zero/negative Q and a centre at/above Nyquist — both yield an
        // unstable/NaN filter that would propagate through the cascade. (AUDIO-26)
        let qSafe = max(q, 0.1)
        let f = min(max(f0, 1), fs * 0.45)
        let a = pow(10.0, gainDB / 40.0)
        let w0 = 2 * Double.pi * f / fs
        let alpha = sin(w0) / (2 * qSafe)
        let cosW = cos(w0)
        let b0 = 1 + alpha * a
        let b1 = -2 * cosW
        let b2 = 1 - alpha * a
        let a0 = 1 + alpha / a
        let a1 = -2 * cosW
        let a2 = 1 - alpha / a
        let result = Biquad(
            b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
            a1: Float(a1 / a0), a2: Float(a2 / a0)
        )
        // Defensive: never return a non-finite filter.
        let coeffs = [result.b0, result.b1, result.b2, result.a1, result.a2]
        return coeffs.allSatisfy { $0.isFinite } ? result : .identity
    }

    /// Magnitude response |H(e^{jω})| at frequency `f0` (Hz) for sample rate `fs`.
    /// Used by the UI to draw the combined response curve (and testable in isolation).
    public func magnitude(atFrequency f0: Double, sampleRate fs: Double) -> Double {
        let w = 2 * Double.pi * f0 / fs
        // Numerator/denominator evaluated on the unit circle: z = e^{jw}.
        let cos1 = cos(w), cos2 = cos(2 * w)
        let sin1 = sin(w), sin2 = sin(2 * w)
        let numRe = Double(b0) + Double(b1) * cos1 + Double(b2) * cos2
        let numIm = -(Double(b1) * sin1 + Double(b2) * sin2)
        let denRe = 1 + Double(a1) * cos1 + Double(a2) * cos2
        let denIm = -(Double(a1) * sin1 + Double(a2) * sin2)
        let numMag = (numRe * numRe + numIm * numIm).squareRoot()
        let denMag = (denRe * denRe + denIm * denIm).squareRoot()
        return denMag == 0 ? 1 : numMag / denMag
    }
}

/// Thread-safe holder for the current biquad set — written on the main actor, read on the
/// audio render thread. Uses an unfair lock (short critical sections, no priority issues).
public final class EQCoefficients: @unchecked Sendable {
    /// One band's rate-independent parameters, so a tap can compute biquads for its OWN
    /// sample rate instead of a hardcoded 44.1 kHz. (W-21 / AUDIO-01)
    public struct BandSpec: Sendable {
        public let frequency: Double
        public let q: Double
        public let gainDB: Double
        public init(frequency: Double, q: Double, gainDB: Double) {
            self.frequency = frequency
            self.q = q
            self.gainDB = gainDB
        }
    }

    private var lock = os_unfair_lock_s()
    private var specs: [BandSpec] = []
    private var referenceBiquads: [Biquad] = [] // computed at 44.1 kHz, for the UI response curve
    private var generation: UInt64 = 0

    public init() {}

    /// Publish the raw band specs (so each tap recomputes for its rate) plus the reference-rate
    /// biquads (for the UI). Bumps the generation so live taps refresh.
    public func setBands(_ newSpecs: [BandSpec], reference: [Biquad]) {
        os_unfair_lock_lock(&lock)
        specs = newSpecs
        referenceBiquads = reference
        generation &+= 1
        os_unfair_lock_unlock(&lock)
    }

    /// Reference-rate (44.1 kHz) biquads, for drawing the UI response curve.
    public func snapshot() -> [Biquad] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return referenceBiquads
    }

    /// If the band set changed since `knownGeneration`, recompute biquads for `sampleRate` into
    /// `dest` and return the new generation, band count, and an auto pre-gain that keeps the
    /// combined boost from clipping (AUDIO-08). Non-blocking (trylock) and only does real work
    /// on a change, so the steady-state render path just fast-returns nil. (W-21)
    public func refreshIfChanged(
        knownGeneration: UInt64, sampleRate: Double,
        into dest: UnsafeMutablePointer<Biquad>, capacity: Int
    ) -> (generation: UInt64, count: Int, preGain: Float)? {
        guard os_unfair_lock_trylock(&lock) else { return nil }
        defer { os_unfair_lock_unlock(&lock) }
        guard generation != knownGeneration else { return nil }
        let count = Swift.min(specs.count, capacity)
        var maxBoostDB = 0.0
        for i in 0 ..< count {
            let s = specs[i]
            dest[i] = Biquad.peaking(frequency: s.frequency, sampleRate: sampleRate, q: s.q, gainDB: s.gainDB)
            if s.gainDB > 0 { maxBoostDB = Swift.max(maxBoostDB, s.gainDB) }
        }
        let preGain = maxBoostDB > 0 ? Float(pow(10.0, -maxBoostDB / 20.0)) : 1
        return (generation, count, preGain)
    }
}
