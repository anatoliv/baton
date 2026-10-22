# Baton Help

**Conduct your music.** Baton is a player for the music you already own, on the Mac and on the
iPhone. It streams from your music server: a self-hosted [Navidrome](https://www.navidrome.org/)
server, or any server that speaks Subsonic, the language Navidrome and many other music servers
share. It plays that library with care: true gapless playback, crossfade, ReplayGain loudness
matching and a 10-band parametric equalizer.

On the Mac, Baton also runs a small control server so an AI agent, like Claude or
[Tonebox](https://tonebox.io), can search, queue and steer your music for you.

Baton is made by [Tonebox](https://tonebox.io). The Mac app is free.

This guide walks through every part of the app in plain language. If you want a quick answer,
the [FAQ](FAQ.md) is shorter. For the design and architecture, see the
[repository on GitHub](https://github.com/anatoliv/baton).

## Contents

- [What Baton is, and what it isn't](#what-baton-is-and-what-it-isnt)
- [The two servers Baton uses](#the-two-servers-baton-uses)
- [Getting connected](#getting-connected)
- [Baton on iPhone](#baton-on-iphone)
- [Shared settings between your devices](#shared-settings-between-your-devices)
- [Using more than one music server](#using-more-than-one-music-server)
- [Finding your way around](#finding-your-way-around)
- [Browsing by folder](#browsing-by-folder)
- [Home](#home)
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
- [Clippings](#clippings)
- [Listening to a document](#listening-to-a-document)
- [Playing music](#playing-music)
- [Adaptive artwork colors](#adaptive-artwork-colors)
- [The queue, shuffle, repeat, and autoplay](#the-queue-shuffle-repeat-and-autoplay)
- [Sleep timer](#sleep-timer)
- [Alarm and Timer](#alarm-and-timer)
  - [Setting an alarm or a timer](#setting-an-alarm-or-a-timer)
  - [An alarm and a timer together](#an-alarm-and-a-timer-together)
  - [Gentle Wake](#gentle-wake)
  - [Choosing what plays](#choosing-what-plays)
  - [When it goes off](#when-it-goes-off)
  - [When Baton is closed on the iPhone](#when-baton-is-closed-on-the-iphone)
  - [When Baton is closed on the Mac](#when-baton-is-closed-on-the-mac)
- [Sound quality: gapless, crossfade, loudness](#sound-quality-gapless-crossfade-loudness)
- [The equalizer](#the-equalizer)
- [Rating, liking, and multi-select](#rating-liking-and-multi-select)
- [Scrobbling](#scrobbling)
- [Finding music you don't have](#finding-music-you-dont-have)
- [Sharing a song with a friend](#sharing-a-song-with-a-friend)
  - [Sharing a song](#sharing-a-song)
  - [What your friend sees](#what-your-friend-sees)
  - [When a friend sends you a song](#when-a-friend-sends-you-a-song)
  - [Sharing a mixtape](#sharing-a-mixtape)
  - [Sharing a book](#sharing-a-book)
  - [Sharing a whole book](#sharing-a-whole-book)
  - [Sharing an album or a playlist](#sharing-an-album-or-a-playlist)
  - [Reactions](#reactions)
  - [Shared Links](#shared-links)
  - [How private sharing is](#how-private-sharing-is)
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
- [Backing up and restoring your settings](#backing-up-and-restoring-your-settings)
- [Updates](#updates)
- [What's next](#whats-next)
- [Privacy and security](#privacy-and-security)
- [Troubleshooting](#troubleshooting)
- [Questions](#questions)

---

## What Baton is, and what it isn't

Baton plays *your* library. It is not a streaming catalog like Spotify or Tidal, and it has no
music of its own. You bring a server full of music, and Baton plays it well. Until you connect a
server there is nothing to browse.

A few things worth knowing up front:

- **It's self-hosted and private.** Your music comes from your own server, and your passwords
  live in the Keychain (the Mac's and the iPhone's secure password store), not in a plain file.
  Baton does reach a few other services, some on by default and most only if you turn them on.
  [Privacy and security](#privacy-and-security) lists every one.
- **There's no subscription and no account with us.** You're playing music you already own, on a
  server you already run.
- **Software can drive it.** This is what makes Baton different from other Subsonic players. An
  AI agent can search, queue, build a mix, rate what's playing, or turn the music down for a
  call, all through a local control interface on your Mac. See
  [Letting an agent control your music](#letting-an-agent-control-your-music). You never have to
  touch that, though. Baton is a complete click-to-play player on its own.
- **It can talk back.** The same control interface lets an agent speak short results out loud in
  a natural voice. Give each agent its own voice and you can follow a whole run of several agents
  by ear. See [Speaking summaries aloud](#speaking-summaries-aloud).

Baton runs on macOS 15 or later, and on iOS 18 or later. See [Baton on iPhone](#baton-on-iphone).

---

## The two servers Baton uses

Baton can talk to two servers of your own. They do different jobs, so the apps give them
different names: your **music server** and your **Baton server**.

**Your music server** is where your library lives. It is Navidrome, or another server that
speaks the Subsonic language, and it is the one you sign in to with a username and password or
an API key. It keeps your songs and albums, your playlists, what you have liked and rated, your
play counts, and the internet radio stations you save there. Every other Subsonic app you use
sees the same things, because they live on the server rather than in Baton.

**Your Baton server** is a small Baton program that you run yourself, on a machine that stays
on. It does the work a phone or a sleeping Mac cannot do, and it keeps a few things your devices
share:

- It makes audiobooks from documents you import, and offers the voices they can be read in.
- It keeps your place in a book, so you can stop on one device and carry on from the other.
- It keeps the settings your devices share, such as the equalizer, crossfade and podcast
  subscriptions.
- It holds files for your other device for a while: a document your iPhone sent to the Mac, or
  a clipping you kept on the Mac for the phone to collect.
- It reads the short "Previously" recap of a book aloud on the iPhone, and it can answer the
  music friend.

The Baton server is optional. Without it, Baton is a complete music player.

**They can be one machine or two.** In a typical home setup both run on the same computer, the
one that is always on in a cupboard or under a desk, and that is fine. They can just as well be
two different machines. Baton only needs to know the address of each.

**What needs which.**

| You want to | Music server | Baton server |
|---|---|---|
| Play, search and download your music | Needed | Not needed |
| Like, rate and build playlists | Needed | Not needed |
| Make a book from a document on the iPhone | Not needed | Needed |
| Make a book on the Baton server from the Mac | Not needed | Needed |
| Make a book on the Mac itself | Not needed | Not needed |
| Pick up a book where you stopped on your other device | Not needed | Needed |
| Keep shared settings in step between devices | Not needed | Needed |
| Send a document from the iPhone to the Mac, or a clipping from the Mac to the iPhone | Not needed | Needed |
| Hear a "Previously" recap on the iPhone | Not needed | Needed |

**When one of them does not answer.** If your music server is off or out of reach, Baton cannot
play from your library, though anything you downloaded still plays. Settings can check whether it
answers.

If your Baton server is off or out of reach, music carries on as normal, and books it already
made and you downloaded still play. New books cannot be made there. On the Mac, a book meant for
the Baton server is made on the Mac instead. The iPhone says so and suggests AirDropping the
document to your Mac, which can make the book itself. Your shared settings and your place in a
book wait, and catch up the next time the server answers.

**Where to set them up.**

On the Mac:

- **Music server:** **Settings → Music Servers**. Click **Add Music Server…**, choose how to
  sign in, and enter the **Server URL** and your sign-in. The first time you open Baton, the
  connect window asks for the same things.
- **Baton server:** **Settings → Remote → Baton server**. Enter the **Baton server address** and
  the **Baton server token**, click **Save token**, then **Test**.
- Where books are made is under **Settings → Speech → Make books on**: **This Mac**, **Baton
  server** or **Ask each time**. **Settings → Storage** lists the books kept on this Mac and
  those on the **Baton Server**.

On the iPhone:

- **Music server:** the **Music server** section at the top of **Settings**. It shows whether
  the server answers, and the address and user you are signed in with, partly hidden until you
  tap **Show Server Details** and pass Face ID or your passcode. **Set up from a Mac…** brings
  your Mac's connection across. While you are trying the demo library, **Connect to
  Navidrome…** lets you type your own server in.
- **Baton server:** **Settings → Music Friend**. Set **Answers come from** to **Baton server**,
  and the **Baton server** section appears with the address and the **Baton server token**.
  Books, your place and the files for your Mac all use these two fields.

**The Baton server's address and token.** The address is the machine's name or IP address and
the port, such as `http://192.0.2.10:8788`. The Baton server listens on port 8788 unless you
changed it, and Baton drops a `/v1` from the end if you paste one. The token is a long password
you make up when you set the server up. Both devices send it, so the server knows the request is
yours. Setting up the server itself is described in
[Running your Baton server](#running-your-baton-server).

---

## Getting connected

The first time you open Baton on the Mac, the **Connect your music** window asks for your music
server. You need three things: the server's address, a sign-in method, and your sign-in details.

1. **Pick a sign-in method** under **Sign in with**. Baton supports two:
   - **Username & password**, the classic Subsonic sign-in. Baton doesn't send the password
     itself. It sends a one-time token made from it with a random salt, which is the scheme
     Subsonic servers expect.
   - **API key**, if your server supports one. Recent versions of Navidrome do. Paste the key
     instead of a username and password.
2. **Enter the Server URL**, the full address, for example `https://music.example.com`.
3. **Enter your Username** (only for the username-and-password method) and your **Password** or
   **API key**.
4. **Click Connect.** Baton checks that it can reach the server and sign in *before* it saves
   anything. If it works, your library loads straight away. If it doesn't, Baton tells you what
   went wrong so you can fix the address or your sign-in and try again.

**Prefer an https:// address.** With a plain `http://` address the window warns you that your
sign-in travels unencrypted. That is fine for a server on your own home network, and not
anywhere else.

**Just looking?** **Try the demo server** fills in Navidrome's public demo, so you can see Baton
working before you set anything up.

Your sign-in is stored in the **macOS Keychain**, the same place Safari and Mail keep passwords.
It is never written to a plain text file. There's more on this in the
[FAQ](FAQ.md#privacy-and-security).

On the iPhone, the first-run screen is **Connect to Navidrome**. See
[Getting your Mac's setup onto your phone](#getting-your-macs-setup-onto-your-phone) for the
quicker routes, and [The demo library](#the-demo-library) for trying it first.

---

## Baton on iPhone

Baton on iPhone plays the same library from the same server, and most of this guide applies to
it unchanged. Where the two differ, the section says so.

The main differences are these. **Settings** is not a window you open with ⌘,, and it
is not a tab either: tap the gear button at the top of **Home** and it opens as a sheet, with
**Done** to close it. The tabs along the bottom are **Home**, **Albums**, **Library** and
**Search**, plus **Friend** once the music friend has passed its connection test. There's no
menu-bar controller, and no window to keep in a corner of a screen.

It's on the App Store as
[Baton: Navidrome Music Player](https://apps.apple.com/app/id6798304294), and it needs iOS 18
or later. Unlike the Mac app it costs money, which is what covers the Apple developer account the
Mac build is signed and notarized with. The source is in the repository under the same licence,
so you can build and install it yourself instead.

### Getting your Mac's setup onto your phone

Typing a server address, a username and a long password into a phone keyboard is the worst part
of setting up any music app, so there are three ways to do it. The first-run screen, **Connect to
Navidrome**, offers all three. Later, the first two are under **Settings → Music server → Set up
from a Mac…**.

- **Scan a code.** On the Mac, open **Settings → Remote → Link a device → Show pairing code**.
  On the phone, choose **Scan a code from your Mac** and point the camera at it. Your server
  address, your sign-in and your settings come across encrypted, and there is nothing to type,
  not even a passphrase. Both devices have to be on the same network, because the code holds a
  local address the phone connects back to.
- **Import a file.** On the Mac, use **Settings → About → Back up & restore → Export…**, then get
  the file to your phone however you like: AirDrop, iCloud Drive, email. On the phone, choose
  **Choose an exported file**. If you exported it with your accounts included, it's encrypted
  and you'll need the passphrase you chose. This is the one that works when the two devices
  aren't on the same network. [Backing up and restoring your
  settings](#backing-up-and-restoring-your-settings) says what the file holds.
- **Type it in.** The first-run screen takes a server address, a username and a password,
  exactly as the Mac's first run does. While you are trying the demo, **Settings → Music server
  → Connect to Navidrome…** does the same.

Your likes, ratings, playlists and play counts don't need any of this. They live on your
Navidrome server, and both apps read and write them as the same user, so they are already the
same on every device.

What travels here is what Navidrome has nowhere to keep: your equalizer curve, crossfade, radio
bans and your music friend's setup. Because pairing encrypts everything it sends, it also
carries your server passwords, your scrobbling tokens and your API keys, so you paste nothing.

All three are a one-time transfer. To keep those settings in step from then on, see
[Shared settings between your devices](#shared-settings-between-your-devices).

### Where the Mac says "right-click"
<!-- baton:audience iphone -->

Most of this guide describes the Mac, where a right-click opens the menu of things you can do to
a song, an album, an artist, a playlist or a station. **On iPhone, touch and hold instead.** A tap
plays.

For a song, the menu that appears holds **Play Next**, **Add to Queue**, **Save to Later**,
**Like**, **Rate**, **Add to Playlist…**, **Download** (or **Remove Download**), **Start Radio**,
**Find More Like This…**, **Go to Album**, **Go to Artist**, **Share…**, **Set Alarm…**, **Start
Timer…**, **Never Play in Radio** and **Mark for Removal**. Albums, playlists and stations have
their own shorter menus.

### Widgets, the lock screen, and Live Activities
<!-- baton:audience iphone -->

Baton puts what's playing where you actually glance.

- **Home screen.** Add the **Now Playing** widget in the usual way: touch and hold the home
  screen, tap **+**, and search for Baton. It comes in small, medium and large. The medium and
  large sizes have **Play/Pause** and **Next** buttons of their own.
- **Lock screen and StandBy.** The same widget also comes in the three accessory shapes:
  rectangular, circular and inline. Add it from the lock screen's own **Customize** screen. It's
  the one you see without unlocking anything.
- **A Live Activity while music plays.** Start something and a compact now-playing line appears
  on the lock screen: a small cover, the title, the artist a step down, and a progress bar that
  runs on its own. With a Dynamic Island, the expanded view adds Previous, Play/Pause, Next and
  **Like this track**.
- **Alarms and timers.** On iOS 26 and later, a running alarm or timer has its own Live Activity
  with a countdown. See [Alarm and Timer](#alarm-and-timer).

Tapping any widget opens Baton's full player.

**Tip:** the link `baton://player` opens the full player directly. It's what the widgets use, and
you can use it in a shortcut too.

The widget draws artwork it already has on disk rather than fetching it, because a widget's
network access is throttled and the cover would never appear. After 30 minutes with no fresh
news from the app it shows "Nothing playing" rather than an old song.

### Siri and Shortcuts
<!-- baton:audience iphone -->

Baton answers Siri, and the same actions are building blocks in the Shortcuts app.

Say **"Play something in Baton"** or **"Play music in Baton"** and Siri asks what you'd like, then
searches your library and plays the results. **"Resume Baton"** picks up where you left off. Siri
can't take the album name in the same breath yet: that needs a kind of input Apple only allows
for fixed lists, so it asks rather than guessing.

In the **Shortcuts** app, search for Baton and you'll find **Play music**, **Pause music**,
**Play or pause**, **Next track**, **Previous track**, **Like the current track** and **Play
songs matching**. Use them in an automation the way you'd use any others: start a playlist when
you arrive somewhere, or pause when a Focus begins.

These run the same commands the music friend and the app's own buttons use, so Siri and the
friend always behave the same way.

### How much data it uses
<!-- baton:audience iphone -->

**Settings → Sound** has two quality settings, one for each kind of connection: **Wi-Fi
Quality** and **Cellular Quality**. Each takes **Original**, **High (320 kbps)**, **Medium (192
kbps)** or **Low (128 kbps)**. Wi-Fi starts on **Original** and cellular on **High (320 kbps)**.

**Original** means no cap: the server sends the file as it is, which for a FLAC library is the
whole point of owning the files. It's also the setting most likely to matter on a metered plan,
which is why the two are separate. Leave Wi-Fi on Original and put cellular on Medium, and the
phone does the right thing without you thinking about it.

"Cellular" here means any connection that costs you data: the mobile network, a personal hotspot,
or a network with Low Data Mode turned on.

Anything you've downloaded ignores both settings. It's already on the phone, at whatever quality
it arrived.

### Face ID on your keys
<!-- baton:audience iphone -->

The music friend's API key costs money when it's used, and a phone in someone else's hand is
already unlocked. So on **Settings → Music Friend** the key and the Baton server token stay
masked until Face ID or Touch ID passes. The same goes for your music server's address and user
under **Settings → Music server**, until you tap **Show Server Details**.

Two things about it are deliberate. It falls back to your passcode (**Use Passcode**), so a wet
thumb or a mask never locks you out of your own settings. And a phone with no passcode set at all
is let through, because there's nothing to check against and refusing would lock you out of a
key with no way back. A phone with a passcode but no Face ID still asks for the passcode.

It is **not** an app-wide lock, so you are never asked for your face just to come back and skip
a track. It guards those secrets and nothing else.

### Making the phone yours
<!-- baton:audience iphone -->

A few things on the iPhone bend to how you actually listen:

- **Edit the Library list.** Tap **Edit** on the Library tab to hide sections you never open and
  drag the rest into your order. New sections appear even if you've customized the list.
- **Jump by letter.** Artists, Folders, Liked, and Playlists sorted by name have an A to Z rail
  along the right edge. Tap or drag it.
- **Search remembers.** The albums and artists you open from search wait under **Recently
  Opened** next time, with **Clear** to empty the list.
- **Albums as a grid or a list.** The sort menu on Albums also switches the **Style**.
- **Keep the screen awake.** **Settings → Display → Keep the screen awake**, for a phone propped
  on a dock. It's off by default because it costs battery.

### The demo library
<!-- baton:audience iphone -->

Baton needs a server, which makes an app with no server a locked door. There are two ways
through it, and they answer different questions.

**Try the demo** on the first-run screen opens a small library built into the app: four real
tracks, played through the real engine, so you can see what Baton does before setting anything
up. Nothing about it touches the network.

**Use Navidrome's public demo server** fills in the sign-in for `https://demo.navidrome.org`
(username `demo`, password `demo`), the server the Navidrome project publishes for exactly this.
That one is a real library over a real connection: a few thousand Creative Commons tracks,
artwork arriving over the network, and search against a proper index. It is not our server, so it
can be slow or offline. If it doesn't answer, **Use the built-in demo instead** appears.

Connect your own server whenever you like from **Settings → Music server → Connect to
Navidrome…**, and either demo gives way to it.

---

## Shared settings between your devices

The three routes above are a *one-time* transfer: they carry your setup across once, and after
that the two devices drift apart. Change the equalizer on the Mac and the phone still has the old
curve. Shared settings is the ongoing version, and it is optional. Leave it alone and both apps
work exactly as they always have.

Your likes, ratings, playlists and play counts were never the problem. They live on your
Navidrome server, under your user, and both apps read and write them as you. The problem is
everything Navidrome has nowhere to put, because Subsonic servers have no place for an app's own
preferences.

Those settings go through your **Baton server**, a small Baton program you run
yourself, which is the one place both devices already sign in to. If the two servers are new to
you, [The two servers Baton uses](#the-two-servers-baton-uses) explains them.

### What travels, and what stays put

| Travels | Stays on the device |
|---|---|
| Equalizer: on/off, preset, band gains | Download folder and downloaded files |
| Crossfade, gapless and its Wi-Fi-only prefetch, autoplay, repeat | Offline mode |
| Loudness mode and pre-amp | Demo mode |
| Radio bans | How far into a podcast episode you are |
| Podcast subscriptions | Every API key and password |
| Search history, filter history, and the albums and artists you opened from search | The "look outside my library" switch |
| Streaming quality, for Wi-Fi and for cellular | Your speech and transcription servers |
| Look up missing lyrics, scrobbling target | The experimental audio engine |
| Which discovery sources are switched on | Ducking and stall timeouts |
| The speed podcasts and books play at | Appearance, and whether the screen stays awake |
| Your Baton server's address | Your local play history |
| The music friend: where answers come from, provider, model, base URL, and whether it speaks replies aloud | The play queue (it has a route of its own, below) |
| The friend's own switches: understand plain English, let it look around first, remember what you tell it | |
| What the friend remembers and has learned, and your clippings list | |

Three of those deserve a word.

**Your speech and transcription servers stay put** because they are addresses of machines
rather than choices about listening. The phone is rarely on the same network as the machine that
runs them, and inheriting an address it cannot reach would look like a broken setting. (Your
Baton server is the exception: it's one server every device shares, so its address does travel.)

**Secrets never travel through sync.** Keys live in the Keychain, and putting them in a synced
file would be a step down in how they are kept. They move by pairing instead, encrypted. So the
friend's provider, model and base URL stay in step all the time, and the key itself arrives once,
when you pair.

**The master switch for looking outside your library stays put on purpose.** That one is consent,
and a phone should not inherit a decision the Mac made to start talking to outside services.

### Picking up where the other device left off

The queue is the one thing in that table with a route of its own. It doesn't travel through
shared settings and it doesn't need the Baton server. It uses the **play-queue slot your Subsonic
server already has**, so it works with nothing running but Navidrome.

Baton saves the queue there when playback **pauses**, and the phone saves it again when you leave
the app. It doesn't save on a timer, so a normal evening of listening doesn't hammer the server.

When you next open Baton, it asks the server once whether another device left a queue behind. If
one is there, you get a short prompt naming the track, with **Continue** and **Not now**.
Continue rebuilds the queue and drops you at the same spot in the same song. It only ever offers
a queue that a *different* device saved. Your own is already restored from disk.

This works in both directions, Mac to phone and phone to Mac.

**It is switched off on the public demo server.** The play-queue slot belongs to the account
rather than to a person, and `demo.navidrome.org` shares one account with the whole internet.
Baton neither saves to nor reads from that slot there, so nobody is offered a stranger's queue.

### Running your Baton server

The Baton server is a small Swift program in this repository, under `gateway/`, where it goes by
its technical name, the Baton gateway (`baton-gateway`). It runs on macOS and on Linux, and it
wants to live somewhere always on. The same machine as your music server is the obvious home. It
needs a token you invent (both devices send it) and your Navidrome sign-in, and it refuses to
start without them:

```sh
export BATON_GATEWAY_TOKEN="a-long-random-string-you-make-up"
export NAVIDROME_URL="https://music.example.com"
export NAVIDROME_USER="you" NAVIDROME_PASSWORD="…"
swift run -c release baton-gateway          # listens on :8788
```

Full configuration, including running it under systemd or Docker and pointing its state file at
a mounted volume, is in [`gateway/README.md`](gateway/README.md).

Settings are kept in a plain JSON file on disk rather than in memory, because a restart is
routine, and losing your settings to a restarted container would be worse than never syncing
them.

### Turning it on

**On the Mac**, open **Settings → Remote → Baton server**. Paste the address into **Baton server
address** and the token into **Baton server token**, click **Save token**, then **Test**. A pass
tells you how many settings are already shared, or that nothing is there yet and this would be
the first device. After that the Mac syncs on its own: at launch, whenever you switch back to the
app, and every so often while a window is open. **Sync now** is there for when you don't want to
wait.

**On the iPhone**, open **Settings → Music Friend** and set **Answers come from** to **Baton
server**. The **Baton server** section appears with the same two fields: the address and the
**Baton server token** you chose when you set the server up.

The green light on both means a request that just happened, not that the fields are filled in.
Editing either field clears it, because the old answer belonged to a different address.

### When two devices disagree

Disagreements are settled per setting, not per device. Each setting carries when it changed and
which device changed it, and the newest one wins. Two devices changing *different* things never
overwrite each other, and the loser of a real race is one setting rather than everything you
touched that day.

Lists are the exception, because "newest wins" is the wrong rule for them: a search made on the
quieter device would vanish the moment the other one synced. Search history, filter history,
podcast subscriptions, clippings and what the friend remembers are **merged** instead.
Subscriptions merge per show, so unsubscribing on one device survives meeting a device that still
had the show, and subscribing again later survives too.

See also: [Getting your Mac's setup onto your phone](#getting-your-macs-setup-onto-your-phone)
for the one-time transfer, and [Backing up and restoring your
settings](#backing-up-and-restoring-your-settings) for a file you keep.

---

## Using more than one music server

If you run more than one music server, or want to keep your own and a friend's side by side,
Baton on the Mac can hold several connections and switch between them. This is about music
servers only. You have one Baton server at most, set up as described in
[The two servers Baton uses](#the-two-servers-baton-uses).

Open **Settings** (⌘,), choose **Music Servers**, and click **Add Music Server…**.
Give the server a name if you like, pick a sign-in method, and enter its address and sign-in.
Baton checks the new connection before saving it, then makes it the active one and reloads your
library.

- The server with the checkmark is the **active** one: the library you're browsing and playing
  right now.
- To switch, click another server in the list, or open its **⋯** menu and choose **Make
  Active**.
- The same menu has **Check Connection**, **Edit…** and **Remove…**. Removing a server makes
  Baton forget it and its saved password.
- Each server keeps its own sign-in, stored separately in the Keychain.

The connection you set up on first launch is already in this list, so you don't lose it.

---

## Finding your way around

On the Mac, the sidebar on the left is your way into the library. Here's each item, in order,
with a link to the section that covers it:

- **[Home](#home)** (⌘1): a greeting and a set of shelves you click to play.
- **[Search](#search)** (⌘2): songs, albums and artists at once.
- **[Mixes](#mixes)** (⌘3): mixes Baton builds for you from your listening.
- **[Albums](#albums-and-artists)** (⌘4) and **[Artists](#albums-and-artists)**
  (⌘5): browse your library the familiar way.
- **[Playlists](#playlists)** (⌘6): your server's playlists, which you can edit here.
- **[Liked](#liked)** (⌘7): everything you've hearted.
- **[Later](#later)** (⌘9): things you mean to get to.
- **[Clippings](#clippings)**: readings you kept.
- **[Books](#listening-to-a-document)**: narrated books made from documents.
- **[History](#history)** (⌘8): your local play log.
- **[Podcasts](#podcasts)**: shows your server hosts, plus any you add.
- **[Radio](#internet-radio)**: internet radio stations.
- **[Downloads](#downloads-and-offline-listening)**: everything you've saved for offline play,
  with a count badge.
- **[Folders](#browsing-by-folder)**: your music as the folders on disk.

Right-click a section to hide it (**Hide** and its name), or choose **Show All Sections** to
bring hidden ones back. Home can't be hidden. The **Go** menu lists every section, so it's the
way back to one you hid.

On the iPhone, the same places are spread across the tabs: **Home**, **Albums**, **Search**, and
**Library**, which holds the rest as rows.

Across list views you can select several rows at once and act on them together. See
[Rating, liking, and multi-select](#rating-liking-and-multi-select).

---

## Browsing by folder

The tag views (albums, artists, genres) are Navidrome's reading of your library. The
**Folders** view is the file system's: the directory tree exactly as it sits on disk, which
for a collection organized by hand often carries meaning the tags don't. If you have a
`Live bootlegs` folder, or a `1997` folder, or a folder per DJ set, that structure *is* your
filing system, and no amount of tag-reading will reconstruct it.

Open a folder to see its subfolders and its tracks in file order.

**Play means everything underneath.** Playing a folder plays every track inside it *and*
inside all of its subfolders, in order, so playing `Live bootlegs` plays the lot, not just
the handful of loose files at the top. On a very large tree Baton stops walking at some point
and tells you it did, rather than quietly playing a part of what you asked for.

It browses like the rest of the app, because it is the rest of the app:

- **Filter and sort** at the top, with the filter box remembering your recent terms.
- **List or grid**, whichever you prefer, remembered per screen.
- **Hover a folder** for a play button without opening it.
- **Right-click** for the same actions as a menu: play, queue, save to Later.
- **Select several** folders and act on all of them at once. Baton gathers the tracks under
  each one and treats them as a single pile.

On the Mac, Folders is a sidebar section. On iPhone it's a row in the Library tab. Both
browse the same tree, live from the server: nothing is duplicated locally.

---

## Home

Home is the screen that greets you when the library loads. On the Mac it opens with a greeting
that changes with the time of day (good morning, afternoon or evening). Below that is a set of
shelves you can click or tap to play. Each shelf appears only when it has something to show.

On the Mac, the shelves are:

- **Continue listening**, the podcast episodes you're part-way through.
- **Jump back in**, the tracks you've played recently, so you can pick up where you left off.
- **Because you liked…**, a radio-style shelf of music similar to something you've hearted or
  played a lot.
- **Recently added**, the newest arrivals on your server.
- **Rediscover**, a random dip back into your own library, for the albums you forgot you had.
- **Your Mixes**, quick cards into the [mixes](#mixes) Baton has built.

On the iPhone, the Home tab has **Recently Played**, **Your Mixes**, **Recently Added**,
**Daily Mixes**, **From Your Music Server** and **Rediscover**. The gear button at the top opens
Settings.

Everything on Home is one click or tap to start. It's meant to be the "just play me something"
screen. Until you've played a few things it stays mostly empty, with a note that it fills in as
you listen.

---

## Search

Search looks across **songs, albums and artists at once** and shows the matches together, so you
don't have to decide what kind of thing you're looking for before you type. Play any result
directly, or open an album or artist to go deeper.

Each browse screen also has its own filter box for narrowing the list you're already looking at.
Baton remembers your recent filter terms per screen. On the Mac you can choose how many it keeps
under **Settings → Playback → Advanced → Filter history size**.

### Search remembers two things, and both follow you

Baton keeps **what you typed** and **what you opened**, because they answer different questions.
The queries are the list under the clock icon in the search field on the Mac, and under **Recent
Searches** on the phone. The albums and artists you opened from a search appear under **Recently
Opened**. That's often the faster way back, since what you wanted was the record, not the words
you used to find it.

Both are shared between your Mac and your phone once
[shared settings](#shared-settings-between-your-devices) are set up. They're **merged, not
overwritten**: a search made on one device is added to what the other already had, so nothing you
looked for disappears because the other device synced more recently.

The opened albums and artists are remembered **per server**. They're stored as your server's own
IDs, which mean nothing on a different library. If you sign in to another server you'll see that
server's list, and switching back brings the first one back.

---

## Mixes

Mixes are playlists Baton assembles for you from how you actually listen. You don't build
them. They refresh from your library and your history. Open **Mixes** to see them.
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

**Playlists** shows the playlists that live on your server, and you can edit them here:

- **Create** a new playlist, **rename** it, or **delete** it.
- **Add** tracks to a playlist or **remove** them. Adding skips any tracks already in the
  playlist, so you won't get duplicates.
- **Reorder** tracks by dragging. The new order is saved back to your server, so it follows
  you to any other Subsonic client.
- **Make a playlist private or shared (public)** from its menu.
- Sort your playlists by name or track count, and hide empty ones.

You can also **save a queue, a selection, or a whole mix as a new playlist** from most browse
screens. Because playlists live on the server, anything you change here changes them there, for every
app you use.

---

## Liked

Anything you heart shows up in **Liked**, split into **Songs**, **Albums**, and **Artists**
so each kind is easy to find. The same sort and filter controls from the rest of the app
apply here too.

The heart appears when you hover a row or a card, so it's there when you want it and out of
the way when you don't. It works the same on an album or an artist as on a song: hover, click
the heart, and it lands in the matching tab of **Liked**.

Likes are stored per user on your server (as Subsonic "stars"), so every Subsonic app you use
sees the same ones.

---

## Later

**Later** is the pile of things you mean to get to. Someone sends you an album, you find a
podcast worth a proper sitting, a station catches your ear in passing: right-click it and
choose **Save to Later**, and it waits for you in one list.

It takes anything (songs, albums, artists, playlists, podcasts, and radio stations) and
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

**On iPhone**, Later is a row in the Library tab, with a badge for how many things are on it.
Touch and hold a song or an album and choose **Save to Later** to add one. Tap anything in
the list to play it, swipe a row left to remove it, and the menu in the top corner clears the
list. A pin is kept on the device that made it, so what you save on the phone stays on the
phone and what you saved on the Mac stays there.

---

## History

**History** is your local play log, the record of what you've actually listened to in Baton. It
has four views:

- **Recent**: your latest plays in order.
- **Tracks**: your most-played songs, each with a play-count badge.
- **Albums**: your most-played albums.
- **Artists**: the artists you've played most.

The Tracks, Albums and Artists views can be limited to **This Week**, **This Month** or **All
Time**, and a small summary strip at the top shows your totals and a per-day sparkline.

The log lives on the device. It's Baton's own memory of your listening, separate from the play
counts it reports to your server, and a free, local alternative to Last.fm or ListenBrainz. It
records a listen only once you've really played a track (the same point that counts for
[scrobbling](#scrobbling): half the track or four minutes), so skips don't clutter it.

From the log's menu you can turn logging off on this device, **export your history as
ListenBrainz JSON or CSV**, **import listens** from elsewhere, or **clear** it. Clearing only
affects your local list and stats. It doesn't touch your server's play counts.

The **Recently Played** list in an alarm's **What to Play** picker comes from this same log. See
[Choosing what plays](#choosing-what-plays).

### Whose plays you're looking at

Your Navidrome server records every play, from every device, against your user, so it has always
been the real record. Baton also keeps a small log on each device, which is what makes History
open instantly and work with no connection.

On iPhone, **Recent** reads from the server by default, so it includes what you played on the
Mac. Switch to **This iPhone** for the on-device log. **All-time Top Tracks** comes from the
server. The weekly and monthly rankings can only come from the device, because a Subsonic server
keeps a running count rather than a dated list of plays.

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
  support needed. Click **Add Show**, paste the feed's address, and Baton checks it before
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
  device sync as your other settings, so it needs your Baton server set up: see
  [Shared settings between your devices](#shared-settings-between-your-devices).
  Where you are in an episode is still per-device.
- **Downloading.** For shows you follow by RSS, episodes play right away with no download
  step, and a show's menu can grab the **latest 5**, **latest 10**, or **all** episodes at
  once for offline listening (and remove them again). For server-hosted shows, an episode
  that hasn't been fetched yet shows a **Download** button that asks the server to pull it.

Baton can delete a downloaded episode's file automatically once you finish it, to save space.
On the Mac that's **Settings → Playback → Downloads → Remove finished podcast episodes**, and
it's on by default.

You can also send an episode to an HTTP endpoint of your choice, for example a transcription
service, using [webhook actions](#webhook-actions).

Podcasts are deliberately left out of [scrobbling](#scrobbling). A podcast isn't a "listen"
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
  the next time it loads the Radio tab: no sync to set up, and nothing to keep in step.

When a station is on air, the [now-playing bar](#playing-music) switches into radio mode:
station artwork and name, the live track, and **Previous** and **Next station** buttons in
place of track skip. The scrubber, queue and rating controls tuck away, because there's
nothing to seek or rate on a live stream. The volume slider and the [sleep timer](#sleep-timer)
keep working, though the menu-bar menu hides its **Sleep Timer**, **Set Alarm…** and **Start
Timer…** while a station plays. Play anything from your library and the radio
stops, and the library player takes over.

---

## Downloads and offline listening

Baton can save tracks, albums, mixes, playlists and podcast episodes to your device and play them
straight from there. That helps in two ways: local files give you true gapless quality without
streaming again, and they keep your favorites with you when you're offline. **Baton prefers a
downloaded copy over streaming automatically**, and the **Downloads** item in the Mac's sidebar
carries a badge with how many you've saved.

On the Mac, the Downloads screen manages everything you've saved:

- **Play the whole set.** **Play all** and **Shuffle** in the header start the entire (filtered)
  list. Click any single track to play the list from that point on, just like an album.
- **Per-track actions.** Hover a row for quick actions: **Like**, **Play next**, **Add to
  queue**, **Start radio** (an endless "more like this"), and **Delete**. Right-click gives you
  the same menu. Each row shows the file's **size** and **length**.
- **Batch actions.** Select several rows (⌘A selects all), then **Play**, **Shuffle**,
  **Add to queue**, **Save as a new playlist**, **Add to an existing playlist**, or **Delete**
  them together.
- **See the footprint.** The header shows the **total size on disk**.
- **Offline mode.** Turn on **Offline mode** to keep playback on your local files and never
  stream. Browsing new things, and playing anything you haven't downloaded, still needs the
  server.

**Where the files go on the Mac.** Downloads live in a folder you can change under **Settings →
Playback → Downloads**, with **Choose Folder…**, **Show in Finder** and **Use Default**. You can
also set a **Filename format** from the tokens `{artist}`, `{album}`, `{title}` and `{id}` (the
default is `{artist} - {title}`) so saved files are named the way you like. Baton finds your
downloads by track ID whatever their names, so changing the folder or the format doesn't move or
rename files you've already saved. See the [Settings reference](#settings-reference) for the
exact controls.

**On the iPhone,** downloads are under **Library → Downloads**. The **Offline mode** switch is at
the top, with a progress bar while downloads run. If some fail, a line says how many, with
**Retry all**. Swipe a row to **Remove** it, or touch and hold it for the full menu. The phone
keeps downloads inside the app, so there's no folder or filename setting. Downloaded songs ignore
the streaming quality settings (see [How much data it uses](#how-much-data-it-uses)).

See also: [Scrobbling](#scrobbling). Plays you make offline wait in a queue and are sent once
you're back online.

---

## Clippings

Clippings are audio Baton made for you and kept: for now, readings saved from
[read aloud](#reading-whats-on-your-screen). After Baton reads something on the Mac, **File →
Keep Reading in Clippings** puts that audio here. They live in **Clippings** in the sidebar, which
carries a badge with how many you have.

This is the sibling of **File → Save Reading as Audio…**, which writes the same audio to a
folder you pick and then forgets about it. Keeping it in Clippings hands the file to Baton
instead, which stores it, lists it, and plays it.

A clipping is a real file on your Mac, so it needs no server and no network. It plays through
the ordinary player, with the same transport, now-playing bar, queue, and scrubber as anything
else. Double-click a row to play from there onwards. With nothing playing, the play button in
the header starts the whole list. The clipping you are listening to shows the moving bars and
stays highlighted, the way a song does in a list.

Clippings holds the short readings you keep. Narrated books made from documents have their own
section, **Books**, next to Clippings (see [Listening to a document](#listening-to-a-document)).

**You can search a clipping by what is said in it.** A saved reading keeps its words, so
typing a phrase from the middle of an article finds it, both in the Clippings filter and in
the main Search screen alongside your library results. The Clippings filter ignores case and
accents, so "cafe" finds "Café". The Books filter works the same way, by a book's title, its
author or something said in it, and stays quick with long books. Nothing else in
Baton can be found this way: your server only ever knows a track's title.

**Another voice.** On the Mac, **Change Voice…** in a reading's right-click menu reads its words
again in a voice you choose from your voice server. The row shows how far it has got, and the
reading keeps its old voice until the new audio is ready, then keeps its name and its place in
the list. **Stop Making Again** leaves it as it was. If you run your Baton server, the reading in
its new voice replaces the old one on your iPhone too.

**Renaming and deleting.** Right-click a row for **Play**, **Play Next**, **Rename…**, **Show in
Finder** and **Delete…**. Deleting asks first, and says plainly that Baton made this audio and there is no
other copy. A clipping is not a cached download with an original waiting on a server, so
deleting it cannot be undone.

**If a file goes missing.** Move or delete a clipping's audio outside Baton and its row stays
in the list, greyed out, saying the audio has gone. It is left out of playback rather than
stalling silently when you press play, and you can delete the leftover entry from the same
right-click menu.

**What a clipping is not.** It isn't a library track, so the controls that only a server can
answer are hidden on its rows: no rating, no like, no download, no radio. It is also left out
of [scrobbling](#scrobbling), since a reading saved from a web page isn't something your
listening history should carry.

**On your iPhone.** If you run your Baton server, clippings you keep on the Mac travel to the
phone, where they appear under **Library → Clippings** and play the same way. The phone collects
them when you open that screen, and when you pull down to refresh. It does not check for new
ones in the background, only when you look.

**Deleting a clipping on the phone asks which you mean.** Every device keeps its own copy of the
file, so the two answers do different things. **Remove from this iPhone** deletes the phone's
copy and remembers not to fetch it again. Your Mac keeps its own. **Delete Everywhere** also
removes the shared copy from your Baton server, so no device collects it again. The Mac asks the same
question, with **Remove from This Mac** and **Delete Everywhere**.

---

## Listening to a document

Baton can turn a document into a narrated book in **Books**: a PDF, an EPUB, a web page (saved
as HTML, or just its link), a Markdown file or plain text. On the Mac, choose **File → Import
Document…** (⇧⌘O) or **File → Import Link…**, or drag the file onto **Books**. In Finder,
Control-click the file and choose **Open With → Baton** or **Services → Make an Audiobook with
Baton**. Baton never makes itself the default app for these files.

On the iPhone, share the file or the web page to Baton from another app's share sheet (Safari
works too), open it in Baton from Files, or use the **+** menu on the Books screen: **Import a
File…** or **Import a Link…**. However it arrives, the book lands in Books.

Before anything is made, Baton shows what it found: the title and author, the chapters, anything
it set aside (a publication note on the title page, for example) and anything it could not read.
It also says roughly how long the book will be and how much space it will take. A scanned PDF,
one made of pictures of pages, is read with text recognition, and Baton names the pages it read
that way, because recognition can misread a word. Choose **Make Audiobook** to start.

**The narrator.** On the Mac, a language model suggests three voices for the book, each with its
reason, and you can hear each one read the book's own words before you choose. Baton asks a model
on your own machines: Apple Intelligence on this Mac, a model you run with Ollama or LM Studio
(set up under **Settings → Speech → Models on this Mac**), or the one your Baton server uses. A
cloud model is asked only if you allow it (see [Book text and cloud
models](#book-text-and-cloud-models)). With no model answering, Baton suggests the default voice
for the book's language.

On the iPhone, the import screen lists the same three voices the Mac offers without a model, from
those your Baton server has (Heart first, or Emma for a book in British English). Tap one to
choose it, and its play button to hear it.

**Every voice.** The suggested voices stay on top, and **All voices** below them lists every voice
the book can be made with: your Baton server's when it makes the book, and on the Mac this Mac's
own when **Made on** says **This Mac**. Each voice is named in words, such as "Heart, American,
female", and grouped by accent or language and by gender. Type in the search field to narrow the
list, for example "british male" or "spanish", and use the play button on any row to hear it.

Baton remembers the narrator you last chose for each language on that device. The next book in
that language starts on it, marked "last used", when the voices on offer include it. If your Baton
server cannot list its voices, the suggested ones are still there, with a line saying why.

**Where it is made.** The import sheet asks **Made on: Baton server** or **This Mac**, unless
**Settings → Speech → Make books on** already says which. With a Baton server set up, the sheet
starts on **Baton server**.

- Your **Baton server** makes the book while the Mac sleeps, with its own voice server.
- **This Mac** narrates it with the engine chosen under **Voice engine for books**: its built-in
  voices, a voice server, or Automatic (see [Voices: on this Mac or on your Baton
  server](#voices-on-this-mac-or-on-your-baton-server)). A book made on this Mac is sent to your
  Baton server as each chapter is done, so your iPhone gets it too. The sheet says so under
  **This Mac**, or says **Only on this Mac** when no Baton server is set up.
- **The iPhone** has no voices of its own, so it always asks your Baton server, and says so when
  none is set up.

Either way the book is made one chapter at a time, starting with chapter 1, which is usually ready
in a minute or two while the rest follows as you listen. Page numbers, running heads and words
broken across lines are tidied up first, and anything that looks like a password or key is left
out.

**When your Baton server cannot make books,** the iPhone offers **Send to my Mac** in place of
Make Audiobook. Your Baton server keeps the document for your Mac to collect for up to two weeks,
and Baton on the Mac collects it while it is open with Documents on. Open Baton on the Mac soon:
after two weeks, or sooner if the Baton server runs short of room for shared files, the document
is gone. The Mac then lists it at the top of Books as not arrived, and you send it again from
the iPhone.

On the Mac, the document opens in the import sheet, marked with the device that sent it. **Not
Now** keeps it waiting in a list at the top of Books, with **Import…** and **Discard**. **Make
Audiobook** or **Discard** takes it off the Baton server. With no Baton server at all, the phone
suggests AirDropping the file or link to your Mac instead.

**If the voice host stops answering,** the book pauses and its row says why. It carries on by
itself when the host is back. It never finishes in a different voice.

**Quitting is fine.** If you quit Baton while a book is being made, it picks up where it stopped
the next time Baton opens. Nothing already narrated is made again. On the iPhone, **Stop Making
This Book** in the book's menu stops one your Baton server is still making.

**Books.** Books have a section of their own: **Books** in the Mac's sidebar, and **Library →
Books** on the iPhone, next to Clippings. Each book is one row, with its author, its length, how
much of it you have heard and where it was made.

Click or tap the row to open the book: its chapters, **Play** (or **Resume**, once you have a place
in it), **Read Along**, **Change Voice…** and its storage. While one of its chapters is playing,
the main button says **Pause**. On the Mac, **More** holds the rest of the book's menu, the same
menu you get by Control-clicking its row, and **Books** at the top goes back to the list (⌘[).

**Listening.** **Play** starts where you left off, and the chapters play in order like the tracks
of an album. Double-click a chapter on the Mac, or tap it on the iPhone, to start there. The
chapter playing shows the moving bars, and so does the book's row in the list.

Your place follows you: Play picks up at the chapter and the moment you last heard on either
device, and finishing a book on one device marks it finished on the others. A book made on the
Baton server from one device appears in Books on your others too, marked **Made on the Baton
server**, without importing the file again, and its chapters come down as they are ready. Once you
finish it, its row on the Mac says how long the Baton server keeps it ("Kept until 2 November").

**Speed and sleep.** While a book or a podcast plays, the speed button beside the moon plays it
anywhere from 0.75× to 2× without changing the voice's pitch. Books and podcasts share one speed,
which Baton remembers and your other devices pick up. Music always plays at normal speed. The
[sleep timer](#sleep-timer) works for books too: its **End of chapter** choice stops between
chapters, so Play carries on with the next one.

**Reading along.** While a book plays, its text can be on screen with the sentence you are hearing
highlighted. Open the book and choose **Read Along**. On the Mac you can also Control-click the
book or open the player's **Transcript** panel, and on the iPhone tap the book button in the full
player. Tap a sentence to listen from there. Books made before this feature show their text
without the highlight.

**Coming back after a break.** On the Mac, press Play on a book you last heard more than a day
ago, once you have heard a fair part of it, and Baton offers **Hear Recap**: a short spoken
summary of what you have heard so far, never anything past where you are, and then the book
carries on. **Just Play** skips it. The recap is written by a model, like the narrator suggestion.

The iPhone offers the same recap, written by the music friend's model when it is on your network,
or by Apple Intelligence on the iPhone, and read by your Baton server in a voice other than the
narrator's. A phone that reaches a model only through your Baton server gets its recap from the
Baton server's model when that model is on your network. Before chapters would go to a cloud
model, the iPhone asks, and keeps your answer in **Settings → Documents**.

**Exporting.** On the Mac, Control-click a book, or open it and choose **More**, then **Export
Audiobook…** to save it as one M4B file that Apple Books and other audiobook players open, with a
chapter mark where each chapter starts. The book has to be finished first. For a book made on this
Mac, the marks need ffmpeg (`brew install ffmpeg`). Without it you get one file with no marks, and
Baton says so.

**Covers.** A book shows its cover on its row, at the top of the open book and in Now Playing,
including the lock screen and Control Center. An EPUB keeps its own cover when you import it. For
any other book, open its menu: on the Mac, Control-click it and choose from the cover items, or
open it and choose **More**. On the iPhone, tap the cover or touch and hold the book's row.

- **Find Cover…** looks the book up on Open Library and shows the covers it has. Pick one and
  choose **Use Cover**. Only the title and author are sent, and only when you ask.
- **Make a Cover** draws a simple cover from the title and author, on your device. It needs both,
  so it is greyed out for a book with no author. The same book always gets the same cover.
- **Choose Image…** uses a picture you pick. Choosing an EPUB uses that book's own cover.
- **Remove Cover** goes back to the plain book mark.

The cover travels with the book through your Baton server, so a cover chosen on the Mac shows on
the iPhone, and the other way round.

**Names the narrator gets wrong.** With a Kokoro narrator, the Mac's import sheet lists names it
might stumble on, each with a pronunciation a model proposed, and you can correct any of them or
add your own. **Pronunciations…** in the book's menu opens the same list later. Saving makes again
only the chapters that say a word you changed. For a book made on the Baton server, those chapters
are made again there and replace the old ones as they arrive, and you keep your place.

**Changing the voice.** To hear a book in another narrator's voice, open it and choose **Change
Voice…**, or Control-click it on the Mac, or touch and hold it on the iPhone. The voices are listed
as they are when you import: the voice it has now and the best for its language on top, and every
voice under **All voices**, each with a button to hear it read the book's own words.

The whole book is made again where it was made before: on your Baton server, or on the Mac. Its
row says "Making again in" the new voice, with how far it has got. Each chapter keeps playing in
its old voice until its new one arrives and takes its place, so there is no gap and you keep your
place. Your pronunciations carry over, and a new narrator keeps the book's cast.

**Voice the dialogue** is in the same sheet: turn it on to give a book made with one narrator a
cast, use **Edit Cast…** to rename, merge, revoice or remove a speaker, or turn it off to go back
to one narrator (see [Voice the dialogue](#voice-the-dialogue)). **Stop Making Again** in the same
menu puts back the old voice, and the old cast with it. Your other devices pick up the new
chapters as they arrive.

**Turning it off.** Documents are on unless you turn them off. The **Documents** switch under
**Settings → Speech → Documents** on the Mac, or **Settings → Documents** on the iPhone, takes the
import items, the drop target and the book rows away on that device alone, at once and without a
restart. The other device keeps its own setting.

**For agents.** The `import_document` tool takes the path of a file on this Mac, or a link to one,
and makes the book the same way, where **Make books on** says. It can also name the narrator and
the book's tone. With **Ask each time** it makes the book on this Mac unless the agent asks for the
Baton server, and if the Baton server does not answer, this Mac makes it. Its reply says where the
book is being made.

`document_context` lets an agent read the passages of a book you have already heard, never anything
past where you are, so it can answer a question like "who is Kuno again?" without spoiling the
rest. Both, and the book tools, are listed only while Documents is on.

### Voices: on this Mac or on your Baton server

A book is read aloud by a voice engine. Baton can use one of two, and on the Mac you choose
which under **Settings → Speech → Voice engine for books**:

- **Built-in voices on this Mac.** Kokoro's English voices, run by Baton itself after a
  one-time download. Mac only.
- **Voice server.** A Kokoro or Chatterbox server you run, on this Mac or on another machine
  on your network, reached by its address.

| | **Built-in voices on this Mac** | **Voice server** |
|---|---|---|
| Where it runs | Inside Baton on this Mac | A Kokoro or Chatterbox server, on this Mac or another machine |
| Quality | Kokoro. In a side-by-side listening test it sounded the same as the server | Kokoro sounds the same; Chatterbox adds its own voices and voice cloning |
| Speed | About 13 times faster than real time on an M5 Max | About 17 times faster than real time for Kokoro on a home-network server |
| Languages and voices | English only, 28 voices | Every voice the server has: Kokoro's other languages, and Chatterbox |
| Privacy | Nothing leaves this Mac | The book's text goes to the server's address |
| Network | None. Works offline | The server's address has to answer while the book is made |
| What to set up | Download 342 MB once. Needs a Mac with Apple silicon | Run the server, and enter its address under **Settings → Speech → Services** |

The speeds were measured once, on one Mac running a test build of Baton and one Kokoro server
on a home network, in October 2026. Your Mac and server will differ.

**Recommended on a Mac with Apple silicon: download the built-in voices.** In a side-by-side
listening test they sounded the same as the server, and the listener could not tell which was
which. With them, an English book is made offline and its text never leaves your Mac. Leave
**Automatic** on and keep a voice server for other languages and Chatterbox.

**Choosing on the Mac.** **Settings → Speech → Voice engine for books** has three choices.
Each shows what it needs and how it stands right now: downloaded or not, or each server's
address and whether it answers.

- **Automatic** (the default). Whenever the built-in voices are downloaded, Baton uses them
  first for every voice they have (their 28 English voices), and the voice server for every
  other voice. Without the download, every voice goes to the voice server.
- **Built-in voices on this Mac.** Only the built-in voices. A voice they do not have, such as
  a Chatterbox voice or a Kokoro voice in another language, is not sent to a server: the book
  pauses and its row says why, and the import sheet offers only the built-in voices. The same
  happens if they are not downloaded yet.
- **Voice server.** Only your voice servers, even when the built-in voices are downloaded. If
  no server answers, the book pauses until one does.

A paused book carries on by itself once the reason is gone, for example after the download
finishes or after you change the choice. The choice is this Mac's alone: it does not travel to
your other devices, and **Reset to Defaults** in the Speech pane puts it back to Automatic.
Spoken summaries and Read aloud are not affected. They use the servers under **Services**.

**Where a book is made.** Under the same heading, **Make books on** decides where the Mac
makes a new book: **Ask each time** (the default) shows the choice in the import sheet,
starting on the Baton server when it answers. **This Mac** or **Baton server** makes it there
without asking. If the Baton server is chosen and not answering, the sheet says so and the book
is made on this Mac. The Baton server reads books with its own voice server, the one named in
the Baton server's own setup, not with this Mac's Voice engine for books.

**On the iPhone** there is no choice to make. The phone has no voices of its own, so every book
is made on your Baton server with its voice server. **Settings → Documents** says so.
It needs the Baton server's address and token under **Settings → Music Friend**, and the
Baton server's voice server answering. When the Baton server cannot make a book, **Send to my Mac**
hands it to Baton on your Mac instead.

#### Setting up the built-in voices

1. On a Mac with Apple silicon, open **Settings → Speech**. Make sure **Documents** is on.
2. Under **Voice engine for books**, press **Download (342 MB)** below **Built-in voices on
   this Mac**. Nothing downloads until you press it, and **Cancel** stops it. A later
   **Download** picks up where it stopped.
3. When the line under the choice says **Downloaded, 28 English voices**, choose **Automatic**
   or **Built-in voices on this Mac**.

**Remove** takes the download away again. An Intel Mac cannot run them, and the line says so.

#### Setting up a voice server

1. Run Kokoro, Chatterbox or both on this Mac or on a machine on your network. The steps are
   under **Setting up Kokoro** and **Setting up Chatterbox** in [The voices
   themselves](#the-voices-themselves).
2. In **Settings → Speech → Services**, enter each address, such as `http://mybox.local:8880`
   for Kokoro, and click the ↻ button beside it (**Test this connection**).
3. Under **Voice engine for books**, the **Voice server** line shows each address and whether
   it answers. Choose **Voice server**, or leave **Automatic**.

#### An expressive voice server

For narration that sounds more like a person reading, Baton can also use a speech server that
answers the same requests as OpenAI's speech API. Qwen3-TTS is the one Baton was tuned with:
it reads at an audiobook pace and moves its voice more than Kokoro does.

1. Run the server on a machine on your network.
2. In **Settings → Speech → Voice engine for books**, under **Expressive voice server**, enter its
   address, such as `http://mybox.local:8190`, and the model name if it is not `qwen3-tts`. Enter
   a key only if the server asks for one. **Save Key** keeps it in the Keychain.
3. Its voices appear in the voice lists under **Expressive voices**, after Kokoro's. Qwen3-TTS's
   own voices are shown by name, language and gender, such as "Aiden, English, male".

An expressive voice reads one sentence at a time, with about half a second between sentences and
about a second between paragraphs. Each line is sent with a short direction: the narrator is
asked to read like an audiobook narrator in the book's tone, and each character in **Voice the
dialogue** is described by their gender and age, such as "an elderly woman". A cast is proposed
from the narrator's engine, so with an expressive narrator the characters get expressive voices
too, and any character can be given a voice from another engine. Kokoro books are read exactly as
before.

#### Setting up the Baton server's voice server

The Baton server makes books with the voice server named in its own setup, whichever device
sent the book.

1. Run Kokoro (and Chatterbox if you want its voices) where the Baton server can reach it. It
   can be the same machine or another one on your network.
2. In the Baton server's environment, set `BATON_TTS_KOKORO_URL` to Kokoro's address, for example
   `http://YOUR-TTS-HOST:8880`, and `BATON_TTS_CHATTERBOX_URL` to Chatterbox's if you use it.
   Without `BATON_TTS_KOKORO_URL` the Baton server looks for Kokoro on its own machine at
   `http://127.0.0.1:8880`. For an expressive voice server, set `BATON_TTS_OPENAI_URL`, and
   `BATON_TTS_OPENAI_MODEL` if its model is not `qwen3-tts`. If it needs a key, put the key in a
   file only its owner can read (`chmod 600`) and set `BATON_TTS_OPENAI_KEY_FILE` to that file.
   Its voices then appear on the iPhone too.
3. Restart the Baton server. Its log names the voice servers it uses (`books: …, TTS …`). The
   Baton server also needs ffmpeg to make books. See [`gateway/README.md`](gateway/README.md).

### Voice the dialogue

Normally one narrator reads everything. Turn on **Voice the dialogue** when you import a book, on
the Mac or the iPhone, to give each speaking character a voice of their own. It is off for the
first book you import on a device. After that it starts the way you last left it there.

A model reads passages from across the book and proposes a cast: who speaks, the names the text
calls them by, and a voice for each from the narrator's engine. Nothing is used until you check
it. **Check the Cast…** lets you rename someone, merge two names for one person, mark the
narrator, remove someone who never speaks, and choose a voice for each from every engine you have,
Kokoro, an expressive server or Chatterbox, with **Hear** to listen to them say one of their own
lines. Then choose **Use This Cast**. Voices from different engines can share a chapter.

Baton then works out who says each line. A line with a speech tag ("said Mr. Bennet") is placed
by rules, and a model is asked about the rest, with a progress line and a **Skip** button. One
line tells you how many have a speaker, and the narrator reads any that nobody can place. With no
model answering, the sheet says so and the book stays with one narrator.

On the iPhone the models are the ones it can reach: the model on your network that Baton's
assistant uses, your Baton server's, and Apple Intelligence on the iPhone, with a cloud model only
if you allow it. Your Baton server makes the book, and reads each line in its speaker's voice.

**A book already made.** **Change Voice…** has the same switch. For a book made with one narrator,
turn it on and the cast is proposed and checked as at import. For a book with a cast, **Edit
Cast…** lets you rename, merge, give someone another voice, or remove them. Each line keeps the
speaker it has, so nothing is worked out again, and the lines of someone you remove go back to the
narrator. Turn it off for one narrator again. Then **Make Again**: the whole book is made again,
and your place is kept.

### Book storage

A book takes about a third of a megabyte for each minute of listening: a 25 page story is about
25 MB. These controls are in the open book (under **Storage** on the iPhone, beside its size on
the Mac) and in the book's menu in Books:

- **Remove Download** frees the space and keeps the book's row, its words, its voice and your
  place. A single chapter can go the same way. It is only offered when the audio can come back.
- **Download Again** brings the chapters back from your Baton server. **Render Again** makes them
  again: on this Mac for a book made here, or on the Baton server once it has removed its copy.
- **Keep on This Mac** (or **Keep on This iPhone**) means no rule or suggestion ever removes it.
- **Delete Book…** asks which you mean. **Remove from This Mac** (or **Remove from this iPhone**)
  removes it from this device. **Delete Everywhere** also removes it from your Baton server and
  your other devices. A book made on the Baton server and removed from one device stays there for
  your other devices, and the device you removed it from does not pick it up again. A book made on
  this Mac and sent to your Baton server follows the same rules.

A deleted book and a removed download stay in **Recently Removed** for a week. A deleted book's
audio is kept until then, so **Restore** brings it back as it was, and **Delete Now** frees the
space sooner.

**Storage** is under **Settings → Storage** on the Mac and **Settings → Documents → Storage** on
the iPhone. It lists this device's books with their sizes, the Baton server's books with how long
it keeps finished ones, and three cleanup rules: **After I finish a book**, **Books I haven't
played** and **Space for books**. Nothing is removed until you choose a rule. A rule removes a
download, never the book, and never the book you are listening to or one marked Keep. Each device
has its own rules.

At most once a week, Books may suggest something: removing the download of a book you
finished a while ago, or, when the device is short of space, of your largest finished books.
**Always Do This** turns the first kind into a rule that removes a finished book's download a
week after you finish it.

### Book text and cloud models
<!-- baton:audience mac -->

Models on this Mac, on your Baton server and Apple Intelligence keep a book on your own machines,
so Baton uses them without asking. A cloud model, such as the one your music friend may run on,
gets a book's text only with your permission.

The first time only a cloud model could suggest a narrator, the import sheet asks whether to
send it the book's opening: **Not Now**, **Allow Once** or **Always**. To change your answers
later, open **Settings → Agents** and find **Book text and cloud models**. Each cloud model you
have set up has two switches:

- **Short excerpts**: the book's opening for the narrator suggestion and the cast list, and the
  names a voice might stumble on.
- **Chapters**: the chapters you have already heard, for a recap, and the lines a model places
  for Voice the dialogue.

**Forget My Answers** clears them all. The answers stay on this Mac, and anything that looks
like a password or key is taken out before any text is sent.

---

## Playing music

### The now-playing bar

On the Mac, a bar sits at the bottom of the window the whole time. Expanded, it gives you the
scrubber, the transport controls (previous, play and pause, next), volume, the queue, the sleep
timer's moon, the alarm clock, and the AirPlay picker. While a timer runs or an alarm is due, a
small pill beside the clock shows it (see [Alarm and Timer](#alarm-and-timer)). You can
**collapse the bar to a slim strip** to save space with ⌃⌘J, and expand it again the same way.

### The little bars that mark what's playing

Wherever a track appears in a list (search results, an album, the queue, a folder), the one
you're listening to is marked by a small set of moving bars instead of a still symbol. They tell
you two things at a glance: which row is current, and whether it's actually playing. A paused
track holds its bars still.

**They move with the music, not on a loop.** The bars follow the sound itself, read in four
frequency bands as it plays, so they lift with the bassline and flicker on the hi-hats. Where
that reading isn't available (internet radio, or the first second of a track before any audio
has arrived), they fall back to an even animation that looks much the same.

If you have **Reduce Motion** turned on, the bars are drawn at rest instead of moving. They still
mark the row.

### Full-screen Now Playing

Open the full-screen player for big artwork, a soft backdrop tinted from the album art, and a
**waveform scrubber** for tracks you've downloaded. Along the side are panels for the **Queue**,
**Lyrics** and **Related** tracks, plus **Transcript** (or **Read Along** for a book). On the
Mac, **Space** plays or pauses and **Escape** leaves full screen.

On the Mac, click **Appearance** beside AirPlay to choose **System**, **Light** or **Dark**
directly. The full player and Mini Player share this choice with Settings. **System** follows
your Mac's appearance.

On the iPhone, tap the mini player to open the full player. Its row of controls holds Up Next,
Lyrics, Transcript (or Read Along), Related, the speed button for books and podcasts, AirPlay,
the alarm clock and the sleep timer's moon.

**Tip:** the link `baton://player` opens the full player directly, in both apps. It's the link the
iPhone's widgets use.

### Lyrics

The **Lyrics** panel shows words for whatever is playing. When they come with timings they
scroll karaoke-style, and you can tap or click a line to jump to it. Without timings you get
plain text.

Where they come from explains an empty panel. Navidrome only serves lyrics that are **embedded in
your files**, and most libraries have very few of those, so for most people this panel starts out
blank whatever is playing.

Turn on **Settings → About → Lyrics → Look up missing lyrics** on the Mac, or **Settings →
Sound → Look Up Missing Lyrics** on the iPhone, and Baton asks [LRCLIB](https://lrclib.net), a free and open lyrics
database, for anything your server doesn't have. It sends only the track's title, artist, album
and length. Your library, your history and who you are stay with you. It's off until you turn it
on. Lyrics embedded in your own files always win, so turning this on never overwrites
what you already have.

Podcast episodes don't use this. They get [transcripts](#transcripts-and-summaries) instead,
which are made a different way.

### The floating mini-player
<!-- baton:audience mac -->

Baton has a borderless, always-on-top **Mini Player** window (⌥⌘M, or **Playback → Mini
Player**). It's a compact card you can park in a corner while you work in other apps, showing the
current track, artwork, the scrubber, the rating, and what's up next, and it expands for a little
more. Opening it closes the main window. On macOS 26 and later it's drawn with Liquid Glass.

### The mini player on iPhone
<!-- baton:audience iphone -->

On the phone, the now-playing bar is a small capsule floating above the tabs: artwork, the track
title and artist, play/pause, next, and an ✕ that stops and closes the player. Tap anywhere else
on it for the full player.

On iOS 26 and later, the bar also **gets out of the way while you browse**. Scroll down any list
and the tab bar shrinks to just the current tab's icon, with a slimmer player (artwork, title,
play/pause) docked beside it. Scroll back up, or tap the shrunken bar, and the full tabs and
controls come back exactly as they were.

### The menu-bar controller
<!-- baton:audience mac -->

Baton also lives in the menu bar, so it stays reachable even when every window is closed, and so
does the [agent control server](#letting-an-agent-control-your-music). Click the icon for a menu
that holds, from the top:

- What's playing (click the title to open the full player), or **Nothing Playing**.
- **Play/Pause**, **Next** and **Previous** (they become **Next Station** and **Previous
  Station** for radio), **Mute**, and **Like** or **Unlike**.
- **Volume** (100, 75, 50, 25 or 0 percent), **Sleep Timer**, **Set Alarm…** and **Start
  Timer…**. The last three are hidden while a radio station plays.
- **Open Baton**, **Mini Player** and **Recent Summaries…**.
- **Copy MCP Endpoint**, **Settings…**, **Check for Updates…**, **What's New…**, **About Baton**
  and **Quit Baton**.

**Settings → Playback → Menu Bar → Show track title in menu bar** puts the current title beside
the icon.

---

## Adaptive artwork colors

Baton tints itself to whatever's playing. In the full-screen player the backdrop is a gentle
gradient built from the current track's cover art, and the player's accents (the progress
and volume fills, the shuffle and repeat indicators, and the heart and star controls) pick
up a vivid color pulled from that same artwork, nudged where needed so it always stays
readable. When a track has no cover art, or only muted, near-grey art, Baton falls back to
its signature **Baton orange**. The colors cross-fade gently as tracks change. This is purely
cosmetic. Nothing about your library or your playback changes.

---

## The queue, shuffle, repeat, and autoplay

**The queue.** Drag to reorder it, remove tracks, or clear it. Baton remembers your queue
between launches (the tracks, your position, and where the queue came from) and restores it
paused the next time you open the app.

**Play, Pause and Resume.** The Play button on an album, playlist, artist, mix, folder or
podcast plays it in order. While that collection is playing the button says **Pause**, and while
it is paused it says **Resume**, so the one button stops and starts it. Rows, cards and their
menus follow the same rule, on the Mac and the iPhone.

**Shuffle** reshuffles the queue while keeping the current track playing. Turn it off and the
original order comes back, including songs you added or chose to play next while shuffling. The
Shuffle button beside a collection's Play starts that collection shuffled, and it lights up only
while that collection is the one shuffling.

**Repeat** cycles through three modes: **Off**, **All** (loop the whole queue), and **One**
(loop the current track).

**Autoplay similar tracks.** When you turn this on, Baton keeps the music going as the queue
runs low by adding tracks similar to what's playing, a kind of radio for the end of a queue. It's
off by default. On the Mac it's **Settings → Playback → Sound → Autoplay similar tracks when the
queue ends**, and on the iPhone **Settings → Queue → Autoplay similar songs**. You can also
choose **Start Radio** from a track's menu for an endless "more like this".

---

## Sleep timer

The sleep timer stops the music for you after a while, so you can fall asleep to it.

**Where to find it.** On the Mac, click the moon in the now-playing bar or the full-screen
player, or use **Playback → Sleep Timer** or the **Sleep Timer** item in the menu-bar menu (that
one is hidden while a radio station plays). On the iPhone, tap the moon in the full player. The
same moon is at the top of **Clippings** and **Books**, and in **Read Along**, while something
plays.

**What you can choose.** Pick a fixed length: **15 minutes**, **30 minutes**, **45 minutes**,
**1 hour**, **2 hours** or **3 hours**. Or choose **End of track** to stop when the current song
finishes. For a book it says **End of chapter**, and for a podcast **End of episode**. (The menus
in the menu bar and the Playback menu write these in title case.)

When a fixed timer is up, Baton **fades out gently** over about five seconds rather than cutting
off mid-note, then pauses. If a radio station is playing, it stops.

**Turning it off.** Once a timer is set, the moon shows the time left, or **End of chapter** and
the like. To cancel it, choose **Turn off sleep timer** from the moon's menu on the Mac (**Turn
Off Sleep Timer** in the Playback and menu-bar menus), or **Cancel sleep timer** at the top of the
menu on the iPhone.

**From an agent.** On the Mac, an agent can set or cancel the timer with the `music_sleep_timer`
tool, in minutes only (it has no end-of-track choice). The iPhone's music friend can't set it.

See also: [Alarm and Timer](#alarm-and-timer). The sleep timer stops music, and an alarm starts
it.

---

## Alarm and Timer

These work like the Alarm and Timer in Apple's Clock app, except that what rings is something
from Baton: a song, an album, a playlist, a book from where you left it, or a radio station.

The [sleep timer](#sleep-timer) is a separate thing. It stops music, and these start it.

### Setting an alarm or a timer

It takes a couple of taps from wherever you are:

- **The clock in the player.** It sits beside the sleep timer's moon: in the full player on the
  iPhone, and in the now-playing bar and the full-screen player on the Mac. It opens on the
  **Timer** tab, as a sheet on the iPhone and a popover on the Mac.
- **Set Alarm…** or **Start Timer…** in the menu of a song, an album, a playlist or a book
  (touch and hold on the iPhone, right-click on the Mac), with that item already chosen. The
  sleep timer's menu has them too. On the Mac they are also under **Playback** and in the
  menu-bar menu, and they open a small window called **Alarm**.

The sheet has two tabs.

**Timer.** Tap **5 min**, **10 min**, **15 min**, **30 min** or **1 hr**, or **Custom** for any
length from one second to 23 hours, 59 minutes and 59 seconds. Then tap **Start** (on the Mac the
button names the length, such as **Start 5 min**). While it runs, the sheet shows the countdown
with **Pause**, **Resume** and **Cancel**. There's one timer at a time, as in Clock: cancel it to
set another.

**Alarm.** Turn the time (on the Mac, type it or use the arrows), or tap a quick pick: 7:00 or
8:00 (each says today or tomorrow, whichever comes next, in your clock's format), **In 1 hour**
or **In 8 hours**. Then choose:

- **Repeat**: the days it goes off. It reads "Never", "Every day", "Weekdays", "Weekends", or the
  days you picked.
- **Label**: a name for it, if you want one.
- **Snooze**: on unless you turn it off.
- **Gentle Wake**: off unless you turn it on. See [Gentle Wake](#gentle-wake).
- **Then play**: what starts when it goes off. See [Choosing what plays](#choosing-what-plays).

Then tap **Save** on the iPhone (**Save Changes** when you're editing one), or **Save Alarm** on
the Mac. Your alarms are listed under **Your Alarms** with a switch each. Tap one to change it,
and swipe it or use its menu to delete it. An alarm that doesn't repeat switches itself off after
it goes off.

### An alarm and a timer together

You can have an alarm and a timer set at the same time. They don't affect each other.

While a timer runs, or an alarm is due within a day, a small pill sits just above the mini player
on the iPhone, and beside the clock on the Mac. The timer's pill counts down ("Timer 12:34 ·
then …") and the alarm's shows its time ("Alarm 7:00 · then …"). With both set there are two
pills, the timer's first. On the iPhone they are stacked, each as wide as the player under it,
and on the Mac they sit side by side.

Tap a pill to open the sheet. Its ✕ affects only that one: it cancels the timer, or switches the
alarm off.

### Gentle Wake

Gentle Wake is for an alarm that shouldn't jump at you. Each alarm has its own **Gentle Wake**
switch ("Starts quiet, full volume in 30 seconds"), and an alarm with it on says ", gentle wake"
in the list. Timers don't have it, because a timer is for something you need to hear straight
away.

**In the player.** When the alarm goes off, Baton starts the music very quiet (30 decibels
below your volume) and raises it evenly to your own volume over 30 seconds. It is never louder than
you set it. Radio stations rise the same way.

- If the music is still loading, the rise waits at the quiet level until the track is actually
  playing. If nothing has started after 60 seconds, Baton stops waiting and goes to your volume.
- If you change Baton's volume yourself, or mute, the rise stops and your setting stands. On the
  iPhone, the side volume buttons change the phone's volume, not Baton's, so they don't end it.
- **Pause**, **Stop** and **Snooze** keep the level the rise had reached rather than jumping to
  full. The next time anything plays, it plays at your normal volume.

**In the alarm sound.** On the iPhone, the alarm sound itself rises too: up to full over its
first 20 seconds, then full for the rest. On iOS 26.1 and later the alarm sound repeats until you
answer it, so each time round it starts quiet again and climbs back to full. When Baton couldn't
make a sound from your song, a Gentle Wake alarm rings a rising version of Baton's chime. On the
Mac, the notification for a Gentle Wake alarm uses the rising chime.

One sound is not faded: the chime Baton plays inside the app when the music hasn't started 10
seconds after the alarm time (see [When it goes off](#when-it-goes-off)).

### Choosing what plays

**Then play** is what starts when the alarm or timer goes off. It begins as the item whose menu
you used, or else what is playing, or else the last song you played.

Tap it to open **What to Play**. There you can search your songs, albums, playlists, books and
radio stations, **Browse** Playlists, Albums, Books and Radio, or pick from **Recently Played**.
The round button on a row plays ten seconds of it, and stops when you leave the picker. Nothing
needs to be playing to choose.

**Recently Played** is this device's own play log: the last 50 different songs you listened to
here, newest first, each listed once. Like [History](#history), it counts only songs you really
listened to, so skips don't appear. It's empty if you turned the log off or cleared it, and on the
iPhone it doesn't include what you played on the Mac.

A book starts from where you left it at the moment the alarm goes off.

### When it goes off

If Baton is open, or playing in the background, the chosen item starts at the time and a ringing
screen comes up over whatever you were doing, Settings included. It has three answers:

- **Keep playing, open player** closes whatever was open and takes you to the full player.
- **Snooze 9 min** pauses and goes off again in nine minutes. For a timer, that's a fresh
  nine-minute timer for the same item. An alarm offers it only when its **Snooze** is on.
- **Stop** pauses the music.

On the Mac the ringing card floats over every Space with the same three buttons, and **Keep
playing, open player** brings the Baton window forward with its full-screen player.

**If the music doesn't start.** If nothing is playing 10 seconds after the time (a stream that
won't load, say), Baton plays its chime. On the Mac it repeats until you answer it. On the iPhone
it plays five times in all.

**If it's very late.** An alarm that comes round while your Mac is asleep, and is more than ten
minutes late when it wakes, plays nothing. Baton shows a message that it went off while you were
away rather than starting music out of nowhere. Baton checks the time at least every 30 seconds,
so it notices when the Mac wakes.

Alarms follow the clock on the wall: 7:00 stays 7:00 when the clocks change or you travel. They
belong to the device you set them on and aren't shared between your iPhone and Mac.

### When Baton is closed on the iPhone
<!-- baton:audience iphone -->

iOS doesn't let an app start its own music at a set time while it isn't running. So when you
save an alarm or start a timer, Baton keeps the first 29 seconds of the track you chose as the
alarm's sound. That works for downloads, books and songs streamed from your server.

If Baton can't get the song in time (you're offline, or the stream takes more than 45 seconds),
the alarm rings Baton's chime instead. An alarm set to a radio station always rings the chime,
because a live stream can't be saved ahead of time.

**On iOS 26 and later**, the alarm rings as a real system alarm, like the ones Clock sets, on the
Lock Screen. The first time, iOS asks your permission.

- With **Snooze** on, the alert's button is **Snooze**, which starts a nine-minute countdown.
- With Snooze off, and for every timer, the button is **Play**, which opens Baton.
- Tapping **Play**, or opening Baton while the alarm rings or snoozes, plays the whole track from
  the beginning.
- A running timer shows a Live Activity with its countdown, and a paused one says **Paused** with
  **Resume**.

**On iOS 18 to 25**, you get a notification instead. It plays the same 29 seconds of your song
(or the chime) once. Tap it, or its **Play** action, to start the track. With Snooze on there's
also a **Snooze** action, which brings the notification back in nine minutes. A notification
doesn't sound through a Focus that silences Baton.

**Settings → Alarm and Timer → Rings with Baton closed** shows where you stand: **Allowed**, **Not
asked yet**, **Off**, or **Only while Baton runs**. **Allow Alarms** asks for permission, and
**Turn On in iPhone Settings** takes you to the iPhone's Settings when you've said no before.

### When Baton is closed on the Mac
<!-- baton:audience mac -->

Baton usually keeps running in the menu bar, so it plays the item itself at the time: the whole
track through Baton's player, not a system sound.

If Baton isn't running at all, a notification appears at the time instead, with Baton's chime
(rising, for a Gentle Wake alarm). Click it to open Baton and play the item. This needs
notifications allowed for Baton in **System Settings → Notifications**. If they're off, the alarm
sheet says so: the alarm then works only while Baton is running.

---

## Sound quality: gapless, crossfade, loudness

Baton has the playback settings that a lot of players leave out. On the Mac they live under
**Settings → Playback → Sound**, and on the iPhone under **Settings → Sound**.

- **True gapless playback.** Live albums, DJ sets and classical recordings that were made without
  gaps play with no silence between tracks. Baton loads the next track ahead of time (for
  streamed tracks, into a small cache on disk) so the change is clean. On the Mac you can limit
  that early loading to Wi-Fi with **Prefetch streamed tracks on Wi-Fi only**, so it doesn't eat
  a metered connection like a personal hotspot, and **Clear prefetch cache** empties the cache.
  Gapless is on by default.
- **Crossfade.** Overlap the end of one track with the start of the next. On the Mac it goes from
  off up to twelve seconds, and on the iPhone you pick **Off**, **2s**, **4s**, **6s** or **8s**.
  Off is a clean cut.
- **Loudness normalization.** Even out volume so a quiet track and a loud one play at a similar
  level, using the ReplayGain or R128 data your server provides. Choose **Track** (every song at
  the same level) or **Album** (keep an album's own quiet-to-loud shape). On the Mac you can also
  set a **Pre-amp**, from −12 to +12 dB. It needs ReplayGain tags in your library: tracks without
  them play at their normal volume. It's off by default.

> [!NOTE]
> Gapless and crossfade can't both be on. Gapless makes tracks touch with no gap, and crossfade
> makes them overlap. On the Mac, **Gapless playback** is greyed out while crossfade is on, with a
> line saying why. On the iPhone, the crossfade choice is hidden while gapless is on.

> [!IMPORTANT]
> One other setting switches both of these off. The **Experimental audio engine**, which is what
> makes [the equalizer](#the-equalizer) reach music streamed from your server, ignores gapless and
> crossfade while it is running: track changes become plain cuts. It is off by default. If you
> turn it on and your albums stop running together, that is why.

Two more controls sit in the Mac's Sound section. **Duck to** sets how far the music dims while a
spoken summary plays or another app asks Baton to make room (0 to 80 percent). **Stall timeout**
sets how long Baton waits on a stream that has stopped arriving before it retries, 20 seconds by
default.

### Defaults that match how you listen

On the Mac you don't have to set any of this by hand. Once you've played about twenty tracks,
Baton looks at how you listen and picks sensible defaults for you, once:

- If you're an **album listener** (you tend to play tracks straight through from the same album),
  it turns **gapless on** and leaves autoplay off, because you're choosing whole albums.
- If you're more of a **singles or shuffle listener**, it sets a gentle **6-second crossfade** and
  turns **autoplay on**, so the music keeps flowing.

It only does this once, and it tells you what it did. You can change any of it in Settings
afterwards.

---

## The equalizer

Baton has a **10-band parametric equalizer**. On the Mac, open it from **Audio → Equalizer…**
(⌥⌘E) or from **Settings → Equalizer**. On the iPhone it's **Settings → Equalizer**, with the
bands behind the **Bands** row.

- It's **off by default**, and when it's off, audio passes through untouched.
- **Presets** get you started with one click: **Flat**, **Bass Boost**, **Treble Boost**,
  **Vocal**, **Rock**, **Electronic**, **Loudness**, **Vocal Boost** and **Bass Reduce**.
- The ten bands sit at 32, 64, 125, 250, 500, 1000, 2000, 4000, 8000 and 16000 Hz. Tap a band to
  open it and adjust its **frequency** (anywhere from 20 Hz to 20 kHz), its **Q** (how wide or
  narrow the band is, from 0.3 to 10), and its **gain** (plus or minus 12 dB).
- A live **response curve** shows the shape you're building as you go.

Because it's parametric, you're not stuck with fixed frequencies: you can move each band where
you want it.

**The preset name always describes the curve you have**, rather than the last button you
pressed. Move a band and it becomes **Custom**. Move every band back to zero and it says **Flat**
again, because that is what Flat is. Choosing a preset replaces the whole curve, so anything you
had tuned by hand is gone. **Flat / Reset** sets every band back to zero when you want to start
over.

**What it affects.** On the standard player the equalizer applies to **downloaded tracks**, not
to music streamed from your server. That is a limit of the system rather than a setting: the
audio hook Baton uses to filter playback doesn't run for a streamed item, on either the Mac or
the phone. The equalizer screen tells you which situation you are in.

To equalize streamed music, turn on the **Experimental audio engine**: **Settings → Playback →
Advanced** on the Mac, **Settings → Advanced** on the iPhone. It plays streams through Baton's
own audio pipeline, where the equalizer is a real part of the chain.

**What it costs you.** Turning it on switches off two of the things
[Sound quality](#sound-quality-gapless-crossfade-loudness) describes: while the experimental
engine is running, **gapless playback and crossfade are both ignored**, and a track change is a
plain cut. AirPlay falls back to realtime mirroring, and the engine uses noticeably more
power, which is why it is off unless you ask for it. Podcasts, downloaded files and internet
radio keep using the standard player either way, so gapless and crossfade still apply to them.
If gapless matters more to you than equalizing streams, leave this off.

The two apps differ on one point. **On iPhone the switch applies straight away**, to whatever is
playing, and **Engine cost** under it shows how much processor time each engine uses. **On the
Mac it takes effect after you quit and reopen Baton**, and the setting says so.

---

## Rating, liking, and multi-select

- **Like** a song by tapping its heart, or set a **1-to-5 star rating**. Both are stored per
  user on your server, so they follow you to any Subsonic client and show up in your
  [Liked](#liked) list and [Top Rated](#mixes) mix.
- **Select several rows at once** in list views: shift-click to select a range, press
  ⌘A to select everything, and then apply a batch action to the whole selection.
  Depending on the screen, batch actions include like or unlike, add to queue, save as a
  playlist, download, and delete.

---

## Scrobbling

Scrobbling means reporting each song you listen to, so there's a record of what you played.
Much of Baton is built from that record.

It's where **Home** gets its shelves, where **Rediscover** finds the album you loved two years
ago and haven't played since, and what the automatic **Mixes** are made from. On the Mac it's
also how Baton set up your playback: after about twenty plays it looks at whether you listen to
whole albums or hop between single tracks, and sets gapless or crossfade to suit, once (see
[Defaults that match how you listen](#defaults-that-match-how-you-listen)).

Baton can report your listens to three places:

- **Your Navidrome or Subsonic server**, which updates its own play counts. This always happens.
- **[ListenBrainz](https://listenbrainz.org/)**, if you paste your **ListenBrainz user token**
  under **Settings → Playback → Scrobbling** on the Mac, or **Settings → Scrobbling** on the
  iPhone. **Test** checks it.
- **[Last.fm](https://www.last.fm/)**, if you connect your account there. Last.fm signs you in
  through the browser: enter your **Last.fm API key** and **Last.fm shared secret**, click
  **Authorize in browser…**, approve it there, then come back and click **I've authorized,
  finish**. **Disconnect** undoes it.

A track counts as played once you've heard **half of it, or four minutes, whichever comes first**
(the usual scrobbling rule). In practice:

- A 3-minute song counts at **1:30**.
- A 7-minute song counts at **3:30**.
- A 20-minute mix counts at **4:00**, not at ten minutes.

Baton tells your server "now playing" the moment a track starts, and reports the completed play
when you cross that point. Skipping through the first thirty seconds of a dozen tracks never gets
counted as listening to them. Podcasts, internet radio and [clippings](#clippings) are never
scrobbled.

If your **server** is already linked to Last.fm or ListenBrainz, you can avoid counting the same
play twice by setting **Last.fm & ListenBrainz scrobbles** to **Handled by my music server**. The
default is **Sent by Baton**. Either way, your server's own play counts are always kept.

> [!TIP]
> Scrobbles you make while offline aren't lost. Baton keeps them in a queue and sends them once
> you're back online. **Waiting to send** shows how many are queued, and **Send now** sends them
> straight away.

---

## Finding music you don't have

Everything else in Baton looks *inside* your library. "More like this" finds the neighbours of a
track among the songs you already own, which is the right answer until you've heard them all.

**Looking outward** asks the same question of public music catalogues instead: given this artist,
what else is out there? Turn it on with **Settings → Playback → Finding music you don't have →
Look outside my library** on the Mac, or **Settings → Sound → Look Outside My Library** on the
iPhone. Then right-click any track or artist and choose **Find More Like This…**, or ask the
music friend (*"find me more like this"*) on the Mac, on your phone, or over Telegram.

Results are things you can act on rather than a list of names: where the source gives a link,
Baton gives you the link.

> [!IMPORTANT]
> This feature talks to services that aren't your own server. Asking "what sounds like Aura?"
> tells the catalogue you were listening to Aura. That's a small disclosure and an obvious one,
> but it's yours to make, so it's **off until you turn it on**. It sends only the artist and
> title. Your library, your history and who you are stay with you.

### The four places it looks

Two need nothing from you at all, which is why this is worth having before you go and collect
API keys:

| Source | What it gives you | Needs |
|---|---|---|
| **MusicBrainz** | Identity: which "Aura" you actually mean | Nothing |
| **ListenBrainz** | Related artists, ranked by what real people play in the same sitting | Nothing |
| **Last.fm** | Track-by-track similarity, finer-grained than the above | An API key |
| **YouTube** | Something you can press play on immediately | An API key |

Each source has its own switch and a **Test** button, and the keys go in **Last.fm API key** and
**YouTube API key** underneath. A source with **no key is off, not broken**. Baton says which ones
are quiet and why, and answers from the rest. If you never add a key, you still get related
artists, just not the YouTube links.

---

## Sharing a song with a friend

Send a song to someone who isn't on your network and has no account on your server. They get a
link, open it in any browser, and listen. They need no app and no sign-up. You can send a few
songs as a mixtape, a whole album or playlist, or chapters of a book, the same way.

The song is encrypted on your device before it's uploaded to Baton's share service, so the
service holds a copy it cannot play. [How private sharing is](#how-private-sharing-is) has the
details.

### Sharing a song

1. Choose **Share…** in a song's menu: right-click it on the Mac, or touch and hold it on the
   iPhone. On the Mac, **Playback → Share Current Track…** does the same for what's playing.
2. In **Share Song**, add a note if you like, say who it's from, and pick how long the link lasts
   under **Link lasts**: 1, 7 or 30 days.
3. Press **Create Link**. Baton gets the song from your server, encrypts it and uploads it.
4. **Send…** opens the share sheet, or **Copy Link** puts the link on the clipboard.

Only songs on your server can be shared, so clippings and the demo library can't. Songs over 20
minutes can't be shared either. The song is sent as a 320 kbps MP3, so your server has to be able
to convert to MP3, which Navidrome does out of the box.

The music friend can share too ("send this to Maya"), through the `music_share` tool, but only
after you have shared a song once yourself and seen where a shared song goes.

### What your friend sees

Your friend sees the artwork, the title, your note, and a play button, with a waveform in the
colour of the cover. Once they've listened for 30 seconds, or to the end, they can send you a
reaction (see [Reactions](#reactions)). **Get Baton** at the bottom takes them to the App Store
or the Mac download.

### When a friend sends you a song

If Baton is on your iPhone, or on your Mac from version 0.20.8, a song or mixtape link opens in
Baton instead of the browser. You see the song and your friend's note, with **Play** to listen
right there and **Find in my library** to play your own copy if you have it. After 30 seconds of
listening, or at the end, you can send a reaction back. **Open in browser** shows the web page
instead.

**Tip:** song links (`https://batonmusic.app/s/…`) and mixtape links (`…/m/…`) open this screen
directly, and so do the app's own forms, `baton://share/…` and `baton://mixtape/…`. Book, album
and playlist links always open in the browser.

### Sharing a mixtape

To send several songs as one link, select them and share the selection:

- **On the Mac**, select two or more songs in **Liked**, **Search** or **Downloads** and click the
  share button in the selection bar (**Share selected**), or right-click one of them and choose
  **Share Selected Songs…**.
- **On the iPhone**, open **Library → Liked**, tap **Select**, pick two or more songs and tap
  **Share…**.

In **Share Songs**, put the songs in order, switch off any you'd rather leave out, give the link
a title, add a note if you like and pick how long the link lasts, then press **Create Link**. Up
to 12 songs within 20 minutes and 25 MiB go as a mixtape; the line under the songs says which
kind of link you'll get. More than that goes as one playlist link (see [Sharing an album or a
playlist](#sharing-an-album-or-a-playlist)), and one song goes as a song link.

Your friend's link plays the tracks in order, in a browser or in Baton on their iPhone or Mac. It
works like a shared song in every other way: the tracks are encrypted on your device, the key is
in the link, and it is listed in [Shared Links](#shared-links). The track titles are always
encrypted. The mixtape's title and note are readable by the service only if you turn on **Show
details in link previews**, which starts off for a mixtape.

If the share service doesn't offer the kind of link the songs need, the sheet says so and **Create
Link** stays off.

### Sharing a book

Choose **Share…** in a book's menu: right-click a book on the Mac, or open it and use its
**More** menu. On the iPhone, touch and hold a book, or open it and tap **Share…** under the
chapters.

To send part of a book, set **Send** to **Some chapters** and pick them with **From** and
**Through**. One link holds up to 12 chapters and 20 minutes, so a short book goes whole and a
long one goes a few chapters at a time. One chapter becomes a song link, and two or more become a
mixtape your friend plays in order.

Only the chapters' audio is uploaded, encrypted like a song. The book's text stays on your
device. A chapter whose audio isn't on this device can't be shared until you get it back.

### Sharing a whole book

Set **Send** to **The whole book** to put every chapter in one link. The sheet starts there when
the book is too long for a chapter link. A whole-book link holds up to 200 chapters and 256 MiB,
which is about twelve hours at the usual quality.

Your friend opens it in any browser, with no app and no account. They see the chapter list and
play from one chapter into the next, and their browser remembers where they were, so they can
come back to it. Baton encrypts the chapters on your device, one at a time, before they leave it,
and the key is in the link, as for a song.

- **Listeners** is how many people can listen: 10 unless you change it, up to 50. Each person
  counts once, however often they pause, go back or come again.
- **Link lasts** is 1, 7 or 30 days, 7 unless you change it. You can extend it later.
- **Include the text for read-along** is off unless you turn it on. Off, only the audio is
  uploaded and the book's text stays on your device. On, each chapter's text travels with it,
  encrypted like the audio, so your friend can follow the words as they listen.
- **Show book details in link previews** is on by default. It lets the service read the title,
  the author, the From name and your note, so a messaging app can show a proper preview.
- Every chapter has to be on this device. If one isn't, the sheet says which, so you can get it
  back first or send some chapters instead.
- A big book takes a while to encrypt and upload. If the upload stops partway, **Retry Upload**
  carries on with the same link, and **Shared Links** keeps an unfinished book until it is done
  or you **Discard** it.

You can have up to three whole-book links live at once. A book link is listed in **Shared Links**
with how many people have listened. It always opens in the browser, even on a device with Baton
on it.

### Sharing an album or a playlist

A whole album or playlist goes as one link, like a whole book.

- **On the Mac**, click **Share…** in an album's or a playlist's header, or right-click an album
  or playlist wherever it's listed and choose **Share…**.
- **On the iPhone**, open the album, tap the **⋯** button at the top and choose **Share…**, or open
  the playlist and tap the share button at the top. Touching and holding an album or a playlist anywhere it's
  listed offers **Share…** too.

**Share Album** or **Share Playlist** lists every song, and every one you can send starts
switched on. Switch off the ones to leave out; a song too long to send says so. A playlist's songs can be put in a different order; an album keeps its own. The title
starts as the album's or playlist's name, and you can add a note, say who it's from, pick how long
the link lasts and choose how many people can listen. The line under the songs says what will go,
for example "14 songs · 52 m · about 50 MB · one album link". A few short songs go as a mixtape
instead, and one song as a song link.

Your friend opens the link in any browser, with no app and no account. They see the cover (an
album's own, or a mosaic of four covers for a playlist), the songs with their lengths, and a
player that goes from one song into the next, with previous, next and seeking. A playlist adds
shuffle and repeat. Their browser remembers where they were, so they can come back to it. There
is no download button.

- Songs are sent as AAC at 128 kbps. Baton asks your music server to convert them, and converts
  on your device when the server can't. One link holds up to 200 songs and 256 MiB, which is
  about four and a half hours. A song over about 25 minutes goes at a lower quality so it fits,
  and one over about 68 minutes can't be sent.
- Baton gets and encrypts the songs one at a time before they leave your device, and the key is
  in the link, as for a song. If the upload stops partway, **Retry Upload** carries on with the
  same link, and **Shared Links** keeps an unfinished link until it's done or you **Discard** it.
- **Listeners** is how many people can listen: 10 unless you change it, up to 50. Each person
  counts once, however often they pause, go back or come again.
- **Link lasts** is 1, 7 or 30 days, 7 unless you change it. You can extend it later.
- **Show details in link previews** is on by default. It lets the service read the title, the
  artist, the From name and your note, so a messaging app can show a proper preview. Song names,
  their order and the cover are always encrypted.

Albums, playlists and whole books share one limit: up to three of these links can be live at
once. They're listed in **Shared Links** with how many people have listened.

### Reactions

A reaction is a short reply your friend sends back: one of five emoji, and if they like, their
name and a message.

- **On the song page**, the reaction buttons appear once your friend has listened for 30
  seconds, or to the end. After the emoji they can add **Your name (optional)** (up to 40
  characters) and **Say something (optional)** (up to 280).
- **On a mixtape or book page**, it's an emoji only.
- **In Baton**, when someone sends you a song, the **Reaction** picker and the two optional fields
  appear after the same 30 seconds, with **Send**.

Each visitor can send up to five reactions to a link per day.

You see reactions in [Shared Links](#shared-links), beside the link they belong to. Baton
doesn't notify you when one arrives: open Shared Links to look.

A reaction is stored on Baton's share service **as plain text**, not encrypted, whatever the
preview setting says. It's kept together with a visitor code (explained in
[How private sharing is](#how-private-sharing-is)) until the link ends, and then deleted with it.

### Shared Links

**Shared Links** lists every link this device has sent: songs, mixtapes, books, albums and
playlists. Find it at
**Settings → About → Shared Links → Show Shared Links…** on the Mac, and **Settings → Shared
Links** on the iPhone, where the row shows "None" or how many are live.

Each row shows when the link ends, what happened to it, and any reactions:

- a song: **Opened**, **Played** and **Finished** counts
- a mixtape: its number of tracks, **Sessions** and **Played**
- a book: its chapters, how many of its listeners have listened, and whether it carries the
  read-along text
- an album or a playlist: its songs and how many of its listeners have listened

For a live link you can **Copy Link**, **Extend 7 Days** (a link can be extended to at most 30
days from now), or **Revoke** it, which asks "Revoke this link?" first. Revoking stops it playing
for everyone and deletes the copy on the service straight away. To your friend, a revoked link
looks exactly like one that expired. For a link that has ended, **Remove from List** clears it
away.

If an upload was interrupted, **Shared Links** offers to retry it, and an unfinished book, album or
playlist link has **Retry Upload** and **Discard**.

A link is listed only on the device that made it, because only that device holds its key and the
right to change it. A settings backup doesn't carry that right (see
[Backing up and restoring your settings](#backing-up-and-restoring-your-settings)).

### How private sharing is

**The song itself is private.** It's encrypted on your device before it leaves. The key is the
part of the link after the `#`, which browsers never send to a server, so Baton's share service
keeps a copy it cannot play. Send the whole link, or it won't open.

**Preview details are readable, if you leave them on.** With **Show song details in link
previews** on (the default), the service can read the title, artist, album, length, your note and
the From name, along with the cover art, the cover's colour, the shape of the waveform and the
song's MusicBrainz ID, and it makes a preview card from them. That's what lets Messages and other
apps show a proper preview. Turn it off and those are encrypted too, and the preview only says
that someone sent a song.

**What the service counts.** It counts opens and plays, and keeps a rough device type for each
open (iPhone, Android, Mac, Windows or Linux). To count each visitor once without storing who they
are, it keeps a short visitor code worked out from the visitor's internet address, their
browser, the link and a value that changes every day. The service's own records keep that code
instead of the address, and reactions are stored with the same code. The web server's own
troubleshooting log is described in the
[privacy policy](https://batonmusic.app/privacy.html#sharing-records).

**A link plays up to 100 times.** That makes it a way to send a song to friends, not to publish
one. A link that reaches its limit stops playing but stays on the service until it expires.

**What's left after a link ends.** When a link expires or you revoke it, the service deletes the
encrypted song, the preview details, the artwork and the reactions. Some things stay longer:

- The counts and the record of opens and plays, with their visitor codes, are kept for up to 400
  days.
- The service is backed up every night to an encrypted offsite backup. A backup can keep a copy
  of a link for up to about 30 nights after it ends, and for longer until the clearing-out of old
  backups is switched on.

The details are in the [privacy policy](https://batonmusic.app/privacy.html#sharing). See also
[Privacy and security](#privacy-and-security) for everything else Baton talks to.

---

## Media keys and AirPlay

- **Media keys and Bluetooth remotes.** The play, pause, next, previous and seek keys on your
  keyboard (F7, F8, F9) and on Bluetooth remotes all control Baton. The current track (title,
  artist, album, artwork and elapsed time) shows in the Now Playing controls in Control Center,
  and on the iPhone's lock screen.
- **AirPlay.** Use the AirPlay picker to send audio to an AirPlay device. On the Mac it's in the
  now-playing bar. On the iPhone it's in the full player's row of controls, not in the mini
  player. Casting to Chromecast, Sonos and UPnP/DLNA is [on the roadmap](#whats-next), but AirPlay
  works today.

---

## Keyboard shortcuts
<!-- baton:audience mac -->

The symbols are the Mac's usual ones: ⌘ is Command, ⌃ is Control, ⌥ is Option and ⇧ is Shift.
Each shortcut is also an item in the menu named beside it, so you can look it up there.

**Playing and the player**

| Action | Shortcut | Menu |
|---|---|---|
| Play or pause | ⌃⌘P | Playback |
| Next track | ⌃⌘→ | Playback |
| Previous track | ⌃⌘← | Playback |
| Skip back ten seconds | ⌥⌘← | Playback |
| Skip forward ten seconds | ⌥⌘→ | Playback |
| Volume up | ⌃⌘↑ | Playback |
| Volume down | ⌃⌘↓ | Playback |
| Mute or unmute | ⌃⌘M | Playback |
| Like or unlike the current track | ⌃⌘L | Playback |
| Rate the current track | ⌃⌘1 to ⌃⌘5 | Playback → Rate Current Track |
| Clear the rating | ⌃⌘0 | Playback → Rate Current Track |
| Get info about the current track | ⌘I | Playback |
| Show the queue | ⌘U | Playback |
| Collapse or expand the player bar | ⌃⌘J | Playback |
| Open the Mini Player | ⌥⌘M | Playback |
| Open the equalizer | ⌥⌘E | Audio |

**Moving around**

| Action | Shortcut | Menu |
|---|---|---|
| Home, Search, Mixes, Albums, Artists, Playlists, Liked, History, Later | ⌘1 to ⌘9, in that order | Go |
| Find | ⌘F | Go |
| Show what's playing now | ⌘0 | Go |
| Refresh the library from the server | ⌘R | Go |
| Open the music friend | ⇧⌘F | Go |
| Hide or show the sidebar | ⌃⌘S | Go |
| Open Settings | ⌘, | Baton (the app menu) |
| Open this guide | ⌘? | Help |
| Quit Baton | ⌘Q | Baton (the app menu) |

**Speech and documents**

| Action | Shortcut | Menu |
|---|---|---|
| Replay the last spoken summary | ⌃⌘R | Playback |
| Stop speaking | ⌃⌘. | Playback |
| Save the last reading as an audio file | ⇧⌘S | File |
| Import a document as a book | ⇧⌘O | File (while Documents is on) |

The **Go** menu lists every section the sidebar can show, including the ones with no number of
their own: Clippings, Books, Podcasts, Radio, Downloads and Folders. That matters if you have
hidden a section from the sidebar, because the menu is then the way back to it.

The **Playback** menu also holds **Shuffle**, **Repeat**, **Speed**, the **Sleep Timer**, **Set
Alarm…**, **Start Timer…** and **Share Current Track…**. The **Audio** menu holds **Gapless
Playback**, **Crossfade** and **Loudness**. **Help → What's New in Baton** shows the notes for
each release.

**Get Info** (⌘I, or **Get Info** in a row's right-click menu) opens a sheet on the track itself:
codec, bitrate, bit depth, sample rate, channels and file size, alongside how many times you've
played it and when you last did. If the track is downloaded, it shows you where on disk it is.
Every field is read from your server's own information about the file: nothing is guessed, and a
blank field means your library doesn't carry that tag.

**Keys that aren't in a menu**

- In the main window, **Space** plays or pauses.
- In the full-screen player, **Space** plays or pauses and **Escape** leaves. The left and right
  **arrow keys** skip back and forward ten seconds, and **[** and **]** move the side panel
  through Queue, Lyrics and Related.
- In song lists (Liked, search results, and the tracks inside an album or playlist), click the
  list once, then use the **up and down arrows** to move through it. **Return** plays the
  highlighted track and **⌘Return** queues it up next. **⌘A** selects everything, and in the
  queue the **Delete** key removes the row you're pointing at.
- In an open book, **⌘[** goes back to the Books list.

Baton also follows the system **Reduce Motion** setting (**System Settings → Accessibility →
Display**). Turn it on and the continuous animations (the breathing artwork in the full-screen
player, the equalizer bars, the zoom on hover) hold still, while hover and selection stay just as
visible.

---

## Webhook actions
<!-- baton:audience mac -->

A webhook is a web address that another service listens on. Webhook actions let you send a
media item to one you choose. They're aimed at
podcast episodes: for example, you could POST an episode's audio URL to a service that
transcribes it, or hand it off to a save-for-later tool.

You set them up in **Settings → Actions**:

1. Click **Add Action…** and give it a **name** and, if you like, an **SF Symbol** icon.
2. Choose the HTTP **method** (POST, GET, PUT, PATCH, or DELETE) and the **URL**.
3. Add any **headers** you need (for example an `Authorization` header). Header values are kept
   in the Keychain, and a settings export leaves them out.
4. For methods that send a body (POST, PUT, PATCH), pick a **content type** (JSON, Form, or
   Text) and write the body.

Anywhere you write a URL, header, or body you can drop in **tokens** that Baton fills from
the episode: `{title}`, `{channelTitle}`, `{enclosureUrl}` (the direct audio URL),
`{feedUrl}`, `{guid}`, `{pubDate}`, `{durationSec}`, `{episodeImageUrl}`,
`{channelImageUrl}`, and `{description}`.

Your saved actions then appear in the **⋯** (or right-click) menu on a podcast episode, and
in the multi-select bar when you've selected several. They **only ever fire when you run
them**. Nothing here happens on its own.

---

## Speaking summaries aloud

Besides controlling your music, Baton on the Mac gives an agent a **voice**. Through the
`speak_summary` tool, an agent can have Baton say a short line out loud in a natural voice, so
you *hear* "deploy finished, all green" instead of watching a screen for it.

This is most useful when you have **more than one agent running at once**. Give each agent, or
each kind of task, its own **voice**, and you can tell them apart by ear without switching
windows. Your deploy agent speaks in one voice, your research agent in another, and an alert
comes through in a third.

You set all of this up in **Settings → Speech**.

### How an agent talks

The agent calls `speak_summary` with a few inputs:

- **`text`** (required): the line to say, for example "research pass done, 3 issues found". It
  can be up to 2,000 characters, though a sentence or two is the point.
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
- **`mode`**: `notify`, `banner` or `auto`, the agent's wish for how the line reaches you. Your
  own **Delivery** settings have the final say (see below).
- **`prepare`**: tidy text taken from a screen before it's spoken: `terminal` (drops colour codes
  and shell prompts and keeps the last command's output), `browser` (drops web page clutter) or
  `generic`. Each one also removes anything that looks like a password or key, shortens hashes
  and links, and announces code blocks rather than reading out their punctuation.

So with two agents running you hear only the summaries themselves, "Env labels
shipped." then "OCR queue drained.", while the window tells you which one each came
from. Lines never overlap either, because Baton queues them and plays them in order.

### One voice per agent

Give each agent its own voice and you know who finished without looking at anything. The
name above the transcript tells you too, but only once you look.

In **Settings → Speech → Agent voices** you keep a list. Each row is a label and a voice,
with a button to hear it. Add as many as you like:

- The **label** is normally what the agent sends as its `session` name, usually the repo it
  is working in. It is matched loosely, so case and stray spaces do not matter, and it is
  free text: "night build" works as well as a repo name.
- **Add Agent** adds a row. **Add one Baton has heard** fills the label in for you from the agents that have already
  spoken, so you do not have to guess the exact spelling.

Anything **not** in the list speaks in a voice from outside it. That is the useful half of
the rule: a project you named never shares its sound with one you did not. Unlisted agents
still sound the same every time, worked out from the name, so you can learn to recognise one
before you get round to adding it.

An explicit `voice` in the tool call beats all of this, and the category map below still
applies to summaries with no agent name at all.

### One voice per category (the voice map)

The category-to-voice map, under **Settings → Speech → Voices**, matches a kind of task to a
voice. Baton starts you with this map, which you can edit, add to and preview:

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

**Settings → Speech → Delivery** decides what happens when a summary arrives. Out of the box,
**nothing is spoken until you press Play**: a notification appears with a **Play** button, and the
line waits for you.

- **When a summary arrives** is the main choice. **Let the agent decide** (the default) lets the
  agent's `mode` set the timing. **Announce immediately** speaks every summary as soon as it's
  ready.
- **Allow the agent to play it immediately** is off by default. Only with it on does an agent's
  `auto` speak the line straight away. With it off, `auto` waits for Play like any other summary.
  This stops anyone who got hold of the control token from playing sound at you.
- **Alert with a notification** (on by default) and **Alert with an in-app banner** choose where a
  waiting summary shows up, whatever the agent asked for with `notify` or `banner`. If you turn
  both off, Baton keeps the banner, so a summary can always be reached.
- **Bluetooth head start** is described just below.

**Recent Summaries…** in the Playback and menu-bar menus opens the **Spoken Summaries** window, a
list of what was said, and **Replay Last Summary** (⌃⌘R) plays the last one again.

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

1. **Nothing at all, the built-in Mac voice.** If you set nothing up, Baton uses macOS's own
   speech (the same engine as VoiceOver). It just works, offline, no install. The voice is a
   bit robotic, but a summary is never dropped.
2. **Kokoro**: a small, free voice server you run yourself. Fast, natural-sounding, 50+ preset
   voices (including Spanish). Runs on any Mac or PC **with no graphics card**.
3. **Chatterbox**: a higher-quality voice server that can also **clone a voice** from a short
   sample. Needs an **NVIDIA graphics card (GPU)**, so it usually lives on a separate machine.

Everything below is optional: set up as much or as little as you like. Baton talks to both
servers the same way (the OpenAI "audio/speech" format), so any service that speaks that format
can be plugged in, on your own machine or hosted elsewhere. Narrated books can also use an
expressive voice server, described under [Voices: on this Mac or on your Baton
server](#voices-on-this-mac-or-on-your-baton-server).

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

- **On the same Mac as Baton (local).** Simplest. The address is `http://127.0.0.1:<port>`:
  `127.0.0.1` means "this machine." **Kokoro** is perfect here because it needs no GPU.
- **On another machine on your network (remote).** For example a Linux box with an NVIDIA GPU
  for **Chatterbox**. You reach it by that machine's name (`http://mybox.local:<port>`) or its
  LAN address (`http://<your-lan-ip>:<port>`).

Either way there's **no cloud account and nothing leaves your own network**: this is different
from a hosted service like ElevenLabs, where your text is sent to someone else's servers.

#### Setting up Kokoro (no GPU needed)

Kokoro ships as a ready-to-run container. On the machine where you want it (your Mac, or any
always-on box) with [Docker](https://docs.docker.com/get-docker/) installed, run:

```sh
docker run -d --restart unless-stopped -p 8880:8880 \
  ghcr.io/remsky/kokoro-fastapi-cpu:latest
```

That's the whole install: Kokoro now answers at `http://<that-machine>:8880`. (`-d` runs it in
the background, and `--restart unless-stopped` brings it back after a reboot.) Confirm it's alive:
`curl http://localhost:8880/health` should return `200`.

> Use the **CPU** image above: it works everywhere and is plenty fast (a short sentence in well
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
voice model).

If you changed the `ports:` line in that compose file, use the number on the **left** of the
colon. Chatterbox always listens on 8004 inside its container, so the left number is the one
you can reach and the right one is not. A common sign you have the wrong port is a reply from
some other service, such as `Error: gzip is not supported by this browser`.

To use a **cloned voice**, drop a 5- to 10-second `.wav` sample of the target voice into its
voices folder. It shows up in Baton's voice list by filename (for example `Emily.wav`).

> Chatterbox is the heavier engine: reach for it when you want the best quality or a custom
> cloned voice, not for every routine "build finished" line.

#### Pointing Baton at your server(s)

Open **Settings → Speech → Services** and enter the address for whichever engine you set up:

- **Kokoro**: for example `http://127.0.0.1:8880` (same Mac) or `http://mybox.local:8880`
  (another machine).
- **Chatterbox**: for example `http://mybox.local:8004`.

Click the ↻ button beside the address (its tooltip says **Test this connection**). Baton shows a
green check with the number of voices it found, or the error if it can't reach the server. Once connected, each row of the [voice
map](#one-voice-per-category-the-voice-map) gets a voice picker (populated live from that server)
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
> silently dropped. The fallback is on by default. Turn off **Fall back to the system voice** under
> **Settings → Speech → Services** if you'd rather an unreachable server report an error. Deeper operator notes (self-hosting specifics,
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

`speak_summary` is a tool the agent *chooses* to call: Baton never speaks on its own. So
**you** decide when a summary is read aloud, either per request or as a standing rule.

**Per request (no setup).** Just ask for it in the moment:

> "Run the tests and **say** the result when you're done."
> → the agent runs the tests, then calls `speak_summary` with something like "All 467 tests
> passed", and stays silent on the next task unless you ask again.

**A standing rule (Claude Code).** Put a one-line instruction in a `CLAUDE.md`: `./CLAUDE.md`
for one project, `~/.claude/CLAUDE.md` for all of them. Two useful shapes:

- **Opt-in (recommended), silent unless asked:**

  ```md
  Spoken summaries: default do NOT speak. Only call `mcp__baton__speak_summary` when I
  explicitly ask in that message (e.g. "…and say", "speak the summary"). Then speak one
  short sentence (voice `af_bella`). If Baton isn't connected, skip silently.
  ```

- **Always, a spoken line after every task:**

  ```md
  When you finish a task, call `mcp__baton__speak_summary` with a one-sentence summary
  (voice `af_bella`). If Baton isn't connected, skip silently.
  ```

**A standing rule (Cursor).** The same idea lives in a Cursor **Rule**: add a project rule in
`.cursor/rules/` (or a global rule under **Cursor → Settings → Rules**) with the same wording,
for example:

```md
Spoken summaries: default do NOT speak. Only call the baton `speak_summary` tool when I
explicitly ask in that message (e.g. "…and say", "speak the summary"). Then speak one short
sentence (voice `af_bella`). If Baton isn't connected, skip silently.
```

Pick a voice per line with the `voice` input (`kokoro:af_bella`, `chatterbox:Emily.wav`, or a
bare id like `af_nova`), or let the [voice map](#one-voice-per-category-the-voice-map) choose by
`category`. A `CLAUDE.md` or Cursor rule takes effect on the **next** session (a running one
won't reload it mid-task), and Baton must be running for the call to land.

---

## Reading what's on your screen
<!-- baton:audience mac -->

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

**Readings are not saved unless you ask.** A reading plays once and is gone. It does not appear
in the **Spoken Summaries** window, which stays a record of what your agents told you. Three things you can ask
for are the exceptions, all described below: keeping a reading in [Clippings](#clippings),
saving it as an audio file, and picking up an article you stopped part-way.

### Ways to start a reading

**Services, which needs no permission at all.** Select some text, then choose **Services →
Speak with Baton** from the application menu (or right-click the selection). The system hands
Baton the text. Baton doesn't reach into anything, so there is nothing to grant and nothing
to set up.

**A keyboard shortcut, which you choose.** **Settings → Speech → Read aloud → Keyboard shortcut**
is a recorder: click it, then press the combination you want. There is **no shortcut set out of the box**, so Baton can
never collide with something you already use. The shortcut asks the app you're in for your
selection, and macOS gates that behind **Accessibility**: Baton asks the first time you press
it, and explains why.

**Reading a whole pane, not just a selection.** Hold **Shift** with your shortcut and Baton
reads the whole thing you're focused on rather than what you've highlighted (the entire
scrollback of a terminal, say, when you'd rather not select it first). This one depends on the
app being willing to hand over its contents, and browsers are not: in Chrome it does nothing,
so select the part you want and use the plain shortcut there.

**Reading something with no text at all.** A PDF, an image, a screen shared from another
machine: there is nothing to hand over, so Baton can photograph the front window and read what
it can see. This is off until you turn on **Read a window Baton cannot get text from** under **Settings →
Speech → Read aloud**, because it needs Screen Recording,
which is the largest thing Baton ever asks for. Once it is on, hold **Option** with your
shortcut. Baton captures only when you press it, only the window in front, and the picture is
never saved.

**Several readings queue.** Send Baton more than one thing to read and it reads them in turn
rather than cancelling what it was doing. The speaking window says how many are still to come.
To stop the lot, close that window.

**An agent hands it over.** Baton's `read_aloud` tool takes text an agent already has and
reads it, which is the practical answer for a web page. Pulling the *article* out of a page,
rather than the navigation and the cookie banner, is real work, and an agent driving the
browser has already done it. It passes Baton the text and Baton reads it. You do not need to
switch anything on or grant anything, because the text arrives over the connection Baton's
other tools already use.

**The gist instead of the whole thing.** For a long article, **Services → Summarize with
Baton** speaks a few sentences rather than reading every one. This is the one part of Read
aloud that needs a model: the one the music friend uses, set up under **Settings → Remote →
Natural language** with **Understand plain English** on.

The model has to be on your own network, because the whole article goes to it. Without one,
Baton says so rather than doing nothing. The text is cleaned, and anything that looks like a
password or key is taken out, before it reaches the model as well as before it is spoken.

### Why some apps need the clipboard

Apps differ in how willing they are to hand over your selection, and browsers are the awkward
case. A terminal like Ghostty hands it straight over. **Chrome does not**: it exposes page
text in a way the ordinary route can't read, so for Chrome and most other browsers Baton falls
back to copying the selection, reading it, and putting your clipboard back the way it was.

That fallback is on by default because otherwise the shortcut would simply do nothing in a
browser, which is where most reading happens. Two honest caveats:

- Your clipboard is replaced for a fraction of a second. Baton restores everything it found,
  including images and files, but a clipboard manager watching in the background may still
  record the intermediate value.
- You can switch it off with **Use the clipboard when an app will not share its selection** under
  **Settings → Speech → Read aloud**. The shortcut will then do nothing
  in apps that won't share their selection, and Services will still work everywhere.

### What Baton does to the text before speaking it

Read aloud is mostly about *not* reading things to you. Before a word is spoken, Baton:

- **Removes anything that looks like a credential.** API keys, tokens, bearer headers and
  private keys are replaced with "a redacted token" rather than spoken. Terminals have secrets
  on screen more often than anyone likes to admit.
- **Cleans up terminal output.** Colour codes and cursor commands disappear, the prompt is
  dropped but the command you typed is kept, and if your selection spans several commands only
  the last one's output is read: that's almost always the one you selected it for.
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

This is off by default. Turn on **Use a different voice per app** under **Settings → Speech →
Read aloud** and a browser and a terminal read in different voices, so you can tell where the text came from
without looking. The two voices are the `browser` and `terminal` rows in the voice map on the
same screen, and you can change them like any other.

### Keeping a reading

There are two ways to keep the last thing Baton read.

**File → Keep Reading in Clippings** hands it to Baton: the audio and its words go into
[Clippings](#clippings), where you can play it, search it by what was said, and (with your Baton
server) find it on your iPhone too.

**File → Save Reading as Audio…** (⇧⌘S) turns it into a single M4A file in a folder you choose.
Read a long article at your desk and listen to it on a walk.

Nothing changes if you never use either. Readings still play once and disappear. With Save
Reading as Audio, the only thing written is the file you asked for, in the place you chose. Baton asks where to put
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
can also forget the lot at any time, with **Forget Saved Readings** in the same menu, or **Forget
Them Now** under **Settings → Speech → Read aloud → Unfinished readings**, which shows how many
are being held.

It stays on this Mac. Where you got to in an article is like where you got to in a podcast, so it
does not travel to your iPhone.

---

## Transcripts and summaries

Spoken audio is the one thing in a library you cannot skim. Baton can turn a podcast episode into
a transcript with a timestamp on every line, so you can read along, find the part you half
remember, and jump straight to it.

On the Mac, open the full-screen player and pick the **Transcript** panel. On the iPhone, tap the
Transcript button in the full player's row of controls. Press **Transcribe** and Baton sends the
episode's audio to a Whisper server you run (Whisper is a speech recognizer), then keeps what
comes back. The current line highlights and scrolls as the episode plays, as synced lyrics do,
and tapping any line jumps to it.

Once a transcript exists it's kept on your device, so opening it later costs nothing and works
with the server switched off.

**Songs work too**, though singing is harder to recognize than speech. The panel is offered for
every track, and for a song it first says that this isn't spoken-word audio before offering to
go ahead. How well it works depends almost entirely on which recognizer you point Baton at.

WhisperX reads sung vocals, so expect the verses and the chorus roughly right rather than a match
for the printed lyric. A plain faster-whisper server tends to give up on singing and return the
same word over and over. Baton drops those runs rather than showing them to you, so a recognizer
that cannot hear the singing reports no speech instead of nonsense. If a track really is an
instrumental, the panel says there was no speech in it and points you to the Lyrics panel. A book
chapter shows **Read Along** here instead.

### Setting it up

Transcription is off by default, because it uploads audio to a server. Switch on **Transcribe
spoken tracks** and give Baton the address of a transcription server that answers OpenAI-style
requests, the same kind of address the Kokoro and Chatterbox voice servers use. On the Mac that's
**Settings → Speech → Transcription**, with the address in **Whisper host**. On the iPhone it's
**Settings → Transcription**, after Advanced. `faster-whisper` behind its OpenAI-compatible server
is the usual choice.

Baton checks the address as soon as you open the screen and shows what it found: a tick and the
number of models when the server answered, or a warning and the reason when it did not. The
refresh button next to the field asks again. Editing the address clears the tick, because it
belonged to the address that was checked.

Every service you can set up works this way, on both apps: the music server, both voice servers,
the recognizer, ListenBrainz, Last.fm, the Baton server and each discovery source. A green light
always means a request that just happened, never only that a key is filled in.

If you run more than one model, put its name in **Model**. Leave it alone and Baton asks for
`whisper-1`, which is what most of these servers answer to.

### Summaries and chapter marks

**Summarize this episode** turns a transcript into a short overview plus a list of timestamped
sections. The sections are the useful half: each one names what that stretch of the episode is
about, and tapping it jumps there. It works by summarizing the episode ten minutes at a time and
then summarizing those summaries, which lets a model with a small memory handle an hour of speech.

The button sits at the top of the transcript, on both apps. It uses the model set up for the
music friend (**Settings → Remote → Natural language** on the Mac, **Settings → Music Friend** on
the iPhone), so set one up there first, or the button tells you there is nothing to summarize
with.

**The model has to be on your own network.** If it isn't, Baton refuses and says so. A transcript
is everything that was said in something you listened to, and that shouldn't go to a hosted
service because of a setting you made for something else. Point it at a model on your home
network and the question doesn't arise.

### What it does not do

Baton never transcribes on its own. There is no background pass over your library and no
transcription when you subscribe to a feed. One episode is a minute or two of work on a graphics
card, so a whole library would take hours. Music keeps its lyrics, which come from your server or
LRCLIB and cost nothing.

If the transcription server cannot be reached, the panel says **unavailable** rather than showing
an error. Away from home that is the normal state of affairs, and a phone on cellular shouldn't
be told something is broken when it isn't.

**Agents can use this too.** `music_transcript` reads a stretch of the transcript, between a start
and an end time, so an agent reads the part it needs instead of the whole hour.
`music_summarize_track` reads the summary, and can make one if there isn't one yet. So you can ask
your assistant what an episode said about something without playing it back yourself.

---

## Letting an agent control your music

This is what makes Baton different from other Subsonic players: software can drive it, not just
you clicking buttons.

Baton on the Mac runs a small **control server** that speaks
[MCP](https://modelcontextprotocol.io/), the Model Context Protocol. It's the language Claude and
other AI agents use to talk to tools. That means you can say things to an agent like:

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
whichever build of Baton is running: yours will show its real values.

> [!NOTE]
> The port is `8787` by default. You can change it in **Settings → Agents → Port**. Baton
> always starts on that port. Only if something else already has it does Baton take the next
> free one, writes it
> into `mcp.json`, shows it in the Port field and posts a notification saying which port it
> moved to. The moved port is remembered, so the next launch starts from it. Always read the
> current `url` and `token` from the file rather than hard-coding them. The token is
> regenerated only if you reset it.

**Settings → Agents** shows the same endpoint and token, and **Client configuration → Copy
configuration** copies a ready-made snippet. The menu-bar menu's **Copy MCP Endpoint** copies the
address.

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

Then enable **baton** under **Cursor → Settings → MCP**, and its tools appear to the agent there.

Baton has to be running for any of this to work, which is another reason for the
[menu-bar controller](#the-menu-bar-controller): it keeps Baton (and the server) alive in the
background even with every window closed.

### What an agent can do

The control server exposes **41 music operations**. They're the same actions Baton's own
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
recommendation has to start from: an agent that can read your genres and what you actually
play can suggest something from your collection instead of guessing at song titles.

| Tool | What it does | Main inputs |
|---|---|---|
| `music_list_genres` | List the genres in your library with song counts: the vocabulary it really uses, which is rarely the words people say | `limit` |
| `music_browse_albums` | Browse albums by kind rather than by search: random, newest, most-played, recently played, liked, by genre, by year | `type`, `genre`, `from_year`, `to_year`, `limit` |
| `music_similar_songs` | Songs your server considers similar to a track or artist: real neighbour data, not a keyword match | `song_id` or `query`, `limit` |
| `music_discover_external` | Music you *don't* have, from public catalogues: the outward-facing twin of the one above. Off unless you turn it on | `artist`, `title`, `limit` |
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
| `music_share` | Make a link a friend outside your network can play in a browser, and return it. Refuses until you've shared a song once yourself. See [Sharing a song with a friend](#sharing-a-song-with-a-friend) | `query`, `note`, `expires_days`, `hide_details` |
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

**Documents:**

| Tool | What it does | Main inputs |
|---|---|---|
| `import_document` | Make a narrated book in Books from a file on this Mac or a link to one. Made where **Settings → Speech → Make books on** says. Listed while **Settings → Speech → Documents** is on. See [Listening to a document](#listening-to-a-document) | `path` or `url`, optional `voice`, `tone` and `where` |
| `document_context` | Read the passages of a book in Books that the listener has already heard, never past their place, to answer a question about it. Listed while **Settings → Speech → Documents** is on | `book`, `question` |

**The rest of the app** (listed on the control server only, not in the in-app chat). The book
tools (`books_list` and every `book_` tool) are listed only while Documents is on. The tools
that delete, revoke, share or replace something change nothing unless the agent passes
`confirm: true`. Without it they answer with what they would do. None of them returns a link,
key, feed or stream address, file path or server address, except `music_share` and
`share_mixtape`, which hand the link they have just made to the agent that asked for it.
When an agent makes a share for you (`music_share` or `share_mixtape`), its answer includes the
whole link, key and all, so the key passes through that agent's model provider and, for Telegram
or Discord, through the chat platform too. Anyone holding that copy of the link can play the
song until you revoke it.

| Tool | What it does | Main inputs |
|---|---|---|
| `books_list` | The books in Books: chapters made, where the listener is, finished, narrator, cover and cast | none |
| `book_chapters` | One book's chapters and whether each is ready | `book` |
| `book_play` | Play a book from the listener's place, or from a chosen chapter | `book`, `chapter` |
| `book_cast` | A book's narrator and, for voiced dialogue, each character's voice | `book` |
| `book_change_voice` | Make a book again in another narrator's voice. Needs `confirm` | `book`, `voice`, `confirm` |
| `book_cover` | Make a cover from the title and author, or remove the cover. Needs `confirm` | `book`, `action`, `confirm` |
| `clippings_list` | The saved readings in Clippings, newest first | `limit` |
| `clipping_play` | Play a clipping | `clipping` |
| `clipping_delete` | Delete a clipping here, or on every device. Needs `confirm` | `clipping`, `everywhere`, `confirm` |
| `podcasts_list` | The shows you follow by feed, with unplayed counts | none |
| `podcast_episodes` | A show's episodes and how far you got | `show`, `limit` |
| `podcast_play_episode` | Play an episode, by default the newest unplayed | `show`, `episode` |
| `podcast_subscribe` | Follow a show by its feed address. Needs `confirm` | `feed_url`, `confirm` |
| `podcast_unsubscribe` | Stop following a show. Needs `confirm` | `show`, `confirm` |
| `radio_list_stations` | Your internet radio stations and the one on air | none |
| `radio_play_station` | Play a station | `station` |
| `later_list` | What is on Later | none |
| `later_add` | Save a song to Later, by default the one playing | `query` |
| `later_remove` | Take something off Later. Needs `confirm` | `item`, `confirm` |
| `later_play` | Play something on Later | `item` |
| `history` | Your latest plays, or your most-played tracks, albums or artists | `view`, `days`, `limit` |
| `downloads_list` | What is downloaded, the space it takes, and offline mode | `limit` |
| `download_songs` | Download songs for offline listening | `song_ids` or `query` |
| `download_remove` | Remove downloaded songs from this Mac. Needs `confirm` | `ids`, `confirm` |
| `shares_list` | The song links and mixtapes you shared, without the links | none |
| `share_revoke` | Stop a shared link or mixtape playing for everyone. Needs `confirm` | `share_id`, `confirm` |
| `share_mixtape` | Share 2 to 12 songs as one mixtape link. Needs `confirm` | `song_ids`, `title`, `confirm` |
| `handoff_status` | Whether another device left a queue to pick up, and the linked devices | none |
| `handoff_accept` | Pick up the queue another device left | none |
| `handoff_save_queue` | Leave this Mac's queue for your other device. Needs `confirm` | `confirm` |
| `playback_speed` | Read or set the speed podcasts and books play at | `rate` |
| `settings_read` | What is set up and the playback, books and speech choices, never an address or key | none |

### Meeting interpretation routes

[Tonebox](https://tonebox.io) can interpret a call as it happens: it listens and translates,
and Baton plays the two translated directions, each on its own route (a "lane"). One lane goes to
your headphones, so you hear the other side in your language. The other goes to a virtual
microphone, a separate audio device you install, which you then choose as the microphone in the
meeting app, so they hear you in theirs.

The audio itself travels over private, signed-in local streams rather than through the control
server. While interpretation is using the routes, ordinary spoken summaries wait. If a lane goes
wrong, it can be stopped or muted at once. Resuming it starts afresh (a new "generation") and
never replays old speech.

| Tool | What it does | Main inputs |
|---|---|---|
| `interpretation_devices` | List stable audio device identifiers and route capabilities | none |
| `interpretation_open` | Open independent headphone and virtual microphone routes | incoming_device_uid, outgoing_device_uid, voice_engine, tts_url |
| `interpretation_status` | Read connection state and lane generations | none |
| `interpretation_configure` | Resume one stopped lane with a new generation; never replay prior speech | session_id, lane, device_uid |
| `interpretation_cancel` | Immediately invalidate and mute one direction | session_id, lane, generation |
| `interpretation_close` | Stop both directions and release music focus | session_id |

### Live resources an agent can read

On top of the tools, Baton publishes five live, read-only views, called resources. An agent
reads one once and is then told whenever it changes, so it can follow along without asking over
and over. These are addresses an agent reads over the control server. They are **not links you
can open** in a browser or click in a message.

| Resource (for agents) | What it holds |
|---|---|
| `baton://now-playing` | The current track, playback state, position, and volume |
| `baton://queue` | The full queue and the current index |
| `baton://library/playlists` | Your playlists |
| `baton://library/liked` | Your liked songs, albums, and artists |
| `baton://history/recent` | Recently played tracks, plus your top tracks and artists |

### Examples: what you say, and what happens

You talk to your agent in plain language. It picks the right tools. A few examples:

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
a fight over your speakers. These are coordination tools, not buttons. A well-behaved agent
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
"play the live version instead": it has the same hands you do.

Open it on the Mac from **Go → Music Friend**, or press **⇧⌘F**. On iPhone it is the
**Friend** tab, which appears once a connection test has passed. Setting a provider is not
enough on its own: a key with a typo in it is still a key, so Baton waits until it has seen
one real request succeed before offering you a tab that promises to answer.

It is one friend, not three. The window on the Mac, the tab on the phone, and the chat
bridges below all run the same conversation, so what it has learned about you in one place
it knows in the others, and a thumbs-down you give here counts the same as one you give in
Telegram.

**Plain commands stay plain.** "Pause", "next", "louder" and their like are understood
directly and answer immediately, without asking a model anything. That keeps the obvious
things instant and free. The model is for the requests that actually need thinking about.

**You have to bring the brain.** Baton ships no key and talks to no model provider until you
set one up: point it at Anthropic, at OpenAI, or at something running on your own machine.
Until then the friend has nothing to answer with. Once you do, what you type goes to that
provider, along with what's playing. [Saying it in your own
words](#saying-it-in-your-own-words) lists exactly what travels.

### Turning it on, on the Mac

The setting lives in **Settings → Remote**, which is also where the Telegram and Discord
bridges are. That pane is about everything that answers you in words, not just the chat apps,
so the friend's brain is set up there too, in the **Natural language** section near the bottom.

1. Open **Settings → Remote**, and scroll past Telegram, Discord, Linking, Devices and Baton
   server to **Natural language**.
2. Turn on **Understand plain English**. Leave **Enable remote control** at the top of the
   pane alone unless you want Telegram or Discord as well: the friend window doesn't need
   it.
3. Pick a **Provider**: *Anthropic* or *OpenAI-compatible*. Choosing one fills in a matching
   model and base URL, so the only thing left is the key.
4. Paste your **API key** and click **Save** beside the field. It saves on the button, not
   as you type, and it goes to your login Keychain rather than a preferences file.
5. Optionally change **Model** or **API base URL**. This is where a model on your own
   machine goes: point the base URL at it and nothing leaves the house.
6. Click **Test**. It sends one real request the way a message would, so a pass means the
   next thing you say will work, rather than only that something answered.
7. Turn on **Let it look around first**. Without it, one message becomes one command decided
   blind: ask for "lazy music" and you get "nothing matched" even with a shelf of things
   tagged *chill*. **Remember what you tell it** sits underneath and needs it on.

Then **Go → Music Friend**, or **⇧⌘F**. If the window still says it has nothing to answer
with, step 2 is the one that was missed: a key with the switch off does nothing.

**Talk to it if you'd rather.** The friend window's composer has a microphone: click it and
speak, click it again to stop and send what you said. The first time, macOS asks for permission
to use the microphone and to recognise speech. If you say no, the window tells you so instead of
appearing to listen and doing nothing. Typing is always there as well: **Return** sends, and
**⌥Return** starts a new line.

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

**Baton server** sends the question to your **Baton server** running on a machine at home,
so your key stays there instead of on your phone. This is the one people get wrong, so it is
worth being blunt: a Baton server is `baton-gateway`, the small program described under
[Running your Baton server](#running-your-baton-server). **It is not a model endpoint.**
Pointing Baton server at Ollama, vLLM, LiteLLM or anything else that speaks an LLM API will
not work, however well that thing runs, because Baton asks it for `/v1/agent` and only the
Baton server answers there. If you want to use a model on your own machine, that is Model
provider, or `BATON_LLM_BASE_URL` on the Baton server itself.

The two addresses on this screen also want opposite shapes, which is easy to miss because
they sit one above the other:

| Field | Address |
|---|---|
| **Baton server** | The bare host and port, `http://192.0.2.10:8788`. The Baton server listens on **8788** by default. A trailing `/v1` is dropped if you paste one. |
| **Model provider** | The API root **including** `/v1`, because that is where `/chat/completions` hangs off. |

**About the fallback.** The panel says Baton falls back to the model provider if your Baton
server cannot be reached, and it does: a Baton server that is asleep or has moved will not
take the friend down with it. What the fallback does *not* do is make the Friend tab appear:
that gate tests the route you actually chose. If you picked Baton server and have none running,
test as **Model provider** instead.

**Tell it when it is wrong.** Every answer has a quiet thumbs-up and thumbs-down under it. A
thumbs-down asks what went wrong (wrong track, misunderstood, too slow, too chatty), and
that correction goes into what it reads before answering next time. You can read the whole
history in the **Friend Log**: **Settings → Friend Log** on the Mac, and the **Friend log** button
at the top of the **Friend** tab on the iPhone.

There is a guided tour for all of this in Help, called **Your music friend**, and the
question-mark button in the friend window's composer opens this page directly.

---

## Controlling Baton from Telegram or Discord

Baton can take commands from a chat app, so the stereo answers to your phone from the couch,
the kitchen, or the other end of a train line. Set it up in **Settings → Remote**.

Nothing about this opens your Mac to the internet. Baton dials *out* to Telegram and Discord
and waits for them to hand it messages. There is no port to forward, no address to publish,
and no change to the loopback-only control server described above.

A "bot" here is just an account on Telegram or Discord that Baton logs into, so you can send
it messages the way you'd message a person. Making one is free and takes about two minutes.
You only need to do one service: pick whichever you already use.

### Telegram, step by step

1. Open Telegram and start a chat with **@BotFather**: Telegram's official bot for making
   bots. Search the name and look for the blue verified checkmark.
2. Send it `/newbot`.
3. It asks for a display name: anything you like, such as `My Music`.
4. It asks for a username, which must be unique and end in `bot`, such as
   `my_music_2026_bot`. If it's taken, it just asks again.
5. BotFather replies with a token that looks like `8123456789:AAF3k9...`. **Treat it like a
   password**: anyone holding it can act as your bot.
6. In Baton: **Settings → Remote**, turn on **Enable remote control**, then **Enable
   Telegram**, paste the token into **Bot token**, click **Save**. Within a second or two the
   **Status** line turns green and shows your bot's `@name`. Red shows Telegram's reason:
   almost always a mistyped token.
7. Open a chat with your new bot and send `/link 123456`, using the six-digit **link code**
   from the **Linking** section of the same pane. It replies "Linked.": try `np` or `play`.

**Using it in a group chat?** Two things to know. Telegram bots in groups default to
*privacy mode*, which hides ordinary messages from them, so `np` goes unseen while `/np`
gets through. Either stick to `/`-prefixed commands in groups, or message BotFather
`/setprivacy` and turn privacy off for your bot. And when several bots share a group,
`/pause@your_bot_name` disambiguates: Baton understands the suffix.

### Discord, step by step

The order below matters: the **Message Content intent** comes before the token, because a
bot that connects without it sees every message with the text stripped out: it looks like
Baton ignoring you, with no error anywhere.

1. Go to **discord.com/developers/applications** and sign in.
2. Click **New Application**, name it (say, `Baton`), and create it.
3. In the left sidebar open **Bot**, then set three things on that page:
   - **Public Bot: off**, so only you can invite it anywhere.
   - Under **Privileged Gateway Intents**, turn **Message Content Intent on**, and click
     **Save Changes**.
   - Click **Reset Token**, confirm, and copy the token. It is shown exactly once. If you
     lose it, reset again (the old one stops working).
4. In Baton: **Settings → Remote**, turn on **Enable remote control** and **Enable
   Discord**, paste the token, click **Save**. The **Status** line turns green with the
   bot's name once the connection is up.
5. Invite the bot to a server: it can see nothing until you do. Grab the **Application
   ID** from the app's **General Information** page, and open this URL with yours
   substituted:

   ```
   https://discord.com/oauth2/authorize?client_id=YOUR_APPLICATION_ID&permissions=68608&scope=bot
   ```

   Pick your server in the dialog and authorize. `68608` grants exactly **View Channels,
   Send Messages, and Read Message History**: all a music remote needs. Don't grant
   Administrator or Manage-anything. A remote control has no business with them. (The same
   thing can be clicked together under **OAuth2 → URL Generator**: scope `bot`, then those
   three permissions.)

   No server of your own? Create one with the **+** button in Discord's left rail: a
   private server with just you in it is the tidiest option.
6. Pick or create a channel for it. A dedicated `#music` or `#baton` channel keeps things
   readable, but any channel works: Baton ignores messages written by bots, so it can
   share a channel with webhook feeds without tripping over them.
7. In that channel, send `/link 123456` with the six-digit code from Baton's **Linking**
   section. "Linked.": you're done.

To confine the bot to specific channels, fill **Limit to channels** with channel ids
(comma-separated). Getting an id: Discord **Settings → Advanced → Developer Mode on**, then
right-click the channel → **Copy Channel ID**. This narrows an already-authorized person.
Leaving it empty is fine, because the link-code allowlist is what actually guards access.

### About that link code

The link step isn't ceremony, and it's worth understanding why it's there. A bot token
identifies *the bot*, not *you*. Anyone who found your bot could otherwise message it and
take over your speakers. So until a chat is linked, Baton ignores every message it gets
except a correct link code, and each code works only once, because you type it into a chat
history that might get backed up or read over your shoulder.

After five wrong codes, Baton stops accepting any code, so a stranger can't keep guessing. Press
**New code** (or restart Baton) to open linking again.

If you ever want to cut a chat off, the Remote pane lists every linked chat with a **Revoke**
button. **New code** rolls the code if you think it's been seen.

On Discord you can also fill in **Limit to channels** with one or more channel ids, which
confines the bot to those channels. That narrows things further. It doesn't replace linking.

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
| `vol 40` | Volume, 0 to 100: Baton's own volume, not the Mac's |
| `seek 1:30` | Jump to a position (`90` and `1m30s` also work) |
| `np` | What's playing right now |
| `search coltrane` | Look without playing |
| `like` · `unlike` | Star the current track (or `like <song>`) |
| `rate 5` | Rate the current track, 0 to 5 |
| `playlists` | List your playlists |
| `playlist Evening` | Play a playlist by name: part of the name is enough |
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
a command gets read as intent instead: "put on something mellow", "skip this one", "make me
a 40-minute driving mix".

This one needs a model to talk to, which you provide. Baton ships no key, and the feature
stays off until you set it up. There's a **Test** button that sends one real request and
tells you whether it worked, so you're never guessing.

Baton speaks two API dialects, which between them cover nearly everything:

- **Anthropic**: Claude's Messages API.
- **OpenAI-compatible**: the `chat/completions` shape that OpenAI, Groq, Together, Mistral,
  DeepSeek and OpenRouter all serve, *and* that self-hosted servers speak: vLLM, Ollama,
  LM Studio, llama.cpp, LiteLLM. This is the one to pick for a model running on your own
  hardware.

**Using a hosted model.** Pick the provider, get a key from them
([console.anthropic.com](https://console.anthropic.com) or
[platform.openai.com](https://platform.openai.com)), paste it into **API key**, click
**Save**, then **Test**. Model and base URL are pre-filled sensibly for each provider and can
be left alone. Costs are yours and are small: each message is one short request.

**Using your own model.** If you run a model on your own machine or network, set the provider
to **OpenAI-compatible**, put your server's address in **API base URL** (the root that
`/chat/completions` hangs off: for example `http://your-server:8000/v1`, or
`http://localhost:11434/v1` for Ollama), and set **Model** to whatever name your server
serves. Most local servers accept any key. Put something in the field anyway. Nothing leaves
your network, and there's no per-message cost.

One thing macOS does that looks like a Baton bug: the first time Baton talks to something on
your own network, macOS asks permission, and if that prompt was missed or declined every attempt
fails with *"The Internet connection appears to be offline"*, even though Baton is plainly
online. Allow it under **System Settings → Privacy & Security → Local Network**, where Baton
should be switched on.

One thing to check with a local model: it must support **tool calling** (also called function
calling). Baton asks the model to pick from its list of commands, and a model or server built
without that support will fail the Test with an error saying so. Most current instruct models
handle it. Very small or older ones often don't. Smaller models are also less precise at
picking details out of a sentence (asking for "kind of blue" might search for just "blue"),
so if results feel vague, a larger model is the fix.

If you'd rather not have any of this, leave it off: every command in the table above works
without it.

If you use a phrase that collides with a command, put `ask` in front to force the
plain-English reading: `ask play something quiet`.

**Commands are tried first, but they don't trap you.** A message starting with a command word
is handled instantly and locally: `play kind of blue` is a search, not a question for the
model. If that literal reading finds nothing, and plain English is on, Baton asks the model
what you meant rather than leaving you with "no songs matched". So `play the second one`
works even though it starts with `play`.

**Follow-ups work.** Each chat remembers its last few exchanges, so you can say "show me
tracks for Dido" and then "play the second one" and it knows what you mean. That memory is
short on purpose: it lives only while Baton is running, covers a few recent exchanges,
expires after about half an hour of quiet, and is kept separately for each chat. Send
`forget` to clear it whenever you like.

**What this sends, and where.** Plain English is off until you switch it on, and once it's on,
each message goes to the model provider you chose. With it goes the list of Baton's own commands,
the chat's last few exchanges, and what's playing: the title, artist and album, and where you
are in the queue. Your server's address and your sign-in never go. With **Let it look around
first** on, more of your listening goes too, as the next section explains. A model on your own
machine keeps all of it at home.

Under the hood the model is choosing from the same controls an AI agent gets, so a sentence can't
ask Baton to do anything the buttons can't. Deleting a playlist is deliberately left out of what a
sentence can reach. Type the command for that.

### Letting it look around first

Underneath is a second switch, **Let it look around first**, and it's the difference between a
translator and something you can have a conversation with.

Off, your sentence becomes one command, chosen blind. Baton looks nothing up for the model, so
apart from what's playing and the chat's last few messages it knows nothing about your library,
and it has to be right first time. Ask for "lazy music" and
you get "nothing matched", even though the chillout is right there, tagged `chill`, `lounge`
and `ambient`, because a mood is rarely a song title.

On, Baton lets it look before it answers. It can read which genres your library actually uses,
what you've liked and played most, what's similar to a track, and what albums are newest or
most-played, then search again with words it has seen work, and play the result. The reply
tells you what it did and why it isn't literally what you asked: *"nothing called 'lazy':
your chillout is tagged chill, playing that"*.

**It asks when asking is the honest thing.** If what it found splits two ways and the answer
changes what you'd hear (two artists sharing a name, a six-hour mix beside a forty-minute set),
it offers them as buttons, each with the fact that decides it. Tap one, or type `2`, or say
"the ambient one". Ignore it and after a minute or so it starts the one it recommended and
says that's what it did, rather than leaving you in silence. Send anything else and the
question is dropped: it won't start playing under you a minute after you've moved on.

**This is the setting that changes how much leaves your Mac,** which is why it's separate and
off by default. Looking around means what it finds (song titles, artists, genres) travels to the
model along with your question, because that's the only way it can answer. Baton also sends the
short summary of your listening described below, what it remembers about you, and what it
recently started playing. With it off, only your message, the recent exchanges and what's playing
go. Point the base URL at a model running on your own machine and the difference stops
mattering: nothing leaves your network either way.

It costs a little more than one request per message, since looking takes turns. Against a
local model that's typically a second or two.

**It knows what you listen to.** Before it answers, Baton hands it a dozen lines read from
your own server: your biggest genres with counts, what you've played most and how often, how
many songs you've liked, what you added recently. Nothing is stored and nothing is guessed:
they're the server's own numbers, read fresh each day. It's what makes "what kind of music do
I listen to?" answerable, "surprise me" grounded in your collection rather than a coin flip,
and a remark like "that's its 34th play" possible at all.

**It occasionally has a view.** When a number is worth mentioning it says so in passing,
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
  actually said. There is nowhere to put "seems to like sad music on Sundays": the file has
  no field for a guess about you, which is a better guarantee than a promise not to make one.
- **It tells you every time it writes one.** "Noted: no vocals while you work." If it
  misunderstood, you see it in the same window a second later, and one message fixes it.
- **It's one command away.** `memories` lists everything with the quote attached, `forget 2`
  removes one, `forget everything` clears the lot.

You do not have to ask in chat to see them. The Friend Log (**Settings → Friend Log** on the
Mac, the **Friend log** button in the **Friend** tab on the iPhone) has a **What it remembers**
section listing every stored memory, each with the sentence you actually said
underneath it and a **Forget** button of its own. Forgetting one there removes it from your
other devices too, rather than letting the next sync push it back.

On the Mac, **Settings → Remote → Natural language** holds the two blunter controls:
**Remember what you tell it**, which stops it storing anything new, and **Delete all…**, which says how many memories are stored
and asks before it removes them. That delete stays available even when you have turned the
friend off, because switching it off is one of the likeliest reasons to want it.

It keeps a couple of dozen things at most, forgetting whatever has gone longest unused. It
also notes what it recently started playing, so "surprise me" stops surprising you with the
same three tracks.

---

## Settings reference

On the Mac, open Settings with **Baton → Settings…** or ⌘,. It reopens on the pane you used
last. It has ten panes, each described below, in the order they appear. On the iPhone, Settings
is a single scrolling list behind the gear button on **Home**, so it has its own section at the
end of this reference.

### Music Servers
<!-- baton:audience mac -->

**Music servers** lists the music servers that hold your library, each with a status badge. Its
**⋯** menu has **Make Active**, **Check Connection**, **Edit…** and **Remove…**, and **Add Music
Server…** adds another. Each one keeps its own sign-in in the Keychain, and a banner appears if
the Keychain is locked. See [Using more than one music server](#using-more-than-one-music-server).

Your Baton server is not here: it is under **Remote**. **About the two servers** explains the
difference, as does [The two servers Baton uses](#the-two-servers-baton-uses).

### Playback
<!-- baton:audience mac -->

- **Sound.** **Loudness normalization** (Off, Track or Album) and its **Pre-amp**;
  **Crossfade** (off up to 12 seconds); **Gapless playback** and its **Prefetch streamed tracks on
  Wi-Fi only** option; **Clear prefetch cache**; **Autoplay similar tracks when the queue ends**;
  **Clear radio bans** (tracks you've told an endless radio to stop suggesting); **Duck to**, how
  far music dims under a spoken summary; and **Stall timeout**, how long a stalled stream waits
  before Baton retries. See [Sound quality](#sound-quality-gapless-crossfade-loudness) and
  [autoplay](#the-queue-shuffle-repeat-and-autoplay).
- **Menu Bar.** **Show track title in menu bar**, which puts the current track or station title
  beside the menu-bar icon. See [The menu-bar controller](#the-menu-bar-controller).
- **Downloads.** **Offline mode**; **Remove finished podcast episodes**; the download folder, with
  **Choose Folder…**, **Show in Finder** and **Use Default**; and the **Filename format** with its
  `{artist}`, `{album}`, `{title}` and `{id}` tokens. See
  [Downloads](#downloads-and-offline-listening).
- **Scrobbling.** Your **ListenBrainz user token** with **Test**; your Last.fm connection
  (**Last.fm API key**, **Last.fm shared secret**, **Authorize in browser…**, **I've authorized,
  finish**, **Disconnect**); **Last.fm & ListenBrainz scrobbles**, sent by Baton or handled by
  your music server; and **Waiting to send** with **Send now**. See [Scrobbling](#scrobbling).
- **Finding music you don't have.** **Look outside my library**, off until you turn it on. Under
  it, a switch and a **Test** button for each of MusicBrainz, ListenBrainz, Last.fm and YouTube,
  and the **Last.fm API key** and **YouTube API key**. See
  [Finding music you don't have](#finding-music-you-dont-have).
- **Advanced.** Collapsed until you open it. **Filter history size** (how many recent filter terms
  each browse screen remembers), **Clear filter history**, and the **Experimental audio engine**
  switch that lets the equalizer reach streamed music. Read what that switch costs you in
  [The equalizer](#the-equalizer) before you turn it on.
- **Reset to Defaults.** Restores the Sound and browse preferences. Your scrobbling accounts and
  your download folder are kept.

### Equalizer
<!-- baton:audience mac -->

- **Equalizer.** **Enable equalizer**, and a line saying where the curve applies right now.
- **Preset.** The named curves, and **Flat / Reset**. It shows **Custom** once you change a band.
- **Response.** The live response graph.
- **Bands.** The ten bands themselves: frequency, gain and Q for each.
- **Reset to Defaults.**

See [The equalizer](#the-equalizer).

### Actions
<!-- baton:audience mac -->

Your **Webhook Actions**, each with Edit and Delete, and **Add Action…**. See
[Webhook actions](#webhook-actions).

### Speech
<!-- baton:audience mac -->

In order:

- **Services.** The addresses of your **Kokoro** and **Chatterbox** voice servers, each with a ↻
  test button, and **Fall back to the system voice**. See
  [Speaking summaries aloud](#speaking-summaries-aloud).
- **Agent voices.** A voice for each agent by name. See [One voice per agent](#one-voice-per-agent).
- **Documents.** The **Documents** switch, which turns books from documents on or off on this Mac.
  See [Listening to a document](#listening-to-a-document).
- **Voice engine for books** (while Documents is on). What reads a book made on this Mac
  (**Automatic**, **Built-in voices on this Mac** or **Voice server**), the built-in voices'
  download, the **Expressive voice server**, and **Make books on**. See [Voices: on this Mac or on
  your Baton server](#voices-on-this-mac-or-on-your-baton-server).
- **Models on this Mac** (while Documents is on). Apple Intelligence, Ollama and LM Studio, the
  models this Mac can run itself.
- **Delivery.** **When a summary arrives**, **Allow the agent to play it immediately**, **Alert with
  a notification**, **Alert with an in-app banner** and **Bluetooth head start**. See [How the line
  reaches you](#how-the-line-reaches-you).
- **Voices.** The category-to-voice map. See
  [One voice per category](#one-voice-per-category-the-voice-map).
- **Transcription.** **Transcribe spoken tracks**, **Whisper host** and **Model**. See
  [Transcripts and summaries](#transcripts-and-summaries).
- **Read aloud.** **Keyboard shortcut**, the clipboard fallback, **Unfinished readings** with
  **Forget Them Now**, **Use a different voice per app**, and **Read a window Baton cannot get text
  from**. See [Reading what's on your screen](#reading-whats-on-your-screen).
- **Reset to Defaults.**

### Storage
<!-- baton:audience mac -->

The books on **This Mac** with their sizes, the **Baton Server**'s books (with **Refresh**), the
cleanup rules (**After I finish a book**, **Books I haven't played**, **Space for books on this
Mac**), and **Recently Removed** with **Restore** and **Delete Now**. See
[Book storage](#book-storage).

### Agents
<!-- baton:audience mac -->

Whether an AI agent can drive Baton, and everything it needs to:

- **Connection.** Whether the control server is running, its endpoint address, the access token,
  and the fast-path socket, with a button to copy each.
- **Port.** The port the server starts on (8787 unless you change it, anything from 1024 to
  65535), the address it is listening on right now, and a notice when the two differ because the
  port you asked for was already taken. Changing the port restarts the server on the new one.
- **Discovery.** The file an MCP client reads to find that endpoint and token by itself, so there
  is nothing to paste.
- **Client configuration.** The same settings written out as a snippet, with **Copy
  configuration**, for a client you have to set up by hand.
- **Book text and cloud models.** What document features may send to each cloud model you have
  set up, and **Forget My Answers**. See [Book text and cloud models](#book-text-and-cloud-models).

See [Letting an agent control your music](#letting-an-agent-control-your-music).

### Remote
<!-- baton:audience mac -->

In order:

- **Enable remote control**, the master switch for the chat bridges.
- **Telegram** and **Discord**: **Enable Telegram** or **Enable Discord**, the **Bot token** with
  **Save**, the **Status** line and **Reconnect**, and for Discord **Limit to channels**. See
  [Controlling Baton from Telegram or Discord](#controlling-baton-from-telegram-or-discord).
- **Linking**: the **Link code** with **New code**, and the chats you've authorized, each with
  **Revoke**.
- **Devices**, under **Link a device**: **Show pairing code** for your iPhone, and your linked
  devices, each with **Forget**. See
  [Getting your Mac's setup onto your phone](#getting-your-macs-setup-onto-your-phone).
- **Baton server**: the **Baton server address** and **Baton server token**, **Save token**,
  **Test** and **Sync now**. See [The two servers Baton uses](#the-two-servers-baton-uses) and
  [Shared settings between your devices](#shared-settings-between-your-devices).
- **Natural language**: **Understand plain English**, the **Provider**, **API key**, **Model** and
  **API base URL**, **Test**, **Let it look around first**, **Remember what you tell it** and
  **Delete all…**. Setting it up is step by step in
  [Turning it on, on the Mac](#turning-it-on-on-the-mac).
- **Privacy**: a short note on what these send.

### Friend Log
<!-- baton:audience mac -->

What the music friend gets wrong and what it remembers, in sections: **What goes wrong**, **What it
remembers** and **What it has learned** (each entry with **Forget**), and **Recent**, every
exchange you've had with it on any of your screens, with the thumbs-up or thumbs-down you gave.
**Clear Log** empties it. This is where a correction goes to live, and where to look when you want
to know why it answered the way it did. See [The music friend](#the-music-friend).

### About
<!-- baton:audience mac -->

Baton's version, its license (MIT), and a link to the website, then these sections:

- **Support Baton**: the tip jar. Baton is free and stays free, and a tip unlocks nothing.
- **Lyrics**: **Look up missing lyrics**, which asks LRCLIB for words your server doesn't carry.
  It lives here rather than under Playback. See [Lyrics](#lyrics).
- **Appearance**: **System**, **Light** or **Dark** for all Baton windows, including the full
  player and Mini Player. The **Appearance** button in the full player changes the same setting.
  The moon beside it is the sleep timer.
- **Startup**: **Launch Baton at login**, so the menu-bar controls are there straight away.
- **Updates**: the update feed, its status, **Automatically check for updates** (on by default),
  **Check for Updates Now**, and when it last checked. See [Updates](#updates).
- **Shared Links**: **Show Shared Links…**, the songs, mixtapes and books you have shared, with who
  listened, and copy, extend or revoke. See [Shared Links](#shared-links).
- **Back up & restore**: **Export…** writes your settings to a file, with or without your
  accounts, and **Import…** reads one back. See
  [Backing up and restoring your settings](#backing-up-and-restoring-your-settings).
- **Diagnostics**: **Send crash & error reports**, off by default, and **Export Logs…**. See
  [Privacy and security](#privacy-and-security).

The Playback, Equalizer and Speech panes each have their own **Reset to Defaults** button, and each
keeps your sign-ins and servers when it resets.

### Settings on iPhone

The phone has no panes. Tap the gear button at the top of **Home**: Settings opens as a sheet,
with **Done** to close it, and everything is one scrolling list, in this order:

- **Music server**: whether your music server answers, its address and user (partly hidden until
  **Show Server Details** passes Face ID or your passcode), **Disconnect…**, and **Set up from a
  Mac…**, which offers the two ways to bring a Mac's setup across. In the demo it shows **Connect
  to Navidrome…** instead. See [Getting your Mac's setup onto your
  phone](#getting-your-macs-setup-onto-your-phone).
- **Music Friend**: shows **Ready**, **Not tested** or **Off**. Inside: **Answers come from**, the
  model provider or Baton server the friend runs on, and **Test connection**. The **Friend** tab
  appears once that test passes. Your Baton server's address and **Baton server token** are set
  here too, and books use them. See [Turning it on, on the iPhone](#turning-it-on-on-the-iphone).
- **Alarm and Timer**: **Rings with Baton closed**, with **Allow Alarms** or **Turn On in iPhone
  Settings**. See [When Baton is closed on the iPhone](#when-baton-is-closed-on-the-iphone).
- **Equalizer**: the switch, a line saying where the curve applies right now, **Preset**, **Flat /
  Reset**, and **Bands**. See [The equalizer](#the-equalizer).
- **Advanced**: the **Experimental audio engine** switch, and under it **Engine cost**, which
  shows the processor time the current engine spends per second of audio, so you can compare the
  two yourself. On the phone the switch applies straight away.
- **Transcription**: **Transcribe spoken tracks**, the Whisper host and model, and whether it
  answers. See [Transcripts and summaries](#transcripts-and-summaries).
- **Documents**: the **Documents** switch, on by default, for making a book on your Baton server
  from a file in Files, the share sheet or the Books **+** menu; **Where books are made**, which
  says your Baton server's voice server reads them and what that needs; **Storage**, for the books
  on this phone and the cleanup rules; and a **Chapters** switch for each cloud model you've been
  asked about. See [Listening to a document](#listening-to-a-document),
  [Voices: on this Mac or on your Baton server](#voices-on-this-mac-or-on-your-baton-server) and
  [Book storage](#book-storage).
- **Sound**: **Gapless playback**, **Crossfade** (hidden while gapless is on, since the two want
  opposite things), **Loudness**, **Look Up Missing Lyrics**, **Look Outside My Library**,
  **Appearance**, and **Wi-Fi Quality** and **Cellular Quality**. See
  [Sound quality](#sound-quality-gapless-crossfade-loudness) and
  [How much data it uses](#how-much-data-it-uses).
- **Queue**: **Autoplay similar songs** when the queue runs out. See
  [The queue, shuffle, repeat, and autoplay](#the-queue-shuffle-repeat-and-autoplay).
- **Scrobbling**: ListenBrainz, Last.fm, and the **Offline queue** with **Send now**. Your music
  server's own play counts need no setup. See [Scrobbling](#scrobbling).
- **Shared Links**: the links this phone has sent, who listened, and copy, extend or revoke. See
  [Shared Links](#shared-links).
- **Help & FAQ** and **What's New**: this guide, and the notes for each release.
- **Diagnostics**: **Send crash reports**, off by default.
- **Display**: **Keep the screen awake**, for a phone propped on a dock or a counter. Off by
  default, because it uses more battery.
- **Version** and **Privacy Policy** at the bottom.

There is no Actions, Speech, Agents or Remote section on the phone. Webhook actions, spoken
summaries, the agent control server and the chat bridges are Mac features. The phone's Friend Log
is in the **Friend** tab rather than in Settings.

---

## Backing up and restoring your settings

Baton on the Mac can write your setup to a file, so you can move it to another Mac or your
iPhone, or keep it in case you need to start again. The file is yours to keep wherever you like.

Your library, likes, ratings, playlists and play counts aren't in it, and don't need to be:
they live on your music server.

### Exporting from the Mac

1. Open **Settings → About → Back up & restore** and click **Export…**.
2. In **Export Settings**, choose whether to turn on **Include accounts & passwords**. It's off by
   default.
3. If you turn it on, choose a passphrase. You'll need it to read the file back, and there is no
   way to recover it.
4. Save the file. It's named **Baton Settings** unless you change it.

**Without accounts**, the file is plain and holds your preferences and your music server list,
without passwords: playback and sound, the equalizer, layouts, spoken-summary voices, your
webhook actions, and the rest of your choices in Settings.

**With accounts**, it also carries your sign-ins, encrypted with your passphrase:

- each music server's password
- your Last.fm and ListenBrainz logins
- your Baton server token
- the music friend's API key, and the Last.fm and YouTube discovery keys
- what the music friend remembers about you and has learned

**Never in the file**, either way: your play queue, your local play history, the scrobbles waiting
to be sent, your spoken-summary history and your download folder. Those belong to the device.

### What never travels

Some secrets stay on the Mac that made them even with **Include accounts & passwords** on:

- **The agent control token.** A restored Mac makes a fresh one, so each agent needs the new token
  from `mcp.json` (see [Connecting an agent to Baton](#connecting-an-agent-to-baton)).
- **Telegram and Discord bot tokens.**
- **Webhook header values**, such as an `Authorization` header. The actions travel, but their
  headers come across empty.
- **The expressive voice server's key.**
- **Your share identity.** Links you shared from the old Mac keep playing until they end, but they
  can't be listed, extended or revoked from a restored one. See [Shared Links](#shared-links).

### Importing a file

**On the Mac**, open **Settings → About → Back up & restore** and click **Import…**, then choose the
file. If it was exported with accounts, Baton asks for the passphrase. When it's done, Baton asks
you to quit and reopen it, so every setting takes effect.

**On the iPhone** you can import but not export. Choose **Settings → Music server → Set up from a
Mac… → Choose an exported file**, pick the file (AirDrop, iCloud Drive or email all work to get it
there), and enter the passphrase if it has one. This is the same route described in
[Getting your Mac's setup onto your phone](#getting-your-macs-setup-onto-your-phone).

### What to enter again

After an import, set these up again where you need them:

- **Always:** your Telegram or Discord bot token (**Settings → Remote**), any webhook header values
  (**Settings → Actions**), the expressive voice server key (**Settings → Speech → Voice engine
  for books**), and the new agent token in each agent you use.
- **If you exported without accounts:** your music server passwords, your Last.fm and
  ListenBrainz logins, your Baton server token, and your API keys.

See also: [Shared settings between your devices](#shared-settings-between-your-devices), which keeps
your preferences in step all the time once your Baton server is set up.

---

## Updates

On the Mac, Baton updates itself with Sparkle, the standard updater many Mac apps use. It checks
Baton's update feed on its own, and offers signed, notarized builds so you don't have to
reinstall by hand. You can download the current release from
[batonmusic.app](https://batonmusic.app), and it keeps itself up to date from there.

- **Automatic checks are on by default.** Turn them off with **Settings → About → Updates →
  Automatically check for updates**. That section also shows the feed, its status and when it
  last checked.
- **To check now**, choose **Baton → Check for Updates…**, **Check for Updates…** in the menu-bar
  menu, or **Check for Updates Now** in **Settings → About → Updates**.

On the iPhone, updates come from the App Store like any other app.

---

## What's next

Recently landed in Baton: the **iPhone app** (see [Baton on iPhone](#baton-on-iphone)), the
**Podcasts** and **Internet radio** tabs, the **Downloads and offline** manager, the
**parametric equalizer**, **multiple servers** and account switching, spoken summaries
(**Speech**), and the agent-built **`music_build_mix`**.

Still on the roadmap, called out here so the docs stay honest:

- **Casting beyond AirPlay**: Chromecast, Sonos, and UPnP/DLNA. AirPlay works today. Wider
  casting needs protocol support Baton doesn't bundle yet.
- **Sonic-analysis mixes**, built from the actual sound of your music (tempo, energy, key),
  not just your play history.
- **Crossfeed and other DSP**. (The lyrics fallback that used to sit on this list has
  shipped: see [Lyrics](#lyrics).)

The full roadmap is in
[`docs/05-roadmap-new-features.md`](https://github.com/anatoliv/baton/blob/main/docs/05-roadmap-new-features.md)
on GitHub.

---

## Privacy and security

- **Your passwords and keys live in the Keychain**, never in a plain text file.
- **Baton has no account with us and no catalog server of its own.** It plays from the music server
  you point it at. Everything else it can talk to is listed below.
- **The control server is loopback-only and token-protected.** It can't be reached from your
  network, and nothing on your Mac can drive it without the secret token. See
  [How it's secured](#how-its-secured).
- **Chat remote control connects outward only, and starts closed.** Baton opens a connection to
  Telegram or Discord rather than accepting one, so no port is exposed, and a chat can't drive
  playback until you link it with the code Baton shows you. See
  [Controlling Baton from Telegram or Discord](#controlling-baton-from-telegram-or-discord).
- **Your Baton server is your own machine.** When you turn a document into a book there, it keeps
  the document's text and the book's audio until you remove them, and none of it reaches Baton's
  developer.

### Everything Baton can talk to

**On unless you turn it off:**

- **Your music server**, for your library, streams, likes, ratings and play counts.
- **Baton's update feed** (Mac), checked automatically for new versions. Turn it off under
  **Settings → About → Updates**. See [Updates](#updates).

**Only when you use it:**

- **Baton's share service**, when you share a song, a mixtape or a book. The audio is encrypted on
  your device first. Preview details, reactions and counts are stored as described in
  [How private sharing is](#how-private-sharing-is).
- **Open Library**, when you choose **Find Cover…** for a book. It gets the title and author.
- **Podcast feeds** you subscribe to by address, and **radio stations** you add, which Baton
  reaches directly. For a station with a homepage, Baton also fetches the site's icon.

**Only if you turn it on:**

- **Scrobbling** to ListenBrainz or Last.fm: each song you finish. See [Scrobbling](#scrobbling).
- **Crash reports** (**Settings → About → Diagnostics → Send crash & error reports** on the Mac,
  **Settings → Diagnostics → Send crash reports** on the iPhone, both off by default). Baton sends
  crash and error data to its developer through Crashbox, its own crash-report service, to help
  fix bugs. It never includes your music, library, server address or account, and no IP or
  identifiers. Turning it on means Baton tries to send a report after a crash. It doesn't confirm
  that the report arrived.
- **LRCLIB**, for missing lyrics: the track's title, artist, album and length. See
  [Lyrics](#lyrics).
- **MusicBrainz, ListenBrainz, Last.fm and YouTube**, when you look outside your library: the
  artist and title you asked about. See [Finding music you don't have](#finding-music-you-dont-have).
- **The model provider** you set up for the music friend and plain English: your message, recent
  exchanges and what's playing, and more with **Let it look around first** on. See
  [Saying it in your own words](#saying-it-in-your-own-words).
- **A cloud model, for book text**, only with your permission for each model. See
  [Book text and cloud models](#book-text-and-cloud-models).
- **Your own servers**: any voice server (Kokoro, Chatterbox or an expressive one) or Whisper
  transcription server you set up gets the text or audio it works on, and your Baton server gets
  what it needs to sync, make books and answer the friend.
- **Telegram or Discord**, if you connect a bot, for the messages in the chats you link.

There's more on all of this in the [FAQ](FAQ.md#privacy-and-security) and the
[privacy policy](https://batonmusic.app/privacy.html).

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

**An alarm didn't ring while Baton was closed.** On the iPhone, check **Settings → Alarm and
Timer → Rings with Baton closed**: it should say **Allowed**. On the Mac, Baton needs
notifications allowed in **System Settings → Notifications**. See
[When Baton is closed on the iPhone](#when-baton-is-closed-on-the-iphone) and
[When Baton is closed on the Mac](#when-baton-is-closed-on-the-mac).

**An agent can't reach Baton.** Baton has to be running, and the agent needs the address and
token from `~/Library/Application Support/Baton/mcp.json`. Baton starts on the port set in
**Settings → Agents → Port** (8787 unless you changed it), and moves to the next free one only if
that port is taken, writing the new one into the file. If the agent's address doesn't match the
file, copy the current one in. See [Connecting an agent to Baton](#connecting-an-agent-to-baton).

**My bot doesn't answer at all.** Baton has to be running, and **Enable remote control** plus
the switch for that service both have to be on. Check the **Status** line in **Settings → Remote**:
green with a name means Baton is connected and the problem is elsewhere. Red shows the reason
the service gave, which is usually a mistyped or reset token.

**Discord: the bot is online but ignores everything I type.** This is almost always the
**Message Content Intent**, which is off by default. Turn it on at
discord.com/developers → your application → **Bot** → Privileged Gateway Intents, then click
**Reconnect** in Baton. Without it Discord delivers your messages with the text removed, so
Baton receives an empty message and has nothing to act on. If the bot doesn't appear in your
server's member list at all, it was never invited: see the
[setup steps](#controlling-baton-from-telegram-or-discord).

**It says the chat isn't authorized.** That's the expected answer until you link it. Send
`/link` followed by the six-digit code from **Settings → Remote → Linking**. If the code is refused, it's
because codes are single-use: click **New code** and send the new one.

**It answers "I don't know that".** The message wasn't one of the commands. Send `help` for
the list, or turn on **Understand plain English** to have Baton read it as intent instead.

**Spoken summaries never play.** With the default settings, a summary waits for you to press
**Play** in its notification or banner. To hear them straight away, set **Settings → Speech →
Delivery → When a summary arrives** to **Announce immediately**. See
[How the line reaches you](#how-the-line-reaches-you).

**Spoken summaries are silent or use the wrong voice.** Check the server addresses under
**Settings → Speech → Services** with the ↻ test button beside each. If a server is down and
**Fall back to the system voice** is off, Baton reports an error rather than speaking. Turn the
fallback back on to always hear something.

---

## Questions

The [FAQ](FAQ.md) has short answers to the common ones. For the vision, architecture, and
integration details, browse the docs in [`docs/`](docs/). Baton is made by
[Tonebox](https://tonebox.io), and given away for free.
