# Baton — FAQ

Quick answers. For walkthroughs, see [HELP.md](HELP.md).

## About Baton

**What is Baton?**
A free macOS music player for your own self-hosted music library. It plays from any
[Navidrome](https://www.navidrome.org/) or Subsonic-compatible server, with real playback
depth (true gapless, crossfade, ReplayGain, a 10-band EQ) — and it hosts a small control
server so an AI agent can search, queue, and steer your music for you. The tagline is
*"Conduct your music."*

**Is Baton free?**
Yes. Baton is free — a give-away from [Tonebox](https://tonebox.io). There's no
subscription and no catalog rent; you're playing music you already own on a server you
already run.

**How is Baton different from Tonebox?**
They're two different products from the same maker:
- **Tonebox** is a paid, local-first notes app — it records meetings and voice notes,
  transcribes them on your Mac, and turns them into searchable, AI-assisted notes (tasks,
  decisions, summaries, Q&A). Music was a side feature inside it.
- **Baton** is the music player, pulled out into its own free app. It focuses on playing
  your library well and being controllable by agents.

They work together: Tonebox can control Baton (for example, ducking the music while you
dictate), but you don't need Tonebox to use Baton.

## Servers & your library

**What servers work with Baton?**
[Navidrome](https://www.navidrome.org/) and any **Subsonic-compatible** server. Baton
speaks the Subsonic API, so most self-hosted music servers in that family work.

**Does Baton have its own music catalog?**
No. Baton plays *your* library from *your* server. It is deliberately not a streaming
catalog like Spotify or Tidal — there's nothing to browse until you connect a server.

**Can I connect more than one server?**
Yes. Open **Settings ▸ Servers** (⌘,) to add servers and switch the active one; each
server's credentials are kept separately in the Keychain. Your first single connection is
migrated into the list automatically.

**Does Baton do podcasts and internet radio?**
Yes, when your server exposes them — there are **Podcasts** and **Radio** tabs in the left
rail. Radio stations can be added/edited by name + stream URL.

**How do I connect?**
On first launch, enter your server URL and either a username & password or an API key.
Baton verifies the connection before saving it. See [HELP.md](HELP.md#getting-connected).

## Privacy & security

**Is my password safe?**
Yes. Your server credentials are stored in the **macOS Keychain** — never in a plaintext
file. With username & password sign-in, Baton uses the salted-token scheme Subsonic
expects, so your password isn't sent in the clear on each request.

**Does Baton phone home?**
No. Baton talks only to the music server you point it at (and, if you turn them on, the
scrobbling services ListenBrainz / Last.fm, plus its own update feed for checking for new
versions). It has no catalog server of its own to call.

**Is the control server a security risk?**
No, by design. Baton's MCP control server listens **only on your own Mac** (loopback), so
it isn't reachable from your network, and every request must carry a **secret token**
Baton generates. Both are required — an app on another machine can't reach it, and a
program on your Mac can't drive it without the token.

## Agent control (MCP)

**What is the MCP control server?**
[MCP](https://modelcontextprotocol.io/) is the Model Context Protocol — the standard way
AI agents talk to tools. Baton hosts a small MCP server locally, exposing music operations
(search, play, queue, pause/skip, like/rate, create playlists, report what's playing).
That lets an agent like Claude — or Tonebox — control your music through natural
requests.

**How do agents control my music?**
You point an MCP client (e.g. Claude Desktop or Claude Code) at Baton's local address with
Baton's token, and then ask the agent for what you want — *"play a focus mix,"* *"what's
this song and like it,"* *"make a playlist of this month's likes."* The agent calls
Baton's tools to do it. Because the tools mirror Baton's own UI actions, the agent can
only do things you could do yourself.

**Do I need an agent to use Baton?**
No. Baton is a complete, click-to-play music player on its own. The agent control is an
extra surface, not a requirement.

**Is agent control available today?**
Yes. The control server runs on launch (loopback, token-authed), exposes 20 operations
including a `music_build_mix` tool that assembles a mix to a requested length, and writes a
discovery file at `~/Library/Application Support/Baton/mcp.json` (endpoint URL + token) so a
client can find it. A menu-bar controller ships too. See
[`docs/04-integration-and-mcp.md`](docs/04-integration-and-mcp.md) for the full design.

## Playback

**Does Baton do gapless?**
Yes — true gapless playback, by pre-loading the next track (and prefetching network
streams to disk) so there's no silence between tracks. There's also optional crossfade,
ReplayGain loudness normalization, and a **parametric equalizer** (Audio ▸ Equalizer, ⌥⌘E)
with adjustable per-band frequency/Q/gain. See
[HELP.md](HELP.md#gapless-crossfade--sound-quality).

**Can I scrobble?**
Yes — to your Navidrome/Subsonic server, and to **ListenBrainz** and/or **Last.fm** if you
add your tokens.

**Does Baton work offline?**
Yes, for downloaded music. You can **download** tracks, albums, mixes, and playlists to your
Mac and play them from disk without re-streaming, and the **Downloads** tab manages them
(size on disk, delete, and a global **Offline mode** that forces local playback). Browsing
new content and streaming still need your server to be reachable.

**Can I cast to speakers?**
AirPlay works today, from the AirPlay picker in the Now-Playing bar. Chromecast, Sonos,
and UPnP/DLNA casting are planned.

## Updates & platform

**How do updates work?**
Baton updates itself with Sparkle (the standard macOS updater), pulling signed, notarized
builds from Baton's own update feed. You don't need to reinstall by hand.

**What platforms does Baton run on?**
macOS. An iOS / iPadOS companion is on the roadmap; Windows and Linux clients are not
planned.

**Where can I read more?**
[HELP.md](HELP.md) for how to use Baton, and the docs in [`docs/`](docs/) for the vision,
architecture, and integration/MCP details.
