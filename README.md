# Baton

**Conduct your music.**

Baton is a free macOS music player for the library you already own: your self-hosted
[Navidrome](https://www.navidrome.org/) or any Subsonic-compatible server. It plays your
music with real depth (true gapless, crossfade, ReplayGain loudness, a 10-band parametric
EQ), and it hosts an [MCP](https://modelcontextprotocol.io/) control server so an AI agent,
like Claude or [Tonebox](https://tonebox.io), can pick up the baton and search, queue, build
a mix, or duck the music for a call.

Made by [Tonebox](https://tonebox.io), and given away for free.

![Baton's full-screen player: album artwork, an artwork-matched accent colour running through
the scrubber and rating, and the Up Next queue](docs/screenshots/baton-now-playing.png)

<sub>Shown with the public Navidrome demo library (Creative Commons music from
[blocsonic](https://blocsonic.com/)).</sub>

## What it is

- **A player for *your* library.** It streams from a Navidrome or Subsonic server you run.
  Not a streaming catalog; you bring the music, Baton plays it well.
- **Deep playback.** True gapless, crossfade, ReplayGain and R128 loudness normalization, a
  10-band parametric EQ, a floating mini-player, media-key and AirPlay support, and dual
  scrobbling (ListenBrainz and Last.fm).
- **Agent-controllable.** An embedded MCP server (loopback, token-secured) exposes the same
  music operations the UI uses, so any MCP client can drive playback. This is the reason
  Baton exists: the control surface *is* the product.
- **Private and self-hosted.** Server credentials live in the macOS Keychain, and Baton only
  talks to the server you point it at.

## Install

Baton is a signed, notarized macOS app with Sparkle auto-update. **Download the latest release
from [baton.tonebox.io](https://baton.tonebox.io)** (free, signed, notarized, and self-updating
via a **Check for Updates** menu item), or build from source.

### Build from source

Requires Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`):

```sh
cd app
xcodegen generate
xcodebuild build -scheme Baton -configuration Release -destination 'platform=macOS'
```

## Connect

On first launch, enter your server URL and either a **username and password** or an **API
key**. Baton verifies the connection before saving it, then loads your library. See
[HELP.md](HELP.md#getting-connected).

Don't have a server yet? Both the first-run screen and **Settings → Servers → Add Server**
offer **Try the demo server**, which fills in the public Navidrome demo so you can look
around before setting anything up.

![Baton's Albums grid: artwork tiles with track counts and durations, section counts in the
sidebar, and the now-playing bar below](docs/screenshots/baton-albums.png)

## Agent / MCP control

Baton hosts a small MCP control server on `127.0.0.1`, secured with a bearer token, so an
agent (Claude Desktop, Claude Code, other MCP clients, or Tonebox) can search your library,
queue and control playback, like and rate tracks, and manage playlists, as well as
coordinate **audio focus** (duck the music while you dictate, then bring it back). The full
design, tool catalog, and security model are in
[`docs/04-integration-and-mcp.md`](docs/04-integration-and-mcp.md).

> **Status:** the control server is live while Baton is running. It exposes 28 `music_*`
> operations (including `music_build_mix`), the `audio_suspend` / `audio_resume` focus
> hand-off, and a `speak_summary` tool; it publishes now-playing, queue, playlists, liked,
> and recent history as live resources; and it writes a discovery file (endpoint URL and
> token) to `~/Library/Application Support/Baton/mcp.json`. A menu-bar controller ships too.

## Docs

- **[HELP.md](HELP.md)** is the full user guide.
- **[FAQ.md](FAQ.md)** has quick answers.
- **[docs/](docs/)** holds the vision, feature inventory, architecture, the integration and
  MCP design, and the roadmap.
- Website: `website/`. Icon and design: `design/`. App: `app/`. Site deploy: `deploy/`.

## License

[MIT](LICENSE), free to use, modify, and distribute. Made by
[Tonebox](https://tonebox.io), given away for free.
