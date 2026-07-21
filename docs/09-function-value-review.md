# 09 — Function Value Review

A ranked, opinionated review of Baton's application functions — every function
scored by **value** (how much it matters to the product's success) and by
**execution** (how well it's built today), each with a short opinion.

> **This is a judgment doc, not an inventory.** The neutral, source-traced list of
> what exists lives in [`02-feature-inventory.md`](02-feature-inventory.md); the
> shipped-but-needs-hardening list is [`06`](06-improvements-existing.md); the
> roadmap gaps are [`05`](05-roadmap-new-features.md). This doc layers a subjective
> value opinion on top of those, to guide prioritization and messaging.

## How to read the scores

- **Value ★/5** — importance to Baton *as a product*: how central it is, and how
  much it differentiates Baton from Spotify / Apple Music / a plain Subsonic web UI.
  Table stakes can still score high (you can't ship without them); the sort is by
  this column.
- **Execution ★/5** — how complete and well-built it is *today*, read from the
  feature inventory and git history. A low execution score on a high-value function
  is where attention pays off most.
- **Opinion** — one honest line. Where a function has a known gap, it's named.

Functions are sorted by value (then by execution within a tier). Rank is just the
row order.

## The table

| # | Function | Value | Execution | Opinion |
|---|----------|:-----:|:---------:|---------|
| 1 | **MCP agent-control surface** (30 tools, 5 resources, auth, discovery) | ★★★★★ | ★★★★★ | Baton's reason to exist and its one true moat. Agent-native from day one, not an API bolted on. Everything else is a *good music player*; this is the part nobody else ships. Protect it fiercely. |
| 2 | **Playback engine** (transport, queue, modes, persistence) | ★★★★★ | ★★★★★ | Table stakes, but every other function rides on it and it's clearly the most battle-tested code in the app (drain-recovery, seek guards, restore-paused). Unglamorous excellence — exactly right. |
| 3 | **Library browse & search** (Subsonic/Navidrome client) | ★★★★★ | ★★★★☆ | Without it there is nothing to play. Broad, correct client surface. The one compromise — forcing `format=mp3` because AVFoundation won't decode Opus/WMA — is pragmatic but caps the audiophile story; worth a native-decode path someday. |
| 4 | **True gapless + stream-prefetch-to-disk** | ★★★★☆ | ★★★★★ | The headline audiophile differentiator over every mainstream streamer, and unusually thorough (pre-inserted items, network prefetch, Wi-Fi-only guard, LRU cache). This is the feature that earns the self-hoster's respect. |
| 5 | **Audio-focus suspend/resume** (duck / restore, MCP + Unix-socket) | ★★★★☆ | ★★★★☆ | The crown jewel of the Tonebox relationship and strategically bigger than music: a clean cross-process "get out of the way politely" primitive. "Only auto-resume if *I* paused it" is the detail that makes it trustworthy. |
| 6 | **Auto-mixes + Home "For You" shelves** | ★★★★☆ | ★★★☆☆ | The main engagement driver and the first thing users see — high value. But mixes are heuristic (history + server lists + genre shuffle), **not** sonic analysis. This is Baton's biggest value-vs-execution gap and the clearest place to invest (see [05](05-roadmap-new-features.md)). |
| 7 | **Downloads / offline** | ★★★★☆ | ★★★★☆ | Genuine self-hoster value and correctly wired (local files silently preferred over streaming; global Offline mode). Turns Baton from a streaming client into something you can take on a plane. |
| 8 | **Scrobbling** (ListenBrainz + Last.fm + server) | ★★★★☆ | ★★★★☆ | Precisely matched to the audience that runs Navidrome. Dual-native, threshold-gated, with a durable offline queue. Quietly one of the most "gets me" features for the target user. |
| 9 | **Playlists CRUD + drag-reorder** | ★★★★☆ | ★★★★☆ | Core library management; the hard part (persisting reorder back to the server via `setPlaylistSongs`) is done. Expected, and done right. |
| 10 | **Continuous radio / related** | ★★★★☆ | ★★★★☆ | Keeps a session alive with no user effort — high stickiness for low cost. Local radio-bans are a thoughtful touch. Depends on the server's `getSimilarSongs2` quality, which is the ceiling. |
| 11 | **Media keys + Now-Playing center** | ★★★★☆ | ★★★★☆ | The difference between "a window that plays audio" and "a Mac app." F-keys, Bluetooth remotes, the system widget — invisible when present, glaring when absent. The off-main-actor artwork merge shows care. |
| 12 | **Menu-bar controller** | ★★★★☆ | ★★★☆☆ | Undersold. It's the thing that keeps Baton — and therefore the **MCP server** — alive when every window is closed. For an agent-native app that's not a convenience, it's load-bearing infrastructure. |
| 13 | **Speak summaries** (`speak_summary` TTS) | ★★★★☆ | ★★★☆☆ | Novel, on-brand, and genuinely fun: agents that *talk back*, one voice per agent. Niche today, but it's the kind of feature that gets Baton talked about. Self-hosted TTS with a macOS-voice fallback is the right call. |
| 14 | **Parametric EQ** (10-band, presets) | ★★★☆☆ | ★★★★★ | Beautifully engineered — render-thread biquad cascade, bit-exact pass-through when off. Appeals to a real but minority audience. Execution far exceeds the audience size; that's fine as a credibility signal. |
| 15 | **Full-screen Now Playing** | ★★★☆☆ | ★★★★☆ | The immersion/delight surface (big art, adaptive backdrop, waveform, side panels). Doesn't win users but keeps them; makes the app feel premium. |
| 16 | **Floating mini-player** | ★★★☆☆ | ★★★★☆ | Strong fit with the multi-agent story — a glanceable HUD while you work. Recent, active investment. Liquid Glass on 26+ is a nice flex. |
| 17 | **History** (local play log + export/import) | ★★★☆☆ | ★★★★☆ | A free, local Last.fm/ListenBrainz alternative that never leaves the Mac. Export/import (ListenBrainz JSON / CSV) is more thoughtful than it needed to be. |
| 18 | **Ratings & liking** (5-star + heart) | ★★★☆☆ | ★★★★☆ | Expected, and the fuel for mixes and Home. Optimistic overrides (instant UI regardless of collection) is the detail that makes it feel good. |
| 19 | **Loudness normalization** (ReplayGain / R128) | ★★★☆☆ | ★★★★☆ | Audiophile expectation, correct math (preamp + peak-clamp). Quiet, correct, off nobody's radar until it's missing. |
| 20 | **Multiple servers / account switching** | ★★★☆☆ | ★★★★☆ | Real for the target user — self-hosters often run more than one library. Per-server Keychain isolation is the right model. |
| 21 | **Multi-select batch actions** | ★★★☆☆ | ★★★★☆ | Power-user efficiency (Finder-style range, select-all, smart batch like). Punches above its weight for library-wranglers. |
| 22 | **Lyrics** (synced / plain) | ★★★☆☆ | ★★★☆☆ | Nice engagement surface, but entirely server-dependent with no fallback yet — so for many libraries it's simply blank. Value is real; reach is gated by the server. |
| 23 | **AirPlay** | ★★★☆☆ | ★★★☆☆ | Expected casting, and it works — but **only** AirPlay. No Chromecast / Sonos / UPnP is a visible gap for a self-hosting crowd that often has mixed-brand speakers (see [05](05-roadmap-new-features.md)). |
| 24 | **Podcasts + Internet-radio tabs** | ★★★☆☆ | ★★★☆☆ | Broadens Baton past "album player" and the webhook-actions tie-in is clever. Secondary to the music core, but cheap breadth that widens the audience. |
| 25 | **Queue persistence / restore-paused** | ★★★☆☆ | ★★★★☆ | Invisible quality-of-life: close the app mid-album, reopen exactly where you were. Nobody praises it; everybody would miss it. |
| 26 | **Crossfade** | ★★☆☆☆ | ★★★★☆ | Well-built, but it's mutually exclusive with the higher-value true-gapless, so most of the target audience will turn it off. A preference feature, not a headliner. |
| 27 | **Sleep timer** (with ~5 s fade-out) | ★★☆☆☆ | ★★★★☆ | Small feature, but the gentle fade instead of a hard cut is a real delighter and a quiet differentiator vs mainstream apps. Cheap charm. |
| 28 | **Adaptive artwork backdrop / palette** | ★★☆☆☆ | ★★★★☆ | Pure polish, but it's the polish that makes screenshots sell. Punches above its weight in perceived quality. |
| 29 | **Mark-for-removal** | ★★☆☆☆ | ★★★★☆ | A clever, honest workaround for Subsonic's lack of a delete API (unlike + 1-star as a prune signal). Small audience, but it respects the platform's limits instead of faking a capability. |
| 30 | **Waveform scrubber** | ★★☆☆☆ | ★★★☆☆ | Delightful, but **downloads-only** (streams fall back to a capsule), so most listening never sees it. Lovely where it appears; limited reach. |
| 31 | **Webhook actions** | ★★☆☆☆ | ★★★☆☆ | Niche power-user glue, aimed at podcast pipelines (POST an episode to a transcriber). Templating is nicely general. Low reach, but it costs the core nothing and delights the few who want it. |

## What the ranking says

A few themes fall out of sorting by value:

1. **The moat is the MCP surface, and it's the best-executed thing in the app
   (#1).** Baton's defensible story isn't "a nice Subsonic player" — a dozen of
   those exist — it's "the player whose control surface *is* an MCP server."
   Messaging, roadmap, and QA should treat #1, #5 (audio-focus), #12 (menu-bar
   keep-alive), and #13 (speak-summary) as one connected agent-native pillar, not
   scattered features. **This is now written up as one unit** — with an end-to-end
   pillar QA invariant — in [`10-findings-implementation.md`](10-findings-implementation.md#the-agent-native-pillar-f1-deliverable).

2. **The biggest value-vs-execution gap is discovery (#6).** Auto-mixes and Home
   are high-value and the front door, but they're heuristic, not sonic. This is the
   single place where raising execution most raises product value — and it's the
   competitive gap against Plexamp called out in [05](05-roadmap-new-features.md).

3. **The audiophile cluster (gapless #4, EQ #14, ReplayGain #19, crossfade #26)
   is over-delivered relative to its audience — and that's correct.** It's
   credibility. Self-hosters choose Baton *because* it sweats the audio path; you
   don't need everyone to use the EQ for it to earn trust.

4. **Casting (#23) is the most conspicuous gap in an otherwise-native macOS
   experience.** AirPlay-only stands out for a mixed-hardware self-hosting crowd.

5. **The "quiet quality" tier (#25 restore, #27 fade, #28 backdrop) is where
   Baton feels expensive.** Individually low-value, collectively they're the
   difference between "works" and "feels crafted." Keep them.

---

*Scores are one reviewer's opinion as of this revision; re-score as the mixes
engine, casting, and lyrics-fallback gaps close.*
