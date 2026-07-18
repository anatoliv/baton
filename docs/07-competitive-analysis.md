# 07 — Competitive Analysis

Expands on the existing comparison at
`docs/music-player-competitive-comparison.html` (the source of the tier tables). This
doc adds the *why* — where Baton wins, where it lags, and what to borrow from each
rival — plus the agent-native angle none of them have.

> **Honesty caveat:** competitor capabilities are a **mid-2026 best-effort
> snapshot** and vary by platform, plan, and version. Treat every "competitor does
> X" as "typical current desktop behavior," not gospel — verify before quoting
> publicly. Baton's own capabilities are grounded in the code
> ([02](02-feature-inventory.md)).

---

## 1. The field

| Player | Category | Owns library? | Streaming catalog | Where it's strong |
|---|---|---|---|---|
| **Baton (this app)** | Self-hosted, agent-native | ● | ○ | Playback depth + agent control + Tonebox integration |
| Spotify | Streaming | ○ | ● | Recommendations, ubiquity, Connect |
| Apple Music | Streaming | ○ | ● | Ecosystem, lossless, AirPlay |
| Plexamp | Self-hosted (Plex) | ● | ◐ (Tidal/Qobuz) | Sonic analysis, mixes, cross-platform |
| Symfonium | Self-hosted (Android) | ● | ○ | Deep playback, multi-server, casting |
| Roon | Self-hosted, audiophile | ● | ◐ (Tidal/Qobuz) | RAAT, DSP, metadata, whole-home |
| Navidrome web | Self-hosted (Subsonic) | ● | ○ | Lightweight server UI |
| Feishin | Self-hosted (Subsonic/Jellyfin) | ● | ○ | Cross-platform desktop client |
| foobar2000 | Local files (Windows) | ● | ○ | DSP, customization, format support |
| YT Music | Streaming | ○ | ● | Catalog breadth, discovery |
| Tidal | Streaming | ○ | ● | Hi-res, Connect |

Baton's natural peer set is **Plexamp / Symfonium / Feishin / Navidrome-web** (the
self-hosted clients). Spotify/Apple/Tidal/YT are the *quality bar* for playback and
discovery UX, not direct competitors (different ownership model).

---

## 2. Where Baton already wins or ties the leaders

(Grounded in [02](02-feature-inventory.md).)

1. **Playback depth on par with Plexamp/Symfonium.** True gapless *plus* stream
   prefetch (`StreamingPlaybackController.swift:1051–1117`), crossfade, ReplayGain
   (`normalizationGain` :788), and a 10-band EQ (`AudioEQProcessor.swift`) — features
   Spotify/Apple/Tidal/YT mostly lack on desktop.
2. **Native dual scrobbling.** Last.fm *and* ListenBrainz built in
   (`MusicLastFM.swift`, `MusicScrobbler.swift`) — most mainstream apps need a
   third-party bridge; open clients usually do one, server-side.
3. **Discovery + stats the open clients don't have.** Home / Mixes / History / Radio
   (`MusicHomeView.swift`, `MusicMix.swift`, `MusicHistoryView.swift`,
   `MusicRelatedView.swift`) — Navidrome-web and Feishin are comparatively bare here.
4. **Polished macOS UX.** Hero detail pages, collapsible now-playing bar, floating
   mini-player, waveform scrubber, Finder-style multi-select — genuinely nicer than
   most Subsonic clients.
5. **You own the library and it's free.** The whole point vs Spotify/Tidal.
6. **The differentiator none of them have: an MCP control surface.** Agent-native
   from day one ([04](04-integration-and-mcp.md)) — see §5.

---

## 3. Where Baton lags — and what to borrow

| Gap | Who does it well | Borrow | Roadmap |
|---|---|---|---|
| **macOS-only** | everyone | A phone client is the price of admission; reuse the `Sendable` client/models | [05](05-roadmap-new-features.md) #1 (L) |
| **Casting = AirPlay only** | Plexamp, Symfonium, Spotify (Connect/Cast) | Chromecast + UPnP/DLNA + Sonos; stream URLs are already plain HTTP | #2 (M) |
| **No podcasts / internet radio** | Plexamp, Feishin, Symfonium | Subsonic already exposes both; mostly UI | #5, #6 (S–M) |
| **Heuristic mixes, not sonic** | Plexamp (sonic analysis, "Sonic Adventures") | Local tempo/energy/key analysis of downloads | #4 (L) |
| **Single server** | Symfonium, Feishin | N-connection store + quick switch | #7 (S–M) |
| **Graphic EQ, not parametric/DSP** | Roon, foobar2000 | Parametric bands, crossfeed, per-output presets | #8 (M) |
| **No standalone identity yet** | all | The whole extraction ([03](03-architecture.md)) | — |

### Per-rival "what to steal"
- **Plexamp** — *sonic analysis* is its moat: mood/energy mixes and smart
  transitions from analyzing the actual audio. This is the one feature that would let
  Baton *beat* the open clients, not just match them (#4). Also its polished
  cross-platform story (#1).
- **Symfonium** — pragmatic **multi-server** + broad **casting**; a model for #2/#7.
- **Roon / foobar2000** — **DSP depth** (parametric EQ, crossfeed, upsampling). Baton
  already has the tap engine (`AudioEQProcessor.swift`); extend it (#8).
- **Spotify** — **recommendation quality** and **Connect** (control playback on any
  device). Baton's answer to "Connect" is *better*: the MCP server already makes Baton
  controllable by anything — lean into that framing.
- **Apple Music / Tidal** — **hi-res/lossless polish** and system integration; Baton's
  ReplayGain + gapless already cover much of the "sounds right" bar.
- **Navidrome-web / Feishin** — they're the baseline Baton already beats on UX and
  discovery; the lesson is *don't regress* to a bare Subsonic client during
  extraction.
- **YT Music** — discovery breadth (impossible without a catalog); the transferable
  idea is *frictionless* "start radio from anything," which Baton has via
  `getSimilarSongs2`.

---

## 4. Honest scorecard (self-assessment)

- **Playback quality:** top-tier for self-hosted; ties Plexamp/Symfonium, beats the
  streaming apps on desktop DSP.
- **Library/browse UX:** best-in-class among Subsonic clients.
- **Discovery:** good heuristics, but sonic analysis (Plexamp) is a real edge Baton
  hasn't matched.
- **Reach:** worst-in-class — macOS-only, AirPlay-only. This is where Baton loses head
  to head today.
- **Ecosystem/control:** *unique* — no competitor exposes an agent control surface.

---

## 5. The category Baton can own: agent-native music

No competitor ships an **MCP server as its control surface**. Spotify has Connect and
a Web API (cloud, OAuth, rate-limited); Plexamp/Roon have remote control within their
own ecosystems. None of them let a *local agent* — Claude Desktop, Claude Code, a
Shortcut, another app — drive playback, curate playlists, and **coordinate audio
focus** over a documented localhost interface.

That's the wedge:

- **"Play me a 40-minute focus mix"** as a first-class interaction, not a hack
  ([05](05-roadmap-new-features.md) #10).
- **Cross-app automations** — duck for dictation, log what was playing to a meeting,
  resume after ([04](04-integration-and-mcp.md) §6, [05](05-roadmap-new-features.md)
  #11).
- **Observability** — agents subscribe to now-playing and react
  ([04](04-integration-and-mcp.md) §5).

Baton doesn't need to out-catalog Spotify or out-DSP Roon to win its niche. It needs to
be the **best self-hosted macOS player that is also the one an agent can actually
control.** The playback depth is already there; the agent surface is the moat.
