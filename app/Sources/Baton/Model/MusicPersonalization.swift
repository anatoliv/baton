import Foundation

/// Derives sensible **playback defaults from your listen history** and applies them.
///
/// What it can and can't infer, honestly: your history entries carry the song + when
/// it played, but neither songs nor albums carry genre tags in Baton's cached data, so
/// an EQ preset can't be inferred without unreliable guessing — the equalizer is left
/// alone. What *is* reliable is your **listening style**: whether you play through full
/// albums or hop between individual tracks / mixes. That maps cleanly onto the
/// gapless-vs-crossfade / autoplay choices.
///
/// Applied **once**, on the first launch where there's enough history (guarded by a
/// flag), so it configures for you without ever silently re-overriding a setting you
/// later change by hand. Re-runnable on demand from Settings.
enum MusicPersonalization {
    /// Below this many plays there isn't enough signal — skip (and don't burn the
    /// one-shot flag, so it retries on a later launch once you've listened more).
    static let minPlays = 20

    /// Set once auto-personalization has run, so it never fires again unattended.
    static let appliedKey = "baton.personalization.applied"

    /// A short human sentence describing what was applied — surfaced in Settings.
    static let rationaleKey = "baton.personalization.rationale"

    /// At/above this fraction of back-to-back plays sharing an album, we treat you as
    /// an album listener (gapless) rather than a singles/shuffle listener (crossfade).
    static let albumListenerThreshold = 0.4

    struct Profile: Equatable {
        /// Fraction of adjacent plays that stayed within the same album (0…1).
        let albumContinuity: Double
        let distinctArtists: Int
        let totalPlays: Int
    }

    struct Recommendation: Equatable {
        let gaplessEnabled: Bool
        let crossfadeSeconds: Double
        let autoplayEnabled: Bool
        let rationale: String
    }

    /// Build a listening profile, or nil when there isn't enough history to be useful.
    @MainActor
    static func analyze(_ history: MusicPlayHistory) -> Profile? {
        let entries = history.entries.sorted { $0.playedAt < $1.playedAt }
        guard entries.count >= minPlays else { return nil }

        var adjacent = 0
        var sameAlbum = 0
        for i in 1 ..< entries.count {
            adjacent += 1
            let a = entries[i].song.album ?? ""
            let b = entries[i - 1].song.album ?? ""
            if !a.isEmpty, a == b { sameAlbum += 1 }
        }
        let continuity = adjacent > 0 ? Double(sameAlbum) / Double(adjacent) : 0
        let distinct = Set(entries.compactMap { $0.song.artist }).count
        return Profile(albumContinuity: continuity, distinctArtists: distinct, totalPlays: entries.count)
    }

    /// Map a profile onto concrete playback defaults. Gapless and crossfade are
    /// mutually exclusive (the controller enforces it), so exactly one is chosen.
    static func recommend(_ profile: Profile) -> Recommendation {
        if profile.albumContinuity >= albumListenerThreshold {
            return Recommendation(
                gaplessEnabled: true,
                crossfadeSeconds: 0,
                autoplayEnabled: false,
                rationale: "You listen through full albums, so Baton turned on Gapless playback "
                    + "(seamless track transitions) and left Autoplay off so albums end when they end.")
        }
        return Recommendation(
            gaplessEnabled: false,
            crossfadeSeconds: 6,
            autoplayEnabled: true,
            rationale: "You mostly play individual tracks and mixes, so Baton turned on a 6-second "
                + "Crossfade and Autoplay (keeps a continuous radio going when the queue runs dry).")
    }

    /// Apply a recommendation to the live player (persists via each property's setter).
    @MainActor
    static func apply(_ rec: Recommendation, to model: MusicModel, defaults: UserDefaults = .standard) {
        let player = model.music
        player.gaplessEnabled = rec.gaplessEnabled
        player.crossfadeSeconds = rec.crossfadeSeconds
        player.autoplayEnabled = rec.autoplayEnabled
        defaults.set(rec.rationale, forKey: rationaleKey)
    }

    /// First-run hook: personalize once when enough history exists. Safe to call on
    /// every launch — it no-ops until there's data, then applies a single time.
    @MainActor
    static func applyFirstRunIfNeeded(_ model: MusicModel, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: appliedKey) else { return }
        guard let profile = analyze(model.musicHistory) else { return }
        apply(recommend(profile), to: model, defaults: defaults)
        defaults.set(true, forKey: appliedKey)
    }

    /// Re-run on demand (Settings button). Always applies if there's enough history;
    /// returns the rationale to show, or nil when history is too thin.
    @MainActor
    @discardableResult
    static func personalizeNow(_ model: MusicModel, defaults: UserDefaults = .standard) -> String? {
        guard let profile = analyze(model.musicHistory) else { return nil }
        let rec = recommend(profile)
        apply(rec, to: model, defaults: defaults)
        defaults.set(true, forKey: appliedKey)
        return rec.rationale
    }
}
