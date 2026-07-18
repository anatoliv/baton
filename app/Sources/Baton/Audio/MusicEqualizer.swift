import Foundation
import Observation
import os

/// A parametric equalizer for the music player. Each band carries its own centre
/// frequency, Q (bandwidth), and gain, so bands can be reshaped — not just boosted or
/// cut on a fixed grid. The equalizer persists its config, recomputes the biquad
/// coefficients on every edit, and publishes them to the audio tap (`AudioEQProcessor`)
/// that actually filters the samples. Disabled by default, in which case the published
/// set is all-flat and an attached tap is a pass-through.
///
/// The legacy 10-band graphic API (`gains`, `setGain(_:band:)`, `apply(preset:)`) is kept
/// intact and maps onto the parametric model: gain-only edits keep each band's default
/// frequency and Q, and `gains` reads back the per-band gains in band order.
@MainActor
@Observable
final class MusicEqualizer {
    /// ISO-ish 10-band centre frequencies (Hz) — the default band layout.
    nonisolated static let frequencies: [Double] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    /// Default Q for the graphic-style bands (moderately wide, so neighbours overlap).
    nonisolated static let defaultQ: Double = 1.0

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey); publish(); onToggle?() }
    }
    /// Called when `isEnabled` flips — AppModel uses it to attach/detach the audio-mix tap.
    @ObservationIgnored var onToggle: (() -> Void)?

    /// The parametric bands, in ascending frequency order. Source of truth for the DSP.
    private(set) var bands: [EQBand]

    var preset: String {
        didSet { UserDefaults.standard.set(preset, forKey: Self.presetKey) }
    }

    /// Legacy shim: per-band gains in dB, one per band. Reads/writes `bands[i].gainDB`.
    var gains: [Double] { bands.map(\.gainDB) }

    /// Shared, lock-protected coefficients the audio-thread tap reads.
    @ObservationIgnored let coefficients = EQCoefficients()

    @ObservationIgnored static let enabledKey = "tonebox.music.eq.enabled"
    @ObservationIgnored static let gainsKey = "tonebox.music.eq.gains"
    @ObservationIgnored static let presetKey = "tonebox.music.eq.preset"
    @ObservationIgnored static let bandsKey = "tonebox.music.eq.bands"

    /// Gain limits (dB) enforced on every edit.
    nonisolated static let minGain: Double = -12
    nonisolated static let maxGain: Double = 12
    /// Q limits — narrow (surgical) to wide (gentle shelf-like) peaks.
    nonisolated static let minQ: Double = 0.3
    nonisolated static let maxQ: Double = 10
    /// Frequency limits (Hz) — the audible band.
    nonisolated static let minFrequency: Double = 20
    nonisolated static let maxFrequency: Double = 20_000

    /// The default flat band layout: one peaking band per default frequency.
    static func defaultBands() -> [EQBand] {
        frequencies.map { EQBand(frequency: $0, q: defaultQ, gainDB: 0) }
    }

    /// Presets. Graphic presets set gains on the default band layout; parametric presets
    /// reshape frequency/Q/gain per band. All still selectable by name via `apply(preset:)`.
    static let presets: [EQPreset] = [
        .graphic("Flat", Array(repeating: 0, count: 10)),
        .graphic("Bass Boost", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        .graphic("Treble Boost", [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        .graphic("Vocal", [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1]),
        .graphic("Rock", [4, 3, 1, -1, -1, 0, 2, 3, 4, 4]),
        .graphic("Electronic", [5, 4, 1, 0, -2, 1, 0, 1, 3, 5]),
        .graphic("Loudness", [6, 4, 0, 0, -2, 0, 0, 0, 4, 6]),
        // Parametric presets: focused bands with hand-picked centre/Q/gain.
        .parametric("Vocal Boost", [
            EQBand(frequency: 200, q: 1.0, gainDB: -2),
            EQBand(frequency: 1_000, q: 1.2, gainDB: 3),
            EQBand(frequency: 3_000, q: 1.6, gainDB: 4),
            EQBand(frequency: 6_500, q: 2.0, gainDB: 2),
        ]),
        .parametric("Bass Reduce", [
            EQBand(frequency: 60, q: 0.7, gainDB: -6),
            EQBand(frequency: 150, q: 1.0, gainDB: -4),
            EQBand(frequency: 400, q: 1.2, gainDB: -2),
        ]),
    ]

    init() {
        let d = UserDefaults.standard
        isEnabled = d.bool(forKey: Self.enabledKey)
        preset = d.string(forKey: Self.presetKey) ?? "Flat"
        // Prefer the parametric config; fall back to legacy gains-only storage; else default.
        if let data = d.data(forKey: Self.bandsKey),
           let stored = try? JSONDecoder().decode([EQBand].self, from: data), !stored.isEmpty {
            bands = stored.map { $0.clamped() }
        } else if let storedGains = d.array(forKey: Self.gainsKey) as? [Double], storedGains.count == 10 {
            bands = zip(Self.frequencies, storedGains).map { EQBand(frequency: $0, q: Self.defaultQ, gainDB: $1).clamped() }
        } else {
            bands = Self.defaultBands()
        }
        publish()
    }

    // MARK: - Legacy graphic API (preserved)

    /// Set a band's gain by index, keeping its frequency and Q. Legacy graphic-EQ entry point.
    func setGain(_ dB: Double, band: Int) {
        guard bands.indices.contains(band) else { return }
        bands[band].gainDB = min(Self.maxGain, max(Self.minGain, dB))
        preset = "Custom"
        persistAndPublish()
    }

    /// Apply a named preset (graphic or parametric). Unknown names are ignored.
    func apply(preset name: String) {
        guard let p = Self.presets.first(where: { $0.name == name }) else { return }
        bands = p.bands
        preset = name
        persistAndPublish()
    }

    // MARK: - Parametric API

    /// Set a band's centre frequency (Hz), clamped to the audible range.
    func setFrequency(_ hz: Double, band: Int) {
        guard bands.indices.contains(band) else { return }
        bands[band].frequency = min(Self.maxFrequency, max(Self.minFrequency, hz))
        preset = "Custom"
        persistAndPublish()
    }

    /// Set a band's Q (bandwidth), clamped to the supported range.
    func setQ(_ q: Double, band: Int) {
        guard bands.indices.contains(band) else { return }
        bands[band].q = min(Self.maxQ, max(Self.minQ, q))
        preset = "Custom"
        persistAndPublish()
    }

    /// Replace a whole band (clamped) — used by draggable-handle editing.
    func setBand(_ band: EQBand, at index: Int) {
        guard bands.indices.contains(index) else { return }
        bands[index] = band.clamped()
        preset = "Custom"
        persistAndPublish()
    }

    /// Reset every band to flat gain (keeping the default layout), i.e. "Flat".
    func reset() {
        bands = Self.defaultBands()
        preset = "Flat"
        persistAndPublish()
    }

    // MARK: - Persistence + publishing

    private func persistAndPublish() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(bands) { d.set(data, forKey: Self.bandsKey) }
        // Keep the legacy gains key in sync so an older build reads sane gains.
        d.set(bands.map(\.gainDB), forKey: Self.gainsKey)
        publish()
    }

    /// Recompute biquad coefficients from the current bands and hand them to the tap.
    /// When disabled, publish an all-flat set so an attached tap is a pass-through.
    private func publish() {
        let sampleRate = 44_100.0
        let active = isEnabled
        let biquads = bands.map { band in
            Biquad.peaking(
                frequency: band.frequency,
                sampleRate: sampleRate,
                q: band.q,
                gainDB: active ? band.gainDB : 0
            )
        }
        coefficients.set(biquads)
    }
}

/// One parametric peaking band: centre frequency (Hz), Q (bandwidth), and gain (dB).
struct EQBand: Codable, Equatable, Sendable, Identifiable {
    var frequency: Double
    var q: Double
    var gainDB: Double
    /// Stable identity for `ForEach` in the editor — derived from the centre frequency
    /// at construction so reorders don't churn identities during a drag.
    let id: UUID

    init(frequency: Double, q: Double, gainDB: Double, id: UUID = UUID()) {
        self.frequency = frequency
        self.q = q
        self.gainDB = gainDB
        self.id = id
    }

    private enum CodingKeys: String, CodingKey { case frequency, q, gainDB }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try c.decode(Double.self, forKey: .frequency)
        q = try c.decode(Double.self, forKey: .q)
        gainDB = try c.decode(Double.self, forKey: .gainDB)
        id = UUID()
    }

    /// Clamp all parameters into the equalizer's supported ranges.
    func clamped() -> EQBand {
        EQBand(
            frequency: min(MusicEqualizer.maxFrequency, max(MusicEqualizer.minFrequency, frequency)),
            q: min(MusicEqualizer.maxQ, max(MusicEqualizer.minQ, q)),
            gainDB: min(MusicEqualizer.maxGain, max(MusicEqualizer.minGain, gainDB)),
            id: id
        )
    }
}

/// A named preset — either a graphic preset (gains on the default band layout) or a
/// parametric one (explicit frequency/Q/gain bands).
struct EQPreset: Sendable {
    let name: String
    let bands: [EQBand]

    static func graphic(_ name: String, _ gains: [Double]) -> EQPreset {
        EQPreset(name: name, bands: zip(MusicEqualizer.frequencies, gains).map {
            EQBand(frequency: $0, q: MusicEqualizer.defaultQ, gainDB: $1)
        })
    }

    static func parametric(_ name: String, _ bands: [EQBand]) -> EQPreset {
        EQPreset(name: name, bands: bands)
    }
}

/// A single peaking-EQ biquad (RBJ cookbook), normalized by a0.
struct Biquad: Sendable {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float

    static let identity = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    static func peaking(frequency f0: Double, sampleRate fs: Double, q: Double, gainDB: Double) -> Biquad {
        guard gainDB != 0 else { return .identity }
        let a = pow(10.0, gainDB / 40.0)
        let w0 = 2 * Double.pi * f0 / fs
        let alpha = sin(w0) / (2 * q)
        let cosW = cos(w0)
        let b0 = 1 + alpha * a
        let b1 = -2 * cosW
        let b2 = 1 - alpha * a
        let a0 = 1 + alpha / a
        let a1 = -2 * cosW
        let a2 = 1 - alpha / a
        return Biquad(
            b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
            a1: Float(a1 / a0), a2: Float(a2 / a0)
        )
    }

    /// Magnitude response |H(e^{jω})| at frequency `f0` (Hz) for sample rate `fs`.
    /// Used by the UI to draw the combined response curve (and testable in isolation).
    func magnitude(atFrequency f0: Double, sampleRate fs: Double) -> Double {
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
final class EQCoefficients: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var biquads: [Biquad] = []

    func set(_ new: [Biquad]) {
        os_unfair_lock_lock(&lock)
        biquads = new
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> [Biquad] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return biquads
    }
}
