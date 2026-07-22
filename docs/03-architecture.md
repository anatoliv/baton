# 03 — Target Architecture & Extraction Plan

How **Baton** is structured as a standalone macOS app, and the
phased plan to lift it out of Tonebox.

---

## 1. Target architecture

### 1.1 Shape

Baton is a **menu-bar agent app** (`LSUIElement`-style, no Dock icon required) that
can open a **main window** on demand. Running as an agent matters: playback should
keep going and the MCP server should keep answering even when no window is open —
the same reason a music player belongs in the menu bar, not tied to a window's
lifecycle.

```
┌──────────────────────────────────────────────────────────────────────┐
│  Baton.app  (single process — owns playback)                            │
│                                                                       │
│  ┌──────────────┐   ┌───────────────────────────┐  ┌──────────────┐  │
│  │ Menu-bar UI  │   │  MusicModel  (root)        │  │ Main window  │  │
│  │ + mini player│──▶│  = the old AppModel.music* │◀─│  (SwiftUI)   │  │
│  └──────────────┘   │    graph, minus tasks      │  └──────────────┘  │
│                     │                            │                     │
│   ┌─────────────────┴─────────────┐   ┌──────────┴───────────────┐    │
│   │ PlaybackEngine                │   │ MusicLibraryStore         │    │
│   │  StreamingPlaybackController  │   │  + play history           │    │
│   │  + GaplessCache + EQ tap      │   │  + scrobblers (LB/Last.fm)│    │
│   │  + NowPlayingCenter (MPRcc)   │   │  + downloads store        │    │
│   │  + OutputVolumeController     │   └──────────┬───────────────┘    │
│   │  + AudioFocusCoordinator ◀────┼── NEW        │                     │
│   └───────────────┬───────────────┘              │                     │
│                   │                              ▼                     │
│                   │                   ┌───────────────────────────┐    │
│                   │                   │ NavidromeClient (Subsonic)│    │
│                   │                   │ + NavidromeConfig (own    │    │
│                   │                   │   Keychain, multi-server) │    │
│                   │                   └───────────────────────────┘    │
│                   ▼                                                    │
│   ┌───────────────────────────────────────────────────────────────┐  │
│   │ Embedded MCP server (Streamable HTTP, 127.0.0.1, bearer token) │  │
│   │  tools/  resources/  notifications/  + audio_suspend/resume    │  │
│   │  writes discovery file: ~/Library/Application Support/Baton/mcp.json │
│   └───────────────────────────────────────────────────────────────┘  │
│                   ▲                                                    │
└───────────────────┼────────────────────────────────────────────────────┘
                    │  MCP over localhost (+ optional native fast-path)
        ┌───────────┼───────────┬─────────────────┬───────────────┐
        ▼           ▼           ▼                 ▼               ▼
   Claude Desktop  Claude Code  Other agents   Tonebox (client)  Shortcuts/
                                                                  Stream Deck
```

`*` "music\* graph" = the objects `AppModel` holds today: `music`
(`StreamingPlaybackController`), `musicLibrary`, `musicHistory`, `musicRadioBans`,
`musicScrobbler`, `musicLastFM`, `musicEqualizer` (`AppModel.swift:357–370`).

### 1.2 Components

| Component | Extracted from | Responsibility |
|---|---|---|
| **MusicModel** (root) | the music slice of `AppModel` | Owns the object graph, wires closures (`relatedProvider`, `streamURLProvider`, `configureAudioMix`), app lifecycle |
| **PlaybackEngine** | `StreamingPlaybackController` + `Audio/*` | AVQueuePlayer, gapless, crossfade, EQ tap, media keys, ducking |
| **AudioFocusCoordinator** | generalize `suspendForCapture`/`resumeAfterCapture` | Cross-process suspend/resume with owner tokens (see [04](04-integration-and-mcp.md)) |
| **MusicLibraryStore** | as-is | Search/browse/starred/playlists cache, ratings, downloads |
| **NavidromeClient / Config** | `Integrations/Navidrome/*` | Subsonic API; config decoupled from `AIConfig`, multi-server |
| **MCP server** | `MCP/MCPServer.swift` + music tools | The primary control surface; music-only tool catalog |
| **App shell** | NEW | Menu-bar item, mini player, main window, onboarding, updater, auto-launch |

### 1.3 Config & secrets

- **Own Keychain namespace.** Today `NavidromeConfig.secret` routes through
  `AIConfig.secretString`/`setSecretString` (`NavidromeConfig.swift:33–44`). Baton has
  no `AIConfig`, so this must become a small `KeychainStore` of its own (same
  migrate-on-read behavior, new service id, e.g. `io.tonebox.baton`).
- **Multi-server.** `NavidromeConfig` is single-server today (comment at
  `NavidromeConfig.swift:5`, keys `tonebox.navidrome.url` etc.). Generalize to a
  list of `ServerConnection` records with an active selection (see
  [05](05-roadmap-new-features.md) and 06 (internal)).
- **MCP config.** Port/token/allow-remote move from Tonebox's `@AppStorage`
  (`MCPSettingsView.swift:9–11`) to Baton's own settings, and Baton additionally
  **writes a discovery file** (new — see [04](04-integration-and-mcp.md)).

### 1.4 Lifecycle & auto-launch

- **Login item** (`SMAppService`) so Baton starts at login and the MCP server is
  available to agents without the user opening a window.
- **Playback survives window close** — the engine lives on `MusicModel`, not a
  view.
- **MCP server starts with the app** (not gated behind opening Settings), reading
  its port/token from Baton's defaults + Keychain and refreshing the discovery file.
- Signed + notarized, own bundle id, own Sparkle-style updater (Tonebox already has
  an appcast pipeline — see the project memory on `appcast.tonebox.io`; Baton needs
  its own channel).

---

## 2. The extraction plan (phased)

The player is already remarkably self-contained: it's a distinct object graph on
`AppModel` and a distinct folder tree (`Audio/`, `Shell/Music/`,
`Integrations/Navidrome/`). The work is **decoupling**, not rewriting.

### Phase 0 — Carve out a `MusicModel` root (inside Tonebox first)
**Goal:** stop reaching through `AppModel` for music; introduce a `MusicModel` that
owns the music graph, still hosted by Tonebox.

- Create `MusicModel` holding `music`, `musicLibrary`, `musicHistory`,
  `musicRadioBans`, `musicScrobbler`, `musicLastFM`, `musicEqualizer`.
- Move the wiring currently in `AppModel` (`relatedProvider` closure at
  `AppModel.swift:746`, scrobble hooks, `configureAudioMix`) onto `MusicModel`.
- Repoint the `music_*` MCP tools and the music command path at `MusicModel` instead
  of `appModel.music` / `appModel.musicLibrary`.
- **Exit test:** Tonebox behaves identically; music code no longer references task /
  session types. This is the seam the standalone app will cut along.

### Phase 1 — Split `NavidromeConfig` off `AIConfig`
**Goal:** music config owns its own secret storage.

- Introduce `KeychainStore` (music-owned) and repoint `NavidromeConfig.secret`
  (`NavidromeConfig.swift:33`) away from `AIConfig.secretString`.
- Keep the same UserDefaults keys for now (migration comes with the standalone
  bundle id).
- **Exit test:** connect/verify/disconnect still work; no `AIConfig` symbol in the
  music module.

### Phase 2 — Generalize capture → audio-focus
**Goal:** replace the in-process `suspendForCapture`/`resumeAfterCapture` with an
`AudioFocusCoordinator` that takes an **owner token**.

- Add `audio_suspend(owner) -> handle` / `audio_resume(handle)` semantics
  (contract in [04](04-integration-and-mcp.md)). The existing private
  `suspendedForCapture` flag becomes an owner-tagged handle with a state generation
  counter so a stale resume is rejected.
- In Tonebox, keep the in-process call path working via the coordinator (so nothing
  breaks before the split), but route it through the same token contract.
- **Exit test:** dictation ducking still works; a resume after the user manually
  stops is a no-op (matches today's `resumeAfterCapture` guard at
  `StreamingPlaybackController.swift:864`).

### Phase 3 — Stand up the Baton app shell
**Goal:** a runnable standalone bundle.

- New Xcode/XcodeGen target: menu-bar agent + main window, imports the now-decoupled
  music module.
- Onboarding (connect a server), Settings (server, playback, EQ, MCP, downloads),
  login item, updater.
- **Exit test:** Baton plays music end-to-end with **no Tonebox present**.

> **Status update (0.1.0):** Phase 4 and most of Phase 5 have shipped. Baton hosts the
> music MCP server on Streamable HTTP with SSE notifications, 5 resources, the
> discovery file, and the Unix-socket fast-path; Tonebox is a client
> (`BatonClient`/`BatonControl`, hybrid delegation). The one Phase-5/6 item still open
> is *deleting* Tonebox's in-process player — it remains as a fallback. See
> [04](04-integration-and-mcp.md) for the shipped surface. The phase text below is the
> original extraction plan, kept for provenance.

### Phase 4 — Move the MCP server into Baton; upgrade the transport
**Goal:** Baton hosts the music MCP server; it becomes the primary control surface.

- Port `MCPServer` + the music tool catalog into Baton (drop the task/session tools).
- Upgrade transport to **Streamable HTTP + SSE** with a persistent stream for
  server→client **notifications** (the pre-extraction Tonebox server was
  request-per-connection with `Connection: close` and had no MCP notifications —
  see the internal audit notes).
- Add MCP **resources** for now-playing + queue with `resources/updated`
  notifications.
- Write the **discovery file** at `~/Library/Application Support/Baton/mcp.json`.
- **Exit test:** Claude Desktop discovers + drives Baton; an agent subscribes to
  now-playing changes.

### Phase 5 — Invert Tonebox: make it a client
**Goal:** Tonebox no longer owns a player.

- Delete the in-process `AppModel.music` engine from Tonebox; replace `music.*`
  calls with an `BatonClient` that speaks MCP (with the native fast-path for
  latency-critical calls — [04](04-integration-and-mcp.md)).
- Dictation start → `audio_suspend(owner: "tonebox.dictation")`; terminal →
  `audio_resume(handle)`.
- Handle "Baton not running": either launch it, or degrade gracefully (music control
  disabled, dictation still works).
- **Exit test:** Tonebox dictation ducks Baton's music and restores it, across
  processes, with no regressions vs the in-process behavior.

### Phase 6 — Cutover & cleanup
- Remove the music UI from Tonebox (or keep a thin "open Baton" affordance).
- Ship Baton on its own channel; migrate user config (server + likes are server-side
  already; local bits: play history, EQ presets, radio bans, download manifest).

---

## 3. Risks & sequencing notes

- **Phases 0–2 are safe to do inside Tonebox** and ship incrementally — they're pure
  decoupling with identical behavior. Do these first; they de-risk everything after.
- **Transport upgrade (Phase 4) is the one genuinely new networking work.** The
  current server is deliberately simple (one request per connection). Streamable
  HTTP + notifications is a real feature, not a refactor — budget for it.
- **The native fast-path (Phase 5) is optional** but likely necessary for dictation
  ducking to feel instant; see the latency discussion in [04](04-integration-and-mcp.md).
- **Downloads path** references a Tonebox cache dir (`~/Library/Caches/Tonebox/...`).
  Rename to Baton's container and migrate the manifest.
- **`AVQueuePlayer` gapless is timing-sensitive** — the prefetch/adopt logic
  (`StreamingPlaybackController.swift:1051–1117`) was tuned against real playback.
  Don't "clean it up" during extraction; move it verbatim and re-verify on hardware
  (06, internal).
