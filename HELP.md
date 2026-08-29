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
- [Baton on iPhone](#baton-on-iphone)
- [Shared settings between your devices](#shared-settings-between-your-devices)
- [Using more than one server](#using-more-than-one-server)
- [Finding your way around](#finding-your-way-around)
- [Browsing by folder](#browsing-by-folder)
- [Home (For You)](#home-for-you)
- [Search](#search)
- [Mixes](#mixes)
- [Albums and artists](#albums-and-artists)
- [Playlists](#playlists)
- [Liked](#liked)
- [Later](#later)
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
- [Finding music you don't have](#finding-music-you-dont-have)
- [Media keys and AirPlay](#media-keys-and-airplay)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Webhook actions](#webhook-actions)
- [Speaking summaries aloud](#speaking-summaries-aloud)
- [Reading what's on your screen](#reading-whats-on-your-screen)
- [Transcripts and summaries](#transcripts-and-summaries)
- [Letting an agent control your music](#letting-an-agent-control-your-music)
- [The music friend](#the-music-friend)
- [Controlling Baton from Telegram or Discord](#controlling-baton-from-telegram-or-discord)
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

## Baton on iPhone

Baton on iPhone plays the same library from the same server, and most of this guide applies
to it unchanged. Where the two differ, it's noted in the section itself. The main
differences: Settings is the last tab rather than a window you open with Command-comma,
there's no menu-bar controller, and there's no window to keep in a corner of a screen.

### Getting your Mac's setup onto your phone

Typing a server address, a username and a long password into a phone keyboard is the worst
part of setting up any music app, so there are three ways round it. All of them live under
**Settings → Set up from a Mac**, and the first two also appear on the first-run screen.

- **Scan a code.** On the Mac, open **Settings → Remote → Link a device → Show pairing code**. On
  the phone, choose **Scan a code from your Mac** and point the camera at it. Your server
  address, your sign-in and your settings come across encrypted, and there is nothing to
  type — not even a passphrase. Both devices have to be on the same network, because the
  code contains a local address the phone connects back to.
- **Import a file.** On the Mac, use **Settings → About → Back up & restore → Export…**, then get the file to
  your phone however you like — AirDrop, iCloud Drive, email. On the phone, choose **Choose
  an exported file**. If you exported it with your accounts included it's encrypted, and
  you'll need the passphrase you chose. This is the one that works when the two devices
  aren't on the same network.
- **Type it in.** **Connect to Navidrome** takes a server address, a username and a
  password, exactly as the Mac's first run does.

Your likes, ratings, playlists and play counts don't need any of this — they live on your
Navidrome server, and both apps read and write them as the same user, so they are already
the same on every device. What travels here is the things Navidrome has nowhere to keep:
your equalizer curve, crossfade, radio bans, your music friend's whole setup, and — because
pairing encrypts everything it sends — your server passwords, your scrobbling tokens and your
API keys. You sign in nowhere and paste nothing.

All three of these are a one-time transfer, though. To keep those settings in step from then
on, see [Shared settings between your devices](#shared-settings-between-your-devices).

### Where the Mac says "right-click"

Everything below describes the Mac, where a right-click opens the menu of things you can do
to a song, an album, an artist, a playlist or a station. **On iPhone, touch and hold instead.**
The menu that appears is the same one: Play, Play Next, Add to Queue, Add to Playlist, Like,
Rate, Download, Start Radio, Go to Album, Go to Artist, and the radio bans.

### Widgets, the lock screen, and Live Activities

Baton puts what's playing where you actually glance.

- **Home screen.** Add the **Now Playing** widget in the usual way — touch and hold the home
  screen, tap **+**, search for Baton. It comes in the three home-screen sizes.
- **Lock screen and StandBy.** The same widget also comes in the three accessory shapes:
  rectangular, circular and inline. Add it from the lock screen's own **Customize** screen.
  This is the one that matters most for a music app, because it's the surface you look at
  without unlocking anything.
- **A Live Activity while music plays.** Start something and a compact now-playing line
  appears on the lock screen with a progress bar that runs on its own — no unlocking, no
  opening the app. It's deliberately quiet: one muted icon, the title, and the artist a step
  down. It's telling you something you already know, so it shouldn't shout.

The widget draws artwork it already has on disk rather than fetching it, because a widget's
network access is throttled and the cover would simply never appear.

### Siri and Shortcuts

Baton answers Siri, and the same actions are building blocks in the Shortcuts app.

Say **"Play something in Baton"** or **"Play music in Baton"** and Siri asks what you'd like,
then searches your library and plays the results. **"Resume Baton"** picks up where you left
off. Siri can't yet take the album name in the same breath — that needs a kind of parameter
Apple only allows for fixed lists, so it asks rather than guessing.

In the **Shortcuts** app, search for Baton and you'll find: **Play music**, **Pause music**,
**Play or pause**, **Next track**, **Previous track**, **Like the current track**, and **Play
songs matching**. Use them in an automation the way you'd use any others — start a playlist
when you arrive somewhere, pause when a focus mode begins.

These run the same command surface the music friend and the app's own buttons use, so Siri
and the friend can never drift apart.

### How much data it uses

**Settings → Sound** has two quality settings, one for each kind of connection: **Wi-Fi
Quality** and **Cellular Quality**. Each takes **Original**, **High (320 kbps)**, **Medium
(192 kbps)** or **Low (128 kbps)**.

**Original** means no cap: the server sends the file as it is, which for a FLAC library is
the whole point of owning the files. That's also the setting most likely to matter on a
metered plan, which is why the two are separate — leave Wi-Fi on Original and put cellular on
Medium, and the phone does the right thing without you thinking about it.

Anything you've downloaded ignores both settings. It's already on the phone at whatever
quality it arrived.

### Face ID on your keys

The music friend's API key is money, and a phone in someone else's hand is already unlocked.
So on **Settings → Music Friend** the key and the gateway token stay masked until Face ID or
Touch ID passes.

Two things about it are deliberate. It falls back to your passcode, so a wet thumb or a mask
never locks you out of your own settings. And a phone with nothing enrolled is simply allowed
through, because there's no way to prove anything and refusing would lock someone out of a key
with no route back.

It is **not** an app-wide lock. Baton is a music player, and asking for your face every time
you come back to skip a track would be the worst feature in the app. It guards secrets and
nothing else.

### Making the phone yours

A few things on the iPhone bend to how you actually listen:

- **Edit the Library list.** Tap **Edit** on the Library tab to hide sections you never
  open and drag the rest into your order. New sections appear automatically even if you've
  customized the list.
- **Jump by letter.** Long alphabetical lists — Albums, Artists, Folders — have an A–Z
  rail along the right edge. Tap or drag it.
- **Search remembers.** The albums and artists you open from search wait under the empty
  search field next time.
- **Albums as a grid or a list.** The sort menu on Albums also switches the view style.
- **Keep the screen awake.** Settings → Display, for a phone propped on a dock. Off by
  default because it costs battery.

### The demo library

Baton needs a server, which makes an app with no server a locked door. There are two ways
through it, and they answer different questions.

**Try the demo** on the first-run screen opens a small library built into the app — real
tracks, played through the real engine — so you can see what Baton does before setting
anything up. Nothing about it touches the network.

**Use Navidrome's public demo server** fills in the sign-in for
`https://demo.navidrome.org` (username `demo`, password `demo`), the instance the Navidrome
project publishes for exactly this. That one is a real library over a real connection: a
few thousand Creative Commons tracks, artwork arriving over the wire, search against a
proper index. It is not our server, so it can be slow or offline — but it shows you what
Baton is actually for in a way four bundled tracks cannot.

Connect your own server whenever you like from **Settings → Connect to Navidrome**, and
either demo gives way to it.

---

## Shared settings between your devices

The three routes above are a *one-time* transfer: they carry your setup across once, and
after that the two devices drift apart. Change the equalizer on the Mac and the phone still
has the old curve. Shared settings is the ongoing version, and it is optional. Leave it
alone and both apps work exactly as they always have.

Your likes, ratings, playlists and play counts were never the problem: they live on your
Navidrome server, keyed to your user, and both apps read and write them as you. The problem
is everything Navidrome has nowhere to put, because there is no client-preference API and
there never will be. Those settings go through a small service you run yourself, called the
**gateway**, which is the one place both devices already sign in to.

### What travels, and what stays put

| Travels | Stays on the device |
|---|---|
| Equalizer: on/off, preset, band gains | Download folder and downloaded files |
| Crossfade, gapless, autoplay, repeat | Offline mode |
| Loudness mode and pre-amp | Demo mode |
| Radio bans | How far into a podcast episode you are |
| Podcast subscriptions | Every API key and password |
| Search and filter history | The "look outside my library" switch |
| Streaming quality, for Wi-Fi and for cellular | Your speech and transcription servers |
| Look up missing lyrics, scrobbling target | The experimental audio engine |
| Which discovery sources are switched on | Ducking and stall timeouts |
| The music friend: where answers come from, provider, model, base URL, and whether it speaks replies aloud | Appearance, and whether the screen stays awake |
| The friend's own switches: understand plain English, let it look around first, remember what you tell it | The play queue and your local play history |

Three of those deserve a word. **Your speech and transcription servers stay put** because
they are addresses of machines rather than choices about listening: the phone is rarely on the
same network as the Whisper box, and inheriting an address it cannot reach would look like a
broken setting. **Secrets never travel through sync** — keys live in the
Keychain, and putting them in a synced JSON file would be a downgrade in handling. They move
by pairing instead, encrypted, which is the one place they belong. So the friend's provider,
model and base URL keep themselves in step continuously; the key itself arrives once, when you
pair.

And the master switch for looking outside your library stays put on purpose: that one is
consent, and a phone should not inherit a decision the Mac made to start talking to strangers.

A full setting-by-setting account of what crosses and what doesn't is in
[`docs/settings-parity-mac-vs-iphone.html`](docs/settings-parity-mac-vs-iphone.html).

### Running a gateway

The gateway is a small Swift service in this repository, under `gateway/`. It runs on macOS
and on Linux, and it wants to live somewhere always on — the same box as Navidrome is the
obvious home. It needs a token you invent (both devices present it) and your Navidrome
sign-in, and it refuses to start without them:

```sh
export BATON_GATEWAY_TOKEN="a-long-random-string-you-make-up"
export NAVIDROME_URL="https://music.example.com"
export NAVIDROME_USER="you" NAVIDROME_PASSWORD="…"
swift run -c release baton-gateway          # listens on :8788
```

Full configuration, including running it under systemd or Docker and pointing its state file
at a mounted volume, is in [`gateway/README.md`](gateway/README.md).

Settings are kept in a plain JSON file on disk rather than in memory, because a restart is
routine and losing your settings to a bounced container would be worse than never syncing
them.

### Turning it on

**On the Mac**, open **Settings → Remote → Shared settings**. Paste the gateway's address
and token, click **Save token**, then **Test**. A pass tells you how many settings are
already shared, or that nothing is there yet and this would be the first device. After that
the Mac syncs on its own: at launch, whenever you switch back to the app, and on a slow
heartbeat while a window is left open. **Sync now** is there for when you don't want to wait.

**On the iPhone**, open **Settings → Music Friend** and set **Answers come from** to **Home
server**. The **Home server** section appears with the same two fields: the address and the
token from your gateway's configuration.

The green light on both means a request that just happened, not that the fields are filled
in — and editing either field clears it, because the old answer belonged to a different
address.

### When two devices disagree

Settled per setting, not per device. Each setting carries when it changed and which device
changed it, and the newest one wins — so two devices changing *different* things never clobber
each other, and the loser of a real race is one setting rather than everything you touched
that day.

Lists are the exception, because "newest wins" is the wrong rule for them: a search made on
the quieter device would vanish the moment the other one synced. Search history, filter
history and podcast subscriptions are **merged** instead. Subscriptions merge per show, so
unsubscribing on one device survives meeting a device that still had the show, and
resubscribing later survives the tombstone.

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

## Browsing by folder

The tag views — albums, artists, genres — are Navidrome's reading of your library. The
**Folders** view is the file system's: the directory tree exactly as it sits on disk, which
for a collection organized by hand often carries meaning the tags don't. If you have a
`Live bootlegs` folder, or a `1997` folder, or a folder per DJ set, that structure *is* your
filing system, and no amount of tag-reading will reconstruct it.

Open a folder to see its subfolders and its tracks in file order.

**Play means everything underneath.** Playing a folder plays every track inside it *and*
inside all of its subfolders, in order — so playing `Live bootlegs` plays the lot, not just
the handful of loose files at the top. On a very large tree Baton stops walking at some point
and tells you it did, rather than quietly playing a part of what you asked for.

It browses like the rest of the app, because it is the rest of the app:

- **Filter and sort** at the top, with the filter box remembering your recent terms.
- **List or grid**, whichever you prefer, remembered per screen.
- **Hover a folder** for a play button without opening it.
- **Right-click** for the same actions as a menu — play, queue, save to Later.
- **Select several** folders and act on all of them at once. Baton gathers the tracks under
  each one and treats them as a single pile.

On the Mac, Folders is a sidebar section. On iPhone it's a row in the Library tab. Both
browse the same tree, live from the server — nothing is duplicated locally.

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

### Search remembers two things, and both follow you

Baton keeps **what you typed** and **what you opened**, because they answer different
questions. The queries are the list under the clock icon in the search field on the Mac,
and under "Recent Searches" on the phone. The albums and artists you opened from a search
appear under "Recently Opened" — often the faster route back, since what you actually
wanted was the record, not the words you used to find it.

Both are shared between your Mac and your phone once
[shared settings](#shared-settings-between-your-devices) are set up (Settings → Remote). They're **merged, not overwritten**: a search made on one device is added to what
the other already had, rather than replacing it, so nothing you looked for disappears
because the other device synced more recently.

The opened albums and artists are remembered **per server**. They're stored as your
server's own ids, which mean nothing on a different library — so if you sign in to another
server you'll see that server's list, and switching back brings the first one with it.

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

The heart appears when you hover a row or a card, so it's there when you want it and out of
the way when you don't. It works the same on an album or an artist as on a song: hover, click
the heart, and it lands in the matching tab of **Liked**.

Likes are stored per user on your server (as Subsonic "stars"), so they're not just a Baton
thing. They travel with you to any Subsonic client, and back again.

---

## Later

**Later** is the pile of things you mean to get to. Someone sends you an album, you find a
podcast worth a proper sitting, a station catches your ear in passing: right-click it and
choose **Save to Later**, and it waits for you in one list.

It takes anything — songs, albums, artists, playlists, podcasts, and radio stations — and
keeps them together rather than scattering them across five screens. When more than one kind
is saved, buttons above the list let you narrow it to just the albums, or just the podcasts.
There's a filter box for the same reason, and the list/grid switch works here as everywhere
else. Clicking anything plays it, whatever kind it is.

**Later is not Liked, and it isn't the queue.** The three answer different questions:

| | What it means | Where it lives |
|---|---|---|
| **Liked** | I love this | On your server, as a star, shared with every Subsonic client |
| **Later** | I mean to get to this | On this Mac only |
| **Queue** | I'm listening to this now | Gone when you replace it |

Because Later is a note to yourself rather than a judgement about the music, it stays on the
machine you made it on and never touches your server. Take something off the list by
right-clicking it and removing it, or clear the whole list at once from the same place.

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

### Whose plays you're looking at

Your Navidrome server records every play, from every device, against your user — so it has
always been the real record. Baton also keeps a small log on each device, which is what
makes History open instantly and work with no connection.

On iPhone, **Recent** reads from the server by default, so it includes what you played on
the Mac; switch to **This iPhone** for the on-device log. **All-time Top Tracks** has always
come from the server. The windowed rankings ("This Week", "This Month") can only come from
the device, because Subsonic keeps a running count rather than a dated event log — so those
are per-device by nature, not by choice.

Clearing history on a device clears only that device's log. Your server's play counts are
untouched.

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
- **Your shows follow you.** Subscribe on the Mac and the show appears on your iPhone, and
  the other way round. Unsubscribing travels too: drop a show on one device and it goes on
  the other, rather than being handed back the next time they talk. This rides the same
  device sync as your other settings, so it needs a gateway set up — see
  [Shared settings between your devices](#shared-settings-between-your-devices).
  Where you are in an episode is still per-device.
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
- **Your stations are already everywhere.** Unlike podcasts, stations live on your server
  rather than on the device, so a station you add on the Mac is simply there on your iPhone
  the next time it loads the Radio tab — no sync to set up, and nothing to keep in step.

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

### The little bars that mark what's playing

Wherever a track appears in a list — search results, an album, the queue, a folder — the one
you're listening to is marked by a small set of moving bars instead of a static symbol. They
tell you two things at a glance: which row is current, and whether it's actually running. A
paused track holds its bars still rather than pretending.

**They move with the music, not on a loop.** The bars are driven by the sound itself, read in
four frequency bands as it plays, so they lift with the bassline and flicker on the hi-hats.
Where that reading isn't available — internet radio, or the first second of a track before
any audio has arrived — they fall back to an even animation that looks much the same. The
difference is that one of them is telling the truth.

If you have **Reduce Motion** turned on in macOS, the bars are drawn at rest instead of
moving. They still mark the row; they just hold still.

### Full-screen Now Playing

Open the full-screen player for big artwork, a soft backdrop tinted from the album art, and
a **waveform scrubber** for tracks you've downloaded. Along the side are panels for the
**Queue**, **Lyrics**, and **Related** tracks. Press **Space** to play or pause, and
**Escape** to leave full-screen.

### Lyrics

The **Lyrics** panel shows words for whatever is playing. When they arrive with timings they
scroll karaoke-style and you can tap or click a line to jump to it; without timings you get
plain text.

Where they come from is worth knowing, because it explains an empty panel. Navidrome only
serves lyrics that are **embedded in your files**, and most libraries have very few of those,
so for most people this panel starts out blank no matter what is playing.

Turn on **Look up missing lyrics** — **Settings → About** on the Mac, **Settings → Sound** on
iPhone — and Baton asks [LRCLIB](https://lrclib.net), a free and open lyrics database, for
anything your server doesn't have. It sends the track's title, artist and length, and nothing
else: not your library, not your history, not who you are. Lyrics embedded in your own files
always win, so turning this on never overwrites what you already have.

Podcast episodes don't use this. They get [transcripts](#transcripts-and-summaries) instead,
which are a different thing built a different way.

### The floating mini-player

Baton has a borderless, always-on-top **mini-player** window (press Command, Option, and M).
It's a compact card you can park in a corner while you work in other apps, showing the
current track, artwork, the scrubber, the rating, and what's up next, and it expands for a
little more. On macOS 26 and later it's drawn with Liquid Glass.

### The mini player on iPhone

On the phone, the now-playing bar is a small capsule floating above the tabs: artwork, the
track title, play/pause, next, and an ✕ that ends the session. Tap anywhere else on it for
the full player.

On iOS 26 and later, the bar also **gets out of the way while you browse**. Scroll down any
list and the tab bar shrinks to just the current tab's icon, with a slimmer player — artwork,
title, play/pause — docking beside it, so one compact row is all the screen gives up while
you're reading. Scroll back up, or tap the shrunken bar, and the full tabs and controls
return exactly as they were. No tab ever disappears for good; the row only stays small while
you're actively scrolling away from it.

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

The preset name always describes the curve you actually have, rather than the last button
you pressed. Move a band and it becomes **Custom**; move every band back to zero and it says
**Flat** again, because that is what Flat is. Choosing a preset replaces the whole curve, so
anything you had hand-tuned is gone — there's a **Flat / Reset** button when you want to
start over.

**What it affects.** On the standard player the equalizer applies to **downloaded tracks**,
not to music streamed from your server. That is a platform limitation rather than a
setting: the audio tap Baton uses to filter playback does not run for a streamed item, on
either the Mac or the phone. It has always been that way, and Settings used to imply
otherwise — this is the honest version.

To equalize streamed music, turn on **Settings → Advanced → Experimental audio engine**,
which plays streams through Baton's own audio pipeline where the equalizer is a real part
of the chain. It costs noticeably more power, so it is off unless you ask for it. The
equalizer screen tells you which of the two situations you are in.

On iPhone this lives under **Settings → Equalizer**, with the bands behind the **Bands** row.

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

Scrobbling is the record of what you listened to — and it is what most of the rest of Baton
is built out of.

That record is where **Home** gets its shelves, where **Rediscover** finds the album you
loved two years ago and haven't played since, and what the automatic **Mixes** are assembled
from. It is also how Baton set up your own playback: after about twenty plays it looks at
whether you listen straight through albums or hop between single tracks, and turns on gapless
or crossfade accordingly, once, without asking. None of that is possible about a library it
has never watched you use. Turn scrobbling off and Baton still plays everything perfectly
well; it just stops being able to tell you anything you didn't already know.

Baton can report your listens to three places:

- **Your Navidrome or Subsonic server**, which updates its own play counts. This always
  happens.
- **[ListenBrainz](https://listenbrainz.org/)**, if you paste your user token in Settings,
  under Playback.
- **[Last.fm](https://www.last.fm/)**, if you connect your account there. Last.fm uses a
  browser authorization: enter your API key and shared secret, click to authorize in the
  browser, approve, and come back to finish.

A track counts as played once you've heard **half of it, or four minutes, whichever comes
first** — the usual scrobbling convention. In practice:

- A 3-minute song counts at **1:30**.
- A 7-minute song counts at **3:30**.
- A 20-minute mix counts at **4:00**, not at ten minutes.

Baton reports "now playing" to your server the moment a track starts, and the completed play
when you cross that point, so skipping through the first thirty seconds of a dozen tracks
never gets miscredited as having listened to them. Podcasts and internet radio are never
scrobbled.

If your **server** is already linked to Last.fm or ListenBrainz, you can avoid
double-counting by switching scrobbling to **Handled by my server** in the same pane. The
default is **Sent by Baton**. Either way, your server's own play counts are always tracked.

> [!TIP]
> Scrobbles you make while offline aren't lost. Baton keeps a durable queue and submits them
> once you're back online.

---

## Finding music you don't have

Everything else in Baton looks *inside* your library. "More like this" finds the neighbours
of a track among the songs you already own, which is the right answer right up until the
moment you've heard them all.

**Looking outward** asks the same question of the public music catalogues instead: given this
artist, what else is out there. Turn it on in **Settings, Playback**, then right-click any
track or artist and choose **Find more like this**, or just ask the music friend — *"find me
more like this"* — on the Mac, on your phone, or over Telegram.

Results are things you can act on rather than a list of names: where the source gives a link,
Baton gives you the link.

> [!IMPORTANT]
> This is the one feature that talks to a service that isn't your own server. Asking
> "what sounds like Aura?" tells the catalogue you were listening to Aura. That's a small
> disclosure and an obvious one, but it's yours to make, so it's **off until you turn it
> on** — and it sends the artist and title, nothing else. Not your library, not your
> history, not who you are.

### The four places it looks

Two need nothing from you at all, which is why this is worth having before you go and
collect API keys:

| Source | What it gives you | Needs |
|---|---|---|
| **MusicBrainz** | Identity — which "Aura" you actually mean | Nothing |
| **ListenBrainz** | Related artists, ranked by what real people play in the same sitting | Nothing |
| **Last.fm** | Track-by-track similarity, finer-grained than the above | An API key |
| **YouTube** | Something you can press play on immediately | An API key |

A source with **no key is off, not broken**. Baton says which ones are quiet and why, and
gets on with the answer from the ones that aren't. If you never add a key, you still get
related artists — you just don't get the YouTube links.

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
| Skip back ten seconds | Option, Command, Left |
| Skip forward ten seconds | Option, Command, Right |
| Volume up | Command, Control, Up |
| Volume down | Command, Control, Down |
| Mute or unmute | Command, Control, M |
| Like or unlike the current track | Command, Control, L |
| Rate the current track | Command, Control, 1 to 5 |
| Clear the rating | Command, Control, 0 |
| Get info about the current track | Command, I |
| Show the queue | Command, U |
| Collapse or expand the player bar | Command, Control, J |
| Open the mini-player | Command, Option, M |
| Open the equalizer | Option, Command, E |
| Open the music friend | Command, Shift, F |
| Open Settings | Command, comma |

**Get Info** (Command, I, or **Get Info** in a row's right-click menu) opens a sheet on the
track itself: codec, bitrate, bit depth, sample rate, channels and file size, alongside how
many times you've played it and when you last did. If the track is downloaded, it shows you
where on disk it is. Every field is read straight from your server's own metadata — nothing
is guessed, and a blank field means your library doesn't carry that tag.

And for moving around your library:

| Action | Shortcut |
|---|---|
| Go to a section in the sidebar | Command, 1 to 9 |
| Find | Command, F |
| Show what's playing now | Command, 0 |
| Refresh the library from the server | Command, R |
| Replay the last spoken summary | Command, Control, R |
| Stop speaking | Command, Control, period |

The Playback menu also holds **Shuffle**, **Repeat**, and the **Sleep Timer**. In the
full-screen player, **Space** toggles play and pause and **Escape** exits.

In song lists — Liked, search results, and the tracks inside an album or playlist — click the
list once, then use the **up and down arrows** to move through it. **Return** plays the
highlighted track and **Command and Return** queues it up next. **Command and A** selects
everything, and in the queue the **Delete** key removes the row you're pointing at.

Baton also follows the system **Reduce Motion** setting (System Settings → Accessibility →
Display). Turn it on and the continuous animations — the breathing artwork in the full-screen
player, the equalizer bars, the zoom on hover — hold still, while hover and selection stay
just as visible.

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
- **`session`**: a short name for the agent itself, usually the repo it's working in.
  Baton shows it at the top of the summary window, above the transcript, so a glance
  tells you who is talking. It's remembered for the rest of that agent's connection,
  so the agent sends it once and later lines inherit it, and it can send a new name
  later to re-label itself. The name is never read aloud, so it costs you no
  listening time and doesn't have to be short enough to say comfortably.
- **`mode`**: how the line reaches you (see below).

So with two agents running you hear only the summaries themselves, "Env labels
shipped." then "OCR queue drained.", while the window tells you which one each came
from. Lines never overlap either, because Baton queues them and plays them in order.

Earlier versions read the name aloud whenever the speaker changed. Showing it works
out better: it's there on every summary rather than only the ones that switched
agents, and you get the summary a beat sooner.

### One voice per agent

Give each agent its own voice and you know who finished without looking at anything. The
name above the transcript tells you once you look; the voice tells you before you do.

In **Settings → Speech → Agent voices** you keep a list. Each row is a label and a voice,
with a button to hear it. Add as many as you like:

- The **label** is normally what the agent sends as its `session` name, usually the repo it
  is working in. It is matched loosely, so case and stray spaces do not matter, and it is
  free text: "night build" works as well as a repo name.
- **Add one Baton has heard** fills the label in for you from the agents that have already
  spoken, so you do not have to guess the exact spelling.

Anything **not** in the list speaks in a voice from outside it. That is the useful half of
the rule: a project you named never shares its sound with one you did not. Unlisted agents
still sound the same every time, worked out from the name, so you can learn to recognise one
before you get round to adding it.

An explicit `voice` in the tool call beats all of this, and the category map below still
applies to summaries with no agent name at all.

### One voice per category (the voice map)

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

### Bluetooth speakers and the missing first word

A Bluetooth speaker powers its radio down when nothing is playing, and takes a moment
to come back when something does. That moment lands on the start of the summary, so
the first word or two goes missing and you hear "...finished, all green".

Baton holds a moment of silence before speaking to let the link wake up first. It does
this **only** over Bluetooth: on the built-in speakers, or anything wired, there is
nothing to wake and nothing is delayed. It also keeps its audio running for a short
while after a summary, so a burst of them pays the wake-up once instead of every time.

The wait is **Settings → Speech → Delivery → Bluetooth head start**, 0.7 seconds by
default. Speakers vary by more than double, so if you still lose the beginning, raise
it. Baton measures what your speaker actually took and writes it to the system log, so
you can set the slider from that rather than by guessing: look for "bluetooth link woke
in" in Console.

### The voices themselves

When Baton speaks, the actual voice comes from a **text-to-speech (TTS) engine**. You have
three options, from zero-effort to best-quality:

1. **Nothing at all — the built-in Mac voice.** If you set nothing up, Baton uses macOS's own
   speech (the same engine as VoiceOver). It just works, offline, no install. The voice is a
   bit robotic, but a summary is never dropped.
2. **Kokoro** — a small, free voice server you run yourself. Fast, natural-sounding, 50+ preset
   voices (including Spanish). Runs on any Mac or PC **with no graphics card**.
3. **Chatterbox** — a higher-quality voice server that can also **clone a voice** from a short
   sample. Needs an **NVIDIA graphics card (GPU)**, so it usually lives on a separate machine.

Everything below is optional — set up as much or as little as you like. Baton talks to both
servers the same way (the OpenAI "audio/speech" format), so any service that speaks that format
can be plugged in, self-hosted or cloud.

#### Which one should I use?

| | **Mac built-in** | **Kokoro** | **Chatterbox** |
|---|---|---|---|
| Setup effort | none | a few minutes | more involved |
| Needs a GPU? | no | **no** (runs on CPU) | **yes** (NVIDIA) |
| Voice quality | basic | very good | best |
| Voice cloning | no | no | **yes** |
| Best for | trying it out | everyday summaries, ops/alerts | premium or cloned voices |

A good path: start with the **Mac voice** to see the feature, add **Kokoro** for pleasant
everyday voices, and only add **Chatterbox** if you want top quality or a cloned voice.

#### Where does the voice server run? (this Mac vs another machine)

A "voice server" is just a small program that turns text into audio and answers over your
network. It can run either place:

- **On the same Mac as Baton (local).** Simplest. The address is `http://127.0.0.1:<port>` —
  `127.0.0.1` means "this machine." **Kokoro** is perfect here because it needs no GPU.
- **On another machine on your network (remote).** For example a Linux box with an NVIDIA GPU
  for **Chatterbox**. You reach it by that machine's name (`http://mybox.local:<port>`) or its
  LAN address (`http://<your-lan-ip>:<port>`).

Either way there's **no cloud account and nothing leaves your own network** — this is different
from a hosted service like ElevenLabs, where your text is sent to someone else's servers.

#### Setting up Kokoro (no GPU needed)

Kokoro ships as a ready-to-run container. On the machine where you want it (your Mac, or any
always-on box) with [Docker](https://docs.docker.com/get-docker/) installed, run:

```sh
docker run -d --restart unless-stopped -p 8880:8880 \
  ghcr.io/remsky/kokoro-fastapi-cpu:latest
```

That's the whole install — Kokoro now answers at `http://<that-machine>:8880`. (`-d` runs it in
the background; `--restart unless-stopped` brings it back after a reboot.) Confirm it's alive:
`curl http://localhost:8880/health` should return `200`.

> Use the **CPU** image above — it works everywhere and is plenty fast (a short sentence in well
> under a second). There's a GPU image too, but for a model this small the GPU buys nothing.

#### Setting up Chatterbox (needs an NVIDIA GPU)

Chatterbox is built from its project repo and needs an NVIDIA GPU with recent drivers
(CUDA 12.8+). With Docker installed on that machine:

```sh
git clone --depth 1 https://github.com/devnen/Chatterbox-TTS-Server.git
cd Chatterbox-TTS-Server
docker compose up -d --build        # serves on port 8004
```

It then answers at `http://<that-machine>:8004`. The first build takes a while (it downloads the
voice model). To use a **cloned voice**, drop a 5–10 second `.wav` sample of the target voice
into its voices folder; it shows up in Baton's voice list by filename (e.g. `Emily.wav`).

> Chatterbox is the heavier engine — reach for it when you want the best quality or a custom
> cloned voice, not for every routine "build finished" line.

#### Pointing Baton at your server(s)

Open **Settings → Speech** and enter the address for whichever engine you set up:

- **Kokoro base URL** — e.g. `http://127.0.0.1:8880` (same Mac) or `http://mybox.local:8880`
  (another machine).
- **Chatterbox base URL** — e.g. `http://mybox.local:8004`.

Press **Test this connection**. Baton shows a green check with the number of voices it found, or
the error if it can't reach the server. Once connected, each row of the [voice
map](#one-voice-per-agent-the-voice-map) gets a voice picker (populated live from that server)
and a ▶︎ **Preview** button, so you can hear a voice before assigning it.

> [!NOTE]
> **First connection to another machine:** modern macOS asks permission before an app talks to
> devices on your local network, so the very first test may fail once with an "offline"-sounding
> error. Approve Baton under **System Settings → Privacy & Security → Local Network** and test
> again. It's a one-time macOS permission, not a Baton problem. (A server on the *same* Mac via
> `127.0.0.1` isn't affected.)

> [!NOTE]
> You don't have to run any of this. With no servers set up (or if one is unreachable), Baton
> falls back to the built-in macOS voice, so `speak_summary` always works and a line is never
> silently dropped. The fallback is on by default; turn it off in Settings → Speech if you'd
> rather an unreachable server report an error. Deeper operator notes (self-hosting specifics,
> GPU tips) live in [`docs/tts-speak-summary.md`](docs/tts-speak-summary.md).

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

### Controlling when an agent speaks

`speak_summary` is a tool the agent *chooses* to call — Baton never speaks on its own. So
**you** decide when a summary is read aloud, either per request or as a standing rule.

**Per request (no setup).** Just ask for it in the moment:

> "Run the tests and **say** the result when you're done."
> → the agent runs the tests, then calls `speak_summary` with something like "All 467 tests
> passed" — and stays silent on the next task unless you ask again.

**A standing rule (Claude Code).** Put a one-line instruction in a `CLAUDE.md` — `./CLAUDE.md`
for one project, `~/.claude/CLAUDE.md` for all of them. Two useful shapes:

- **Opt-in (recommended) — silent unless asked:**

  ```md
  Spoken summaries: default do NOT speak. Only call `mcp__baton__speak_summary` when I
  explicitly ask in that message (e.g. "…and say", "speak the summary"). Then speak one
  short sentence (voice `af_bella`). If Baton isn't connected, skip silently.
  ```

- **Always — a spoken line after every task:**

  ```md
  When you finish a task, call `mcp__baton__speak_summary` with a one-sentence summary
  (voice `af_bella`). If Baton isn't connected, skip silently.
  ```

**A standing rule (Cursor).** The same idea lives in a Cursor **Rule** — add a project rule in
`.cursor/rules/` (or a global rule under Cursor → Settings → Rules) with the same wording,
e.g.:

```md
Spoken summaries: default do NOT speak. Only call the baton `speak_summary` tool when I
explicitly ask in that message (e.g. "…and say", "speak the summary"). Then speak one short
sentence (voice `af_bella`). If Baton isn't connected, skip silently.
```

Pick a voice per line with the `voice` input (`kokoro:af_bella`, `chatterbox:Emily.wav`, or a
bare id like `af_nova`), or let the [voice map](#one-voice-per-agent-the-voice-map) choose by
`category`. A `CLAUDE.md` or Cursor rule takes effect on the **next** session — a running one
won't reload it mid-task — and Baton must be running for the call to land.

---

## Reading what's on your screen

Baton can read text out loud from wherever you're working: an article in Chrome, a wall of
build output in a terminal, a changelog, a long email. You select the text, Baton speaks it in
the same voice it uses for spoken summaries, and your music ducks underneath and comes back at
the same level afterwards.

**This is not a screen reader in the accessibility sense.** VoiceOver reads interfaces, and it
does that far better than Baton ever will. This reads *content*, when you ask for it. If you
need something to describe buttons and menus as you move through them, VoiceOver is the tool.

**Nothing watches your screen.** Baton has no idea what is on it until you select something and
ask. Nothing runs in the background looking for things to read: every reading happens because
you started it, at the moment you started it. That is a deliberate limit rather than a feature
still to come.

**Readings are not saved.** A reading plays once and is gone. It does not appear in Spoken
Summaries, which stays a record of what your agents told you. Two things you can ask for are the
exceptions, and both are below: keeping one as an audio file, and picking up an article you
stopped part-way.

### Ways to start a reading

**Services, which needs no permission at all.** Select some text, then choose **Services →
Speak with Baton** from the application menu (or right-click the selection). The system hands
Baton the text; Baton doesn't reach into anything, so there is nothing to grant and nothing
to set up.

**A keyboard shortcut, which you choose.** Settings → Speech → Read aloud has a recorder: click
it, press the combination you want. There is **no shortcut set out of the box**, so Baton can
never collide with something you already use. The shortcut asks the app you're in for your
selection, and macOS gates that behind **Accessibility** — Baton asks the first time you press
it, and explains why.

**Reading a whole pane, not just a selection.** Hold **Shift** with your shortcut and Baton
reads the whole thing you're focused on rather than what you've highlighted — the entire
scrollback of a terminal, say, when you'd rather not select it first. This one depends on the
app being willing to hand over its contents, and browsers are not: in Chrome it does nothing,
so select the part you want and use the plain shortcut there.

**Reading something with no text at all.** A PDF, an image, a screen shared from another
machine: there is nothing to hand over, so Baton can photograph the front window and read what
it can see. This is off until you turn it on in Settings, because it needs Screen Recording,
which is the largest thing Baton ever asks for. Once it is on, hold **Option** with your
shortcut. Baton captures only when you press it, only the window in front, and the picture is
never saved.

**An agent hands it over.** Baton's `read_aloud` tool takes text an agent already has and
reads it, which is the practical answer for a web page. Pulling the *article* out of a page,
rather than the navigation and the cookie banner, is real work, and an agent driving the
browser has already done it. It passes Baton the text and Baton reads it. You do not need to
switch anything on or grant anything, because the text arrives over the connection Baton's
other tools already use.

**The gist instead of the whole thing.** For a long article, **Services → Summarize with
Baton** speaks a few sentences rather than reading every one. This is the one part of Read
aloud that needs a model configured (Settings → Remote); without one it says so rather than
doing nothing. The text is cleaned and stripped of anything credential-shaped before it reaches
the model, not just before it reaches the speaker.

### Why some apps need the clipboard

Apps differ in how willing they are to hand over your selection, and browsers are the awkward
case. A terminal like Ghostty hands it straight over. **Chrome does not** — it exposes page
text in a way the ordinary route can't read, so for Chrome and most other browsers Baton falls
back to copying the selection, reading it, and putting your clipboard back the way it was.

That fallback is on by default because otherwise the shortcut would simply do nothing in a
browser, which is where most reading happens. Two honest caveats:

- Your clipboard is replaced for a fraction of a second. Baton restores everything it found,
  including images and files, but a clipboard manager watching in the background may still
  record the intermediate value.
- You can switch it off in Settings → Speech → Read aloud. The shortcut will then do nothing
  in apps that won't share their selection, and Services will still work everywhere.

### What Baton does to the text before speaking it

Read aloud is mostly about *not* reading things to you. Before a word is spoken, Baton:

- **Removes anything that looks like a credential.** API keys, tokens, bearer headers and
  private keys are replaced with "a redacted token" rather than spoken. Terminals have secrets
  on screen more often than anyone likes to admit.
- **Cleans up terminal output.** Colour codes and cursor commands disappear, the prompt is
  dropped but the command you typed is kept, and if your selection spans several commands only
  the last one's output is read — that's almost always the one you selected it for.
- **Skips what can't be listened to.** A commit hash becomes "a forty-character hash", a UUID
  becomes "a UUID", a link becomes "a link to example.com", and a block of code is announced as
  "Swift code block, twelve lines" instead of having its punctuation pronounced.
- **Trims web furniture.** Navigation, cookie banners and "back to top" lines are dropped.

### While it's reading

The speaking window shows the whole reading and highlights the sentence being spoken, scrolling
along as it goes. Pause, resume and stop work throughout, and skipping back ten seconds works
within the current sentence. There's no scrubber for a reading: Baton speaks a document as a
run of sentences rather than one long clip, which is what lets it start talking about a second
after you ask instead of after the whole thing has been prepared.

If your text-to-speech server is unreachable, a reading falls back to the built-in macOS voice
rather than failing, exactly as spoken summaries do.

### A different voice per app

Off by default. Turn on **Use a different voice per app** in Settings → Speech → Read aloud and
a browser and a terminal read in different voices, so you can tell where the text came from
without looking. The two voices are the `browser` and `terminal` rows in the voice map on the
same screen, and you can change them like any other.

### Keeping a reading

**File → Save Reading as Audio…** (⇧⌘S) turns the last thing Baton read into a single M4A
file. Read a long article at your desk and listen to it on a walk.

Nothing changes if you never use it. Readings still play once and disappear, and the only thing
ever written is the file you asked for, in the place you chose for it. Baton asks where to put
it every time on purpose: a folder that quietly filled up with everything you had ever listened
to is exactly the persistence this feature promises not to do.

Because nothing was kept, Baton reads the article again to make the file, so a long one takes a
moment. It happens in the background and you can carry on. The file comes from the same cleaned
text you heard, so a credential Baton removed cannot reappear in the audio. If your
text-to-speech server is unreachable, Baton makes the file in the built-in voice, exactly as a
live reading would.

The reading stays available until you read something else, so stopping one half way through and
then saving it still gives you the whole thing.

### Picking up where you left off

Stop half way through a long article and Baton keeps your place. **File → Resume Reading** lists
what you were in the middle of and carries on from the sentence you had reached, not from the top.

This is the one place Baton keeps the text of a reading, so it is worth being exact about what
that means. It holds up to five unfinished readings for seven days, and what it holds is the
cleaned text you actually heard: anything shaped like a password or a key was removed before a
word was spoken, so it was never written down either. Finish an article and its entry goes. You
can also forget the lot at any time, from the same menu or from Settings → Speech → Read aloud,
which shows how many are being held.

It stays on this Mac. Where you got to in an article is like where you got to in a podcast, so it
does not travel to your iPhone.


## Transcripts and summaries

Spoken audio is the one thing in a library you cannot skim. Baton can turn a podcast episode
into a transcript with a timestamp on every line, so you can read along, find the part you
half remember, and jump straight to it.

Open the full-screen player and pick the **Transcript** panel (on iPhone, the
`text.viewfinder` button under the artwork). Press **Transcribe** and Baton sends the episode's
audio to a Whisper server you run, then keeps what comes back. The current line highlights and
scrolls as the episode plays, exactly as synced lyrics do, and tapping any line seeks to it.

Once a transcript exists it lives on disk, so opening it later costs nothing and works with the
server switched off.

Songs work too, though they are a harder problem than speech, and how well they work depends
almost entirely on which recognizer you point Baton at. WhisperX reads sung vocals, so expect
the verses and the chorus roughly right, rather than a match for the printed lyric. A plain
faster-whisper server tends to give up on singing and return the same word over and over
instead. Baton drops those runs rather than showing them to you, so a recognizer that cannot
hear the singing reports no speech instead of reporting nonsense. If that happens on a track
you know has words in it, the recognizer is the thing to change. And if a track really is an
instrumental, the panel says there was no speech in it and points you at the Lyrics panel.

### Setting it up

Transcription is off by default, because it uploads audio to a server. Switch on
**Transcribe spoken tracks** and give Baton the address of an OpenAI-compatible transcription
endpoint, the same shape the Kokoro and Chatterbox hosts above use. On the Mac that lives in
**Settings → Speech → Transcription**; on iPhone it is **Settings → Transcription**, near the
bottom of the list. `faster-whisper` behind its OpenAI-compatible server is the usual
choice. Baton checks the address as soon as you open the screen and shows what it found: a
tick and the number of models when the host answered, a warning and the reason when it did
not. The refresh button next to the field asks again. Editing the address clears the tick,
because it belonged to the address that was checked rather than to the field.

Every service you can configure works this way now, on both apps: the music server, both
speech hosts, the recognizer, ListenBrainz, Last.fm, the shared-settings gateway and each
discovery source. A green light always means a request that just happened, never that a key
is filled in.

If you run more than one model, put its id in **Model**. Leave it alone and Baton asks for
`whisper-1`, which is what most of these servers answer to.

### Summaries and chapter marks

**Summarize** turns a transcript into a short overview plus a list of timestamped sections.
The sections are the useful half: each one names what that stretch of the episode is about, and
tapping it seeks there. It works by summarizing the episode ten minutes at a time and then
summarizing those summaries, which is what lets a model with a small context handle an hour of
speech.

**Summarize** sits under the transcript itself: at the foot of the panel on the Mac, and at the
top of the sheet on iPhone. It uses the model configured for the music friend (**Settings →
Remote** on the Mac, **Settings → Music Friend** on iPhone), so set one up there first or the
button will tell you there is nothing to summarize with. If that model is not on your own network, Baton refuses and says so: a transcript is
everything that was said in something you listened to, and that is not the kind of thing to
send to a hosted API on the strength of a setting you made for something else. Point it at a
model on your LAN and the question does not arise.

### What it does not do

Baton never transcribes on its own. There is no background pass over your library and no
transcription when you subscribe to a feed. One episode is a minute or two of work on a GPU,
so a library of them would be hours. The button is offered for podcast episodes; music keeps
its lyrics, which come from your server or LRCLIB and cost nothing.

If the transcription server cannot be reached, the panel says **unavailable** rather than
showing an error. Away from home that is simply the normal state of affairs, and a phone on
cellular should not be told something is broken when it isn't.

Agents get at all of this too. `music_transcript` reads a window of the transcript and
`music_summarize_track` reads the summary, so you can ask your assistant what an episode said
about something without playing it back yourself. Both take a start and end time, so an agent
reads the part it needs instead of the whole hour.

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
  "app": { "bundleId": "io.tonebox.baton", "version": "0.6.x" }
}
```

You connect a client by pointing it at that **url** over the **Streamable HTTP** transport and
passing the **token** as a bearer token in the `Authorization` header. Both values come
straight out of `mcp.json`. The token above is shortened for display, and **app.version** is
whichever build of Baton is running — yours will show its real values.

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

**Cursor.** Same `mcpServers` block, in `~/.cursor/mcp.json` (all projects) or
`.cursor/mcp.json` (one project). Cursor infers HTTP from the `url`, so the `type` field
isn't needed:

```json
{
  "mcpServers": {
    "baton": {
      "url": "http://127.0.0.1:8787/mcp",
      "headers": { "Authorization": "Bearer <token-from-mcp.json>" }
    }
  }
}
```

Then enable **baton** under Cursor → Settings → MCP; its tools appear to the agent there.

Baton has to be running for any of this to work, which is another reason for the
[menu-bar controller](#playing-music): it keeps Baton (and the server) alive in the
background even with every window closed.

### What an agent can do

The control server exposes **40 music operations**. They're the same actions Baton's own
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

**Explore the library:**

Searching answers "is this in here". These answer "what *is* in here", which is what a
recommendation has to start from — an agent that can read your genres and what you actually
play can suggest something from your collection instead of guessing at song titles.

| Tool | What it does | Main inputs |
|---|---|---|
| `music_list_genres` | List the genres in your library with song counts — the vocabulary it really uses, which is rarely the words people say | `limit` |
| `music_browse_albums` | Browse albums by kind rather than by search: random, newest, most-played, recently played, liked, by genre, by year | `type`, `genre`, `from_year`, `to_year`, `limit` |
| `music_similar_songs` | Songs your server considers similar to a track or artist — real neighbour data, not a keyword match | `song_id` or `query`, `limit` |
| `music_discover_external` | Music you *don't* have, from public catalogues — the outward-facing twin of the one above. Off unless you turn it on | `artist`, `title`, `limit` |
| `music_liked` | Your liked songs, albums, and artists | `limit` |
| `music_random` | Random songs, optionally within a genre or year range | `genre`, `from_year`, `to_year`, `limit` |
| `music_artist_info` | An artist's biography and every album of theirs you have | `artist_id` or `query` |

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
| `music_set_crossfade` | Set the crossfade length between tracks, in seconds (0 turns it off) | `seconds` |

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
| `music_get_playlist` | Read one playlist's tracks | `name` or `playlist_id` |

**Report and shape sound:**

| Tool | What it does | Main inputs |
|---|---|---|
| `music_now_playing` | Report the current track, playback state, and queue position | none |
| `music_recent_events` | What was played recently and how long each was heard before moving on, including skips | none |
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

## The music friend

Baton has a music friend: ask for something in plain language and it works out what you
meant, then does it with your library and your player. "Something calmer", "what is this?",
"play the live version instead" — it has the same hands you do.

Open it on the Mac from **Go › Music Friend**, or press **⌘⇧F**. On iPhone it is the
**Friend** tab, which appears once a connection test has passed. Setting a provider is not
enough on its own: a key with a typo in it is still a key, so Baton waits until it has seen
one real request succeed before offering you a tab that promises to answer.

It is one friend, not three. The window on the Mac, the tab on the phone, and the chat
bridges below all run the same conversation, so what it has learned about you in one place
it knows in the others, and a thumbs-down you give here counts the same as one you give in
Telegram.

**Plain commands stay plain.** "Pause", "next", "louder" and their like are understood
directly and answer immediately, without asking a model anything. That keeps the obvious
things instant and free; the model is for the requests that actually need thinking about.

**You have to bring the brain.** Baton ships no key and talks to no model provider until you
set one up — point it at Anthropic, at OpenAI, or at something running on your own machine.
Until then the friend has nothing to answer with.

### Turning it on, on the Mac

The setting lives in **Settings, Remote**, which is also where the Telegram and Discord
bridges are. That pane is about everything that answers you in words, not just the chat
apps, so the friend's brain is configured there too — in the **Natural language** section
near the bottom.

1. **Settings → Remote**, and scroll past Telegram, Discord, Linking and Devices to
   **Natural language**.
2. Turn on **Understand plain English**. Leave **Enable remote control** at the top of the
   pane alone unless you want Telegram or Discord as well — the friend window doesn't need
   it.
3. Pick a **Provider**: *Anthropic* or *OpenAI-compatible*. Choosing one fills in a matching
   model and base URL, so the only thing left is the key.
4. Paste your **API key** and click **Save** beside the field. It saves on the button, not
   as you type, and it goes to your login Keychain rather than a preferences file.
5. Optionally change **Model** or **API base URL**. This is where a model on your own
   machine goes: point the base URL at it and nothing leaves the house.
6. Click **Test**. It sends one real request the way a message would, so a pass means the
   next thing you say will work — not just that something answered.
7. Turn on **Let it look around first**. Without it, one message becomes one command decided
   blind: ask for "lazy music" and you get "nothing matched" even with a shelf of things
   tagged *chill*. **Remember what you tell it** sits underneath and needs it on.

Then **Go › Music Friend**, or **⌘⇧F**. If the window still says it has nothing to answer
with, step 2 is the one that was missed — a key with the toggle off does nothing.

### Turning it on, on the iPhone

The same settings have a pane of their own: **Settings → Music Friend**. The **Friend** tab
is not there until a connection test passes, so if you cannot find it, that is why rather
than anything being broken.

**Answers come from** picks where the thinking happens, and the two choices want very
different things:

**Model provider** talks to a model directly from the phone. Choose the provider, paste the
key, name the model, and press **Test connection**. The test asks the model to resolve a real
request and checks it picked the matching tool, so a pass means the next thing you say will
work rather than merely that something answered. When it passes, the Friend tab appears.

**Home server** sends the question to a **Baton gateway** running on a machine at home, so
your key stays there instead of on your phone. This is the one people get wrong, so it is
worth being blunt: a gateway is `baton-gateway`, the small service described under
[Shared settings](#shared-settings-between-your-devices). **It is not a model endpoint.**
Pointing Home server at Ollama, vLLM, LiteLLM or anything else that speaks an LLM API will
not work, however well that thing runs, because Baton asks it for `/v1/agent` and only the
gateway answers there. If you want to use a model on your own machine, that is Model
provider, or `BATON_LLM_BASE_URL` on the gateway itself.

The two addresses on this screen also want opposite shapes, which is easy to miss because
they sit one above the other:

| Field | Address |
|---|---|
| **Home server** | The bare host and port, `http://192.0.2.10:8788`. The gateway listens on **8788** by default. A trailing `/v1` is dropped if you paste one. |
| **Model provider** | The API root **including** `/v1`, because that is where `/chat/completions` hangs off. |

**About the fallback.** The panel says Baton falls back to the model provider if the home
server cannot be reached, and it does — a home server that is asleep or has moved will not
take the friend down with it. What the fallback does *not* do is make the Friend tab appear:
that gate tests the route you actually chose. If you picked Home server and have no gateway,
test as **Model provider** instead.

**Talk to it if you'd rather.** The composer has a microphone: click it and speak, click it
again to stop and send what you said. The first time, macOS asks for permission to use the
microphone and to recognise speech; if you say no, the window tells you so instead of
appearing to listen and doing nothing. Typing is always there as well, and **Return** sends
while **Option-Return** starts a new line.

**Tell it when it is wrong.** Every answer has a quiet thumbs-up and thumbs-down under it. A
thumbs-down asks what went wrong — wrong track, misunderstood, too slow, too chatty — and
that correction goes into what it reads before answering next time. On the Mac you can read
the whole history in **Settings, Friend Log**.

There is a guided tour for all of this in Help, called **Your music friend**, and the
question-mark button in the friend window's composer opens this page directly.

## Controlling Baton from Telegram or Discord

Baton can take commands from a chat app, so the stereo answers to your phone from the couch,
the kitchen, or the other end of a train line. Set it up in **Settings, Remote**.

Nothing about this opens your Mac to the internet. Baton dials *out* to Telegram and Discord
and waits for them to hand it messages; there is no port to forward, no address to publish,
and no change to the loopback-only control server described above.

A "bot" here is just an account on Telegram or Discord that Baton logs into, so you can send
it messages the way you'd message a person. Making one is free and takes about two minutes.
You only need to do one service — pick whichever you already use.

#### Telegram, step by step

1. Open Telegram and start a chat with **@BotFather** — Telegram's official bot for making
   bots. Search the name and look for the blue verified checkmark.
2. Send it `/newbot`.
3. It asks for a display name — anything you like, such as `My Music`.
4. It asks for a username, which must be unique and end in `bot`, such as
   `my_music_2026_bot`. If it's taken, it just asks again.
5. BotFather replies with a token that looks like `8123456789:AAF3k9...`. **Treat it like a
   password** — anyone holding it can act as your bot.
6. In Baton: **Settings → Remote**, turn on **Enable remote control**, then **Enable
   Telegram**, paste the token into **Bot token**, click **Save**. Within a second or two the
   **Status** line turns green and shows your bot's `@name`. Red shows Telegram's reason —
   almost always a mistyped token.
7. Open a chat with your new bot and send `/link 123456`, using the six-digit **link code**
   from the **Linking** section of the same pane. It replies "Linked." — try `np` or `play`.

**Using it in a group chat?** Two things to know. Telegram bots in groups default to
*privacy mode*, which hides ordinary messages from them — so `np` goes unseen while `/np`
gets through. Either stick to `/`-prefixed commands in groups, or message BotFather
`/setprivacy` and turn privacy off for your bot. And when several bots share a group,
`/pause@your_bot_name` disambiguates — Baton understands the suffix.

#### Discord, step by step

The order below matters: the **Message Content intent** comes before the token, because a
bot that connects without it sees every message with the text stripped out — it looks like
Baton ignoring you, with no error anywhere.

1. Go to **discord.com/developers/applications** and sign in.
2. Click **New Application**, name it (say, `Baton`), and create it.
3. In the left sidebar open **Bot**, then set three things on that page:
   - **Public Bot: off** — so only you can invite it anywhere.
   - Under **Privileged Gateway Intents**, turn **Message Content Intent on**, and click
     **Save Changes**.
   - Click **Reset Token**, confirm, and copy the token. It is shown exactly once; if you
     lose it, reset again (the old one stops working).
4. In Baton: **Settings → Remote**, turn on **Enable remote control** and **Enable
   Discord**, paste the token, click **Save**. The **Status** line turns green with the
   bot's name once the connection is up.
5. Invite the bot to a server — it can see nothing until you do. Grab the **Application
   ID** from the app's **General Information** page, and open this URL with yours
   substituted:

   ```
   https://discord.com/oauth2/authorize?client_id=YOUR_APPLICATION_ID&permissions=68608&scope=bot
   ```

   Pick your server in the dialog and authorize. `68608` grants exactly **View Channels,
   Send Messages, and Read Message History** — all a music remote needs. Don't grant
   Administrator or Manage-anything; a remote control has no business with them. (The same
   thing can be clicked together under **OAuth2 → URL Generator**: scope `bot`, then those
   three permissions.)

   No server of your own? Create one with the **+** button in Discord's left rail — a
   private server with just you in it is the tidiest option.
6. Pick or create a channel for it. A dedicated `#music` or `#baton` channel keeps things
   readable, but any channel works — Baton ignores messages written by bots, so it can
   share a channel with webhook feeds without tripping over them.
7. In that channel, send `/link 123456` with the six-digit code from Baton's **Linking**
   section. "Linked." — you're done.

To confine the bot to specific channels, fill **Limit to channels** with channel ids
(comma-separated). Getting an id: Discord **Settings → Advanced → Developer Mode on**, then
right-click the channel → **Copy Channel ID**. This narrows an already-authorized person;
leaving it empty is fine, because the link-code allowlist is what actually guards access.

#### About that link code

The link step isn't ceremony, and it's worth understanding why it's there. A bot token
identifies *the bot*, not *you*. Anyone who found your bot could otherwise message it and
take over your speakers. So until a chat is linked, Baton ignores every message it gets
except a correct link code — and each code works only once, because you type it into a chat
history that might get backed up or read over your shoulder.

If you ever want to cut a chat off, the Remote pane lists every linked chat with a **Revoke**
button. **New code** rolls the code if you think it's been seen.

On Discord you can also fill in **Limit to channels** with one or more channel ids, which
confines the bot to those channels. That narrows things further; it doesn't replace linking.

### What you can say

Type these as ordinary messages. The leading slash is optional on both services, so `pause`
and `/pause` do the same thing.

| Message | What it does |
|---|---|
| `play kind of blue` | Searches your library and plays the best match |
| `play` | Resumes what was paused |
| `pause` · `resume` · `stop` | The obvious ones |
| `next` · `prev` | Skip forward or back (`skip` and `back` work too) |
| `queue radiohead` | Adds matches to the end of the queue |
| `queue` | Shows what's coming up |
| `playnext <song>` | Slots something in right after the current track |
| `vol 40` | Volume, 0 to 100 — Baton's own volume, not the Mac's |
| `seek 1:30` | Jump to a position (`90` and `1m30s` also work) |
| `np` | What's playing right now |
| `search coltrane` | Look without playing |
| `like` · `unlike` | Star the current track (or `like <song>`) |
| `rate 5` | Rate the current track, 0 to 5 |
| `playlists` | List your playlists |
| `playlist Evening` | Play a playlist by name — part of the name is enough |
| `mix upbeat focus` | Build a mix from a description |
| `radio` | Endless "more like this" from the current track |
| `shuffle on` · `repeat one` | Modes (`repeat` takes `off`, `all`, or `one`) |
| `sleep 30` | Pause in 30 minutes (`sleep off` cancels) |
| `forget` | Clear what this chat remembers |
| `memories` | Everything Baton keeps about you, with your own words |
| `forget 2` · `forget everything` | Remove one memory, or all of them |
| `help` | The list, in the chat |

Replies come with buttons for the common actions, so skipping a track is a tap rather than a
typed word.

### Saying it in your own words

Turn on **Understand plain English** in the same pane and anything Baton doesn't recognize as
a command gets read as intent instead — "put on something mellow", "skip this one", "make me
a 40-minute driving mix".

This one needs a model to talk to, which you provide; Baton ships no key, and the feature
stays off until you set it up. There's a **Test** button that sends one real request and
tells you whether it worked, so you're never guessing.

Baton speaks two API dialects, which between them cover nearly everything:

- **Anthropic** — Claude's Messages API.
- **OpenAI-compatible** — the `chat/completions` shape that OpenAI, Groq, Together, Mistral,
  DeepSeek and OpenRouter all serve, *and* that self-hosted servers speak: vLLM, Ollama,
  LM Studio, llama.cpp, LiteLLM. This is the one to pick for a model running on your own
  hardware.

**Using a hosted model.** Pick the provider, get a key from them
([console.anthropic.com](https://console.anthropic.com) or
[platform.openai.com](https://platform.openai.com)), paste it into **API key**, click
**Save**, then **Test**. Model and base URL are pre-filled sensibly for each provider and can
be left alone. Costs are yours and are small — each message is one short request.

**Using your own model.** If you run a model on your own machine or network, set the provider
to **OpenAI-compatible**, put your server's address in **API base URL** (the root that
`/chat/completions` hangs off — for example `http://your-server:8000/v1`, or
`http://localhost:11434/v1` for Ollama), and set **Model** to whatever name your server
serves. Most local servers accept any key; put something in the field anyway. Nothing leaves
your network, and there's no per-message cost.

One thing macOS does that looks like a Baton bug: the first time Baton talks to something on
your own network, macOS asks permission, and if that prompt was missed or declined every attempt
fails with *"The Internet connection appears to be offline"* — even though Baton is plainly
online. Allow it under **System Settings → Privacy & Security → Local Network**, where Baton
should be switched on.

One thing to check with a local model: it must support **tool calling** (also called function
calling). Baton asks the model to pick from its list of commands, and a model or server built
without that support will fail the Test with an error saying so. Most current instruct models
handle it; very small or older ones often don't. Smaller models are also less precise at
picking details out of a sentence — asking for "kind of blue" might search for just "blue" —
so if results feel vague, a larger model is the fix.

If you'd rather not have any of this, leave it off — every command in the table above works
without it.

If you use a phrase that collides with a command, put `ask` in front to force the
plain-English reading: `ask play something quiet`.

**Commands are tried first, but they don't trap you.** A message starting with a command word
is handled instantly and locally — `play kind of blue` is a search, not a question for the
model. If that literal reading finds nothing, and plain English is on, Baton asks the model
what you meant rather than leaving you with "no songs matched". So `play the second one`
works even though it starts with `play`.

**Follow-ups work.** Each chat remembers its last few exchanges, so you can say "show me
tracks for Dido" and then "play the second one" and it knows what you mean. That memory is
short on purpose: it lives only while Baton is running, covers a few recent exchanges,
expires after about half an hour of quiet, and is kept separately for each chat. Send
`forget` to clear it whenever you like.

This is the one feature in Baton that talks to a third party, and it's off until you switch it
on. What leaves your Mac is the sentence you typed and the list of Baton's own commands —
never your server credentials or what you've been listening to. Under the hood the model is
choosing from the same control surface an AI agent gets, so a sentence can't ask Baton to do
anything the buttons can't. Deleting a playlist is deliberately left out of what a sentence
can reach; type the command for that.

### Letting it look around first

Underneath is a second switch, **Let it look around first**, and it's the difference between a
translator and something you can have a conversation with.

Off, your sentence becomes one command, chosen blind. The model has never seen your library,
so it has to be right first time about music it knows nothing about. Ask for "lazy music" and
you get "nothing matched" — even though the chillout is right there, tagged `chill`, `lounge`
and `ambient`, because a mood is rarely a song title.

On, Baton lets it look before it answers. It can read which genres your library actually uses,
what you've liked and played most, what's similar to a track, and what albums are newest or
most-played — then search again with words it has seen work, and play the result. The reply
tells you what it did and why it isn't literally what you asked: *"nothing called 'lazy' —
your chillout is tagged chill, playing that"*.

**It asks when asking is the honest thing.** If what it found splits two ways and the answer
changes what you'd hear — two artists sharing a name, a six-hour mix beside a forty-minute set
— it offers them as buttons, each with the fact that decides it. Tap one, or type `2`, or say
"the ambient one". Ignore it and after a minute or so it starts the one it recommended and
says that's what it did, rather than leaving you in silence. Send anything else and the
question is dropped — it won't start playing under you a minute after you've moved on.

**This is the setting that changes what leaves your Mac,** which is why it's separate and off
by default. Looking around means what it finds — song titles, artists, genres — travels to the
model along with your question, because that's the only way it can answer. With it off, none of
your library ever does. Point the base URL at a model running on your own machine and the
distinction stops mattering: nothing leaves your network either way.

It costs a little more than one request per message, since looking takes turns. Against a
local model that's typically a second or two.

**It knows what you listen to.** Before it answers, Baton hands it a dozen lines read from
your own server: your biggest genres with counts, what you've played most and how often, how
many songs you've liked, what you added recently. Nothing is stored and nothing is guessed —
they're the server's own numbers, read fresh each day. It's what makes "what kind of music do
I listen to?" answerable, "surprise me" grounded in your collection rather than a coin flip,
and a remark like "that's its 34th play" possible at all.

**It occasionally has a view.** When a number is worth mentioning it says so in passing —
and then does what you asked anyway. It never refuses and never lectures, and it mentions any
one thing at most once a day, because a friend says it once and software that says it three
times running is nagging.

### What it remembers

Some things your server can't know: that you don't want vocals while you work, that the
gothic playlists are your partner's, that "my trance" means the Classic Trance ones. Tell
Baton and it keeps them, in a plain file you can open at
`~/Library/Application Support/Baton/remote-memory.json`.

Three rules make that safe rather than creepy:

- **It stores your words, not its impressions.** Every memory carries the sentence you
  actually said. There is nowhere to put "seems to like sad music on Sundays" — the file has
  no field for a guess about you, which is a better guarantee than a promise not to make one.
- **It tells you every time it writes one.** "Noted — no vocals while you work." If it
  misunderstood, you see it in the same window a second later, and one message fixes it.
- **It's one command away.** `memories` lists everything with the quote attached, `forget 2`
  removes one, `forget everything` clears the lot. Settings, Remote has a switch to turn it
  off and a button to delete everything.

It keeps a couple of dozen things at most, forgetting whatever has gone longest unused. It
also notes what it recently started playing, so "surprise me" stops surprising you with the
same three tracks.

---

## Settings reference

On the Mac, open Settings by pressing Command and comma. On iPhone, Settings is the
last tab. The panes are:

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

### Agents

Whether an AI agent can drive Baton, and everything it needs to: the connection status, the
endpoint address, and the access token, with a button to copy each. See
[Letting an agent control your music](#letting-an-agent-control-your-music).

### Remote

Telegram and Discord bot tokens, the link code and the list of chats you've authorized (each
revocable), an optional restriction to particular Discord channels, and the model provider
and natural-language settings the music friend runs on, plus **Shared settings** — the
gateway that keeps your preferences in step with your iPhone. Setting the friend's model
provider up is step-by-step in [Turning it on, on the Mac](#turning-it-on-on-the-mac); the
chat bridges are in [Controlling Baton from Telegram or
Discord](#controlling-baton-from-telegram-or-discord); the gateway is in [Shared settings
between your devices](#shared-settings-between-your-devices).

### Friend Log

Every exchange you've had with the music friend, on any of your screens, with the thumbs-up
or thumbs-down you gave it. This is where a correction goes to live, and where to look when
you want to know why it answered the way it did. See [The music friend](#the-music-friend).

### About

Baton's version, its license (MIT), and a link to the website, plus two small sections:

- **Updates**: the auto-update feed, its status, an "automatically check for updates" toggle,
  and a **Check for Updates Now** button. See [Updates](#updates).
- **Diagnostics**: the opt-in **Send crash & error reports** toggle, off by default. See
  [Privacy and security](#privacy-and-security).
- **Lyrics**: **Look up missing lyrics**, which asks LRCLIB for words your server doesn't
  carry. See [Lyrics](#lyrics). (It lives here rather than under Playback, which is not where
  you would look for it — worth knowing.)

Each of the Playback, Equalizer, and Speech panes has its own **Reset to Defaults** button,
and each is careful to keep your credentials and servers when it resets.

---

## Updates

Baton updates with Sparkle, the standard macOS updater that many Mac apps use. There's a
**Check for Updates** item in the app menu, and Baton checks its own feed and installs signed,
notarized builds so you don't have to reinstall by hand. You can download the current release
from [baton.tonebox.io](https://baton.tonebox.io), and it updates itself from there on.

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
- **Crossfeed and other DSP**. (The lyrics fallback that used to sit on this list has
  shipped — see [Lyrics](#lyrics).)

The full roadmap is in [`docs/05-roadmap-new-features.md`](docs/05-roadmap-new-features.md).

---

## Privacy and security

- **Your credentials live in the macOS Keychain**, never in a plain text file.
- **Baton doesn't phone home by default.** It talks only to the music server you point it at,
  plus the scrobbling services and its own update feed if you turn those on, any
  text-to-speech server you set up, and — if you connect a chat bot — Telegram or Discord. It has no catalog server of its own to call. The one
  opt-in exception is crash reporting (Settings, About, Diagnostics, off by default): when you
  turn it on, Baton sends crash and error data to its developer via Sentry to help fix bugs,
  never your music, library, server address, or account, and no IP or identifiers.
- **The control server is loopback-only and token-protected.** It can't be reached from your
  network, and nothing on your Mac can drive it without the secret token. See
  [how it's secured](#letting-an-agent-control-your-music).
- **Chat remote control connects outward only, and starts closed.** Baton opens a connection
  to Telegram or Discord rather than accepting one, so no port is exposed; and a chat can't
  drive playback until you link it with the code Baton shows you. See
  [Controlling Baton from Telegram or Discord](#controlling-baton-from-telegram-or-discord).

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

**My bot doesn't answer at all.** Baton has to be running, and **Enable remote control** plus
the switch for that service both have to be on. Check the **Status** line in Settings, Remote:
green with a name means Baton is connected and the problem is elsewhere; red shows the reason
the service gave, which is usually a mistyped or reset token.

**Discord: the bot is online but ignores everything I type.** This is almost always the
**Message Content Intent**, which is off by default. Turn it on at
discord.com/developers → your application → **Bot** → Privileged Gateway Intents, then click
**Reconnect** in Baton. Without it Discord delivers your messages with the text removed, so
Baton receives an empty message and has nothing to act on. If the bot doesn't appear in your
server's member list at all, it was never invited — see the
[setup steps](#controlling-baton-from-telegram-or-discord).

**It says the chat isn't authorized.** That's the expected answer until you link it. Send
`/link` followed by the six-digit code from Settings, Remote. If the code is refused, it's
because codes are single-use — click **New code** and send the new one.

**It answers "I don't know that".** The message wasn't one of the commands. Send `help` for
the list, or turn on **Understand plain English** to have Baton read it as intent instead.

**Spoken summaries are silent or use the wrong voice.** Check the server addresses in the
[Speech](#speaking-summaries-aloud) pane with the Test button. If a server is down and the
system-voice fallback is off, Baton reports an error rather than speaking; turn the fallback
back on to always hear something.

---

## Questions

The [FAQ](FAQ.md) has short answers to the common ones. For the vision, architecture, and
integration details, browse the docs in [`docs/`](docs/). Baton is made by
[Tonebox](https://tonebox.io), and given away for free.
