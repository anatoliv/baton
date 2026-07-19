import AVFoundation
import Foundation
import Observation

/// The self-contained root for the music player — owns the playback engine, the library,
/// history, scrobblers, radio bans, and the equalizer, and wires them together. Grouped out
/// of `AppModel` so the player has a single root object: Tonebox embeds one via `AppModel`
/// (which forwards these members, so every existing `appModel.music` / `appModel.musicLibrary`
/// call-site is unchanged), and a future standalone build can instantiate `MusicModel`
/// directly. Behaviour is identical to the previous inline `AppModel` music members + wiring.
@MainActor
@Observable
final class MusicModel {
    /// Streams + plays music from the configured Navidrome server.
    let music = StreamingPlaybackController()
    /// Full-player library: search/browse state + optimistic like/rating + playlist CRUD.
    let musicLibrary = MusicLibraryStore()
    /// Local listening history — Recently Played + top tracks/artists stats.
    let musicHistory = MusicPlayHistory()
    /// Tracks excluded from radio/autoplay suggestions ("don't play in radio").
    let musicRadioBans = MusicRadioBans()
    /// External scrobbling to ListenBrainz (opt-in via a user token).
    let musicScrobbler = MusicScrobbler()
    /// External scrobbling to Last.fm (opt-in via API key/secret + browser auth).
    let musicLastFM = MusicLastFM()
    /// Owns all scrobble policy — server play-counts + "now playing", threshold-gated
    /// completed listens, podcast exclusion, the durable offline retry queue, and whether
    /// Last.fm/ListenBrainz are scrobbled by Baton or delegated to the server.
    let scrobbler: ScrobbleService
    /// 10-band equalizer for the music player (off by default).
    let musicEqualizer = MusicEqualizer()
    /// Internet-radio stations + raw-stream player + lazily-resolved logos/genre.
    let internetRadio = InternetRadioStore()
    /// Whether the active server implements the Subsonic podcast API (Navidrome does not).
    /// Selects which backend the Podcasts tab uses (server-side vs. client-side RSS).
    let podcastCapability = PodcastCapabilityStore()
    /// Client-side podcast subscriptions (RSS feeds Baton fetches directly). The universal
    /// podcast backend — works on every server, including Navidrome.
    let podcastSubscriptions = PodcastSubscriptionStore()
    /// Per-episode listening progress — resume position + played state for podcasts.
    let podcastProgress = PodcastProgressStore()
    /// User-defined webhook actions (e.g. "save transcript"), run per-item or over a selection.
    let webhookActions = WebhookActionStore()
    /// Cross-type "save for later" pins (songs, albums, podcasts, radio…), surfaced in Later.
    let pins = PinStore()
    /// One-off spoken task summaries (the `speak_summary` MCP tool) + in-app banner state.
    let speech = SpeechPlaybackEngine()

    /// Retained so the audio-mix closure keeps a strong reference to the tap processor.
    @ObservationIgnored private let eqProcessor: AudioEQProcessor

    init() {
        eqProcessor = AudioEQProcessor(coefficients: musicEqualizer.coefficients)
        scrobbler = ScrobbleService(listenBrainz: musicScrobbler, lastfm: musicLastFM, localArchive: musicHistory)
        // Radio ducks the library transport while a station is on the air.
        internetRadio.duckController = music
        wire()
    }

    /// UserDefaults flag (default true): remove a podcast episode's download once finished.
    static let autoRemoveFinishedKey = "tonebox.podcast.autoRemoveFinished"

    /// A client-side podcast episode plays with its enclosure URL as its id (an absolute
    /// http(s) string); library tracks use Subsonic ids. That distinction is enough to route
    /// resume/progress to podcasts only.
    static func isPodcastEpisode(_ song: NavidromeSong) -> Bool {
        song.id.hasPrefix("http://") || song.id.hasPrefix("https://")
    }

    /// Wire the stores together — continuous radio, history + scrobbling on track start,
    /// scrobble submission, and the equalizer audio-mix tap. Moved verbatim from `AppModel`.
    private func wire() {
        // Continuous radio (autoplay): when the queue runs dry, pull "more like this".
        music.relatedProvider = { [musicLibrary, musicRadioBans] song in
            musicRadioBans.filtered(await musicLibrary.similarSongs(seedID: song.id))
        }
        // Log every track start to history + ping "now playing" to the scrobblers.
        // Starting a library track also stops any on-air internet-radio station so the two
        // transports stay mutually exclusive — and the bottom bar reverts from the radio
        // view back to the normal library player.
        music.onTrackStarted = { [scrobbler, internetRadio] song in
            internetRadio.stop()
            scrobbler.nowPlaying(song)
        }
        // Local listening history is recorded at the *threshold* (via ScrobbleService.completed),
        // not at track start, so it counts only tracks you actually listened to — matching the
        // external scrobblers instead of over-counting skips.
        // Podcast resume: when a podcast episode starts, hand the player its saved offset so it
        // picks up where you left off. Library tracks (non-URL ids) never resume.
        music.resumeOffsetProvider = { [podcastProgress] song in
            guard Self.isPodcastEpisode(song) else { return nil }
            return podcastProgress.resumeOffset(id: song.id)
        }
        // Podcast progress: persist position periodically + at end. When an episode crosses
        // into "played", auto-remove its download (storage hygiene, opt-out via UserDefaults).
        music.onProgressUpdate = { [podcastProgress] song, time, duration in
            guard Self.isPodcastEpisode(song) else { return }
            podcastProgress.record(id: song.id, position: time, duration: duration)
            // Auto-remove the download only when the episode actually reaches its end (the
            // end-of-track handler reports time == duration) — NOT at the 97%-played mark, so a
            // long episode isn't deleted with minutes still to play.
            let reachedEnd = duration > 1 && time >= duration - 1
            if reachedEnd, UserDefaults.standard.object(forKey: Self.autoRemoveFinishedKey) as? Bool ?? true {
                MusicDownloadStore.shared.delete(song.id)
            }
        }
        // A fixed-time sleep timer stops internet radio too (it plays on a separate engine).
        music.onSleepFire = { [internetRadio] in internetRadio.stop() }
        // Record a completed listen once a track passes the scrobble threshold. `startedAt`
        // is when the track began — the canonical scrobble timestamp.
        music.onScrobbleEligible = { [scrobbler] song, startedAt in
            scrobbler.completed(song, startedAt: startedAt)
        }
        // Attach/detach the EQ audio-mix tap on each loaded item; re-apply when toggled.
        music.configureAudioMix = { [musicEqualizer, eqProcessor] item in
            guard musicEqualizer.isEnabled else { item.audioMix = nil; return }
            Task { @MainActor in
                if let track = try? await item.asset.loadTracks(withMediaType: .audio).first {
                    item.audioMix = eqProcessor.makeAudioMix(for: track)
                }
            }
        }
        musicEqualizer.onToggle = { [music] in music.refreshAudioMix() }

        // First run only (once there's enough listen history): set playback defaults
        // — gapless vs crossfade + autoplay — from how you actually listen. Guarded by
        // a flag so it never re-overrides a setting you later change yourself.
        MusicPersonalization.applyFirstRunIfNeeded(self)
    }
}
