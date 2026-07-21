# 02 — Feature Inventory (Existing)

Exhaustive inventory of what the in-Tonebox player **already does**, grouped, with
each capability traced to its implementing type / file so it's traceable during
extraction. Paths are relative to `app/Sources/Baton/`.

> Reading note: "verified" here means read from source. Line numbers are as of the
> commit this suite was written against; treat them as anchors, not guarantees.

---

## A. Playback engine

Root type: **`StreamingPlaybackController`** (`Audio/StreamingPlaybackController.swift`,
~64 KB, `@MainActor @Observable`). Built on `AVQueuePlayer`. Held by
`AppModel.music` (`Model/AppModel.swift:357`).

### Transport & queue
| Capability | Method / property | Notes |
|---|---|---|
| Play a list, replacing queue | `play(_:startAt:source:)` (:513) | Sets `queueSource` metadata |
| Append to queue | `enqueue(_:)` (:525) | Auto-starts if queue was empty |
| Play next (insert after current) | `playNext(_:)` (:543) | |
| Pause / resume / stop | `pause()` (:573) / `resume()` (:552) / `stop()` (:581) | `resume()` reloads if AVQueuePlayer drained (fixed in git `0bc2db7b`) |
| Next / previous | `next()` (:611) / `previous()` (:697) | `previous()` restarts current if >3s played |
| Seek | `seek(to:)` (:710) | `isSeeking` guard stops the clock observer snapping the scrubber back |
| Jump to index | `jump(to:)` (:660) | |
| Reorder queue (drag) | `moveQueueItem(from:to:)` (:669) | Keeps current track selected |
| Remove from queue | `removeFromQueue(at:)` (:681) | |
| Clear queue | `clearQueue()` (:592) | |
| Volume 0–100 | `setVolume(percent:)` (:734), `volumePercent` (:235) | Mapped to `AVPlayer.volume` 0…1 |
| Mute (independent of slider) | `toggleMute()` (:743), `isMuted` (:70) | |

### Modes
| Capability | API | Persisted key |
|---|---|---|
| Repeat off/all/one | `RepeatMode` (:172), `cycleRepeat()` (:628) | `tonebox.navidrome.repeat` |
| Shuffle | `toggleShuffle()` (:639), `isShuffled` (:83) | `tonebox.navidrome.shuffle` — saves pre-shuffle order in `orderBeforeShuffle`, keeps current track first |
| Continuous radio / autoplay | `autoplayEnabled` (:89), `extendQueueIfNeeded()` (:1194) | `tonebox.navidrome.autoplay` — tops up queue via `relatedProvider` when within 2 of the end |

### State surface (all `@Observable`, drives SwiftUI)
`state: State` (idle/loading/playing/paused/error, :30), `queue` (:51),
`currentIndex` (:53), `currentTime`/`duration` (:54–55), `isBuffering` (:66,
derived from `AVPlayer.timeControlStatus`), `nowPlaying` (:245),
`nowPlayingSummary` (:1400, the one-line summary the MCP tools return),
`queueSource` (:212, a `QueueSource` = playlist/album/artist/radio/search/liked).

### Persistence
Queue (songs + index + position + source), volume, repeat, shuffle, autoplay,
loudness, crossfade, gapless flags — all in `UserDefaults` under
`tonebox.navidrome.*`. Test isolation uses suite `io.tonebox.tests.music`
(:347). Queue restore is `restoreQueue()` (paused on launch).

---

## B. Gapless, crossfade & loudness

### True gapless (git: `47468444`, `30a5046d`)
- `gaplessEnabled` (:154), active only when `crossfadeSeconds < 0.05`
  (`isGaplessMode`, :274). Implemented by pre-inserting the next `AVPlayerItem`
  into the `AVQueuePlayer` so the OS advances with no reload/rebuffer
  (`gaplessAdvanced(to:item:)` :1144, `handleEnded()` :973).
- **Stream prefetch to disk** for zero-gap even on network streams:
  `preloadGaplessNextIfNeeded()` (:1051), `startGaplessPrefetch(...)` (:1085),
  `adoptPrefetchedNext(...)` (:1105) swaps the streaming item for the local file
  once downloaded — but only if we haven't advanced past it.
- **Prefetch cache:** `MusicGaplessCache` (`Audio/MusicGaplessCache.swift`) — an
  LRU disk cache (`maxEntries` default 6) at
  `~/Library/Caches/Tonebox/gapless-prefetch/`. `sizeBytes()` / `clear()` back the
  Settings "clear cache" button.
- **Wi-Fi-only prefetch:** `gaplessPrefetchWifiOnly` (:165) skips prefetch on
  metered connections, checked via `NetworkReachability` (`Audio/NetworkReachability.swift`,
  `isMetered = isExpensive || isConstrained`).

### Crossfade
`crossfadeSeconds` (:140, 0 = hard cut). >0 overlaps tracks via a second player and
**disables** true-gapless (:144).

### Loudness normalization (ReplayGain / R128)
`loudnessMode` (:123, off/track/album), `loudnessPreampDB` (:131), pure calculator
`normalizationGain(for:mode:preampDB:)` (:788) applies ReplayGain data + preamp +
headroom clamp (1/peak) capped at 4×. ReplayGain data comes from the server on each
`NavidromeSong.replayGain` (`Integrations/Navidrome/NavidromeModels.swift:29`).

---

## C. Equalizer

- **`MusicEqualizer`** (`Audio/MusicEqualizer.swift`, `@Observable`) — 10 ISO-ish
  bands (32 Hz…16 kHz), per-band gain ±12 dB, presets (Flat, Bass Boost, Treble
  Boost, Vocal, Rock, Electronic, Loudness). Off by default (git `a0a10823`).
  Persisted (`tonebox.music.eq.enabled`, `...preset`). Computes RBJ peaking-biquad
  coefficients into a lock-protected holder read by the audio thread.
- **`AudioEQProcessor`** (`Audio/AudioEQProcessor.swift`) — an `MTAudioProcessingTap`
  that runs a Direct-Form-II-Transposed biquad cascade per sample on the render
  thread. `makeAudioMix(for:)` (:19) builds the tap; `process(_:)` (:48) filters.
- Wired to the player via `configureAudioMix` (:107) / `refreshAudioMix()` (:110):
  toggling EQ attaches/detaches the tap; off = bit-exact pass-through.

---

## D. Library / browse (Navidrome / Subsonic)

Client: **`NavidromeClient`** (`Integrations/Navidrome/NavidromeClient.swift`);
cache/state: **`MusicLibraryStore`** (`Model/MusicLibraryStore.swift`,
`@MainActor @Observable`).

### Client surface (verified)
- Auth: `.tokenSalt` (classic Subsonic `md5(password+salt)`) or `.apiKey`
  (OpenSubsonic `apikeyauth`). API version advertised `1.16.1`, client id `tonebox`.
- Search/browse: `search3` (:142), `getAlbum` (:159), `getAlbumList2` (:222, by
  newest/frequent/recent/starred/highest/random/alphabetical), `getArtists` (:232),
  `getArtistAlbums` (:238), `getGenres` (:244), `getSongsByGenre` (:250),
  `getArtistInfo` (:259, bio + portrait, filters last.fm placeholder image),
  `getSong` (:206), `getStarred2` (:215).
- Discovery: `getSimilarSongs` (:265, via `getSimilarSongs2`) — powers radio.
- Lyrics: `getLyrics` (:275, via `getLyricsBySongId`, synced or plain).
- Ratings (server-side, per-user): `star` (:186), `unstar` (:191), `setRating`
  (:196).
- Scrobble: `scrobble(id:submission:)` (:287) — `false` = "now playing", `true` =
  played.
- Playlist CRUD: `createPlaylist` (:298), `updatePlaylist` (:309),
  `setPlaylistSongs` (:331, replaces tracks in order — persists drag-reorder),
  `deletePlaylist` (:339).
- Streaming URL: `streamURL(songID:)` (:112) forces `format=mp3` (Ogg/Opus/WMA
  don't decode in AVFoundation → would be silent). `coverArtURL(id:size:)` (:120).

### Library store features
- Search results, albums, artists, starred, playlists, genres (state at
  `MusicLibraryStore.swift:72–77`).
- Album sort: newest/recent/frequent/name/artist/tracks/duration/starred/highest/random
  (`AlbumSort` :10, with client-side re-sort for tracks/duration).
- **Optimistic rating overrides** (`ratingOverrides` :88) so a like/star tap
  updates instantly regardless of which collection the song lives in.
- **Cover-art URL cache** (:111) keyed by `id#size` so `AsyncImage` doesn't refetch
  every frame (signed URLs get a fresh salt each build).
- Artist stats/info/follow, playlist add/remove/reorder/rename, "mark for removal"
  (unlike + rating 1 as an external-pipeline prune signal, :351).
- **`mixSongs(type:...)`** (:307) gathers deduped songs from the first N albums of a
  server list — the engine behind the auto-mixes.

---

## E. Discovery: Home / Mixes / History / Radio

### Home ("For You") — `Shell/Music/MusicHomeView.swift`
Time-of-day greeting, then tap-to-play shelves: Recently Played (18 distinct),
"Because You Liked X" radio (seeded from most-played/recent/liked), Recently Added
(16 newest albums), Rediscover (16 random albums), and Your Mixes.

### Mixes — `Shell/Music/MusicMix.swift` + `MusicMixesView.swift`
Six auto-mixes (`MusicMix:24–44`): **Most Played** (local history),
**Fresh Additions** (server `newest`), **Top Rated** (server `highest`),
**On Repeat** (server `frequent`), **Forgotten Favorites** (liked but not played in
30 days, :63), **Discover** (server `random`, shuffled). Plus **per-genre "Daily
Mix" cards** — top 12 genres each seeding `songsByGenre(...).shuffled()` (git
`1cecc4cb`). Each mix has a detail page (Play/Shuffle/Queue/Download all).
**Note:** mixes are heuristic (history + server lists + genre shuffle), **not**
sonic analysis — a competitive gap vs Plexamp (see [05](05-roadmap-new-features.md)).

### History — `Shell/Music/MusicHistoryView.swift` + `MusicPlayHistory.swift`
Local play log, deduped for immediate replays (60 s window), capped 1000 entries,
persisted (`tonebox.music.playHistory`). Segments: Recent / Top Tracks / Top Artists
with a This-Week / This-Month / All-Time window. `topTracks`/`topArtists`/`playCount`
queries. Clear-history (local only — doesn't touch server counts).

### Radio / Related — `Shell/Music/MusicRelatedView.swift` + `MusicRadioBans.swift`
Similar-songs panel via `getSimilarSongs2`, deduped. **Radio bans** (`MusicRadioBans`)
are a local-only exclusion list (persisted UserDefaults) filtering Related results
and the continuous-radio auto-queue — songs stay in the library. Wired to the
engine via `music.relatedProvider` (`AppModel.swift:746`).

---

## F. UX surfaces

| Surface | File | Highlights |
|---|---|---|
| Main tab / nav rail | `Shell/Music/MusicView.swift` | Collapsible 8-tab rail (Home/Search/Mixes/Albums/Artists/Playlists/Liked/History), artwork-tinted UltraBlur backdrop |
| Now-playing bar | `Shell/Music/NowPlayingBar.swift` | Persistent; collapsible to a slim strip (git `c5c5e387`); expanded = seek/transport/volume/queue/sleep/AirPlay |
| Floating mini-player | `Shell/Music/MiniPlayerWindowView.swift` | Borderless always-on-top panel; compact/expanded, Up Next, rating, scrubber; Liquid Glass on macOS 26+ |
| Pop-out window | `Shell/Music/MusicWindowView.swift` | Full player in its own window |
| Full-screen now-playing | `Shell/Music/FullScreenNowPlaying.swift` | Big artwork, adaptive backdrop, waveform scrubber, side panels (Queue/Lyrics/Related) |
| Transport / scrubber | `Shell/Music/MusicControls.swift` | Waveform-or-capsule scrubber, drag-to-seek with live drag progress |
| Lyrics | `Shell/Music/MusicLyricsView.swift` | Synced (karaoke auto-scroll) or plain, via `getLyricsBySongId` |
| Waveform | `Shell/Music/WaveformExtractor.swift` | **Downloads only** (:8) — streams fall back to a capsule; 120 peak buckets; memory→disk→compute cache at `~/Library/Caches/Tonebox/waveforms/` |
| Artwork palette | `Shell/Music/ArtworkPalette.swift` | Primary/secondary/accent extraction for backdrops |
| Multi-select | `Shell/Music/MusicMultiSelect.swift`, `MusicSelectionMath.swift` | Finder-style shift-range, select-all, smart batch like/unlike |
| Toasts | `Shell/Music/MusicToastOverlay.swift` | Auto-dismiss confirmation capsule |
| Menu commands | `Shell/Music/PlaybackMenuCommands.swift` | Play/Pause ⌘⌃P, Next/Prev ⌘⌃→/←, Vol ⌘⌃↑/↓, Mute ⌘⌃M, Shuffle, Repeat, Sleep timer, Minimize bar ⌘⌃J, Mini Player ⌘⌥M |
| Detail pages | `Shell/Music/MusicDetailViews.swift` | Album/artist/playlist hero pages; browse header (filter + list/grid + sort) |
| Browse rows/cards | `MusicBrowseRows.swift`, `MusicTrackRow.swift`, `MusicMediaCard.swift`, `MusicArtistsBrowser.swift` | Grid/list, hover-play, now-playing highlight, auto-import junk flags, duplicate detection |
| Liked / Search | `Shell/Music/MusicLikedView.swift` (shared `MusicCollectionView`) | Songs/Albums/Artists segments, sort/filter, per-song 5-star + heart, batch actions |
| Filter history | `Shell/Music/FilterHistory.swift` | Per-screen recent-filter dropdown, capped 15 |

### Sleep timer
`setSleepTimer(minutes:)` (:807, fades out ~5 s then pauses),
`sleepAtEndOfTrack()` (:829), `cancelSleepTimer()` (:837). End-of-track fade is a
differentiator vs most mainstream apps.

---

## G. Integrations & ecosystem

### Downloads / offline — `Shell/Music/MusicDownloadStore.swift`
Fetch stream to a user folder (default Application Support), filename templating
(`{artist} {album} {title} {id}`), manifest `.tonebox-downloads.json`, plays from
disk (`localURL(for:)` is preferred by the streaming path), per-song + batch
download, download-status icons.

### Scrobbling (dual, native)
- **ListenBrainz** — `Shell/Music/MusicScrobbler.swift`. Token-only (no OAuth),
  `updateNowPlaying` + `submitListen`, threshold = `min(duration/2, 240)` s.
- **Last.fm** — `Shell/Music/MusicLastFM.swift` (git `0c1e5a30`). API key + secret +
  browser-auth session key, MD5 `api_sig` signing, now-playing + scrobble.
- **Navidrome server scrobble** — `StreamingPlaybackController.scrobble(songID:)`
  (:1361), fired on track start via `onScrobbleEligible` at the half/4-min
  threshold (:438).
- Coordinated by `MusicScrobbler`/`MusicLastFM` instances on `AppModel`
  (`AppModel.swift:366–368`).

### Now-playing / media keys — `Audio/MusicNowPlayingCenter.swift`
`MPRemoteCommandCenter` (play/pause/toggle/next/prev/seek — F7/F8/F9, Bluetooth
remotes) + `MPNowPlayingInfoCenter` (title/artist/album/artwork/elapsed). Artwork
fetched off-main-actor and merged into the live info dict so a slow load can't
clobber state.

### Output ducking — `Audio/OutputVolumeController.swift`
System output-device ducking for recording/dictation (fade, restore-to-exact,
read-back retry, watchdog re-assert, crash recovery). Distinct from the *player*
volume — this ducks the whole default output device.

### AirPlay — `Shell/Music/AirPlayRoutePicker.swift`
`AVRoutePickerView` wrapper (system AirPlay selector). **AirPlay only** — no
Chromecast/Sonos/UPnP (gap, see [05](05-roadmap-new-features.md)).

---

## H. Control layers (in-app + agent)

- **Agent / natural-language control** — Baton ships **no** in-app NL command
  interpreter; natural-language control is done by the *client* agent driving the MCP
  tool catalog (`MCP/BatonMCPTools.swift`). "Play some jazz" resolves to `music_search`
  + `music_play`; "turn it down" to `music_set_volume`, etc. — the agent maps intent to
  tools, so there is no `MusicIntent`/interpreter type to maintain.
- **Shared execution** — the `music_play` tool's album-vs-loose-search resolution
  (`resolvePlayQueue` / `bestAlbumMatch`, `MCP/BatonMCPTools.swift`) runs against the
  same `MusicModel` graph (`Model/MusicModel.swift`) the in-app UI drives, so tool and
  UI paths stay consistent.
- **MCP tools** — the control surface shipped in Baton 0.1.0 as **30 tools**
  (`app/Sources/Baton/MCP/BatonMCPTools.swift` + `BatonMCPMixTools.swift`): the 17
  `music_*` control tools this inventory traces, plus `music_build_mix`, 10
  gap-fillers, and `audio_suspend`/`audio_resume`. Full catalog and schemas in
  [04](04-integration-and-mcp.md).

---

## I. Capture coordination (the audio-focus seed)

`suspendForCapture()` (:854) / `resumeAfterCapture()` (:863), gated by private
`suspendedForCapture` (:316). Suspend only pauses if currently `.playing`; resume
only resumes if *this* controller paused it **and** it's still `.paused`. Callers:
`DictationController.swift:431` (dictation start → suspend) and `:67` (terminal
state → resume, idempotent), `AppModel+Recording.swift:24` (record start) / `:750`
(record stop). This in-process contract is the model for — and now shipped as — the
cross-process `audio_suspend`/`audio_resume` primitive
(`app/Sources/Baton/MCP/BatonAudioFocus.swift`), with duck mode, handle expiry, and a
Unix-socket fast-path; see [04](04-integration-and-mcp.md).

---

## Traceability summary (where to look first when extracting)

| Domain | Primary file(s) |
|---|---|
| Playback engine | `Audio/StreamingPlaybackController.swift` |
| Gapless / cache / reachability | `Audio/MusicGaplessCache.swift`, `Audio/NetworkReachability.swift` |
| EQ | `Audio/MusicEqualizer.swift`, `Audio/AudioEQProcessor.swift` |
| Now-playing / media keys / ducking | `Audio/MusicNowPlayingCenter.swift`, `Audio/OutputVolumeController.swift` |
| Subsonic client / config / models | `Integrations/Navidrome/*` |
| Library / music state | `Model/MusicModel.swift`, `Model/MusicLibraryStore.swift` |
| History / scrobbling | `Shell/Music/MusicPlayHistory.swift`, `MusicScrobbler.swift`, `MusicLastFM.swift` |
| UI | `Shell/Music/*` (~32 files) |
| Agent control | `MCP/BatonMCPTools.swift`, `MCP/BatonMCPServer.swift` |
