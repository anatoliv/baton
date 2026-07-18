# 06 — Improvements to Existing (Implemented) Features

Things that are **shipped and working** but have known limitations, edge cases, or
tech debt worth hardening — mined from the code and the recent git log. Format: what's
there → the limitation → the suggested improvement (and why).

Paths relative to `apps/tonebox-mac/Sources/Tonebox/`.

---

## 1. Gapless stream-prefetch edge cases
**There:** true gapless via pre-inserting the next `AVPlayerItem`, plus disk prefetch
for network streams (`StreamingPlaybackController.swift:1051–1117`,
`MusicGaplessCache.swift`). Tuned against real playback (git `30a5046d`,
"real-playback verified").
**Limitation:** the adopt/swap logic is timing-sensitive — `AVQueuePlayer` doesn't
update `currentItem` synchronously after `insert()`, so the code deliberately avoids
an identity check (`:1058–1061`) and swaps the prefetched local file only if we
haven't advanced (`adoptPrefetchedNext` :1105). A late prefetch, a mid-track skip, or
a queue mutation during prefetch can still land a stream where a local file was
intended (falls back gracefully, but the gap isn't guaranteed). Cache is only 6
entries (`maxEntries` default), so deep manual skipping churns it.
**Improve:** add instrumentation (already has `gaplessLocalSwapCountForTesting` :1115)
to a debug HUD; formalize the prefetch state machine (queued → downloading → adopted
→ stale) so races are explicit; consider prefetching N+2 for autoplay/radio; re-verify
on real hardware after the extraction move (the logic must move *verbatim*).

## 2. Playlist reorder capped at 200 tracks (URL length)
**There:** drag-reorder persists via `setPlaylistSongs` which overwrites the track
list (`NavidromeClient.swift:331`); the UI caps reorder at 200 tracks (git
`9aa0bd02`, "URL-overwrite safety").
**Limitation:** Subsonic sends song ids as GET query params, so a big reorder blows
the URL length limit — hence the 200 cap. Playlists over 200 tracks can't be fully
reordered.
**Improve:** chunk the reorder the way bulk Add-to-Playlist already chunks (git
`0868b380`), or use `updatePlaylist` with incremental add/remove-by-index instead of
a full overwrite, or POST the params if the server accepts it. Lifts an arbitrary
user-facing ceiling.

## 3. Add-to-playlist takes two round-trips
**There:** `music_add_to_playlist` and the UI resolve the playlist id (list all
playlists, match by name) then update (`MCPTools.swift:4288`,
`resolvePlaylistID` :4313; `MusicLibraryStore.addToPlaylist` :400).
**Limitation:** every add re-fetches the full playlist list to resolve a name; the UI
add also chunks server calls. Fine at small scale, chatty at large.
**Improve:** cache the playlist id map in `MusicLibraryStore` (it already holds
`playlists`); prefer `playlist_id` over `name` in agent calls; dedupe the
"list-then-update" into one path.

## 4. EQ & gapless need real-hardware tuning
**There:** 10-band EQ via `MTAudioProcessingTap` (`AudioEQProcessor.swift`,
`MusicEqualizer.swift`); gapless (§1).
**Limitation:** biquad coefficients and gapless boundary timing were tuned on the
developer's hardware/output path. Different sample rates, Bluetooth codecs, and
AirPlay latency can shift both. EQ is off by default (git `a0a10823`) partly because
it's unverified across outputs.
**Improve:** a test matrix (built-in / USB DAC / Bluetooth / AirPlay; 44.1/48/96 kHz),
verify EQ gain accuracy and gapless zero-gap on each, and add a per-output EQ preset
(also a roadmap item, [05](05-roadmap-new-features.md) #8).

## 5. Waveform scrubber only for downloads
**There:** real waveform for downloaded tracks; capsule fallback for streams
(`WaveformExtractor.swift:8`, used by `MusicControls.swift` scrubber).
**Limitation:** streaming tracks — the common case — get no waveform, because the
extractor reads local PCM ahead of the playhead.
**Improve:** (a) have the server precompute/serve waveform data if available; (b) build
a coarse waveform progressively from the prefetch buffer; (c) at minimum, prefetch the
*current* stream to the gapless cache and extract from that. Closes a visible gap vs
the "downloads only" ● in the comparison.

## 6. Single-server config coupled to AIConfig
**There:** `NavidromeConfig` is single-server and stores its secret *through*
`AIConfig.secretString`/`setSecretString` (`NavidromeConfig.swift:5, 33–44`).
**Limitation:** blocks multi-server, and hard-couples music to Tonebox's AI-config
Keychain layer — a problem for extraction ([03](03-architecture.md) Phase 1).
**Improve:** own `KeychainStore`, a `ServerConnection` list with an active selection
(roadmap #7). Do this during extraction regardless.

## 7. Capture coordination is in-process only
**There:** `suspendForCapture`/`resumeAfterCapture` with the `suspendedForCapture`
guard (`StreamingPlaybackController.swift:854–867`), called directly from
`DictationController` / `AppModel+Recording`.
**Limitation:** only works because player and capture share an address space. Two
callers (dictation + recording) share one boolean flag with no ownership — if both
overlap, the second suspend no-ops and the first resume clears the flag for both.
**Improve:** the owner-token audio-focus contract in [04](04-integration-and-mcp.md)
(§4) — owner + generation counter + handle expiry — fixes both the cross-process need
*and* the two-caller ambiguity. Highest-leverage hardening on this list.

## 8. `.task`-on-context-menu lazy-load reliability
**There:** several browse rows lazily load data (artist stats, similar songs,
lyrics) when a row appears or a menu opens, via SwiftUI `.task`/`.onAppear`.
**Limitation:** SwiftUI's `.task` tied to menu/hover presentation can fire late, twice,
or get cancelled on quick interactions — so a context menu can briefly show stale or
empty stats. (Symptom class; verify each call site.)
**Improve:** move lazy loads into explicit, cached async requests on
`MusicLibraryStore` (which already caches artist stats, `artistStats` :239) with a
loading/loaded/failed state per key, rather than view-lifecycle `.task`. Deterministic
and testable.

## 9. Auto-import junk detection is heuristic
**There:** heuristics flag YouTube-imported junk artists/albums (quoted names,
numeric prefixes, "User NNN", "YT Mix", zero-padded numbers) in
`MusicArtistsBrowser.swift` / album browse, with hide toggles.
**Limitation:** heuristics have false positives/negatives; a legitimately
numbered/quoted artist gets flagged, and novel junk patterns slip through.
**Improve:** make the rules user-editable (a small allow/deny list) and/or key off a
server-side tag if the import pipeline can set one. Also surface *why* something was
flagged (already shows a badge) so users trust the toggle.

## 10. Radio bans are local-only
**There:** `MusicRadioBans` filters Related/auto-radio results, persisted locally
(`Shell/Music/MusicRadioBans.swift`).
**Limitation:** bans don't sync across devices (they're UserDefaults-local) and don't
influence server-side recommendations.
**Improve:** if a companion/iOS app arrives, sync bans (small JSON); optionally map a
ban to a server-side rating-1 signal (the "mark for removal" pattern already exists,
`MusicLibraryStore.markForRemoval` :351) so other clients respect it.

## 11. MCP transport is one-shot HTTP (no notifications)
**There:** JSON-RPC over HTTP, one request per connection, `Connection: close`
(`MCPServer.swift:294–313`); no server→client notifications over MCP.
**Limitation:** agents can't subscribe to now-playing/queue changes — they must poll
`music_now_playing`. Multiple concurrent long-lived clients aren't first-class.
**Improve:** Streamable HTTP + `notifications/resources/updated`
([04](04-integration-and-mcp.md) §5, [03](03-architecture.md) Phase 4). This is the
enabling change for the whole agent-observability story.

## 12. Now-playing/library MCP tools return prose, not always structured JSON
**There:** transport tools return the `nowPlayingSummary` **string**
(`MCPTools.swift:4132–4159`) while `music_now_playing`/`music_search` return JSON.
**Limitation:** an agent parsing "Playing: So What [1/12]" is brittle; mixed
string/JSON returns across the catalog are inconsistent.
**Improve:** return structured JSON uniformly (keep a human `summary` field), and add
the read tools from [04](04-integration-and-mcp.md) §3.4 (`music_get_queue`,
`music_seek`, etc.) so agents don't have to infer state from prose.

## 13. Downloads live under `~/Library/Caches/Tonebox/...`
**There:** gapless cache, waveform cache, and default download folder are under
Tonebox's container.
**Limitation:** on extraction these must move to Baton's container, and the download
**manifest** (`.tonebox-downloads.json`) needs migration or users lose their
offline library mapping.
**Improve:** define the migration during Phase 6 ([03](03-architecture.md)); rename the
manifest and cache dirs to Baton's namespace; write a one-time importer.

---

## Quick-win shortlist (highest value / lowest risk)
1. **Structured JSON from all music tools** (#12) — small, unblocks better agent UX.
2. **Playlist-id cache** (#3) — small, removes chatty round-trips.
3. **Radio-ban → server signal / sync** (#10) — small, real user benefit.
4. **Own Keychain + multi-server groundwork** (#6) — required for extraction anyway.
5. **Audio-focus owner-token contract** (#7) — the keystone fix; do it with Phase 2.
