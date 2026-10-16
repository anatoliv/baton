import Foundation
import BatonSubsonicModels

/// The speeds and sleep-timer choices both apps offer, kept in one place so the Mac's menus and
/// the phone's menus cannot drift apart.
public enum SpokenPlaybackOptions {
    /// Speeds offered for spoken items. 0.75× is as slow as speech stays natural; 2× is where
    /// the time-domain stretcher still keeps words distinct.
    public static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    public static let minimumRate: Float = 0.75
    public static let maximumRate: Float = 2.0

    /// "1×", "1.25×", "0.75×": no trailing zero on a whole number, and every digit that
    /// matters on a fraction. (The phone's player wrote `%.2g`, which rounds 1.25 to "1.2×".)
    public static func rateLabel(_ rate: Float) -> String {
        let rounded = (rate * 100).rounded() / 100
        return rounded == rounded.rounded() ? "\(Int(rounded))×" : String(format: "%g×", rounded)
    }

    public static func clampRate(_ rate: Float) -> Float {
        guard rate.isFinite else { return 1 }
        return min(maximumRate, max(minimumRate, rate))
    }
}

/// Shared sleep-timer durations and labels, so the moon menu, the Playback menu, the menu bar
/// extra and the phone's player offer the same choices.
public enum SleepTimerOptions {
    public static let minutes = [15, 30, 45, 60, 120, 180]

    public static func label(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) minutes" }
        let hours = minutes / 60
        return "\(hours) hour\(hours == 1 ? "" : "s")"
    }

    /// The "stop when this one ends" choice, named for what is playing: a chapter of a book (or
    /// any other clipping Baton made), an episode, or a track. `titleCase` for menu-bar menus.
    public static func endLabel(for song: NavidromeSong?, isSpoken: Bool, titleCase: Bool = false) -> String {
        let noun: String
        if song?.isPodcastEpisode == true {
            noun = "episode"
        } else if isSpoken, let song, MediaKind(id: song.id) == .localFile {
            noun = "chapter"
        } else {
            noun = "track"
        }
        return titleCase ? "End of \(noun.capitalized)" : "End of \(noun)"
    }
}

/// Speed for spoken items.
///
/// **One speed for everything spoken, not one per book.** Podcasts already had a single
/// app-wide speed, and someone who listens to speech at 1.5× wants that for the next book as
/// much as for the next episode. It is one scalar in `PreferenceSync.syncedKeys`, so the Mac
/// and the phone share it the way they share every other setting.
///
/// **Music is never sped up.** The rate used to be one controller-wide value: 1.5× set on a
/// podcast carried on into the next song. Now the decks get the spoken speed only while
/// `isSpokenItem` says the current item is speech, and 1× otherwise.
extension StreamingPlaybackController {
    public static let spokenRateKey = "baton.playback.spokenRate"

    /// Whether what is playing now is speech, and so plays at `spokenRate`.
    public var isSpokenNowPlaying: Bool {
        nowPlaying.map { isSpokenItem($0) } ?? false
    }

    /// The speed the current item should play at.
    var effectiveRateForNowPlaying: Float {
        isSpokenNowPlaying ? spokenRate : 1
    }

    /// The speed `song` plays at: a blend sets up its incoming player before that song is the
    /// one playing, so it asks about the song rather than about `nowPlaying`.
    func effectiveRate(for song: NavidromeSong) -> Float {
        isSpokenItem(song) ? spokenRate : 1
    }

    /// Re-read the stored speed (another device may have changed it through sync) and apply
    /// the right rate for the item now playing. Cheap enough to call on every item change.
    func applyEffectiveRate() {
        if let stored = defaults.object(forKey: Self.spokenRateKey) as? Double {
            let clamped = SpokenPlaybackOptions.clampRate(Float(stored))
            if clamped != spokenRate { adoptingStoredSpokenRate = true; spokenRate = clamped; adoptingStoredSpokenRate = false }
        }
        let target = effectiveRateForNowPlaying
        if playbackRate != target { playbackRate = target }
    }

    /// Called whenever the queue or the index moves; does work only when the item changed.
    func nowPlayingMayHaveChanged() {
        let id = nowPlaying?.id
        guard id != rateResolvedForID else { return }
        rateResolvedForID = id
        applyEffectiveRate()
    }
}
