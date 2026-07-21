import Foundation
import Observation
import os
// Re-export the DSP module so EQBand/Biquad/EQCoefficients/EQPreset/EQLimits stay visible to every
// existing call site (store, tap processor, settings, tests) via `import Baton` — no per-file churn
// as the DSP moves to its own SPM module.
@_exported import BatonDSP

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
    nonisolated static let frequencies: [Double] = EQLimits.frequencies
    /// Default Q for the graphic-style bands (moderately wide, so neighbours overlap).
    nonisolated static let defaultQ: Double = EQLimits.defaultQ

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey); publish(); onToggle?() }
    }
    /// Called when `isEnabled` flips — AppModel uses it to attach/detach the audio-mix tap.
    @ObservationIgnored var onToggle: (() -> Void)?

    /// The parametric bands, in ascending frequency order. Source of truth for the DSP.
    private(set) var bands: [EQBand]

    var preset: String {
        didSet { defaults.set(preset, forKey: Self.presetKey) }
    }

    /// Legacy shim: per-band gains in dB, one per band. Reads/writes `bands[i].gainDB`.
    var gains: [Double] { bands.map(\.gainDB) }

    /// Shared, lock-protected coefficients the audio-thread tap reads.
    @ObservationIgnored let coefficients = EQCoefficients()

    /// Where the EQ config persists. Injectable so tests never touch the developer's real EQ
    /// settings — under XCTest `defaultStore()` returns a throwaway suite instead of `.standard`,
    /// which running the suite would otherwise overwrite.
    @ObservationIgnored private let defaults: UserDefaults

    /// `.standard` in production; a unique throwaway suite per instance in the test environment.
    static func defaultStore(environment: BatonEnvironment = .current) -> UserDefaults {
        guard environment.isTesting else { return .standard }
        return UserDefaults(suiteName: "io.tonebox.tests.eq.\(UUID().uuidString)") ?? .standard
    }

    @ObservationIgnored static let enabledKey = "tonebox.music.eq.enabled"
    @ObservationIgnored static let gainsKey = "tonebox.music.eq.gains"
    @ObservationIgnored static let presetKey = "tonebox.music.eq.preset"
    @ObservationIgnored static let bandsKey = "tonebox.music.eq.bands"

    /// Gain limits (dB) enforced on every edit.
    nonisolated static let minGain: Double = EQLimits.minGain
    nonisolated static let maxGain: Double = EQLimits.maxGain
    /// Q limits — narrow (surgical) to wide (gentle shelf-like) peaks.
    nonisolated static let minQ: Double = EQLimits.minQ
    nonisolated static let maxQ: Double = EQLimits.maxQ
    /// Frequency limits (Hz) — the audible band.
    nonisolated static let minFrequency: Double = EQLimits.minFrequency
    nonisolated static let maxFrequency: Double = EQLimits.maxFrequency

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

    init(environment: BatonEnvironment = .current, defaults: UserDefaults? = nil) {
        let store = defaults ?? MusicEqualizer.defaultStore(environment: environment)
        self.defaults = store
        let d = store
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
        // Case-insensitive lookup — an agent (via music_set_eq) guesses casing constantly, and a
        // "flat" that silently did nothing was a foot-gun. Store the canonical name.
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let p = Self.presets.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        bands = p.bands
        preset = p.name
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
        let d = defaults
        if let data = try? JSONEncoder().encode(bands) { d.set(data, forKey: Self.bandsKey) }
        // Keep the legacy gains key in sync so an older build reads sane gains.
        d.set(bands.map(\.gainDB), forKey: Self.gainsKey)
        publish()
    }

    /// Recompute biquad coefficients from the current bands and hand them to the tap.
    /// When disabled, publish an all-flat set so an attached tap is a pass-through.
    private func publish() {
        let active = isEnabled
        let specs = bands.map { band in
            EQCoefficients.BandSpec(frequency: band.frequency, q: band.q, gainDB: active ? band.gainDB : 0)
        }
        // Reference biquads for the UI response curve are computed at 44.1 kHz; each audio tap
        // recomputes for its own actual rate from the specs.
        let reference = specs.map { Biquad.peaking(frequency: $0.frequency, sampleRate: 44_100, q: $0.q, gainDB: $0.gainDB) }
        coefficients.setBands(specs, reference: reference)
    }
}
