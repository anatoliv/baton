# Baton — Documentation Suite

> **Working name:** `Baton`. Used everywhere a product name is
> needed so it can be find-replaced later. The final name is **not** decided —
> see [`08-open-questions-and-ideas.md`](08-open-questions-and-ideas.md).

## Elevator pitch

**Baton** is a standalone macOS music player for self-hosted
libraries (Navidrome / Subsonic), extracted from the mature player that today
lives *inside* Tonebox. It owns playback — a true-gapless `AVQueuePlayer`
engine with crossfade, ReplayGain, a 10-band EQ, waveform scrubbing, smart
mixes, radio, history, and dual scrobbling — and it wraps all of that behind an
**embedded MCP server** so any MCP client (Claude Desktop, Claude Code, other
agents, *and Tonebox itself*) can control it over one universal interface.

The thesis: a great local music player that is **agent-native from day one**.
Not "a player with an API bolted on," but a player whose control surface *is* an
MCP server, so "make me a 40-minute focus mix and duck it when I start
dictating" is a first-class interaction, not a hack.

## The goal / vision

1. **Extract** the in-Tonebox player into its own macOS app that owns playback.
2. **Host an MCP server** (Streamable HTTP over `127.0.0.1`, token-authenticated,
   discoverable via a config file) so *any* MCP client can drive playback,
   search the library, manage playlists, and observe now-playing state.
3. **Invert the Tonebox relationship**: Tonebox stops owning an in-process
   player and becomes a *client* of Baton, controlling it over the same universal
   interface every other agent uses.
4. **Introduce an "audio focus" primitive** — `audio_suspend(owner)` /
   `audio_resume(handle)` with an owner token — that generalizes Tonebox's
   in-process `suspendForCapture` / `resumeAfterCapture` so music ducks during
   dictation/recording and *only* auto-resumes if it was the one that paused.
5. **Be agent-first**: full tool catalog with JSON schemas, MCP resources with
   change notifications, discovery + auth that an agent can bootstrap, and
   registration snippets for Claude Desktop / Claude Code.

## The documents

| # | File | What it covers |
|---|------|----------------|
| — | [`README.md`](README.md) | This index + elevator pitch + audit notes |
| 01 | [`01-vision-and-goals.md`](01-vision-and-goals.md) | Problem, goal, target user, principles, non-goals, success criteria |
| 02 | [`02-feature-inventory.md`](02-feature-inventory.md) | Exhaustive inventory of **existing** functionality, each traced to its type/file |
| 03 | [`03-architecture.md`](03-architecture.md) | Target standalone architecture + the phased extraction plan + diagram |
| 04 | [`04-integration-and-mcp.md`](04-integration-and-mcp.md) | **The big one** — the shipped universal control interface: 30-tool MCP catalog, 5 resources + notifications, audio-focus contract, Tonebox-as-client wiring, native fast-path, registration |
| 05 | [`05-roadmap-new-features.md`](05-roadmap-new-features.md) | **New** features to build, prioritized (S/M/L), each tied to a competitive gap |
| 06 | [`06-improvements-existing.md`](06-improvements-existing.md) | Shipped-but-needs-hardening items mined from the code + git log |
| 07 | [`07-competitive-analysis.md`](07-competitive-analysis.md) | Expanded competitor analysis (Spotify, Apple Music, Plexamp, Symfonium, Roon, Navidrome-web, Feishin, foobar2000, YT Music, Tidal) |
| 08 | [`08-open-questions-and-ideas.md`](08-open-questions-and-ideas.md) | Self-audit of this suite: gaps, open decisions, and "wild ideas" |

## How to read this

- Building the extraction? Start at **03** (architecture) then **06** (what to
  harden as you move it).
- Wiring an agent or Tonebox as a client? Go straight to **04**.
- Pitching / prioritizing? **01**, **05**, **07**.

## Source-of-truth pointers (where the code lives)

The standalone app now lives at `app/Sources/Baton/`. Some feature docs still cite
the original in-Tonebox paths (`Sources/Tonebox/…`) the code was extracted from —
those are historical provenance, not the current location.

- MCP control surface (shipped): `app/Sources/Baton/MCP/` — `BatonMCPServer.swift`
  (Streamable-HTTP transport + SSE notifications + discovery file),
  `BatonMCPTools.swift` (30-tool catalog + dispatch), `BatonMCPMixTools.swift`
  (`music_build_mix` + pure `MixBuilder`), `BatonMCPResources.swift` (5 resources),
  `BatonAudioFocus.swift` (`audio_suspend`/`audio_resume` registry),
  `BatonControlSocket.swift` (Unix-socket fast-path), `BatonMCPProtocol.swift`
  (JSON-RPC + HTTP framing + token compare).
- Playback engine: `StreamingPlaybackController.swift` (the `AVQueuePlayer` engine),
  plus `MusicGaplessCache`, `AudioEQProcessor`, `MusicEqualizer`,
  `MusicNowPlayingCenter`, `OutputVolumeController`.
- Subsonic client: `NavidromeClient.swift`, `NavidromeConfig.swift`,
  `NavidromeModels.swift`.
- Tonebox-as-client (in the Tonebox repo):
  `Sources/Tonebox/Integrations/Baton/BatonClient.swift` (music delegation) +
  `BatonControl.swift` (dictation duck bridge); delegation seam in
  `Model/AppModel+Music.swift`.
- Existing competitive doc: `docs/music-player-competitive-comparison.html`.
- Local release/notarization: `scripts/publish.sh` (Release build → Developer ID
  sign → notarize/staple → DMG → Sparkle appcast; the credentialed stages are
  opt-in via `SIGN_ID` / `NOTARY_PROFILE`).

---

## Audit & review notes

The pre-implementation "proposed vs. today-in-Tonebox" framing this section once
carried is **obsolete**: the MCP control surface described in **04** is now shipped
in 0.1.0. What follows is the current state.

### Shipped in 0.1.0 (verified against `app/Sources/Baton/MCP/`)
- **Transport is Streamable HTTP.** `BatonMCPServer` serves `POST /mcp` (JSON-RPC) +
  `GET /mcp` (SSE), multi-client, `Mcp-Session-Id`, loopback-only, bearer-token,
  protocol `2025-06-18`. Server→client `notifications/resources/updated` are real
  (driven by a 0.5 s change-poll + post-tool-call check).
- **Discovery file** `~/Library/Application Support/Baton/mcp.json` (`0600`) with
  `url` + `token` + `fastPath.unixSocket`; scheme/name is `baton`, bundle id
  `io.tonebox.baton`. Default port `8787`, walks upward if taken.
- **30 tools** — 17 `music_*` + `music_build_mix` + 10 gap-fillers (seek, repeat,
  shuffle, get_queue, reorder, remove, play_next, radio, sleep_timer, eq) +
  `audio_suspend` / `audio_resume`.
- **5 resources** — `baton://now-playing`, `baton://queue`,
  `baton://library/playlists`, `baton://library/liked`, `baton://history/recent`.
- **Audio focus** with real **duck mode**, session/time-bound **handle expiry**, and
  **crash recovery**, plus the **Unix-socket fast-path** (~0.08 ms round-trip)
  sharing the same focus registry (`BatonAudioFocusRegistry`).
- **Tonebox is a client.** `BatonClient` + `BatonControl` ship; hybrid delegation is
  wired (`AppModel+Music.swift`, pref `tonebox.music.preferBaton` default on).
- **Signed + notarizable.** `scripts/publish.sh` produces a Developer ID-signed,
  notarized+stapled DMG and Sparkle appcast (credentialed stages opt-in); a
  `Baton-0.1.0.dmg` builds from it.

### Still roadmap / not done
- **Removing Tonebox's in-process player.** It remains as the fallback; Tonebox
  becoming a *pure* Baton client is a deliberate open product decision — see
  [04 §6](04-integration-and-mcp.md#6-tonebox-as-a-client-shipped-one-open-item).
- The standalone-app polish, casting, iOS, and every item in **05** (roadmap)
  remain proposals; **06** items are grounded in shipped code but the *fixes* are
  recommendations.
- **07** competitor cells are a mid-2026 best-effort snapshot and should be
  re-verified before quoting publicly.
