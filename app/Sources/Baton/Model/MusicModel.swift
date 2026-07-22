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
    let music: StreamingPlaybackController
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
    let musicEqualizer: MusicEqualizer
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
    /// Bounded, persisted history of spoken summaries, so any past one can be replayed. (Speech)
    let speechHistory = SpeechHistoryStore()

    /// True while the "Spoken Summaries" window is the key (focused) window — set by
    /// `SpeechHistoryView`. When it is, that window shows the player inline in its detail pane, so
    /// the floating speaking HUD stays hidden to avoid a redundant duplicate card on top of it.
    /// The HUD's ambient role is untouched when the window isn't focused (or is closed).
    var summariesWindowIsForeground = false

    /// The history entry currently playing / most recently played, so the Spoken Summaries list can
    /// highlight it and the detail pane can show its metadata. Set both when replaying from the list
    /// and when a fresh summary is spoken (see `BatonMCPSpeakTools`).
    var nowPlayingSummaryID: SpeechHistoryStore.Entry.ID?

    /// The track whose info inspector is open (⌘I / "Get Info"). `MusicView` presents it as a sheet;
    /// any row or the now-playing surface sets it. Nil when closed.
    var inspectorSong: NavidromeSong?

    /// Re-synthesize and play a past spoken summary from history, in its original voice. Stops any
    /// current/paused utterance first so it starts *now* rather than queuing behind it — this is a
    /// deliberate user action (Replay / the pane's Play), not an agent's FIFO summary.
    func replaySpokenSummary(_ entry: SpeechHistoryStore.Entry) {
        nowPlayingSummaryID = entry.id
        speech.cancel()
        Task { await SpeechSummaryReplay.play(entry, on: speech) }
    }

    /// Delete one summary from history, clearing the now-playing marker if it pointed at it.
    func deleteSpokenSummary(_ entry: SpeechHistoryStore.Entry) {
        if nowPlayingSummaryID == entry.id { nowPlayingSummaryID = nil }
        speechHistory.remove(entry)
    }

    /// Clear all spoken-summary history and the now-playing marker together.
    func clearSpokenSummaries() {
        nowPlayingSummaryID = nil
        speechHistory.clear()
    }

    /// Retained so the audio-mix closure keeps a strong reference to the tap processor.
    @ObservationIgnored private let eqProcessor: AudioEQProcessor
    /// Ducks the music transport while a spoken summary plays (owned here; the engine holds it
    /// weakly).
    @ObservationIgnored private let speechDucker: ControllerSpeechDucker

    /// The single composition root: `environment` decides production-vs-test config once and is
    /// threaded to the player + equalizer (the stores that persist state / touch the system), so no
    /// store sniffs the runtime for itself. Tests can build `MusicModel(environment: .testing)`;
    /// the default auto-detects.
    init(environment: BatonEnvironment = .current) {
        music = StreamingPlaybackController(environment: environment)
        musicEqualizer = MusicEqualizer(environment: environment)
        eqProcessor = AudioEQProcessor(coefficients: musicEqualizer.coefficients)
        scrobbler = ScrobbleService(listenBrainz: musicScrobbler, lastfm: musicLastFM, localArchive: musicHistory)
        // Server-side podcast episodes carry opaque Subsonic ids, so the id-only default can't
        // spot them; teach the scrobbler to consult the registry too or episodes scrobble as music.
        scrobbler.isPodcast = { [podcastProgress] song in
            MusicModel.isPodcastEpisode(song) || podcastProgress.isServerEpisode(song.id)
        }
        // Radio ducks the library transport while a station is on the air.
        internetRadio.duckController = music
        // A spoken summary ducks the library transport so it's audible over the music.
        speechDucker = ControllerSpeechDucker(controller: music)
        speech.ducking = speechDucker
        // Downloads LRU eviction ranks by last-played time from history.
        MusicDownloadStore.shared.lastPlayedProvider = { [musicHistory] in musicHistory.lastPlayedByID() }
        wire()
        // Restore the persisted queue (paused, at the saved position) so relaunch picks up
        // where the user left off. After wire() so track-start side effects are connected;
        // restoreQueue itself never auto-plays.
        music.restoreQueue()
        // Route media-key / Now Playing commands to the radio when a station is on air, so a
        // play/next key drives the radio instead of resuming the library player over the live
        // stream (double audio).
        music.radioIsOnAir = { [internetRadio] in internetRadio.onAirStation != nil }
        music.radioRemote = .init(
            play: { [internetRadio] in if let s = internetRadio.onAirStation, !internetRadio.isPlaying(s) { internetRadio.play(s) } },
            pause: { [internetRadio] in internetRadio.stop() },
            toggle: { [internetRadio] in if let s = internetRadio.onAirStation { internetRadio.toggle(s) } },
            next: { [internetRadio] in internetRadio.playAdjacent(1) },
            previous: { [internetRadio] in internetRadio.playAdjacent(-1) }
        )
    }

    /// The active Navidrome server changed. Subsonic ids are per-server, so the transport queue,
    /// now-playing item, and the library's browse/rating caches all belong to the *previous*
    /// server and would resolve wrong (or fail) against the new one. Stop and clear the transport,
    /// then reset the library; callers reload from the new server afterwards. Podcasts, radio, and
    /// pins are URL/RSS-based (server-independent) and are intentionally left untouched.
    ///
    func handleActiveServerChanged() {
        music.stop()
        music.clearQueue()
        musicLibrary.resetForServerChange()
    }

    /// Make `id` the active server and re-point the library at it, then reload its albums. If this
    /// is a real switch (the active server actually changed) the previous server's queue + caches
    /// are cleared first via `handleActiveServerChanged`; a no-op re-select — e.g. saving a
    /// credential edit to the already-active server — keeps the queue and just refreshes the
    /// cached connection so nothing playing is disrupted.
    func selectServer(id: UUID) async {
        let changed = NavidromeConfig.activeServerID() != id
        NavidromeConfig.setActiveServer(id: id)
        if changed {
            handleActiveServerChanged()
        } else {
            musicLibrary.refreshConnection()
        }
        await musicLibrary.loadAlbums()
    }

    /// UserDefaults flag (default true): remove a podcast episode's download once finished.
    static let autoRemoveFinishedKey = "tonebox.podcast.autoRemoveFinished"

    /// A client-side podcast episode plays with its enclosure URL as its id (an absolute
    /// http(s) string); library tracks use Subsonic ids. That distinction is enough to route
    /// resume/progress to podcasts only. Delegates to the typed `NavidromeSong.mediaKind`.
    ///
    /// Note this is the *id-only* test: it cannot see server-side podcast episodes, whose ids are
    /// opaque Subsonic ids. Use the instance method `isPodcast(_:)` for anything that must treat
    /// both podcast backends alike.
    static func isPodcastEpisode(_ song: NavidromeSong) -> Bool {
        song.isPodcastEpisode
    }

    /// True for a podcast episode from **either** backend — a client-side RSS enclosure (known
    /// from its id) or a server-side episode (known from the registry the Podcasts screen fills).
    /// Resume, progress, and scrobble-exclusion all key off this so the two backends behave
    /// identically; see [[baton-podcasts]].
    func isPodcast(_ song: NavidromeSong) -> Bool {
        Self.isPodcastEpisode(song) || podcastProgress.isServerEpisode(song.id)
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
            guard Self.isPodcastEpisode(song) || podcastProgress.isServerEpisode(song.id) else { return nil }
            return podcastProgress.resumeOffset(id: song.id)
        }
        // Podcast progress: persist position periodically + at end. When an episode crosses
        // into "played", auto-remove its download (storage hygiene, opt-out via UserDefaults).
        music.onProgressUpdate = { [podcastProgress] song, time, duration in
            guard Self.isPodcastEpisode(song) || podcastProgress.isServerEpisode(song.id) else { return }
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

/// Ducks the library transport for the duration of a spoken summary by acquiring a
/// `StreamingPlaybackController` audio-focus duck token on begin and releasing it on end, so a
/// summary is audible over lowered music and the exact prior level is restored after. Holds the
/// token between the paired calls; begin is idempotent while a duck is already held.
@MainActor
final class ControllerSpeechDucker: SpeechDucking {
    private let controller: StreamingPlaybackController
    private var token: StreamingPlaybackController.AudioFocusToken?

    init(controller: StreamingPlaybackController) { self.controller = controller }

    func beginSpeechDuck() {
        guard token == nil else { return }
        token = controller.acquireAudioFocusDuck(owner: "baton.speech", toPercent: controller.duckPercent)
    }

    func endSpeechDuck() {
        guard let token else { return }
        _ = controller.releaseAudioFocus(token)
        self.token = nil
    }
}
