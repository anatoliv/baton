# 04 — Integration & the Universal Control Interface

> **Status: shipped in 0.1.0.** Everything in this document describes the control
> surface as it actually ships in Baton 0.1.0 (code under
> `app/Sources/Baton/MCP/`). Where something is still a roadmap item (removing
> Tonebox's in-process player, casting, iOS) it is called out explicitly as
> not-done.

This is the load-bearing document. Baton's control surface is an **MCP server** so
any MCP client — Claude Desktop, Claude Code, other agents, and **Tonebox** — can
drive playback, search the library, curate playlists, observe now-playing state,
and coordinate **audio focus** over one interface.

---

## 1. The interface at a glance

- **Primary:** an embedded **MCP server** speaking **Streamable HTTP** on
  `127.0.0.1`, bearer-token authenticated, discoverable via a config file. Supports
  **multiple concurrent clients** and **server→client notifications** over SSE.
- **Native fast-path:** a Unix-domain socket for latency-critical control (dictation
  ducking) — the same audio-focus operations, sub-millisecond round-trip, sharing the
  same focus registry as the MCP path.
- **Key primitive:** `audio_suspend(owner)` / `audio_resume(handle)` — cooperative
  audio focus with an owner token, so music pauses or ducks during capture and only
  auto-resumes if the suspender still holds focus and the user didn't intervene.

---

## 2. Transport, discovery & security

### 2.1 Transport — Streamable HTTP

The server (`BatonMCPServer`) speaks MCP **Streamable HTTP** on `127.0.0.1`:

- **`POST /mcp`** carries JSON-RPC 2.0 — `initialize`, `ping`, `tools/list`,
  `tools/call`, `resources/list`, `resources/read`, and `notifications/*`. A request
  with an `id` gets a JSON response; a notification (no `id`) gets `202 Accepted`.
- **`GET /mcp`** opens a long-lived **SSE stream** (`text/event-stream`, kept alive)
  that the client reads to receive **server→client notifications**. Every open stream
  is added to a fan-out set, so multiple clients (Claude Desktop + Claude Code +
  Tonebox at once) each receive track/queue-change notifications.
- **`DELETE /mcp`** tears the session down.

Protocol version is `2025-06-18` (`BatonMCPConstants.protocolVersion`). Session ids
travel in the `Mcp-Session-Id` header and are echoed back; the server records which
SSE stream belongs to which session so it can auto-expire that session's audio-focus
handles when the stream closes (§4.3).

Hardening: a 1 MB request cap (`BatonMCPConstants.maxRequestBytes`, enforced in
`HTTPRequestMessage.parse`), constant-time token compare
(`BatonMCPAuth.constantTimeEquals`), and a loopback-only listener.

### 2.2 Discovery file

Baton writes, at startup (after it binds a port):

```
~/Library/Application Support/Baton/mcp.json
```

```json
{
  "schemaVersion": 1,
  "name": "baton",
  "transport": "streamable-http",
  "url": "http://127.0.0.1:8787/mcp",
  "token": "e3b0c44298fc1c149afbf4c8996fb924...",
  "pid": 41234,
  "app": { "bundleId": "io.tonebox.baton", "version": "0.1.0" },
  "fastPath": {
    "unixSocket": "~/Library/Application Support/Baton/control.sock"
  }
}
```

- File perms are `0600` (the token is a secret). A client (or Tonebox) reads this
  file to self-configure — no manual token copying.
- The default port is `8787`; if it's taken the server walks upward
  (`BatonMCPConstants.portScanRange`) and writes whatever port it actually bound.
- The token is generated once (~256-bit hex) and persisted in `UserDefaults`
  (`baton.mcp.token`); the discovery file is the bootstrap that makes Baton "just
  work" for agents.

### 2.3 Security model

1. **Loopback-only** — the listener binds `requiredInterfaceType = .loopback`
   (`BatonMCPServer.bind`); it's unreachable off-device.
2. **Bearer token required** — every request is checked in constant time; a bad or
   missing token → `401`. The token is ~256 bits.
3. **Both layers required** — neither alone is sufficient.
4. **Discovery file is `0600`** so the token isn't world-readable.
5. **The fast-path socket is `0600`** too — same trust model as the token.
6. **Tool annotations** — read-only / destructive / open-world hints (`annotate` in
   `BatonMCPToolCatalog`) so a client can warn before, e.g., `music_delete_playlist`
   (the one tool tagged `destructiveHint`).

---

## 3. The MCP tool catalog

**30 tools** ship in 0.1.0 (`BatonMCPToolCatalog.definitions()`, dispatch in
`BatonMCPToolCatalog.run(...)`): 17 `music_*` control tools, the agent-native
`music_build_mix`, the 10 gap-filler tools (§3.4), and the two `audio_*` focus tools
(§4).

Conventions (from the code):
- Tool result is `{ content: [{type:"text", text: <JSON string>}], isError }`
  (`BatonMCPServer.dispatch`). Outputs below are the JSON inside `text`.
- All music tools are `openWorldHint: true` (they reach the Navidrome server);
  `music_search` / `music_now_playing` / `music_list_playlists` / `music_get_queue`
  are also `readOnlyHint` + `idempotentHint`.
- `query`-based tools resolve a search and act on the results; playback tools act on
  this Mac's player (`MusicModel.music`).

### 3.1 Transport & queue tools

#### `music_play`
Search and immediately play, replacing the queue. An exact/prefix album match plays
the album in track order; otherwise loose song hits (`resolvePlayQueue`).
```jsonc
// input
{ "type":"object",
  "properties": {
    "query":  {"type":"string","description":"artist, album, song, or vibe"},
    "limit":  {"type":"integer","description":"max songs to queue (default 25, max 100)"}
  },
  "required":["query"] }
// output
{ "playing": {"id":"...","title":"So What","artist":"Miles Davis","album":"Kind of Blue","duration_seconds":544},
  "queued": 5 }
```

#### `music_queue_add`
Append search matches without interrupting playback.
```jsonc
// input: same shape as music_play (query, limit)
// output
{ "added": 5, "queue_length": 12, "summary": "Playing: So What [1/12]" }
```

#### `music_pause` · `music_resume` · `music_stop` · `music_next` · `music_previous`
No inputs. Return the `nowPlayingSummary` string (`music_stop` returns `"Stopped."`).

#### `music_set_volume`
```jsonc
// input
{ "properties": { "percent": {"type":"integer","description":"0 (silent)–100 (full)"} },
  "required":["percent"] }
// output: "Music volume set to 70."
```
Affects only Baton's player, not the macOS system volume.

### 3.2 Now-playing & search

#### `music_now_playing` (read-only)
```jsonc
// no input
// output
{ "state":"playing", "summary":"Playing: So What [1/12]",
  "queue_length":12, "queue_index":0,
  "now_playing":{"id":"...","title":"So What","artist":"Miles Davis","album":"Kind of Blue","duration_seconds":544} }
```
`state` ∈ stopped/loading/playing/paused/`error: <msg>`
(`BatonMCPToolCatalog.musicStateLabel`).

#### `music_search` (read-only)
```jsonc
// input
{ "properties": {
    "query": {"type":"string"},
    "limit": {"type":"integer","description":"max songs (default 20, max 100)"} },
  "required":["query"] }
// output
{ "songs":[{"id":"...","title":"...","artist":"...","album":"...","duration_seconds":210}],
  "albums":[{"id":"...","name":"...","artist":"..."}],
  "artists":[{"id":"...","name":"..."}] }
```

### 3.3 Playlists & ratings

| Tool | Input (required) | Effect |
|---|---|---|
| `music_list_playlists` (read-only) | — | `{playlists:[{id,name,song_count}]}` |
| `music_play_playlist` | `name` **or** `playlist_id` | Replace queue with playlist tracks |
| `music_like` | (optional `query`, `unlike`) | Star/unstar; acts on current track if no `query` |
| `music_rate` | `rating` (0–5; 0 clears), optional `query` | Server-side per-user rating |
| `music_create_playlist` | `name`, optional `query` seed | Create, optionally seeded |
| `music_add_to_playlist` | `query`, `name`/`playlist_id` | Append matches |
| `music_delete_playlist` | `name` **or** `playlist_id` | Delete (only `destructiveHint` tool) |

Example — `music_rate`:
```jsonc
// input
{ "properties": {
    "rating": {"type":"integer","description":"0–5, 0 clears"},
    "query":  {"type":"string","description":"song to rate; omit for current track"} },
  "required":["rating"] }
// output: "Rated Miles Davis — So What 5★."
```

### 3.4 Gap-filler tools (shipped)

These round out the surface so an agent can do everything the UI can. All shipped in
0.1.0:

| Tool | What it does | Backed by |
|---|---|---|
| `music_seek` | Seek to an absolute position (seconds), clamped to length | `seek(to:)` |
| `music_set_repeat` | Set repeat `off` / `all` / `one` | `cycleRepeat` (cycled to the target) |
| `music_set_shuffle` | Turn shuffle on/off | `toggleShuffle` |
| `music_get_queue` (read-only) | Full queue with per-track index + source | `queue`, `queueSource` |
| `music_reorder_queue` | Move a track `from`→`to` index | `moveQueueItem` |
| `music_remove_from_queue` | Remove a track by index | `removeFromQueue` |
| `music_play_next` | Insert matches right after the current track | `playNext` |
| `music_start_radio` | Endless "more like this" from a seed / current track | `relatedProvider` / `getSimilarSongs` |
| `music_sleep_timer` | Arm/cancel a pause-after-N-minutes timer | `setSleepTimer` |
| `music_set_eq` | Enable/disable the EQ and apply a named preset | `MusicEqualizer.apply(preset:)` |

`music_set_eq` returns the list of valid preset names when handed an unknown preset.
`music_start_radio` prefers the wired radio-ban-filtered `relatedProvider` and falls
back to a direct `getSimilarSongs` call.

### 3.5 Agent-native mix builder (shipped)

#### `music_build_mix`
The differentiator: an agent describes an intent and Baton assembles a track set of a
target length from the library, then queues it or saves it as a playlist. The
selection math lives in a pure, unit-tested `MixBuilder`
(`BatonMCPMixTools` + `MixBuilder`).
```jsonc
// input
{ "properties": {
    "prompt":         {"type":"string","description":"'upbeat focus mix', 'mellow evening jazz'"},
    "target_minutes": {"type":"integer","description":"desired length (default 45)"},
    "seed_artist":    {"type":"string"},
    "seed_genre":     {"type":"string"},
    "limit":          {"type":"integer","description":"candidates to gather (default 200, max 500)"},
    "action":         {"type":"string","description":"'queue' (default) or 'playlist'"},
    "name":           {"type":"string","description":"playlist name when action='playlist'"} },
  "required":["prompt"] }
```
A target length and genre/mood hint are also parsed out of `prompt`, so
`{prompt:"40 minute mellow jazz"}` works with no other args.

---

## 4. Audio focus — the integration primitive

The single most important cross-app contract. It generalizes Tonebox's in-process
`suspendForCapture()` / `resumeAfterCapture()` into a **cross-process, owner-token**
protocol. Shipped as the `audio_suspend` / `audio_resume` tools, backed by
`BatonAudioFocusRegistry` over the player's `AudioFocusToken`.

### 4.1 Why a plain pause isn't enough

A naive `pause`/`resume` pair loses two guards:

1. **Suspend only pauses if currently playing** — a no-op if already paused, so it
   never "resumes" music the user had stopped.
2. **Resume only fires if *this* owner suspended it AND the user hasn't intervened**
   — if the user hit play/stop/next during the capture, the auto-resume is skipped.

Across processes, "this owner" and "did the user change state in between" must be made
explicit. Hence an **owner** on suspend and a **handle** on resume, plus a **state
generation counter** (in the controller) to detect intervening user actions.

### 4.2 Contract

```
audio_suspend(owner: string, mode?: "pause"|"duck", duckToPercent?: int)
  -> { handle, owner, generation, suspended, mode, previousState }

audio_resume(handle: string)          // or (owner + generation)
  -> { resumed: bool, reason?: "user-changed-state"|"nothing-to-resume"|"already-resumed" }
```

Semantics (as shipped in `BatonAudioFocusRegistry`):

- **`audio_suspend`**
  - Acquires focus for `owner`, capturing `previousState` and the current generation.
  - `mode:"pause"` (default) pauses; `mode:"duck"` lowers Baton's *player* volume to
    `duckToPercent` (default 20) and restores it on resume — better for "assistant is
    talking" than a hard pause. Both modes go through the controller
    (`acquireAudioFocusSuspend` / `acquireAudioFocusDuck`).
  - Returns an opaque `handle` bound to the controller token, plus `owner`,
    `generation`, `suspended` (`token.didSuspend`), `mode`, and `previousState`. The
    handle is always returned so `audio_resume` is safe to call even when nothing was
    actually suspended.
- **`audio_resume`**
  - Redeems the handle through `releaseAudioFocus`, which resumes **only if** the
    recorded owner still holds focus, it actually suspended, and the generation is
    unchanged. Any intervening user action bumps the generation, yielding
    `{resumed:false, reason:"user-changed-state"}`.
  - Idempotent: a second resume returns `{resumed:false, reason:"already-resumed"}`.
  - Also accepts `owner` + `generation` instead of a handle (the fast-path variant).

### 4.3 Race-safety, expiry & crash recovery (shipped)

- **Last-writer-wins focus.** The controller is last-writer-wins on `currentFocus`,
  which gives the "stacking" behaviour for free: a second `audio_suspend` takes focus,
  and releasing an older (superseded) handle is a clean no-op.
- **Generation counter is the source of truth.** Every state-mutating action bumps it;
  `releaseAudioFocus` compares against the captured generation — the cross-process
  analog of the in-process `state == .paused && suspendedForCapture` check.
- **Handles are session-scoped and time-bounded.** Each handle remembers the
  connection/session that created it and when it was placed. When that SSE stream (or
  fast-path socket) closes, the server calls `expireHandles(forConnection:)` and
  auto-resumes/restores — subject to the generation guard, so it never fights a user
  who took over. A crashed dictation client therefore can't leave Baton paused/ducked
  forever.
- **Time-bound sweep.** A 0.5 s poll also calls `expireStaleHandles`; any handle older
  than `handleMaxAge` (10 min) is released. Belt-and-braces for a client that vanished
  without a clean stream-close.

### 4.4 Message schemas

```jsonc
// audio_suspend input
{ "type":"object",
  "properties": {
    "owner": {"type":"string","description":"stable id, e.g. 'tonebox.dictation'"},
    "mode":  {"type":"string","description":"'pause' (default) or 'duck'"},
    "duckToPercent": {"type":"integer","description":"target volume for mode='duck' (default 20)"}
  },
  "required":["owner"] }
// audio_suspend output
{ "handle":"af_9f2c...", "owner":"tonebox.dictation", "generation":7,
  "suspended":true, "mode":"duck", "previousState":"playing" }

// audio_resume input  (handle, or owner+generation)
{ "type":"object",
  "properties": {
    "handle":     {"type":"string"},
    "owner":      {"type":"string"},
    "generation": {"type":"integer"} },
  "required":[] }
// audio_resume output
{ "resumed":true }
// or: { "resumed":false, "reason":"user-changed-state" }
```

Both tools are annotated as coordination primitives — a client should **not** surface
them as user-facing actions.

---

## 5. MCP resources & notifications (shipped)

### 5.1 Resources

**5 resources** ship (`BatonMCPResources.list()` / `.read(uri:music:)`):

| URI | Content | Backed by |
|---|---|---|
| `baton://now-playing` | Current track + state + position + duration | `music.nowPlaying`, `state`, `currentTime`, `duration` |
| `baton://queue` | Ordered queue with `current_index` + `queue_source` | `music.queue`, `queueSource` |
| `baton://library/playlists` | Playlist list (id/name/song_count) | `MusicLibraryStore.playlists` |
| `baton://library/liked` | Starred songs/albums/artists | `MusicLibraryStore.starred` |
| `baton://history/recent` | Recently played + top tracks + top artists | `MusicPlayHistory` |

`resources/read` returns `{contents:[{uri, mimeType:"application/json", text}]}`. The
library/history snapshots are capped at 50 entries each so a large library can't blow
up a single read; those two are populated from already-loaded state (no network on
read), so they're empty until the library has loaded.

### 5.2 Notifications

Over the SSE stream, Baton emits `notifications/resources/updated`:

- `{uri:"baton://now-playing"}` on **track change, play/pause/stop, and seek**.
- `{uri:"baton://queue"}` on enqueue / reorder / remove / clear.

Implementation: a lightweight 0.5 s poll compares a signature of now-playing / queue
and broadcasts on change (`emitStateChangeIfNeeded`); `tools/call` also triggers a
check immediately after any mutating tool. When no client stream is open the poll
keeps the signatures current so a newly-connected client doesn't get a spurious
"changed" on its first read. On connect, each stream is primed with a now-playing
notification so the client can read the current state without waiting for a change.

The `initialize` capabilities advertise `resources` with `subscribe:false,
listChanged:false` — clients receive the `resources/updated` broadcasts on the stream
rather than subscribing per-URI.

---

## 6. Tonebox as a client (shipped, one open item)

Tonebox ships a full `BatonClient` (music control) and `BatonControl` (the dictation
duck bridge), and **hybrid delegation** is wired: when Baton is running, Tonebox's
command/voice/agent music actions delegate to Baton over MCP; otherwise they run
in-process exactly as before.

**Delegation seam** (`AppModel+Music.swift`): `execute(_ intent:)` first tries
`delegateToBatonIfRunning`, which delegates **iff** the user prefers Baton *and* it's
running, otherwise returns `nil` and falls through to `executeInProcess`. It is a pure
no-op when Baton is absent (no `mcp.json` / connection refused ⇒ `isRunning()` false).

- **Preference:** `tonebox.music.preferBaton`, **default on** (`preferBaton ?? true`).
  Opt out to force the in-process player.
- **Only the command/voice/agent surface delegates.** Tonebox's own in-app Music UI is
  unaffected either way.

| Tonebox event | Baton call | Notes |
|---|---|---|
| Voice/command "play some jazz" | `music_play` (via `BatonClient`) | `MusicCommandInterpreter` intent maps 1:1 |
| Command palette / voice pause/next/volume/now-playing | `music_pause` / `music_next` / … | Delegated when Baton is running |
| Dictation **start** | `audio_suspend(owner:"tonebox-dictation")` → store handle | Via `BatonControl.suspendForCapture()` |
| Dictation **terminal** (idle/complete/error) | `audio_resume(handle)` | Via `BatonControl.resumeAfterCapture()`; replays the exact handle; no-op if the user changed state |

`BatonControl` is a best-effort actor with a short timeout (~1.5 s) that silently
no-ops when Baton isn't installed/running — it must never affect Tonebox behavior, it
only asks Baton to duck/resume so dictation capture isn't polluted by Baton's audio.

**Client bootstrap:** both clients read `~/Library/Application Support/Baton/mcp.json`
for `url` + `token` (`BatonClient.parseDiscovery`); there is a single source of truth
for the discovery location + shape.

> **Open item (roadmap, not done):** Tonebox still contains its in-process music
> player as the fallback. Physically removing it — so Tonebox is *only* a Baton client
> — is a deliberate open product decision, not yet taken. Until then both code paths
> coexist and the preference/`isRunning()` check picks between them.

---

## 7. Native fast-path

For latency-critical, single-consumer audio focus (chiefly ducking at dictation
start), Baton ships a **Unix-domain-socket fast-path** alongside the MCP server, so a
duck doesn't pay HTTP/SSE setup cost.

- **Socket:** `~/Library/Application Support/Baton/control.sock`, perms `0600` (same
  trust model as the token). Advertised in the discovery file's `fastPath.unixSocket`.
- **Protocol** (`BatonControlSocket`), one request per line:
  ```
  SUSPEND <owner> [mode] [duckPct]   →  HANDLE <handle>
  RESUME  <handle>                   →  OK  |  SKIP <reason>
  ```
  `<mode>` is `pause` or `duck`; `<duckPct>` defaults to 20.
- **Shared registry.** The socket shares the **same** `BatonAudioFocusRegistry` as the
  MCP path, so a socket `SUSPEND` and an MCP `audio_resume` interoperate — the
  handle/owner/generation live in Baton regardless of transport. Each socket connection
  is a session: when it drops, its handles are expired (crash safety), exactly like an
  SSE stream close.
- **Why a raw POSIX socket:** `NWListener` doesn't bind `AF_UNIX`, and the round-trip
  must be well under a frame. A tiny blocking accept loop runs on a background thread
  and hops to the main actor only for the (trivial) registry call.
- **Measured round-trip: ~0.08 ms** — three-plus orders of magnitude under an
  HTTP+SSE round-trip.

**Trade-off:** the fast-path is single-consumer and unobserved by other agents — it's
for audio focus only; everything else (and anything an agent should *see*) goes through
MCP.

---

## 8. Example agent interactions

### 8.1 "Play something for focus, and duck it when I talk"
```
User → Claude: put on a 40-minute instrumental focus set
Claude → music_build_mix {prompt:"instrumental focus", target_minutes:40, action:"queue"}
Claude ← {queued: 12, total_minutes: 41, now_playing:{...}}
Claude → "Playing an instrumental focus set (~41 min)."

[later, dictation starts in Tonebox — via the fast-path socket]
Tonebox → SUSPEND tonebox.dictation duck 15
Tonebox ← HANDLE af_...
[dictation ends]
Tonebox → RESUME af_...
Tonebox ← OK
```

### 8.2 "What's playing, and like it"
```
Claude → music_now_playing {}
Claude ← {state:"playing", now_playing:{title:"So What", artist:"Miles Davis"}}
Claude → music_like {}          // no query → current track
Claude ← "Liked Miles Davis — So What."
```

### 8.3 Agent-built playlist from the month's likes
```
Claude → resources/read {uri:"baton://library/liked"}
Claude (filters to this month) → music_create_playlist {name:"July Likes"}
Claude → music_add_to_playlist {name:"July Likes", query:"..."}  // per batch
```

### 8.4 Reacting to track changes (subscription)
```
Client opens GET /mcp (SSE)
Baton → notifications/resources/updated {uri:"baton://now-playing"}   // primed on connect
Client → resources/read {uri:"baton://now-playing"}   // fetch the new track
Client (e.g.) → scrobbles to a third service / updates a status page
```

---

## 9. Registering Baton with a client

### Claude Desktop
`~/Library/Application Support/Claude/claude_desktop_config.json`:
```jsonc
{
  "mcpServers": {
    "baton": {
      "transport": "streamable-http",
      "url": "http://127.0.0.1:8787/mcp",
      "headers": { "Authorization": "Bearer <token from mcp.json>" }
    }
  }
}
```

### Claude Code
```bash
claude mcp add --transport http baton http://127.0.0.1:8787/mcp \
  --header "Authorization: Bearer <token>"
```
Or point a helper at `~/Library/Application Support/Baton/mcp.json` to read `url` +
`token` automatically — the whole reason the discovery file exists.

### Auth quick reference
Every request carries `Authorization: Bearer <token>` (or `?token=` for a
discovery-style GET); a bad/missing token → `401`. The token is in the discovery file
(`0600`) and Baton's Settings. The default port is `8787`, but always read the actual
port from `mcp.json` — the server walks upward if `8787` is taken.

---

## 10. Summary — the interface contract

- **One universal surface:** MCP over Streamable HTTP, `127.0.0.1`, bearer token,
  discoverable via `mcp.json`, multi-client, with SSE notifications.
- **Complete tool catalog:** 30 tools — 17 `music_*` + `music_build_mix` + 10
  gap-fillers + `audio_suspend` / `audio_resume`.
- **Live state:** 5 resources (`baton://now-playing`, `baton://queue`,
  `baton://library/playlists`, `baton://library/liked`, `baton://history/recent`) with
  `resources/updated` notifications.
- **Audio focus:** owner-token suspend/resume with a generation counter, duck mode,
  handle expiry, and crash recovery — the cross-process replacement for
  `suspendForCapture` / `resumeAfterCapture`.
- **Fast-path:** a Unix-socket mirror of audio focus (~0.08 ms) for instant dictation
  ducking; everything agent-visible stays on MCP.
- **Tonebox is a client:** hybrid delegation over MCP (pref `tonebox.music.preferBaton`,
  default on) with the in-process player still present as a fallback (removing it is the
  one open item).
