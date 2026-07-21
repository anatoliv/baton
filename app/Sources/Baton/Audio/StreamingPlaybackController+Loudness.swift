import Foundation

/// ReplayGain loudness-normalization math, extracted from `StreamingPlaybackController` (W-50).
/// Pure, side-effect-free functions of a track's ReplayGain tags + the loudness mode + pre-amp —
/// no player, queue, or actor state — so they're unit-tested directly (see
/// `LoudnessAdvanceCharacterizationTests`, W-47) and safe to reason about in isolation. They stay
/// static members of the controller (via this extension) so `Self.loudnessMultiplier(...)` /
/// `Self.normalizationGain(...)` call sites are unchanged.
extension StreamingPlaybackController {
    /// Constant negative headroom applied whenever loudness normalization is on. AVPlayer.volume
    /// only attenuates (0…1), so without headroom a quiet track's positive ReplayGain just clips
    /// against the ceiling and never actually plays louder. Reserving ~6 dB of headroom turns
    /// every RG adjustment into an attenuation that fits — consistent loudness at a slightly
    /// lower absolute level. (W-44 / AUDIO-23) A DSP gain stage would avoid the level drop.
    static var loudnessHeadroom: Float { 0.5 } // ≈ -6 dB

    /// The effective `player.volume` multiplier for the loudness mode, including the headroom.
    static func loudnessMultiplier(for song: NavidromeSong?, mode: LoudnessMode, preampDB: Double) -> Float {
        guard mode != .off else { return 1 }
        let norm = song.map { normalizationGain(for: $0, mode: mode, preampDB: preampDB) } ?? 1
        return min(norm * loudnessHeadroom, 1) // stay within the player's [0,1] range
    }

    /// Linear volume multiplier from a track's ReplayGain (pure, unit-testable). Applies the
    /// chosen gain (track or album) + a pre-amp in dB, clamps by the peak so boosting a quiet
    /// track never clips, and caps the boost. Returns 1 when off or the track has no data —
    /// so a library without ReplayGain tags simply plays at normal volume.
    static func normalizationGain(for song: NavidromeSong, mode: LoudnessMode, preampDB: Double) -> Float {
        guard mode != .off, let rg = song.replayGain else { return 1 }
        let gainDB: Double?
        let peak: Double?
        switch mode {
        case .track: gainDB = rg.trackGain ?? rg.albumGain; peak = rg.trackPeak ?? rg.albumPeak
        case .album: gainDB = rg.albumGain ?? rg.trackGain; peak = rg.albumPeak ?? rg.trackPeak
        case .off: return 1
        }
        guard let gainDB else { return 1 }
        var linear = pow(10.0, (gainDB + preampDB) / 20.0)
        if let peak, peak > 0 { linear = min(linear, 1.0 / peak) } // headroom: never clip
        return Float(min(max(linear, 0), 4)) // cap so a huge boost can't blast the speakers
    }
}
