# 01 — Vision & Goals

## The problem

Tonebox grew a genuinely good music player as a *side feature* of a voice /
dictation / task app. It has depth that rivals Plexamp and Symfonium (true
gapless, crossfade, ReplayGain, a 10-band EQ, smart mixes, radio, dual
scrobbling — see [`02-feature-inventory.md`](02-feature-inventory.md)). But it is
trapped:

- **It lives inside another app.** No identity, no onboarding, no independent
  updates, no downloads manager of its own. Users who want "just the music
  player" have to run a task app.
- **It's a private, in-process feature.** Only Tonebox's own UI and its embedded
  MCP tools can drive it. Playback is owned by `AppModel.music`
  (`Model/AppModel.swift:357`), a `StreamingPlaybackController` that no other
  process can reach.
- **Its agent story is half-built.** Tonebox already exposes 20 `music_*` MCP
  tools, but they are bolted onto the *task/library* MCP server, share its
  lifecycle, and can't emit playback notifications an agent could subscribe to.
- **The capture coordination is hard-wired.** Music ducks for dictation via an
  in-process call (`music.suspendForCapture()`), which only works because the
  player and the dictation engine are in the *same address space*. Nothing
  outside Tonebox can participate in that hand-off.

## The goal

Extract the player into **Baton**, a standalone macOS app
that:

1. **Owns playback.** It is the single process that holds the `AVQueuePlayer`,
   the queue, the EQ tap, and the now-playing state.
2. **Hosts an MCP server** as its *primary* control surface — Streamable HTTP on
   `127.0.0.1`, token-authenticated, discoverable via a config file — so any MCP
   client (Claude Desktop, Claude Code, other agents, and Tonebox) can drive it.
3. **Turns Tonebox into a client.** Tonebox stops owning a player and instead
   calls Baton over the same universal interface everyone else uses.
4. **Generalizes capture coordination into an audio-focus primitive** with an
   owner token, so "duck the music while I dictate, then bring it back — but only
   if you were the one who paused it" works *across process boundaries*.

## Target users

| Persona | What they want | Why Baton |
|---------|----------------|---------|
| **Self-hoster / audiophile** | A first-class macOS client for their Navidrome / Subsonic server | Playback depth (gapless/EQ/ReplayGain) + polished UX, no subscription |
| **Agent power-user** | "Play me a focus mix," "what's this song," "make a playlist of everything I liked this month" — from Claude | The control surface *is* an MCP server; the agent story is the product, not an afterthought |
| **Tonebox user** | Dictation that automatically ducks music and restores it | Audio-focus hand-off works cleanly because it's a first-class protocol contract |
| **Tinkerer / integrator** | Wire music into home automation, Stream Deck, shortcuts | A documented localhost control interface + a native fast-path |

## Principles

1. **Agent-native, not agent-bolted.** The MCP server is the front door, not a
   plugin. Every capability the UI has should be reachable as a tool.
2. **Own your library.** Self-hosted Subsonic first. No lock-in, no catalog rent.
3. **Playback quality is non-negotiable.** Keep the gapless / crossfade /
   ReplayGain / EQ depth that already beats the mainstream desktop apps.
4. **Local-first + private.** Loopback binding, token auth, secrets in the
   Keychain. Nothing phones home by default.
5. **One behavior, many surfaces.** The in-app assistant, dictation commands, and
   MCP tools must resolve to the *same* operations — as they already do today
   (`AppModel+Music.swift` reuses the `music_*` operations; verified at
   `AppModel+Music.swift:4–7`).
6. **Race-safe coordination.** The audio-focus contract must survive concurrent
   agents and user intervention without leaving music silently paused.

## Non-goals (at least for v1)

- **A streaming catalog.** No Spotify/Tidal-style tens-of-millions library. Baton
  plays *your* server.
- **Being a DAW / editor.** Playback + library management, not production.
- **Windows / Linux desktop clients.** macOS first (iOS companion is roadmap —
  [`05-roadmap-new-features.md`](05-roadmap-new-features.md)).
- **Re-implementing Tonebox's task/session MCP tools.** Those stay in Tonebox;
  Baton's MCP server is music-only.
- **A general audio router.** Audio-focus is a cooperative suspend/resume
  contract, not a system-wide mixer.

## Success criteria

**Extraction is "done" when:**

- Baton runs as its own signed, notarized macOS app with its own bundle id,
  updater, and onboarding — no Tonebox dependency.
- Playback parity: every feature in [`02-feature-inventory.md`](02-feature-inventory.md)
  works in the standalone app.
- Tonebox's **command / voice / agent** music surface delegates to Baton over MCP when
  Baton is running (hybrid, `tonebox.music.preferBaton`), falling back to the in-process
  player otherwise. (The in-app Music **UI** and Tonebox's own `music_*` MCP tools still
  drive the in-process player by design — fully removing Tonebox's built-in player is a
  deliberate open decision, not a shipped goal; see `04-integration-and-mcp.md` §6.)
  Dictation ducking works over the audio-focus contract with **zero** cases of "music
  stayed paused" or "music resumed when the user had stopped it."

**The product is "working" when:**

- A fresh Claude Desktop can discover Baton from its `mcp.json`, authenticate, and
  run "play something relaxing" end-to-end with no manual token copying.
- An agent can subscribe to now-playing changes and react (e.g. scrobble to a
  third service, post to a status page) via MCP resource notifications.
- Latency for `music_next` / `audio_suspend` from Tonebox is imperceptible
  (< ~50 ms), using the native fast-path where the HTTP round-trip is too slow.

## The one-sentence version

*A standalone, self-hosted macOS music player whose control surface is an MCP
server — so agents (and Tonebox) can play, search, curate, and coordinate audio
focus over one universal, token-authenticated localhost interface.*
