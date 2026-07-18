# Baton — Help

**Conduct your music.** Baton is a free macOS music player for the library you already
own — your self-hosted [Navidrome](https://www.navidrome.org/) or any
Subsonic-compatible server. It plays your music with real depth (true gapless,
crossfade, ReplayGain loudness, a 10-band EQ), and it hosts a small control server so an
AI agent — Claude, or Tonebox — can search, queue, and steer playback for you.

Baton is made by [Tonebox](https://tonebox.io) and given away for free.

---

## What Baton is (and isn't)

- **A player for *your* library.** Baton streams from a server you run — it is not a
  streaming catalog like Spotify or Tidal. You bring the music; Baton plays it well.
- **Self-hosted, private, no subscription.** Your server credentials live in the macOS
  Keychain, and Baton only talks to the server you point it at.
- **Agent-controllable.** Baton's distinguishing feature is that software can drive it —
  an AI agent can pick up the baton and search, queue, build a mix, or duck the music
  for a call, all through a local control interface (see [Let an agent control your
  music](#let-an-agent-control-your-music)).

---

## Getting connected

When you first open Baton, it asks you to connect to your music server.

1. **Sign-in method** — choose one:
   - **Username & password** — the classic Subsonic sign-in. Baton never sends your
     password in the clear; it uses the salted-token scheme Subsonic servers expect.
   - **API key** — if your server (e.g. a recent Navidrome) supports API keys, paste one
     instead of a username and password.
2. **Server URL** — the full address of your server, e.g. `https://music.example.com`.
3. **Username** (username & password mode only) and your **password** or **API key**.
4. Click **Connect**. Baton verifies the connection *before* saving anything. If it
   works, your library loads and the player unlocks in place. If it doesn't, you'll see
   the reason, so you can fix the URL or credentials and try again.

Your credentials are stored in the **macOS Keychain** — never in a plaintext file. See
the [FAQ](FAQ.md) for more on password safety.

**Multiple servers.** Open **Settings ▸ Servers** (⌘,) to add more than one server and
switch the active one — Baton keeps each server's credentials separately in the Keychain
and reloads the library when you switch. Your existing single connection is carried over
automatically the first time you open the manager.

---

## Browsing your library

Baton's left rail gives you the ways into your library:

- **Home ("For You")** — a time-of-day greeting and tap-to-play shelves: **Recently
  Played**, **"Because You Liked…"** radio, **Recently Added**, **Rediscover** (a random
  dip into your library), and **Your Mixes**.
- **Search** — search across songs, albums, and artists at once.
- **Mixes** — auto-built mixes: **Most Played**, **Fresh Additions**, **Top Rated**,
  **On Repeat**, **Forgotten Favorites** (things you liked but haven't played in a
  while), and **Discover**, plus per-genre **Daily Mix** cards. Each mix has its own page
  where you can Play, Shuffle, Queue, or download the whole thing.
- **Albums** — browse your albums, sortable by newest, recently added, most played,
  name, artist, track count, duration, rating, or at random; grid or list view.
- **Artists** — browse artists, with bios and artist pages.
- **Playlists** — your server-side playlists. You can create, rename, reorder, and delete
  them, and add or remove tracks (reordering is saved back to the server).
- **Liked** — everything you've hearted, split into Songs / Albums / Artists, with the
  same sort and filter controls.
- **History** — your local play log: **Recent**, **Top Tracks**, and **Top Artists**,
  over This Week / This Month / All Time.
- **Podcasts** — browse the podcast channels your server hosts and play episodes through
  the normal player (episodes stream and queue just like tracks).
- **Radio** — your server's internet-radio stations. Add, edit, or remove a station
  (name + stream URL) and play it.
- **Downloads** — everything you've saved for offline play, with total size on disk, a
  per-item delete, and an **Offline mode** toggle.

**Rating and liking.** Tap the heart to like a song, or use the 5-star rating. Ratings
are stored per-user on your server, so they follow you to any Subsonic client.

**Multi-select.** In list views you can shift-click a range, ⌘A to select all, and apply
batch actions (like/unlike, queue, download) to the selection.

---

## Playing music

### The Now-Playing bar

A persistent bar sits at the bottom of the window. Expanded, it gives you the scrubber,
transport controls (previous / play-pause / next), volume, the queue, a sleep timer, and
the AirPlay picker. You can **collapse it to a slim strip** to reclaim space (⌘⌃J), and
expand it again the same way.

### Full-screen Now Playing

Open the full-screen player for big artwork, an adaptive backdrop tinted from the album
art, a waveform scrubber (for downloaded tracks), and side panels for **Queue**,
**Lyrics** (synced karaoke-style when your server has them, otherwise plain), and
**Related** tracks. Press **Space** to play/pause and **Esc** to leave full-screen.

### The floating mini-player

Baton has a borderless, always-on-top **mini-player** window (⌘⌥M) — a compact card you
can keep in a corner while you work in other apps. It shows the current track, artwork,
scrubber, rating, and Up Next, and it expands for a little more. On macOS 26+ it uses
Liquid Glass.

### The queue

Drag to reorder the queue, remove tracks, or clear it. Baton remembers your queue
(tracks, position, and where it came from) between launches and restores it paused on
next open.

### Modes

- **Shuffle** — shuffles the queue while keeping the current track playing; toggling it
  off restores the original order.
- **Repeat** — Off / All / One track.
- **Continuous radio (autoplay)** — when you near the end of the queue, Baton tops it up
  with similar tracks so the music keeps going.

### Sleep timer

Set a timer from the Playback menu, or choose **End of Track**. Baton fades out gently
(about 5 seconds) rather than cutting off abruptly.

---

## Gapless, crossfade & sound quality

Baton keeps the playback depth that most desktop players skip:

- **True gapless playback.** Live albums and continuous mixes play with no silence
  between tracks. Baton pre-loads the next track (even prefetching network streams to
  disk) so the hand-off is seamless. It can be set to prefetch on Wi-Fi only, to avoid
  eating a metered connection.
- **Crossfade.** Optionally overlap the end of one track into the start of the next.
  (Crossfade and true-gapless are mutually exclusive — crossfade means the tracks
  overlap, gapless means they abut perfectly.)
- **Loudness normalization (ReplayGain / R128).** Even out volume across tracks or across
  albums, using the ReplayGain data your server provides, with an adjustable preamp.
- **Parametric equalizer.** Open **Audio ▸ Equalizer** (⌥⌘E) for a multi-band EQ where each
  band's **frequency, Q, and gain** are adjustable, with a live response curve and presets
  (Flat, Bass Boost, Treble Boost, Vocal Boost, Bass Reduce, and more). Off by default, and
  bit-exact pass-through when off.

---

## Downloads

Baton can download tracks, albums, mixes, or playlists to a folder on your Mac and play
them from disk — useful for gapless quality without re-streaming, and for keeping
favorites local. Downloaded tracks are preferred over streaming automatically.

The **Downloads** tab in the left rail manages everything you've saved: it shows total
size on disk, lets you play or delete any download, and has a global **Offline mode**
toggle that keeps playback on local files.

---

## Scrobbling

Baton can report your listens to:

- **Your Navidrome/Subsonic server** (updates its own play counts), and
- **ListenBrainz** and/or **Last.fm**, if you add your account tokens.

A track scrobbles once you've played about half of it (capped at a few minutes for long
tracks), matching the usual scrobbling convention.

---

## Media keys & AirPlay

- **Media keys and Bluetooth remotes** — the F7/F8/F9 keys and Bluetooth remote
  play/pause/next/previous/seek all control Baton, and the current track (title, artist,
  album, artwork, elapsed time) shows up in the macOS Now Playing widget.
- **AirPlay** — use the AirPlay picker in the Now-Playing bar to send audio to an AirPlay
  device. (Chromecast / Sonos / UPnP casting is planned — see below.)

---

## Keyboard shortcuts

From the **Playback** menu (available anywhere in the app):

| Action | Shortcut |
|---|---|
| Play / Pause | ⌘⌃P |
| Next track | ⌘⌃→ |
| Previous track | ⌘⌃← |
| Volume up | ⌘⌃↑ |
| Volume down | ⌘⌃↓ |
| Mute / Unmute | ⌘⌃M |
| Minimize / expand player bar | ⌘⌃J |
| Open mini-player | ⌘⌥M |

The Playback menu also holds **Shuffle**, **Repeat**, and the **Sleep Timer**. In the
full-screen player, **Space** toggles play/pause and **Esc** exits. In browse lists, **⌘A**
selects all.

---

## Let an agent control your music

This is what makes Baton different from every other Subsonic player: it can be driven by
software, not just by you clicking buttons.

Baton hosts a small **control server** on your Mac that speaks
[MCP](https://modelcontextprotocol.io/) (the Model Context Protocol) — the same protocol
Claude and other AI agents use to talk to tools. That means you can say things to an agent
like:

- *"Put on a 40-minute instrumental focus set."*
- *"What's playing? Like it."*
- *"Make a playlist of everything I liked this month."*
- *"Turn it down"* / *"skip this"* / *"play some jazz."*

…and the agent carries them out in Baton — searching your library, building a queue,
starting playback, rating tracks, and creating playlists. The control surface exposes the
same set of music operations Baton's own UI uses, so anything the agent does is something
you could have done by hand.

**How it's secured:**

- The control server listens **only on your own machine** (loopback) — it is not
  reachable from the network.
- Every request must present a **secret token** that Baton generates. No token, no
  access.

**How Tonebox uses it.** Baton is built to be [Tonebox](https://tonebox.io)'s music
player: when you start dictating or recording in Tonebox, it can ask Baton to **duck the
music** and then bring it back afterward — but only if you didn't change the playback
yourself in the meantime. This "audio-focus" hand-off is a first-class part of Baton's
control interface, so it works cleanly across two separate apps.

One agent-native operation worth calling out: **`music_build_mix`** — an agent can hand
Baton a free-text request ("upbeat 40-minute focus mix") and Baton assembles a set from
your library that lands close to the requested length, then either queues it or saves it as
a playlist.

> **Status.** The control server is **live**: it speaks MCP Streamable-HTTP on loopback,
> exposes 20 music operations (including `music_build_mix` and the `audio_suspend` /
> `audio_resume` focus hand-off), publishes now-playing/queue as live resources, and writes
> a discovery file at `~/Library/Application Support/Baton/mcp.json` with the endpoint URL +
> token. A menu-bar mini-controller ships too. See the technical write-up in
> [`docs/04-integration-and-mcp.md`](docs/04-integration-and-mcp.md).

---

## Updates

Baton updates itself using Sparkle (the standard macOS updater), the same mechanism
Tonebox uses. It checks for updates against Baton's own update feed and installs signed,
notarized builds — you don't need to reinstall by hand.

---

## Planned features

**Now in Baton** (recently landed): **Podcasts** and **Internet radio** tabs, a **Downloads /
offline manager**, a **parametric Equalizer** (Audio ▸ Equalizer, ⌥⌘E), **multiple servers /
account switching** (Settings ▸ Servers, ⌘,), and the agent-native **`music_build_mix`**.

Still on the roadmap, not in Baton today (called out so the docs stay honest):

- **iOS / iPadOS companion** — listen away from the desk.
- **Casting beyond AirPlay** — Chromecast, Sonos, and UPnP/DLNA. (AirPlay works today; wider
  casting needs protocol support Baton doesn't bundle yet.)
- **Sonic-analysis mixes** — mixes built from the *sound* of your music (tempo/energy/key),
  not just play history.
- **Crossfeed / additional DSP** and **lyrics fallback** (e.g. LRCLIB when your server has
  none).

For the full roadmap see [`docs/05-roadmap-new-features.md`](docs/05-roadmap-new-features.md).

---

## Questions?

See the [FAQ](FAQ.md) for quick answers, or the docs in [`docs/`](docs/) for the deeper
architecture and integration details.
