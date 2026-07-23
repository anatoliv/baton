# Baton

*Conduct your music.*

Baton plays the music you already own. Point it at your own
[Navidrome](https://www.navidrome.org/) server (or anything that speaks the Subsonic API),
and it streams your library with the kind of care most players skip: true gapless, crossfade,
ReplayGain loudness matching, and a proper 10-band parametric EQ.

The part that makes Baton unusual is that it can be handed off. It runs a small
[MCP](https://modelcontextprotocol.io/) control server, so an AI agent (Claude, or
[Tonebox](https://tonebox.io)) can pick up the baton and search, queue, build a mix, or duck
the music when you take a call. The control surface is really the whole point; the player is
just the thing it conducts.

It's free, and it always will be. Made under [Tonebox](https://tonebox.io).

![Baton's full-screen player: album artwork, an artwork-matched accent colour running through
the scrubber and rating, and the Up Next queue](screenshots/baton-now-playing.png)

<sub>Shown with the public Navidrome demo library (Creative Commons music from
[blocsonic](https://blocsonic.com/)).</sub>

## What it is

Baton is a player for *your* library, not a catalog you rent. You bring the music on a
Navidrome or Subsonic server you run; Baton's job is to play it well and stay out of the way.

Playing it well means sweating the details. Gapless and crossfade so albums breathe the way
they were sequenced. ReplayGain and R128 loudness so nothing jumps out at you between tracks.
A 10-band parametric EQ for when you want to shape the sound, a floating mini-player, media
keys, AirPlay, and scrobbling to both ListenBrainz and Last.fm.

And because everything the interface can do is also exposed over a token-secured MCP server on
loopback, any agent you trust can drive playback exactly the way you do. Your server
credentials live in the macOS Keychain, and Baton only ever talks to the one server you point
it at. Nothing else leaves your machine.

## Install

Baton is a signed, notarized macOS app with Sparkle auto-update. Download the latest release
from [baton.tonebox.io](https://baton.tonebox.io). It's free, signed, notarized, and updates
itself from the **Check for Updates** menu item. Or build it from source.

### Build from source

You'll need Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`):

```sh
cd app
xcodegen generate
xcodebuild build -scheme Baton -configuration Release -destination 'platform=macOS'
```

## Connect

On first launch, enter your server URL and either a username and password or an API key. Baton
checks the connection before it saves anything, then loads your library. There's more in
[HELP.md](HELP.md#getting-connected).

No server yet? Both the first-run screen and **Settings → Servers → Add Server** offer **Try
the demo server**, which fills in the public Navidrome demo so you can look around before
setting anything up.

![Baton's Albums grid: artwork tiles with track counts and durations, section counts in the
sidebar, and the now-playing bar below](screenshots/baton-albums.png)

## Agent / MCP control

Baton runs a small MCP control server on `127.0.0.1`, secured with a bearer token, so an agent
(Claude Desktop, Claude Code, other MCP clients, or Tonebox) can search your library, queue
and control playback, like and rate tracks, manage playlists, and coordinate audio focus (duck
the music while you dictate, then bring it back). The full design, tool catalog, and security
model live in [`docs/04-integration-and-mcp.md`](docs/04-integration-and-mcp.md).

![Baton's Agents settings pane: the MCP server's status, loopback endpoint, masked bearer token,
fast-path socket, the discovery file agents read, and a ready-to-paste client configuration
block](screenshots/baton-agents.png)

<sub>The bearer token is masked in this screenshot; the app shows it only when you reveal it.</sub>

The control server is live whenever Baton is running. It exposes 28 `music_*` operations
(including `music_build_mix`), the `audio_suspend` / `audio_resume` focus hand-off, and a
`speak_summary` tool; it publishes now-playing, queue, playlists, liked, and recent history as
live resources; and it writes a discovery file (endpoint URL and token) to
`~/Library/Application Support/Baton/mcp.json`. There's a menu-bar controller too.

## Docs

- [HELP.md](HELP.md) is the full user guide.
- [FAQ.md](FAQ.md) has quick answers.
- [docs/](docs/) holds the vision, feature inventory, architecture, the integration and MCP
  design, and the roadmap.
- Website lives in `website/`, icon and design in `design/`, the app in `app/`, site deploy in
  `deploy/`.

## Support

Baton is free and MIT-licensed, and it always will be. Tips don't unlock anything; there's
nothing to unlock. But if it's earned a place in your day and you'd like to chip in, a one-time
tip helps me keep it maintained and moving forward:

[GitHub Sponsors](https://github.com/sponsors/anatoliv) ·
[Ko-fi](https://ko-fi.com/anatolivishnyakov) ·
[PayPal](https://paypal.me/anatolivishnyakov)

You can also [vote on what to build next](https://github.com/anatoliv/baton/issues?q=is%3Aissue+is%3Aopen+label%3Aroadmap+sort%3Areactions-%2B1-desc).
The features with the most thumbs-up rise to the top.

## License

[MIT](LICENSE). Free to use, change, and share. Made by [Tonebox](https://tonebox.io) and
given away.
