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
    /// 10-band equalizer for the music player (off by default).
    let musicEqualizer = MusicEqualizer()

    /// Retained so the audio-mix closure keeps a strong reference to the tap processor.
    @ObservationIgnored private let eqProcessor: AudioEQProcessor

    init() {
        eqProcessor = AudioEQProcessor(coefficients: musicEqualizer.coefficients)
        wire()
    }

    /// Wire the stores together — continuous radio, history + scrobbling on track start,
    /// scrobble submission, and the equalizer audio-mix tap. Moved verbatim from `AppModel`.
    private func wire() {
        // Continuous radio (autoplay): when the queue runs dry, pull "more like this".
        music.relatedProvider = { [musicLibrary, musicRadioBans] song in
            musicRadioBans.filtered(await musicLibrary.similarSongs(seedID: song.id))
        }
        // Log every track start to history + ping "now playing" to the scrobblers.
        music.onTrackStarted = { [musicHistory, musicScrobbler, musicLastFM] song in
            musicHistory.record(song)
            musicScrobbler.updateNowPlaying(song)
            musicLastFM.updateNowPlaying(song)
        }
        // Submit a completed listen once a track passes the scrobble threshold.
        music.onScrobbleEligible = { [musicScrobbler, musicLastFM] song in
            musicScrobbler.submitListen(song)
            musicLastFM.scrobble(song)
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
    }
}
