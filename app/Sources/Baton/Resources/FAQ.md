# Baton FAQ

Short answers to the questions that come up most. For step-by-step walkthroughs, see
[HELP.md](HELP.md).

## About Baton

**What is Baton?**
A free macOS music player for your own self-hosted music library. It plays from any
[Navidrome](https://www.navidrome.org/) or Subsonic-compatible server, with real playback
depth (true gapless, crossfade, ReplayGain loudness matching, and a 10-band equalizer). It
also runs a small control server so an AI agent can search, queue, and steer your music for
you. The tagline is *"Conduct your music."*

**Is Baton free?**
Yes. Baton is a give-away from [Tonebox](https://tonebox.io). There's no subscription and no
catalog rent. You're playing music you already own, on a server you already run.

**How is Baton different from Tonebox?**
They're two products from the same maker. [Tonebox](https://tonebox.io) is a paid,
local-first notes app that records meetings and voice notes, transcribes them on your Mac,
and turns them into searchable, AI-assisted notes. Baton is the music player, pulled out into
its own free app, focused on playing your library well and being controllable by agents.
Tonebox can control Baton (for example, turning the music down while you dictate), but you
don't need Tonebox to use Baton.

**What platforms does Baton run on?**
macOS 15 or later. An iOS and iPadOS companion is on the roadmap. Windows and Linux clients
are not planned.

## Servers and your library

**What servers work with Baton?**
[Navidrome](https://www.navidrome.org/) and any Subsonic-compatible server. Baton speaks the
Subsonic API, so most self-hosted music servers in that family work.

**Does Baton have its own music catalog?**
No. Baton plays *your* library from *your* server. It is deliberately not a streaming catalog
like Spotify or Tidal, so there's nothing to browse until you connect a server.

**How do I connect?**
On first launch, enter your server's URL and either a username and password or an API key.
Baton verifies the connection before it saves anything. See
[Getting connected](HELP.md#getting-connected).

**Can I connect more than one server?**
Yes. Open Settings (press Command and comma), choose the Servers pane, and add servers there.
Baton keeps each server's credentials separately in the Keychain, and you switch the active
one with a click. Your first single connection is carried into the list automatically. See
[Using more than one server](HELP.md#using-more-than-one-server).

**Does Baton do podcasts and internet radio?**
Yes. The Podcasts tab plays shows your server hosts, and it can also follow any podcast by its
RSS feed directly (which is how it works on Navidrome). The Radio tab plays internet-radio
stations you add, including plain-HTTP streams, and shows the live track each station is
broadcasting. See [Podcasts](HELP.md#podcasts) and [Internet radio](HELP.md#internet-radio).

## Privacy and security

**Is my password safe?**
Yes. Your server credentials are stored in the macOS Keychain, never in a plain text file.
With username-and-password sign-in, Baton uses the salted-token scheme Subsonic expects, so
your password isn't sent in the clear on each request.

**Does Baton phone home?**
Not by default. Baton talks only to the music server you point it at, plus the scrobbling
services (ListenBrainz and Last.fm) if you turn them on, its own update feed for checking for
new versions, and any text-to-speech server you set up for spoken summaries. It has no catalog
server of its own to call. The one opt-in exception is crash reporting: if you turn on **Send
crash & error reports** (Settings, About, Diagnostics, off by default), Baton sends crash and
error data to its developer via Sentry to help fix bugs. It never sends your music, library,
server address, or account, and no IP or identifiers.

**Is the control server a security risk?**
No, by design. Baton's control server listens only on your own Mac (loopback), so it isn't
reachable from your network, and every request must carry a secret token that Baton
generates. Both are required: an app on another machine can't reach it, and a program on your
own Mac can't drive it without the token. See
[how it's secured](HELP.md#letting-an-agent-control-your-music).

## Agent control

**What is the control server?**
Baton hosts a small server on your Mac that speaks [MCP](https://modelcontextprotocol.io/),
the Model Context Protocol, the standard way AI agents talk to tools. It exposes the same
music operations Baton's own interface uses (search, play, queue, pause and skip, like and
rate, create playlists, report what's playing), so an agent like Claude, or Tonebox, can
control your music from a natural request.

**How do agents control my music?**
You point an MCP client (like Claude Desktop or Claude Code) at Baton's local address and
token, then ask the agent for what you want: *"play a focus mix," "what's this song, and like
it," "make a playlist of this month's likes."* The agent calls Baton's tools to do it.
Because the tools mirror Baton's own actions, an agent can only do things you could do
yourself.

**Do I need an agent to use Baton?**
No. Baton is a complete, click-to-play music player on its own. Agent control is an extra
surface, not a requirement.

**Is agent control available today?**
Yes. The control server runs while Baton is open. It exposes 28 music operations (including a
`music_build_mix` tool that assembles a mix to a length you ask for), two behind-the-scenes
audio-focus operations for ducking, and a `speak_summary` tool. It publishes five live views
(what's playing, your queue, playlists, liked music, and recent history), and it writes a
discovery file at `~/Library/Application Support/Baton/mcp.json` with the endpoint URL and
token so a client can find it. The full tool catalog, resources, and examples are in
[Letting an agent control your music](HELP.md#letting-an-agent-control-your-music).

**How do I connect Claude (or another client) to Baton?**
Point an MCP client at the `url` from `mcp.json` (something like `http://127.0.0.1:8787/mcp`)
over the Streamable HTTP transport, and pass the `token` from that same file as a bearer
token. In Claude Code that's one command:

```sh
claude mcp add --transport http baton \
  http://127.0.0.1:8787/mcp \
  --header "Authorization: Bearer <token-from-mcp.json>"
```

Baton has to be running for the server to be live. See
[Connecting an agent to Baton](HELP.md#connecting-an-agent-to-baton) for a Claude Desktop
config example and the full details.

## Playback

**Does Baton do gapless?**
Yes, true gapless playback. It pre-loads the next track (and prefetches streamed tracks to a
small cache) so there's no silence between songs. There's also optional crossfade, loudness
normalization, and a parametric equalizer. See
[Sound quality](HELP.md#sound-quality-gapless-crossfade-loudness) and
[The equalizer](HELP.md#the-equalizer).

**Do I have to set all that up?**
No. After you've played about twenty tracks, Baton picks sensible playback defaults based on
how you listen (gapless for album listeners, a gentle crossfade and autoplay for shuffle
listeners), and explains what it did. You can change any of it. See
[defaults that match how you listen](HELP.md#defaults-that-match-how-you-listen).

**Can I scrobble?**
Yes, to your Navidrome or Subsonic server, and to [ListenBrainz](https://listenbrainz.org/)
and/or [Last.fm](https://www.last.fm/) if you add your accounts. A track scrobbles once
you've played half of it, up to a four-minute cap. See [Scrobbling](HELP.md#scrobbling).

**Does Baton work offline?**
Yes, for downloaded music. You can download tracks, albums, mixes, playlists, and podcast
episodes to your Mac and play them from disk without re-streaming. The Downloads screen
manages them, with play-all and shuffle, batch actions, per-track actions, total size on
disk, and a global Offline mode. Browsing new content, and streaming anything you haven't
downloaded, still needs your server reachable. See
[Downloads](HELP.md#downloads-and-offline-listening).

**Why do the player's colors change with the music?**
That's Baton adapting to your artwork. The full-screen backdrop and the player's accent
colors are drawn from the current track's cover art, and fall back to Baton orange when
there's no usable color. It's purely cosmetic. See
[Adaptive artwork colors](HELP.md#adaptive-artwork-colors).

**Can I cast to speakers?**
AirPlay works today, from the AirPlay picker in the now-playing bar. Chromecast, Sonos, and
UPnP/DLNA casting are planned.

**Is there a menu-bar controller?**
Yes. Baton puts an item in the macOS menu bar with the current track and Play/Pause, Next,
and Previous, plus ways to open the main window or the mini-player. It keeps Baton (and the
control server) running in the background even when every window is closed.

**Can Baton speak things out loud?**
Yes, and it's one of the two big agent features. Through the `speak_summary` tool, an agent can
have Baton say a short result aloud in a natural voice, so you hear "deploy finished, all
green" instead of watching a screen. It's especially handy with several agents running at
once: map a voice to each one (a category-to-voice map, editable in the Speech pane), and you
can follow a whole multi-agent run by ear. Baton speaks through self-hosted text-to-speech
servers you configure (Kokoro for fast preset voices, Chatterbox for cloning), and falls back
to the built-in macOS voice if none are set up. See
[Speaking summaries aloud](HELP.md#speaking-summaries-aloud).

**Do I need to run text-to-speech servers for spoken summaries?**
No. If you haven't set any up, Baton uses the built-in macOS voice, so `speak_summary` still
works. Self-hosted servers (Kokoro and Chatterbox) get you better and more varied voices, plus
voice cloning, and keep the audio on your own network. Setup is in
[`docs/tts-speak-summary.md`](docs/tts-speak-summary.md).

## Your data

**Where does Baton keep my listening history?**
On your Mac. The History tab is a local play log, separate from the play counts Baton reports
to your server, and it works as a free, local alternative to Last.fm or ListenBrainz. You can
export it as ListenBrainz JSON or CSV, import listens, or clear it. See
[History](HELP.md#history).

**What does "Mark for Removal" do?**
Subsonic servers have no delete-file command, so Baton can't remove tracks from your server
directly. Marking a track for removal unlikes it and rates it one star, which a separate
server-side cleanup routine can read to prune it later. If you don't run such a routine, it
just unlikes and low-rates the track. See [Albums and artists](HELP.md#albums-and-artists).

## Updates and platform

**How do updates work?**
Baton uses Sparkle (the standard macOS updater). There's a **Check for Updates** item in the
app menu, and Baton can pull signed, notarized builds from its own feed. The public feed goes
live with Baton's first published release; until then the in-app status shows "Not available
yet" and you update by downloading the latest build yourself.

**Where can I read more?**
[HELP.md](HELP.md) covers how to use every part of Baton. The docs in [`docs/`](docs/) go into
the vision, architecture, and integration details.
