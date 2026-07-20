# Baton Help

**Conduct your music.** Baton is a free macOS player for the music you already own. It
streams from your self-hosted [Navidrome](https://www.navidrome.org/) server, or any
Subsonic-compatible server, and it plays that library with real care: true gapless
playback, crossfade, ReplayGain loudness matching, and a 10-band parametric equalizer. It
also runs a small control server on your Mac so an AI agent, like Claude or
[Tonebox](https://tonebox.io), can search, queue, and steer your music by voice or on your
behalf.

Baton is made by [Tonebox](https://tonebox.io) and given away for free.

This guide walks through every part of the app in plain language. If you just want a quick
answer, the [FAQ](FAQ.md) is shorter. For the deeper design and architecture, see the docs
in [`docs/`](docs/).

## Contents

- [What Baton is, and what it isn't](#what-baton-is-and-what-it-isnt)
- [Getting connected](#getting-connected)
- [Using more than one server](#using-more-than-one-server)
- [Finding your way around](#finding-your-way-around)
- [Home (For You)](#home-for-you)
- [Search](#search)
- [Mixes](#mixes)
- [Albums and artists](#albums-and-artists)
- [Playlists](#playlists)
- [Liked](#liked)
- [History](#history)
- [Podcasts](#podcasts)
- [Internet radio](#internet-radio)
- [Downloads and offline listening](#downloads-and-offline-listening)
- [Playing music](#playing-music)
- [Adaptive artwork colors](#adaptive-artwork-colors)
- [The queue, shuffle, repeat, and autoplay](#the-queue-shuffle-repeat-and-autoplay)
- [Sleep timer](#sleep-timer)
- [Sound quality: gapless, crossfade, loudness](#sound-quality-gapless-crossfade-loudness)
- [The equalizer](#the-equalizer)
- [Rating, liking, and multi-select](#rating-liking-and-multi-select)
- [Scrobbling](#scrobbling)
- [Media keys and AirPlay](#media-keys-and-airplay)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Webhook actions](#webhook-actions)
- [Speaking summaries aloud](#speaking-summaries-aloud)
- [Letting an agent control your music](#letting-an-agent-control-your-music)
- [Settings reference](#settings-reference)
- [Updates](#updates)
- [What's next](#whats-next)
- [Privacy and security](#privacy-and-security)
- [Troubleshooting](#troubleshooting)
- [Questions](#questions)

---

## What Baton is, and what it isn't

Baton plays *your* library. It is not a streaming catalog like Spotify or Tidal, and it has
no music of its own. You bring a server full of music, and Baton plays it well. Until you
connect a server there is nothing to browse.

A few things worth knowing up front:

- **It's self-hosted and private.** Baton only ever talks to the server you point it at.
  Your credentials live in the macOS Keychain, not in a plain file on disk.
- **There's no subscription and no account with us.** You're playing music you already own,
  on a server you already run.
- **Software can drive it.** This is the part that makes Baton different from other Subsonic
  players. An AI agent can pick up the baton and search, queue, build a mix, rate what's
  playing, or turn the music down for a call, all through a local control interface. See
  [Letting an agent control your music](#letting-an-agent-control-your-music). You never
  have to touch that, though: Baton is a complete, click-to-play player on its own.
- **It can talk back.** The same control interface lets an agent speak short results out loud
  in a natural voice. Give each agent its own voice and you can follow a whole multi-agent run
  by ear. See [Speaking summaries aloud](#speaking-summaries-aloud).

Baton runs on macOS 15 or later.

---

## Getting connected

The first time you open Baton it asks you to connect to your music server. You need three
things: the server's address, a sign-in method, and your credentials.

1. **Pick a sign-in method.** Baton supports two:
   - **Username and password**, the classic Subsonic sign-in. Baton never sends your
     password in the clear. It uses the salted-token scheme that Subsonic servers expect,
     so what goes over the wire on each request is a one-time token, not your password.
   - **API key**, if your server supports one. Recent versions of Navidrome do. Paste the
     key instead of a username and password.
2. **Enter the server URL**, the full address, for example `https://music.example.com`.
3. **Enter your username** (only for the username-and-password method) and your **password**
   or **API key**.
4. **Click Connect.** Baton checks that it can actually reach the server and sign in
   *before* it saves anything. If it works, your library loads and the player unlocks right
   there. If it doesn't, Baton tells you what went wrong so you can fix the address or your
   credentials and try again.

Your credentials are stored in the **macOS Keychain**, the same place Safari and Mail keep
passwords. They are never written to a plain text file. There's more on this in the
[FAQ](FAQ.md#privacy-and-security).

---

## Using more than one server

If you run more than one server, or want to keep a home server and a friend's server side by
side, Baton can hold several connections and switch between them.

Open **Settings** (press Command and comma), choose the **Servers** pane, and click **Add
Server**. Give the server a name if you like, pick a sign-in method, and enter its address
and credentials. Baton verifies the new connection before saving it, then makes it the
active one and reloads your library.

- The server with the checkmark is the **active** one: the library you're browsing and
  playing right now.
- To switch, click another server in the list, or open its `...` menu and choose **Make
  Active**.
- Each server keeps its own credentials, stored separately in the Keychain.
- **Edit** or **Remove** a server from that same `...` menu. Removing a server makes Baton
  forget it and its saved password.

The single connection you set up on first launch is carried into this list automatically the
first time you open the Servers pane, so you don't lose it.

---

## Finding your way around

The left rail is your way into the library. Here's what each item is, with a link to the
section that covers it in full:

- **[Home](#home-for-you)**, labeled "For You": a greeting and a set of tap-to-play shelves.
- **[Search](#search)**: search songs, albums, and artists at once.
- **[Mixes](#mixes)**: mixes Baton builds for you from your listening.
- **Albums** and **[Artists](#albums-and-artists)**: browse your library the familiar way.
- **[Playlists](#playlists)**: your server-side playlists, which you can edit here.
- **[Liked](#liked)**: everything you've hearted.
- **[History](#history)**: your local play log.
- **[Podcasts](#podcasts)**: podcast shows your server hosts, plus any you add.
- **[Radio](#internet-radio)**: internet-radio stations.
- **[Downloads](#downloads-and-offline-listening)**: everything you've saved for offline
  play, with a count badge.

Across list views you can select several rows at once and act on them together. See
[Rating, liking, and multi-select](#rating-liking-and-multi-select).

---

## Home (For You)

Home is the screen that greets you when the library loads. It opens with a greeting that
changes with the time of day (good morning, afternoon, or evening), and below that a set of
shelves you can tap to play. Each shelf appears only when it has something to show:

- **Jump back in**, the tracks you've played recently, so you can pick up where you left off.
- **Because you liked...**, a radio-style shelf of music similar to something you've hearted
  or played a lot.
- **Recently added**, the newest arrivals on your server.
- **Rediscover**, a random dip back into your own library, for the albums you forgot you
  had.
- **Your Mixes**, quick cards into the [mixes](#mixes) Baton has built.

Everything on Home is one click to start. It's meant to be the "just play me something"
screen. Until you've played a few things it stays mostly empty, with a note that Home fills
in as you listen.

---

## Search

Search looks across **songs, albums, and artists at once** and shows the matches together,
so you don't have to decide what kind of thing you're looking for before you type. Start
playing any result directly, or open an album or artist to go deeper.

Each browse screen also has its own filter box for narrowing the list you're already looking
at. Baton remembers your recent filter terms per screen; you can control how many it keeps
in Settings, under Playback, in the Advanced section.

---

## Mixes

Mixes are playlists Baton assembles for you from how you actually listen. You don't build
them; they refresh from your library and your history. Open the **Mixes** tab to see them.
There are six standing mixes:

- **Most Played**: the tracks you return to most.
- **Fresh Additions**: the newest music in your library.
- **Top Rated**: your highest-rated tracks.
- **On Repeat**: what you've been playing a lot lately.
- **Forgotten Favorites**: music you liked but haven't played in the last month.
- **Discover**: a random shuffle across your library, for the things you haven't heard much.

Below those is a **Genres** section: one card per genre you listen to, up to a dozen, each
showing how many songs it holds. Tap it to play that genre as a mix.

Each mix has its own page. From there you can **Play** it, **Shuffle** it, add it to the
**Queue**, or **download the whole thing** for offline listening. You can also sort or filter
within a mix while keeping its ranked order.

There's also an agent-built variety of mix. If you ask an agent for something like "an
upbeat 40-minute focus mix," Baton can assemble a set from your library that lands close to
the length you asked for and either queue it or save it as a playlist. See
[Letting an agent control your music](#letting-an-agent-control-your-music).

---

## Albums and artists

**Albums** and **Artists** are the classic ways through a library.

- Browse albums in a **grid** or a **list**. Sort them by recently added, recently played,
  most played, name, artist, track count, play time, liked, top rated, or at random, in
  either direction.
- **Artists** default to a list showing each one's album, track, and time counts, with a
  grid option. Sort by name or number of albums. Open an artist to see their bio (where your
  server has one) and their albums.
- Both browsers have a **Hide auto-imports** toggle for filtering out auto-imported or junk
  albums, and the Artists list has a **Duplicates** toggle that shows only artists whose
  names look like duplicates, which is handy for tidying a messy library.
- Hover a row or right-click for quick actions: play, shuffle, add to queue, **Find Similar
  (Radio)** (an endless "more like this"), pin, download, and save as a playlist.
- Open any album or artist to play, shuffle, queue, or download it, and to like or rate
  individual tracks.

> [!NOTE]
> Subsonic servers don't offer a "delete this file" command, so Baton can't remove tracks
> from your server directly. Instead, **Mark for Removal** unlikes a track and rates it one
> star, the lowest. That's a signal a separate server-side cleanup routine can read to prune
> those tracks later. If you don't run such a routine, marking for removal simply unlikes and
> low-rates the track.

---

## Playlists

The **Playlists** tab shows the playlists that live on your server, and it's a full editor,
not just a viewer:

- **Create** a new playlist, **rename** it, or **delete** it.
- **Add** tracks to a playlist or **remove** them. Adding skips any tracks already in the
  playlist, so you won't get duplicates.
- **Reorder** tracks by dragging. The new order is saved back to your server, so it follows
  you to any other Subsonic client.
- **Make a playlist private or shared (public)** from its menu.
- Sort your playlists by name or track count, and hide empty ones.

You can also **save a queue, a selection, or a whole mix as a new playlist** from most browse
screens. Because playlists are server-side, anything you change here is a real change on the
server, not just a local view.

---

## Liked

Anything you heart shows up in **Liked**, split into **Songs**, **Albums**, and **Artists**
so each kind is easy to find. The same sort and filter controls from the rest of the app
apply here too.

Likes are stored per user on your server (as Subsonic "stars"), so they're not just a Baton
thing. They travel with you to any Subsonic client, and back again.

---

## History

**History** is your local play log, the record of what you've actually listened to in Baton.
It has four views:

- **Recent**: your latest plays in order.
- **Tracks**: your most-played songs, each with a play-count badge.
- **Albums**: your most-played albums.
- **Artists**: the artists you've played most.

The Tracks, Albums, and Artists views can be scoped to **This Week**, **This Month**, or
**All Time**, and a small summary strip up top shows your totals and a per-day sparkline.

This log lives on your Mac. It's Baton's own memory of your listening, separate from the play
counts it reports to your server, and it's a free, local alternative to Last.fm or
ListenBrainz. It records a listen only once you've genuinely played a track (the same
half-way point that triggers [scrobbling](#scrobbling)), so skips don't clutter it.

From the log's menu you can turn logging on this Mac off, **export your history as
ListenBrainz JSON or CSV**, **import listens** from elsewhere, or **clear** it. Clearing only
affects your local list and stats; it doesn't touch your server's play counts.

---

## Podcasts

The **Podcasts** tab plays podcast episodes through the normal player. There are two ways a
show can get here, and Baton picks the right one for your server automatically:

- **Shows your server hosts.** If your server manages podcasts itself (some Subsonic servers
  do), those channels show up here. Navidrome doesn't offer podcasts through its API, so on a
  Navidrome server Baton uses the second path instead.
- **Shows you add yourself.** Baton can follow a podcast directly by its RSS feed, no server
  support needed. Click **Add Show**, paste the feed URL, and Baton checks it before
  subscribing. This is the fallback that makes podcasts work everywhere, including on
  Navidrome.

How it works:

- **Latest Episodes strip.** A scrollable row at the top gathers the newest playable episodes
  from every show. Click one to play it and queue the rest of the strip behind it.
- **Browse shows.** Filter by name and sort by **Name**, **Latest episode**, or **Episodes**,
  in a grid or a list. Click a show, or its chevron, to open it.
- **Inside a show.** You get the artwork, the description, and the episode list, each row with
  its publish date and length. Click an episode to play it and queue the rest of that show
  from there. Episodes behave just like tracks: they stream, queue, and download.
- **Keeping your place.** Baton remembers how far into an episode you got and shows a small
  progress bar and a "minutes left" note, with a checkmark once you've finished. You can mark
  an episode played or unplayed by hand.
- **Downloading.** For shows you follow by RSS, episodes play right away with no download
  step, and a show's menu can grab the **latest 5**, **latest 10**, or **all** episodes at
  once for offline listening (and remove them again). For server-hosted shows, an episode
  that hasn't been fetched yet shows a **Download** button that asks the server to pull it.

Baton can delete a downloaded episode's file automatically once you finish it, to save space.
That's the **Remove finished podcast episodes** option in Settings, under Playback, and it's
on by default.

You can also send an episode to an HTTP endpoint of your choice, for example a transcription
service, using [webhook actions](#webhook-actions).

Podcasts are deliberately left out of [scrobbling](#scrobbling); a podcast isn't a "listen"
in the Last.fm sense.

---

## Internet radio

If your server hosts internet-radio stations, or you add your own, the **Radio** tab plays
them alongside your library.

- **Add, edit, or remove a station.** Click **Add Station** and give it a **name** and a
  **stream URL**. Any `http://` or `https://` address works, including plain-HTTP streams
  that some players refuse to touch. A **homepage** is optional: add one and Baton shows a
  link to the station's site and pulls in its logo for you. Edit or remove a station from
  its right-click menu.
- **Browse your way.** Switch between **list** and **grid**, filter by name, and sort by
  **Name** or **Website**. Baton remembers how you left it.
- **See what's on air.** While a station plays, its card or row shows the **live track**
  it's broadcasting, read from the stream's now-playing metadata. Next to it is a little
  animated on-air badge. If the station doesn't send a track title, you'll see **"On air"**
  with its genre and bitrate instead. Baton also tidies up messy metadata, like a station
  name that's been sent twice.
- **Station logos.** For stations with a homepage, Baton fetches the site's icon. If it
  can't find one, it shows a colored monogram made from the station's name.

When a station is on air, the [now-playing bar](#playing-music) switches into radio mode:
station artwork and name, the live track, and **Previous** and **Next station** buttons in
place of track skip. The scrubber, queue, and rating controls tuck away, because there's
nothing to seek or rate on a live stream, while the volume slider and the
[sleep timer](#sleep-timer) keep working. Play anything from your library and the radio
stops, handing playback back to the library player.

---

## Downloads and offline listening

Baton can save tracks, albums, mixes, playlists, and podcast episodes to a folder on your
Mac and play them straight from disk. That's useful for two reasons: local files give you
true gapless quality without re-streaming, and they keep your favorites available when you're
offline. **Baton prefers a downloaded copy over streaming automatically**, and the
**Downloads** item in the left rail carries a badge with how many you've saved.

The Downloads screen is laid out like the Artists list and manages everything you've saved:

- **Play the whole set.** **Play all** and **Shuffle** in the header start the entire
  (filtered) list. Click any single track to play the list continuously from that point on,
  just like an album.
- **Per-track actions.** Hover a row for quick actions: **Like**, **Play next**, **Add to
  queue**, **Start radio** (an endless "more like this"), and **Delete**. Right-click gives
  you the same menu. Each row shows the file's **size** and **length**.
- **Batch actions.** Select several rows (press Command and A to select all), then **Play**,
  **Shuffle**, **Add to queue**, **Save as a new playlist**, **Add to an existing
  playlist**, or **Delete** them together.
- **See the footprint.** The header shows the **total size on disk**.
- **Offline mode.** Turn on **Offline mode** to keep playback on your local files and never
  stream. Browsing new content, and playing anything you haven't downloaded, still needs the
  server reachable.

**Where the files go.** Downloads live in a folder you can change in Settings, under
Playback. You can also set a **filename format** from the tokens `{artist}`, `{album}`,
`{title}`, and `{id}` (the default is `{artist} - {title}`) so saved files are named the way
you like. Baton finds your downloads by track ID regardless of their names, so changing the
folder or the format doesn't move or rename files you've already saved. See the
[Settings reference](#settings-reference) for the exact controls.

---

## Playing music

### The now-playing bar

A bar sits at the bottom of the window the whole time. Expanded, it gives you the scrubber,
the transport controls (previous, play and pause, next), volume, the queue, a sleep timer,
and the AirPlay picker. You can **collapse it to a slim strip** to reclaim space (press
Command, Control, and J), and expand it again the same way.

### Full-screen Now Playing

Open the full-screen player for big artwork, a soft backdrop tinted from the album art, and
a **waveform scrubber** for tracks you've downloaded. Along the side are panels for the
**Queue**, **Lyrics** (synced karaoke-style when your server provides timed lyrics, plain
text otherwise), and **Related** tracks. Press **Space** to play or pause, and **Escape** to
leave full-screen.

### The floating mini-player

Baton has a borderless, always-on-top **mini-player** window (press Command, Option, and M).
It's a compact card you can park in a corner while you work in other apps, showing the
current track, artwork, the scrubber, the rating, and what's up next, and it expands for a
little more. On macOS 26 and later it's drawn with Liquid Glass.

### The menu-bar controller

Baton also lives in the menu bar. The menu-bar item shows what's playing and gives you
Play/Pause, Next, and Previous, plus shortcuts to open the main window or the mini-player.
Because it keeps Baton present even when every window is closed, the transport (and the
[agent control server](#letting-an-agent-control-your-music)) stays reachable in the
background.

---

## Adaptive artwork colors

Baton tints itself to whatever's playing. In the full-screen player the backdrop is a gentle
gradient built from the current track's cover art, and the player's accents (the progress
and volume fills, the shuffle and repeat indicators, and the heart and star controls) pick
up a vivid color pulled from that same artwork, nudged where needed so it always stays
readable. When a track has no cover art, or only muted, near-grey art, Baton falls back to
its signature **Baton orange**. The colors cross-fade gently as tracks change. This is purely
cosmetic; nothing about your library or your playback changes.

---

## The queue, shuffle, repeat, and autoplay

**The queue.** Drag to reorder it, remove tracks, or clear it. Baton remembers your queue
between launches (the tracks, your position, and where the queue came from) and restores it
paused the next time you open the app.

**Shuffle** reshuffles the queue while keeping the current track playing. Turn it off and the
original order comes back.

**Repeat** cycles through three modes: **Off**, **All** (loop the whole queue), and **One**
(loop the current track).

**Autoplay similar tracks.** When you turn this on, Baton keeps the music going as the queue
runs low by adding tracks similar to what's playing. It's a kind of continuous radio for the
end of a queue. It's off by default; you'll find it in Settings, under Playback. You can also
start an explicit **Start radio** from a track's menu for an endless "more like this."

---

## Sleep timer

Set a sleep timer from the Playback menu or the moon icon in the now-playing bar. Pick a
fixed length (15, 30, 45, 60 minutes, or 2 or 3 hours), or choose **End of track** to stop
when the current song finishes. When a fixed timer is up, Baton **fades out gently** over
about five seconds rather than cutting off mid-note. There's a **Turn off sleep timer** item
once one is armed, and an agent can arm or cancel the timer too.

---

## Sound quality: gapless, crossfade, loudness

Baton keeps the playback depth that a lot of desktop players skip. These live in Settings,
under Playback, in the **Sound** section.

- **True gapless playback.** Live albums, DJ sets, and classical recordings that were made
  without gaps play with no silence between tracks. Baton pre-loads the next track (and for
  streamed tracks, prefetches the stream to a small on-disk cache) so the hand-off is clean.
  You can limit that prefetch to **Wi-Fi only** so it doesn't eat a metered connection like
  a personal hotspot. Gapless is off by default, and it's mutually exclusive with crossfade
  (one abuts tracks perfectly, the other overlaps them).
- **Crossfade.** Overlap the end of one track with the start of the next, anywhere from off
  up to twelve seconds. Off is a clean cut.
- **Loudness normalization.** Even out volume so a quiet track and a loud one play at a
  similar level, using the ReplayGain or R128 data your server provides. Choose **Track**
  (level every song the same) or **Album** (keep an album's own quiet-to-loud dynamics), and
  set a **pre-amp** to taste. It needs ReplayGain tags in your library; tracks without that
  data just play at their normal volume. It's off by default.

> [!NOTE]
> Gapless and crossfade can't both be on. Gapless makes tracks touch with no gap; crossfade
> makes them overlap. Baton hides the gapless toggle whenever crossfade is turned up, so you
> won't accidentally ask for both.

### Defaults that match how you listen

You don't have to set any of this by hand. Once you've played about twenty tracks, Baton
takes a look at how you listen and picks sensible defaults for you, one time:

- If you're an **album listener** (you tend to play tracks straight through from the same
  album), it turns **gapless on** and leaves autoplay off, because you're choosing whole
  albums.
- If you're more of a **singles or shuffle listener**, it sets a gentle **6-second crossfade**
  and turns **autoplay on**, so the music keeps flowing.

It only does this once, and it explains what it did. You can override any of it in Settings,
and re-run the suggestion from there if your habits change.

---

## The equalizer

Baton has a **10-band parametric equalizer**. Open it from the Audio menu (press Option,
Command, and E), or from the **Equalizer** pane in Settings.

- It's **off by default**, and when it's off, audio passes through bit-for-bit untouched.
- **Presets** get you started with one click: **Flat**, **Bass Boost**, **Treble Boost**,
  **Vocal**, **Rock**, **Electronic**, **Loudness**, **Vocal Boost**, and **Bass Reduce**.
- The ten bands sit at 32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, and 16000 Hz. Tap a
  band to open it and adjust its **frequency** (anywhere from 20 Hz to 20 kHz), its **Q**
  (how wide or narrow the band is, from 0.3 to 10), and its **gain** (plus or minus 12 dB).
- A live **response curve** shows the shape you're building as you go.
- The moment you hand-tune any band, the preset switches to **Custom**. **Flat / Reset**
  zeroes every band back to a neutral response.

Because it's parametric, this is more than a graphic EQ: you're not stuck with fixed
frequencies, you can move each band where you want it.

---

## Rating, liking, and multi-select

- **Like** a song by tapping its heart, or set a **1-to-5 star rating**. Both are stored per
  user on your server, so they follow you to any Subsonic client and show up in your
  [Liked](#liked) list and [Top Rated](#mixes) mix.
- **Select several rows at once** in list views: shift-click to select a range, press
  Command and A to select everything, and then apply a batch action to the whole selection.
  Depending on the screen, batch actions include like or unlike, add to queue, save as a
  playlist, download, and delete.

---

## Scrobbling

Scrobbling is the record of what you listened to. Baton can report your listens to three
places:

- **Your Navidrome or Subsonic server**, which updates its own play counts. This always
  happens.
- **[ListenBrainz](https://listenbrainz.org/)**, if you paste your user token in Settings,
  under Playback.
- **[Last.fm](https://www.last.fm/)**, if you connect your account there. Last.fm uses a
  browser authorization: enter your API key and shared secret, click to authorize in the
  browser, approve, and come back to finish.

A track scrobbles once you've played **half of it, up to a maximum of four minutes**, which
is the usual scrobbling convention. Baton reports "now playing" to your server when a track
starts, and the completed play when you cross that halfway point, so a skip near the start
never gets miscredited. Podcasts and internet radio are never scrobbled.

If your **server** is already linked to Last.fm or ListenBrainz, you can avoid
double-counting by switching scrobbling to **Handled by my server** in the same pane. The
default is **Sent by Baton**. Either way, your server's own play counts are always tracked.

> [!TIP]
> Scrobbles you make while offline aren't lost. Baton keeps a durable queue and submits them
> once you're back online.

---

## Media keys and AirPlay

- **Media keys and Bluetooth remotes.** The play, pause, next, previous, and seek keys on
  your keyboard (F7, F8, F9) and on Bluetooth remotes all control Baton, and the current
  track (title, artist, album, artwork, and elapsed time) shows up in the macOS Now Playing
  widget in Control Center.
- **AirPlay.** Use the AirPlay picker in the now-playing bar to send audio to an AirPlay
  device. Casting to Chromecast, Sonos, and UPnP/DLNA is [on the roadmap](#whats-next), but
  AirPlay works today.

---

## Keyboard shortcuts

Most of these come from the **Playback** menu, which is available anywhere in the app.

| Action | Shortcut |
|---|---|
| Play or pause | Command, Control, P |
| Next track | Command, Control, Right |
| Previous track | Command, Control, Left |
| Volume up | Command, Control, Up |
| Volume down | Command, Control, Down |
| Mute or unmute | Command, Control, M |
| Collapse or expand the player bar | Command, Control, J |
| Open the mini-player | Command, Option, M |
| Open the equalizer | Option, Command, E |
| Open Settings | Command, comma |

The Playback menu also holds **Shuffle**, **Repeat**, and the **Sleep Timer**. In the
full-screen player, **Space** toggles play and pause and **Escape** exits. In browse lists,
**Command and A** selects everything.

---

## Webhook actions

Webhook actions let you send a media item to an HTTP endpoint you choose. They're aimed at
podcast episodes: for example, you could POST an episode's audio URL to a service that
transcribes it, or hand it off to a save-for-later tool.

You set them up in Settings, in the **Actions** pane:

1. Click **Add Action** and give it a **name** and, if you like, an **SF Symbol** icon.
2. Choose the HTTP **method** (POST, GET, PUT, PATCH, or DELETE) and the **URL**.
3. Add any **headers** you need (for example an `Authorization` header).
4. For methods that send a body (POST, PUT, PATCH), pick a **content type** (JSON, Form, or
   Text) and write the body.

Anywhere you write a URL, header, or body you can drop in **tokens** that Baton fills from
the episode: `{title}`, `{channelTitle}`, `{enclosureUrl}` (the direct audio URL),
`{feedUrl}`, `{guid}`, `{pubDate}`, `{durationSec}`, `{episodeImageUrl}`,
`{channelImageUrl}`, and `{description}`.

Your saved actions then appear in the `...` (or right-click) menu on a podcast episode, and
in the multi-select bar when you've selected several. They **only ever fire when you run
them**. Nothing here happens automatically.

---

## Speaking summaries aloud

Alongside controlling your music, Baton gives an agent a **voice**. Through the
`speak_summary` tool, an agent can have Baton say a short line out loud in a natural voice, so
you *hear* "deploy finished, all green" instead of watching a screen for it. It's the second
half of what makes Baton a good teammate for an agent: it can act on your music, and it can
talk back.

This is genuinely useful the moment you have **more than one agent running at once**. Give
each agent, or each kind of task, its own **voice**, and you can tell them apart by ear
without switching windows. Your deploy agent speaks in one voice, your research agent in
another, and an alert comes through in a third. It's practical for keeping track of a busy
multi-agent run, and, honestly, it's just good fun to have your tools talk to you.

You configure all of this in the **Speech** pane in Settings.

### How an agent talks

The agent calls `speak_summary` with a few inputs:

- **`text`** (required): the line to say, for example "research pass done, 3 issues found".
- **`category`**: a label like `deploy`, `research`, or `alert`. Baton looks the category up
  in your voice map and speaks in the mapped voice. This is the key to telling agents apart:
  one category per agent or per role.
- **`voice`**: force a specific voice, ignoring the map (given as `engine:voice`, or a bare
  voice id).
- **`engine`**: `kokoro` (fast preset voices, the default) or `chatterbox` (premium and
  cloned voices).
- **`mode`**: how the line reaches you (see below).

### One voice per agent (the voice map)

The category-to-voice map is where the multi-agent magic lives. Baton ships with a starter
map you can edit, add to, and preview in Settings:

| Category | Voice | Good for |
|---|---|---|
| `default` | Kokoro af_heart | Anything with no category of its own |
| `research` | Kokoro af_bella | A research or analysis agent |
| `deploy` | Kokoro am_michael | Deploys and builds |
| `ops` | Kokoro am_fenrir | Ops and infrastructure |
| `alert` | Kokoro af_nova | Anything urgent that should stand out |
| `premium` | Chatterbox Emily.wav | A cloned or premium voice for special cases |
| `es` | Kokoro ef_dora | Spanish |

An agent that passes no category (or one you haven't mapped) gets the **default** voice. Add
your own categories for each agent you run, pick the engine and voice, and hit **preview** to
hear it. So a five-agent run can become five distinct voices, and you always know who's
talking.

### How the line reaches you

The `mode` input decides how a spoken line is delivered:

- **`notify`** (the default): a macOS notification appears with a **Play** button, and Baton
  speaks the line. Good when you're heads-down elsewhere.
- **`banner`**: an in-app banner with a Play button.
- **`auto`**: Baton just speaks it, right away.

### The voices themselves

Baton speaks through self-hosted, OpenAI-compatible text-to-speech servers on your own
network, so the audio never leaves your machines. There are two engines:

- **Kokoro** for fast, natural preset voices (the default).
- **Chatterbox** for premium voices and **voice cloning**, so a category can speak in a voice
  you've cloned.

Enter each server's address in the Speech pane and use **Test this connection** to check it.
Baton shows a green check with the number of voices it found, or the error if it can't reach
the server.

> [!NOTE]
> You don't have to run any TTS servers to use this. If none are set up (or one is
> unreachable), Baton falls back to the built-in macOS voice, so `speak_summary` still works
> and a line is never silently dropped. That fallback is on by default; turn it off if you'd
> rather an unreachable server report an error. For setting up Kokoro and Chatterbox, see
> [`docs/tts-speak-summary.md`](docs/tts-speak-summary.md).

### Examples

A deploy agent finishing its work:

> `speak_summary` with `text` "Deploy finished, all green" and `category` "deploy".
> Baton speaks it in the `deploy` voice (am_michael).

A multi-agent run, so you can follow along by ear:

> The research agent says "Research pass done" in af_bella, the deploy agent says "Build
> green, shipping" in am_michael, and a disk-space `alert` comes through in af_nova. Three
> agents, three voices, no window-switching.

Because `speak_summary` is just another tool on Baton's [control
server](#letting-an-agent-control-your-music), any MCP client that can reach Baton can use it,
the same way it uses the music tools.

---

## Letting an agent control your music

This is the part that makes Baton different from every other Subsonic player: software can
drive it, not just you clicking buttons.

Baton runs a small **control server** on your Mac that speaks
[MCP](https://modelcontextprotocol.io/), the Model Context Protocol, the same protocol Claude
and other AI agents use to talk to tools. That means you can say things to an agent like:

- *"Put on a 40-minute instrumental focus set."*
- *"What's playing? Like it."*
- *"Make a playlist of everything I liked this month."*
- *"Turn it down."* / *"Skip this."* / *"Play some jazz."*

and the agent carries them out in Baton: searching your library, building a queue, starting
playback, rating tracks, and creating playlists. The controls the agent uses are the same
music operations Baton's own interface uses, so anything an agent does is something you
could have done by hand.

### Connecting an agent to Baton

Baton runs the control server automatically while it's open, so there's nothing to switch on.
When it starts, it writes a small **discovery file** with everything a client needs:

`~/Library/Application Support/Baton/mcp.json`

It looks like this:

```json
{
  "schemaVersion": 1,
  "name": "baton",
  "transport": "streamable-http",
  "url": "http://127.0.0.1:8787/mcp",
  "token": "b7f3c0…a1c9",
  "app": { "bundleId": "io.tonebox.baton", "version": "0.1.0" }
}
```

You connect a client by pointing it at that **url** over the **Streamable HTTP** transport and
passing the **token** as a bearer token in the `Authorization` header. Both values come
straight out of `mcp.json`.

> [!NOTE]
> The port is `8787` by default, but if something else already has it, Baton uses the next
> free port (up to 16 above it) and writes the real one into `mcp.json`. Always read the
> current `url` and `token` from the file rather than hard-coding them; the token is
> regenerated only if you reset it, but the port can change between launches.

**Claude Code.** Add Baton in one command (paste the token from `mcp.json`):

```sh
claude mcp add --transport http baton \
  http://127.0.0.1:8787/mcp \
  --header "Authorization: Bearer <token-from-mcp.json>"
```

**Claude Desktop, or any client that uses an `mcpServers` config block:**

```json
{
  "mcpServers": {
    "baton": {
      "type": "http",
      "url": "http://127.0.0.1:8787/mcp",
      "headers": { "Authorization": "Bearer <token-from-mcp.json>" }
    }
  }
}
```

Baton has to be running for any of this to work, which is another reason for the
[menu-bar controller](#playing-music): it keeps Baton (and the server) alive in the
background even with every window closed.

### What an agent can do

The control server exposes **28 music operations**. They're the same actions Baton's own
interface uses, so anything an agent does is something you could have done by hand. Here's the
full catalog.

**Search and play:**

| Tool | What it does | Main inputs |
|---|---|---|
| `music_search` | Search your library for songs, albums, and artists | `query`, `limit` |
| `music_play` | Play the matches for a search right away, replacing the queue | `query`, `limit` |
| `music_play_next` | Insert matches right after the current track | `query`, `limit` |
| `music_queue_add` | Add matches to the end of the queue | `query`, `limit` |
| `music_play_playlist` | Play one of your playlists | `name` or `playlist_id` |
| `music_start_radio` | Start an endless "more like this" from the current track or a search | `query` (optional) |
| `music_build_mix` | Build a mix to a target length, then queue it or save it as a playlist | `prompt`, `target_minutes`, `seed_artist`, `seed_genre`, `action`, `name` |

**Control playback:**

| Tool | What it does | Main inputs |
|---|---|---|
| `music_pause` / `music_resume` / `music_stop` | Pause, resume, or stop | none |
| `music_next` / `music_previous` | Skip forward or back | none |
| `music_seek` | Jump to a position in the current track | `seconds` |
| `music_set_volume` | Set Baton's own volume, 0 to 100 (not your Mac's) | `percent` |
| `music_set_repeat` | Set repeat to off, all, or one | `mode` |
| `music_set_shuffle` | Turn shuffle on or off | `enabled` |
| `music_sleep_timer` | Pause after some minutes (0 or empty cancels) | `minutes` |

**Work the queue:**

| Tool | What it does | Main inputs |
|---|---|---|
| `music_get_queue` | Return the full queue with positions and the current index | none |
| `music_reorder_queue` | Move a track to a new spot | `from`, `to` |
| `music_remove_from_queue` | Remove a track | `index` |

**Rate and organize:**

| Tool | What it does | Main inputs |
|---|---|---|
| `music_like` | Like or unlike a track (the current one if no search is given) | `query`, `unlike` |
| `music_rate` | Set a 1 to 5 star rating (0 clears it) | `rating`, `query` |
| `music_create_playlist` | Create a playlist, optionally seeded from a search | `name`, `query` |
| `music_add_to_playlist` | Add search matches to an existing playlist | `query`, `name` or `playlist_id` |
| `music_delete_playlist` | Delete a playlist | `name` or `playlist_id` |
| `music_list_playlists` | List your playlists | none |

**Report and shape sound:**

| Tool | What it does | Main inputs |
|---|---|---|
| `music_now_playing` | Report the current track, playback state, and queue position | none |
| `music_set_eq` | Turn the equalizer on or off and apply a preset | `enabled`, `preset` |

### Live resources an agent can read

On top of the tools, Baton publishes five live, read-only views. A client reads them once and
is then notified whenever they change, so an agent can follow along without polling:

| Resource | What it holds |
|---|---|
| `baton://now-playing` | The current track, playback state, position, and volume |
| `baton://queue` | The full queue and the current index |
| `baton://library/playlists` | Your playlists |
| `baton://library/liked` | Your liked songs, albums, and artists |
| `baton://history/recent` | Recently played tracks, plus your top tracks and artists |

### Examples: what you say, and what happens

You talk to your agent in plain language; it picks the right tools. A few examples:

| You say | Baton does |
|---|---|
| "Play some jazz" | `music_play` with the query "jazz" |
| "What's playing? Like it." | `music_now_playing`, then `music_like` |
| "Make a 40-minute instrumental focus mix" | `music_build_mix` (target 40 minutes) |
| "Turn it down to 20 percent" | `music_set_volume` |
| "Skip this" / "pause" | `music_next` / `music_pause` |
| "Make a playlist of everything I liked this month" | `music_create_playlist` and `music_add_to_playlist` |
| "Start a radio from this track" | `music_start_radio` |
| "Set a 30-minute sleep timer" | `music_sleep_timer` |
| "Bass boost, please" | `music_set_eq` with the Bass Boost preset |

### Speaking a result aloud

There's one more tool worth calling out: `speak_summary`. After finishing a task, an agent can
have Baton read a short line out loud in a natural voice, so you hear the result instead of
watching a screen. For example, an agent finishing a deploy might call `speak_summary` with the
text "Deploy finished, all green" and the category `deploy`, and Baton speaks it in the voice
you mapped to that category. See [Speaking summaries aloud](#speaking-summaries-aloud) for the
setup.

### Audio focus (ducking for a call or dictation)

Two more operations, `audio_suspend` and `audio_resume`, let another app duck or pause Baton
politely and then bring it back. This is how [Tonebox](https://tonebox.io) lowers the music
while you dictate or record, then restores it afterward. The key safeguard: Baton only restores
playback **if you didn't change it yourself in the meantime**. If you hit pause or started a
different track while the music was ducked, the other app's "resume" is a quiet no-op instead of
a fight over your speakers. These are coordination tools, not buttons; a well-behaved agent
won't surface them to you as actions.

### How it's secured

- The control server listens **only on your own machine** (loopback, `127.0.0.1`). It is not
  reachable from your network. An app on another computer simply cannot see it.
- Every request must present the **secret token** that Baton generates on first run. No token,
  no access. The token is compared in constant time, and it's stored where only your account
  can read it. The `mcp.json` file that carries it is readable only by you.

Both are required together, which is what keeps a local control interface from becoming a back
door. If an agent can't reach Baton, see [Troubleshooting](#troubleshooting).

For the deeper technical design (transport, protocol revision, notifications, and the socket
fast-path), see [`docs/04-integration-and-mcp.md`](docs/04-integration-and-mcp.md).

---

## Settings reference

Open Settings by pressing Command and comma. The panes are:

### Servers

Add, edit, remove, and switch between music servers. Each server keeps its own credentials in
the Keychain. See [Using more than one server](#using-more-than-one-server).

### Playback

- **Sound.** Loudness normalization (Off, Track, or Album) and its pre-amp; crossfade length;
  gapless playback and its Wi-Fi-only prefetch option; a button to clear the prefetch cache;
  autoplay of similar tracks when the queue ends; and a button to clear "radio bans" (tracks
  you've told an endless radio to stop suggesting). Covered under
  [sound quality](#sound-quality-gapless-crossfade-loudness) and
  [autoplay](#the-queue-shuffle-repeat-and-autoplay).
- **Downloads.** Offline mode; whether to remove finished podcast episodes automatically; the
  download folder (with buttons to choose a folder, show it in Finder, or go back to the
  default); and the filename format with its `{artist}`, `{album}`, `{title}`, and `{id}`
  tokens. See [Downloads](#downloads-and-offline-listening).
- **Scrobbling.** Your ListenBrainz token, your Last.fm connection, and the choice between
  scrobbles sent by Baton or handled by your server. See [Scrobbling](#scrobbling).
- **Advanced.** How many recent filter terms each browse screen remembers, and a button to
  clear that history.
- **Reset to Defaults.** Restores the Sound and Browse preferences. Your scrobbling accounts
  and your download folder are kept.

### Equalizer

The 10-band parametric equalizer, its presets, the per-band controls, and a live response
curve. See [The equalizer](#the-equalizer).

### Actions

Your webhook actions. See [Webhook actions](#webhook-actions).

### Speech

The text-to-speech servers and the category-to-voice map for spoken summaries. See
[Speaking summaries aloud](#speaking-summaries-aloud).

### About

Baton's version, its license (MIT), and a link to the website. Nothing to configure.

Each of the Playback, Equalizer, and Speech panes has its own **Reset to Defaults** button,
and each is careful to keep your credentials and servers when it resets.

---

## Updates

Baton updates with Sparkle, the standard macOS updater that many Mac apps use. There's a
**Check for Updates** item in the app menu, and Baton can check its own feed and install
signed, notarized builds so you don't have to reinstall by hand. The public update feed goes
live with Baton's first published release; until then the in-app status reads "Not available
yet" and you update by downloading the latest build yourself from
[baton.tonebox.io](https://baton.tonebox.io).

---

## What's next

Recently landed in Baton: the **Podcasts** and **Internet radio** tabs, the **Downloads and
offline** manager, the **parametric equalizer**, **multiple servers** and account switching,
spoken summaries (**Speech**), and the agent-built **`music_build_mix`**.

Still on the roadmap, called out here so the docs stay honest:

- **An iOS and iPadOS companion**, so you can listen away from the desk.
- **Casting beyond AirPlay**: Chromecast, Sonos, and UPnP/DLNA. AirPlay works today; wider
  casting needs protocol support Baton doesn't bundle yet.
- **Sonic-analysis mixes**, built from the actual sound of your music (tempo, energy, key),
  not just your play history.
- **Crossfeed and other DSP**, and a **lyrics fallback** (like LRCLIB) for when your server
  has no lyrics of its own.

The full roadmap is in [`docs/05-roadmap-new-features.md`](docs/05-roadmap-new-features.md).

---

## Privacy and security

- **Your credentials live in the macOS Keychain**, never in a plain text file.
- **Baton doesn't phone home by default.** It talks only to the music server you point it at,
  plus the scrobbling services and its own update feed if you turn those on, and any
  text-to-speech server you set up. It has no catalog server of its own to call. The one
  opt-in exception is crash reporting (Settings, About, Diagnostics, off by default): when you
  turn it on, Baton sends crash and error data to its developer via Sentry to help fix bugs,
  never your music, library, server address, or account, and no IP or identifiers.
- **The control server is loopback-only and token-protected.** It can't be reached from your
  network, and nothing on your Mac can drive it without the secret token. See
  [how it's secured](#letting-an-agent-control-your-music).

There's more on all of this in the [FAQ](FAQ.md#privacy-and-security).

---

## Troubleshooting

**Baton can't connect to my server.** Double-check the full URL, including `https://`, and
your username and password or API key. Baton verifies the connection before saving, so the
error it shows is the server's own reason. If your server uses a self-signed certificate or
an unusual port, make sure that address works in a browser first.

**A track won't play or keeps buffering.** Confirm the server is reachable and that you're
not in [Offline mode](#downloads-and-offline-listening) with a track you haven't downloaded.
Downloaded tracks always play from disk.

**An internet-radio station shows "On air" but stays silent.** Some stations are plain-HTTP
streams. Baton allows those for media playback, but a handful of stations simply go down or
change their stream URL. Try the station's homepage to confirm it's live, then re-add it with
the current stream URL.

**Loudness normalization doesn't seem to do anything.** It only works on tracks that carry
ReplayGain or R128 tags. Tracks without that data play at their normal volume. Many servers
can add these tags when they scan your library.

**An agent can't reach Baton.** Baton has to be running, and the agent needs the URL and
token from `~/Library/Application Support/Baton/mcp.json`. If the file's port looks wrong,
quit and reopen Baton; it picks a free port at launch and rewrites the file. See
[connecting an agent](#letting-an-agent-control-your-music).

**Spoken summaries are silent or use the wrong voice.** Check the server addresses in the
[Speech](#speaking-summaries-aloud) pane with the Test button. If a server is down and the
system-voice fallback is off, Baton reports an error rather than speaking; turn the fallback
back on to always hear something.

---

## Questions

The [FAQ](FAQ.md) has short answers to the common ones. For the vision, architecture, and
integration details, browse the docs in [`docs/`](docs/). Baton is made by
[Tonebox](https://tonebox.io), and given away for free.
