# Baton FAQ

Short answers to the questions that come up most. For step-by-step walkthroughs, see
[HELP.md](HELP.md).

## Contents

- [About Baton](#about-baton)
  - [What is Baton?](#what-is-baton)
  - [Is Baton free?](#is-baton-free)
  - [How is Baton different from Tonebox?](#how-is-baton-different-from-tonebox)
  - [What platforms does Baton run on?](#what-platforms-does-baton-run-on)
- [Servers and your library](#servers-and-your-library)
  - [What are the music server and the Baton server?](#what-are-the-music-server-and-the-baton-server)
  - [What music servers work with Baton?](#what-music-servers-work-with-baton)
  - [Does Baton have its own music catalog?](#does-baton-have-its-own-music-catalog)
  - [How do I connect?](#how-do-i-connect)
  - [Can I connect more than one music server?](#can-i-connect-more-than-one-music-server)
  - [Does Baton do podcasts and internet radio?](#does-baton-do-podcasts-and-internet-radio)
  - [Can I try Baton without a server?](#can-i-try-baton-without-a-server)
- [Your settings on more than one device](#your-settings-on-more-than-one-device)
  - [How do I get my Mac's settings onto my iPhone?](#how-do-i-get-my-macs-settings-onto-my-iphone)
  - [Do my podcasts and radio stations follow me between devices?](#do-my-podcasts-and-radio-stations-follow-me-between-devices)
  - [What are shared settings, and do I need a Baton server?](#what-are-shared-settings-and-do-i-need-a-baton-server)
  - [What actually travels?](#what-actually-travels)
  - [Does my API key travel?](#does-my-api-key-travel)
  - [What happens if I change the same thing on both devices?](#what-happens-if-i-change-the-same-thing-on-both-devices)
  - [Where are my settings actually stored?](#where-are-my-settings-actually-stored)
- [Your data](#your-data)
  - [Where does Baton keep my listening history?](#where-does-baton-keep-my-listening-history)
  - [What does "Mark for Removal" do?](#what-does-mark-for-removal-do)
  - [How do I back up and restore my settings?](#how-do-i-back-up-and-restore-my-settings)
- [Privacy and security](#privacy-and-security)
  - [Is my password safe?](#is-my-password-safe)
  - [Does Baton phone home?](#does-baton-phone-home)
  - [Is the control server a security risk?](#is-the-control-server-a-security-risk)
  - [Where does the audio go when I transcribe something?](#where-does-the-audio-go-when-i-transcribe-something)
- [Sharing with friends](#sharing-with-friends)
  - [Can I send a song to a friend who isn't on my server?](#can-i-send-a-song-to-a-friend-who-isnt-on-my-server)
  - [Does a shared link open in Baton?](#does-a-shared-link-open-in-baton)
  - [Can I share several songs, an album, a playlist or a whole book?](#can-i-share-several-songs-an-album-a-playlist-or-a-whole-book)
  - [Where are my friend's reactions kept?](#where-are-my-friends-reactions-kept)
  - [How long does the share service keep things?](#how-long-does-the-share-service-keep-things)
- [Alarms and timers](#alarms-and-timers)
  - [Can I wake up to a song?](#can-i-wake-up-to-a-song)
  - [Can I have an alarm and a timer at once?](#can-i-have-an-alarm-and-a-timer-at-once)
  - [What does Gentle Wake do?](#what-does-gentle-wake-do)
  - [Why does my alarm ring a chime instead of my song?](#why-does-my-alarm-ring-a-chime-instead-of-my-song)
- [Agent control](#agent-control)
  - [What is the control server?](#what-is-the-control-server)
  - [How do agents control my music?](#how-do-agents-control-my-music)
  - [Do I need an agent to use Baton?](#do-i-need-an-agent-to-use-baton)
  - [Can I control Baton from my phone?](#can-i-control-baton-from-my-phone)
  - [Why does it say "nothing matched" for music I know I have?](#why-does-it-say-nothing-matched-for-music-i-know-i-have)
  - [Does turning that on send my library somewhere?](#does-turning-that-on-send-my-library-somewhere)
  - [Does it remember things between conversations?](#does-it-remember-things-between-conversations)
  - [Does chat control open my Mac to the internet?](#does-chat-control-open-my-mac-to-the-internet)
  - [Can anyone who finds my bot control my music?](#can-anyone-who-finds-my-bot-control-my-music)
  - [Can I use my own local model instead of a paid API?](#can-i-use-my-own-local-model-instead-of-a-paid-api)
  - [What permissions does the Discord bot need?](#what-permissions-does-the-discord-bot-need)
  - [Can the bot share a channel with webhooks or other bots?](#can-the-bot-share-a-channel-with-webhooks-or-other-bots)
  - [Why does my bot ignore messages in a Telegram group?](#why-does-my-bot-ignore-messages-in-a-telegram-group)
  - [Does the plain-English option send my library anywhere?](#does-the-plain-english-option-send-my-library-anywhere)
  - [Is agent control available today?](#is-agent-control-available-today)
  - [How do I connect Claude (or another client) to Baton?](#how-do-i-connect-claude-or-another-client-to-baton)
- [The music friend](#the-music-friend)
  - [What is the music friend?](#what-is-the-music-friend)
  - [Do I need an API key, and what does it cost?](#do-i-need-an-api-key-and-what-does-it-cost)
  - [How do I turn it on, on the Mac?](#how-do-i-turn-it-on-on-the-mac)
  - [There's no Friend tab on my iPhone.](#theres-no-friend-tab-on-my-iphone)
  - [Can Baton server point at my own LLM?](#can-baton-server-point-at-my-own-llm)
  - [Which address needs a /v1 on the end?](#which-address-needs-a-v1-on-the-end)
  - [What does the fallback actually do?](#what-does-the-fallback-actually-do)
  - [I set a key and it still says it can't answer.](#i-set-a-key-and-it-still-says-it-cant-answer)
  - [Where does my data go?](#where-does-my-data-go)
  - [Why is the window empty, or why does it say it can't answer?](#why-is-the-window-empty-or-why-does-it-say-it-cant-answer)
  - [Is the friend on my Mac the same one on my phone and in Telegram?](#is-the-friend-on-my-mac-the-same-one-on-my-phone-and-in-telegram)
  - [Can I talk to it instead of typing?](#can-i-talk-to-it-instead-of-typing)
  - [How do I correct it when it gets something wrong?](#how-do-i-correct-it-when-it-gets-something-wrong)
- [Playback](#playback)
  - [Does Baton do gapless?](#does-baton-do-gapless)
  - [Do I have to set all that up?](#do-i-have-to-set-all-that-up)
  - [Can I scrobble?](#can-i-scrobble)
  - [Does Baton work offline?](#does-baton-work-offline)
  - [Why do the player's colors change with the music?](#why-do-the-players-colors-change-with-the-music)
  - [Does Baton have widgets, or work on the lock screen?](#does-baton-have-widgets-or-work-on-the-lock-screen)
  - [Can I use Siri or the Shortcuts app?](#can-i-use-siri-or-the-shortcuts-app)
  - [Can I limit what Baton uses on cellular data?](#can-i-limit-what-baton-uses-on-cellular-data)
  - [Why does my iPhone ask for Face ID in Settings?](#why-does-my-iphone-ask-for-face-id-in-settings)
  - [Can I cast to speakers?](#can-i-cast-to-speakers)
  - [Is there a menu-bar controller?](#is-there-a-menu-bar-controller)
  - [Can Baton tell me what a podcast episode said?](#can-baton-tell-me-what-a-podcast-episode-said)
- [Speaking and reading aloud](#speaking-and-reading-aloud)
  - [Can Baton speak things out loud?](#can-baton-speak-things-out-loud)
  - [With several agents running, how do I tell which one is speaking?](#with-several-agents-running-how-do-i-tell-which-one-is-speaking)
  - [Can each agent have its own voice?](#can-each-agent-have-its-own-voice)
  - [The first word gets cut off on my Bluetooth speaker.](#the-first-word-gets-cut-off-on-my-bluetooth-speaker)
  - [Do I need to run text-to-speech servers for spoken summaries?](#do-i-need-to-run-text-to-speech-servers-for-spoken-summaries)
  - [Can Baton read things on my screen out loud?](#can-baton-read-things-on-my-screen-out-loud)
  - [Does Baton watch my screen?](#does-baton-watch-my-screen)
  - [Is Read aloud a screen reader?](#is-read-aloud-a-screen-reader)
  - [Why does Read aloud need Accessibility permission, and can I avoid it?](#why-does-read-aloud-need-accessibility-permission-and-can-i-avoid-it)
  - [Why does my clipboard flicker when I use the shortcut in Chrome?](#why-does-my-clipboard-flicker-when-i-use-the-shortcut-in-chrome)
  - [Will Baton read my API keys out loud?](#will-baton-read-my-api-keys-out-loud)
- [Documents and audiobooks](#documents-and-audiobooks)
  - [Which documents can Baton read?](#which-documents-can-baton-read)
  - [Can I start from a file in Finder?](#can-i-start-from-a-file-in-finder)
  - [How do I get a document onto my iPhone?](#how-do-i-get-a-document-onto-my-iphone)
  - [Why did my book stop part way?](#why-did-my-book-stop-part-way)
  - [Does my document leave my device?](#does-my-document-leave-my-device)
  - [Can I choose the narrator?](#can-i-choose-the-narrator)
  - [Can I make books on my Mac without a voice server?](#can-i-make-books-on-my-mac-without-a-voice-server)
  - [Should I use the built-in voices or a voice server?](#should-i-use-the-built-in-voices-or-a-voice-server)
  - [Can a book sound more like a person reading it?](#can-a-book-sound-more-like-a-person-reading-it)
  - [Can the characters have their own voices?](#can-the-characters-have-their-own-voices)
  - [How do I free the space a book takes?](#how-do-i-free-the-space-a-book-takes)
  - [I deleted a book by mistake. Can I get it back?](#i-deleted-a-book-by-mistake-can-i-get-it-back)
  - [Can a book have a cover?](#can-a-book-have-a-cover)
  - [Why does the book have the wrong title or chapters?](#why-does-the-book-have-the-wrong-title-or-chapters)
  - [I never use this. Can I hide it?](#i-never-use-this-can-i-hide-it)
- [Updates and platform](#updates-and-platform)
  - [How do I install Baton?](#how-do-i-install-baton)
  - [How do updates work?](#how-do-updates-work)
  - [Where can I read more?](#where-can-i-read-more)

## About Baton

What Baton is, what it costs, and where it runs.

### What is Baton?

A music player for your own music library, on the Mac and the iPhone. It plays from
[Navidrome](https://www.navidrome.org/) or any other Subsonic server (Subsonic is the shared
language of that family of self-hosted music servers), with true gapless playback, crossfade,
ReplayGain loudness matching and a 10-band equalizer.

On the Mac it also runs a small control server, so an AI agent can search, queue and steer your
music for you, and so can a Telegram or Discord message from your phone. The tagline is
*"Conduct your music."* See [What Baton is, and what it
isn't](HELP.md#what-baton-is-and-what-it-isnt).

### Is Baton free?

The Mac app is. It's a give-away from [Tonebox](https://tonebox.io), with no subscription and
no catalog rent: you're playing music you already own, on a server you already run.

The iPhone app costs money. It's on the App Store as
[Baton: Navidrome Music Player](https://apps.apple.com/app/id6798304294), and the price covers
the Apple developer account the Mac build is signed and notarized with. The source of both is
in the repository under the same licence, so you can build the iPhone app yourself instead.
See [Baton on iPhone](HELP.md#baton-on-iphone).

### How is Baton different from Tonebox?

They're two products from the same maker. [Tonebox](https://tonebox.io) is a paid, local-first
notes app that records meetings and voice notes, transcribes them on your Mac, and turns them
into searchable, AI-assisted notes. Baton is the music player, pulled out into its own app,
focused on playing your library well and being controllable by agents.

Tonebox can control Baton (for example, turning the music down while you dictate), but you
don't need Tonebox to use Baton. See [What Baton is, and what it
isn't](HELP.md#what-baton-is-and-what-it-isnt).

### What platforms does Baton run on?

The Mac app needs macOS 15 or later, and the iPhone app needs iOS 18 or later. Windows and
Linux clients are not planned. See [Baton on iPhone](HELP.md#baton-on-iphone).

## Servers and your library

Baton plays music from a server you run yourself. These answers cover which servers work, how
to connect, and how to look around before you have one.

### What are the music server and the Baton server?

Two servers of your own, with different jobs. Your **music server** holds your library: it is
Navidrome or another Subsonic server, and you sign in to it. Your **Baton server** is an
optional small Baton program you run at home. It makes books from documents, keeps your place
and your shared settings in step between devices, and holds files for your other device.

Both can run on the same machine, and music needs only the music server. See [The two servers
Baton uses](HELP.md#the-two-servers-baton-uses).

### What music servers work with Baton?

[Navidrome](https://www.navidrome.org/) and any Subsonic-compatible server. Baton speaks the
Subsonic API, so most self-hosted music servers in that family work. See [Getting
connected](HELP.md#getting-connected).

### Does Baton have its own music catalog?

No. Baton plays *your* library from *your* music server. It is deliberately not a streaming
catalog like Spotify or Tidal, so there's nothing to browse until you connect a music server.
See [What Baton is, and what it isn't](HELP.md#what-baton-is-and-what-it-isnt).

### How do I connect?

On the Mac, the first-launch screen asks for your music server's address and either a username
and password or an API key, and Baton checks the connection before it saves anything. On the
iPhone, the **Connect to Navidrome** screen asks for the same, or brings your Mac's setup across
with **Set up from a Mac**. See [Getting connected](HELP.md#getting-connected).

### Can I connect more than one music server?

Yes, on the Mac. Open Settings (⌘,), choose **Music Servers** and click **Add Music Server…**.
Baton keeps each server's sign-in separately in the Keychain, and **Make Active** in a server's
⋯ menu switches to it. See [Using more than one music
server](HELP.md#using-more-than-one-music-server).

### Does Baton do podcasts and internet radio?

Yes. **Podcasts** plays shows your server hosts, and it can also follow any podcast by its RSS
feed directly (which is how it works on Navidrome). **Radio** plays internet-radio stations you
add, including plain-HTTP streams, and shows the live track each station is broadcasting. Both
are in the Mac's sidebar and under **Library** on the iPhone. See [Podcasts](HELP.md#podcasts)
and [Internet radio](HELP.md#internet-radio).

### Can I try Baton without a server?

Yes. On the iPhone, **Try the demo** on the first-run screen opens a small library built into
the app: four real tracks, played through the real engine, with nothing going over the network.
**Use Navidrome's public demo server** on the same screen connects to a real library instead.

On the Mac, **Try the demo server** fills in Navidrome's public demo server. The Navidrome
project runs it, so it can be slow or offline. Connect your own music server whenever you like:
on the iPhone that's **Settings → Connect to Navidrome…**, on the Mac **Settings → Music
Servers**. See [The demo library](HELP.md#the-demo-library).

## Your settings on more than one device

Your likes, ratings, playlists and play counts live on your music server, so both apps already
see the same ones. These answers cover your settings, and how they get from one device to the
other.

### How do I get my Mac's settings onto my iPhone?

On the iPhone, open **Settings → Music server → Set up from a Mac…** and choose **Scan a code from your Mac**.
On the Mac, open **Settings → Remote → Link a device → Show pairing code**. Scanning is the
quickest way (nothing to type, not even a passphrase), but both devices need to be on the same
network.

If they aren't, export a settings file on the Mac with **Settings → About → Back up & restore →
Export…**, then pick it on the phone with **Choose an exported file**. Either way your music
server's address, sign-in, equalizer and the rest come across. See [Getting your Mac's setup
onto your phone](HELP.md#getting-your-macs-setup-onto-your-phone).

### Do my podcasts and radio stations follow me between devices?

Yes, by two different routes. **Radio stations** live on your music server alongside your
music, so they're the same on every device with nothing to set up. **Podcast subscriptions**
can't work that way (Navidrome has no podcast API, so Baton follows RSS feeds itself), so they
travel with your other settings through your Baton server instead (see
[shared settings](#what-are-shared-settings-and-do-i-need-a-baton-server) below).

Removals travel too: unsubscribe from a show on the Mac and it goes on the phone as well. Baton
records *when* you subscribed or unsubscribed to each show, so a device that has been switched
off for a week can't undo something you deleted yesterday. How far you are into an episode is
still kept on each device. See [What travels, and what stays
put](HELP.md#what-travels-and-what-stays-put).

### What are shared settings, and do I need a Baton server?

You don't need one. Baton works without it on both devices. Shared settings is the optional
upgrade that keeps your preferences in step *after* the one-time transfer, so changing the
equalizer on the Mac changes it on the phone too.

It needs a **Baton server**: a small Baton program you run yourself, included in this
repository under `gateway/`, where it is called the Baton gateway. It runs on macOS and Linux,
and the natural place for it is whatever machine already runs your music server. Point both
devices at its address with a token you invent, and they keep each other current: at launch,
when you switch back to the app, and on a slow heartbeat. Setup is in [Shared settings between
your devices](HELP.md#shared-settings-between-your-devices), and the Baton server's own options
are in [`gateway/README.md`](gateway/README.md).

### What actually travels?

The equalizer, crossfade, gapless, autoplay, repeat, loudness, radio bans, Wi-Fi and cellular
quality, missing-lyrics lookup, the speed for podcasts and books, podcast subscriptions, your
search history, which outside sources Baton may search, your Baton server's address, and the
music friend's settings and what it has learned.

What stays on the device is anything that describes *that device* rather than you: the download
folder, offline mode, demo mode, how far into an episode you are, and the switch that lets
Baton look outside your library. See [What travels, and what stays
put](HELP.md#what-travels-and-what-stays-put).

### Does my API key travel?

Not through shared settings: keys live in the Keychain and never enter the shared file. Pairing
is what moves them. The pairing code carries your music server passwords, your ListenBrainz and
Last.fm sign-ins, your discovery keys, the Baton server token and the music friend's API key,
all encrypted.

Some secrets never travel, even by pairing: Telegram and Discord bot tokens, webhook header
values, the expressive voice server's key, the token agents use to reach Baton (each Mac makes
its own), and the identity behind the links you share. The switch that lets Baton look outside
your library stays on each device too: that one is consent, and a phone shouldn't inherit it.
See [Backing up and restoring your
settings](HELP.md#backing-up-and-restoring-your-settings).

### What happens if I change the same thing on both devices?

The newer change wins, one setting at a time rather than one device at a time, so two devices
changing different things never overwrite each other. Lists work differently: search history
and podcast subscriptions are merged rather than replaced, so nothing disappears because the
other device synced more recently. See [When two devices
disagree](HELP.md#when-two-devices-disagree).

### Where are my settings actually stored?

In a plain JSON file on the machine running your Baton server, which you can open and read.
It's written to disk rather than held in memory, so restarting the Baton server doesn't lose
anything. See [Running your Baton server](HELP.md#running-your-baton-server).

## Your data

What Baton keeps about your listening, and how to save your settings in a file.

### Where does Baton keep my listening history?

On each device. On the Mac, **History** is a local play log, separate from the play counts
Baton reports to your server, and it works as a free, local alternative to Last.fm or
ListenBrainz. You can export it as ListenBrainz JSON or CSV, import listens, or clear it.

On the iPhone, **History** shows your server's record by default, so it includes what you
played on the Mac. Switch to **This iPhone** for the phone's own log. Clearing a device's log
never touches your server's play counts. See [Whose plays you're looking
at](HELP.md#whose-plays-youre-looking-at).

### What does "Mark for Removal" do?

Subsonic servers have no delete-file command, so Baton can't remove tracks from your server
directly. Marking a track for removal unlikes it and rates it one star, which a separate
server-side cleanup routine can read to prune it later. If you don't run such a routine, it
just unlikes and low-rates the track. See [Albums and artists](HELP.md#albums-and-artists).

### How do I back up and restore my settings?

On the Mac, open **Settings → About → Back up & restore** and click **Export…**. With **Include
accounts & passwords** off (the default), the file holds your preferences as plain text. With
it on, the file also holds your server passwords, scrobbling sign-ins, keys and what the music
friend remembers, all encrypted with a passphrase you choose. Your queue and play history are
not in it.

**Import…** in the same place restores a file; quit and reopen Baton afterwards. The iPhone can
only import, with **Settings → Music server → Set up from a Mac… → Choose an exported file**.
Bot tokens, webhook header values and the expressive voice server's key are never exported, so
enter those again after a restore. The agent control token is made fresh on each Mac, and your
share identity stays behind too, so links shared from the old Mac can't be managed from the new
one. See [Backing up and restoring your
settings](HELP.md#backing-up-and-restoring-your-settings).

## Privacy and security

What stays private, and the few things that do leave your device.

### Is my password safe?

Yes. Your sign-ins are stored in the Keychain on your Mac or iPhone, never in a plain text file.
With username-and-password sign-in, Baton uses the salted-token scheme Subsonic expects, so your
password isn't sent in the clear on each request. See [Privacy and
security](HELP.md#privacy-and-security).

### Does Baton phone home?

Baton has no catalog server of its own, and it never sends your library to its developer. With
nothing turned on, it talks to your music server and, on the Mac, to Baton's update feed, which
it checks for new versions by default (you can turn that off in **Settings → About →
Updates**). Everything else happens only when you share something or set it up:

- Baton's share service, when you share a song, mixtape or book. The audio is encrypted on
  your device first. Its records count opens and plays with a daily visitor code instead of
  anyone's address (the web server's troubleshooting log is described in the
  [privacy policy](https://batonmusic.app/privacy.html#sharing-records)). It also stores any
  reaction your friend sends back.
- ListenBrainz and Last.fm, if you set up scrobbling.
- Telegram or Discord, if you connect a chat bot on the Mac.
- Crash reports, sent to Baton's developer through Crashbox, if you turn on **Send crash &
  error reports** on the Mac or **Send crash reports** on the iPhone. Both are off by default.
  A report never includes your music, library, server address or account, and Baton doesn't
  confirm that it arrived.
- LRCLIB, if you turn on missing-lyrics lookup. It receives the song's title, artist, album
  and length.
- MusicBrainz, ListenBrainz, Last.fm and YouTube, if you turn on **Look outside my library**
  to find music you don't have.
- The model provider you choose for plain-English commands and the music friend, and a
  cloud model for book text, but only once you allow it.
- Open Library, when you use **Find Cover…** on a book. Only the title and author are sent.

Then there are the servers you set up yourself: speech and transcription servers, your Baton
server, podcast feeds, radio stations and webhook actions. Your Baton server keeps the text of
documents you turn into books, and the books' audio, on that machine until you remove them, and
none of it reaches Baton's developer. See [Privacy and security](HELP.md#privacy-and-security).

### Is the control server a security risk?

No, by design. Baton's control server listens only on your own Mac (loopback, the address
nothing outside the Mac can reach), and every request must carry a secret token that Baton
generates. Both are required: an app on another machine can't reach it, and a program on your
own Mac can't drive it without the token. See [How it's secured](HELP.md#how-its-secured).

### Where does the audio go when I transcribe something?

To the server you configured, and nowhere else. There is no hosted transcription service behind
this and no default address to fall back on, so with nothing set up the feature isn't
available. Summaries are stricter still: Baton refuses to send a transcript to a summarizing
model that isn't on your own network, because a transcript is the full content of what you were
listening to. See [Transcripts and summaries](HELP.md#transcripts-and-summaries).

## Sharing with friends

Send a song, a mixtape or a book to someone who isn't on your server. These answers cover what
your friend sees and what Baton's share service keeps.

### Can I send a song to a friend who isn't on my server?

Yes. Choose **Share…** in a song's menu (or **Playback → Share Current Track…** on the Mac),
then **Create Link**. Your friend plays it in any browser, with no app and no account. The song
is encrypted on your device and the key is in the link, so Baton's share service can't play it.

A link lasts 1, 7 or 30 days. **Shared Links** shows how often each link was opened and played,
and lets you extend or revoke it: on the Mac it's in **Settings → About → Shared Links**, on the
iPhone in **Settings → Shared Links**. See [Sharing a song](HELP.md#sharing-a-song).

If you ask an agent to share for you, its answer carries the whole link, key included. The key
then passes through that agent's model provider, and through Telegram or Discord if you asked
there, and anyone holding that copy can play the song until you revoke the link.

### Does a shared link open in Baton?

If your friend has Baton on their iPhone or Mac, a song or mixtape link opens in Baton, where
they can play it or find their own copy. Everyone else gets the browser player. Links to a
whole book, an album or a playlist always open in the browser. See [When a friend sends you a
song](HELP.md#when-a-friend-sends-you-a-song).

### Can I share several songs, an album, a playlist or a whole book?

Yes. Select two or more songs and share them (on the Mac with the share button in the selection
bar of **Liked**, **Search** or **Downloads**, on the iPhone with **Select** and **Share…** in
**Liked**), or choose **Share…** on an album or a playlist. Up to 12 songs within 20 minutes go as
a mixtape. More than that goes as one album or playlist link of up to 200 songs and 256 MiB, with
the cover, the song list, and shuffle and repeat for a playlist. You choose how many people can
listen, up to 50.

For a book, choose **Share…** in its menu and set **Send** to **The whole book** (or **Some
chapters**). You can have up to three album, playlist and whole-book links live at once. See
[Sharing a mixtape](HELP.md#sharing-a-mixtape), [Sharing an album or a
playlist](HELP.md#sharing-an-album-or-a-playlist) and [Sharing a whole
book](HELP.md#sharing-a-whole-book).

### Where are my friend's reactions kept?

On Baton's share service, until the link ends. A reaction is an emoji, plus a name and a reply
if your friend types them. Unlike the song, reactions aren't encrypted, so they're readable on
the service. Your app fetches them when you open **Shared Links**. See
[Reactions](HELP.md#reactions).

### How long does the share service keep things?

The shared song, mixtape or book and its reactions are deleted when the link expires or you
revoke it, and to your friend a revoked link looks the same as an expired one. Counts of opens
and plays are kept for up to 400 days.

The service is backed up every night to an encrypted offsite backup. A backup can keep a copy
for up to about 30 nights after a link ends, and longer until pruning of old backups ships. See
[How private sharing is](HELP.md#how-private-sharing-is).

## Alarms and timers

Baton can wake you with a song, or start one when a timer runs out, much like the Clock app does
with a sound.

### Can I wake up to a song?

Yes. Set an alarm with the clock beside the sleep timer's moon in the player, or with **Set
Alarm…** in the menu of a song, album, playlist or book. **Then play** sets what starts: a song,
an album, a playlist, a book from where you left off, or a radio station.

On the iPhone with Baton closed, the alarm rings with the first 29 seconds of your song. Tap
**Play**, or open Baton while it rings, and the whole track plays from the start. On the Mac,
Baton plays it itself at the time, or shows a notification you click if Baton isn't running.
See [Setting an alarm or a timer](HELP.md#setting-an-alarm-or-a-timer).

### Can I have an alarm and a timer at once?

Yes. They're independent. You can run one timer at a time, as in Clock, and keep as many alarms
as you like. While a timer runs and an alarm is due within a day, two pills show (above the
player on the iPhone, beside the clock on the Mac), and each one's ✕ cancels only that one. See
[An alarm and a timer together](HELP.md#an-alarm-and-a-timer-together).

### What does Gentle Wake do?

It starts an alarm quiet and raises it to your volume over 30 seconds, never louder than you set
it. You turn it on for each alarm; it's off by default, and timers don't have it. On the iPhone
the alarm sound itself rises too, over its first 20 seconds. Changing Baton's volume yourself,
or muting, ends the rise at your setting. See [Gentle Wake](HELP.md#gentle-wake).

### Why does my alarm ring a chime instead of my song?

The chime is Baton's fallback. On the iPhone, Baton keeps the first 29 seconds of your song as
the alarm sound when you save the alarm or start the timer, and rings the chime if it couldn't
get the song in time (offline, say, or a stream that didn't arrive within 45 seconds). A radio
station always rings the chime, because there's no song to take a clip from.

On the Mac, the notification you get with Baton closed always uses the chime. And on either
device, with Baton running, the chime plays if the music hasn't started 10 seconds after the
alarm time. To get your song back, save the alarm again while your server is reachable (Baton
waits ten minutes before retrying a song it couldn't get). See [When Baton is closed on the
iPhone](HELP.md#when-baton-is-closed-on-the-iphone).

## Agent control

On the Mac, Baton runs a small control server so AI agents and chat apps can play your music for
you. You don't need any of it to use Baton.

### What is the control server?

Baton hosts a small server on your Mac that speaks [MCP](https://modelcontextprotocol.io/), the
Model Context Protocol, the standard way AI agents talk to tools. It offers the same music
operations Baton's own interface uses (search, play, queue, pause and skip, like and rate,
create playlists, report what's playing), so an agent like Claude, or Tonebox, can control your
music from a natural request. See [Letting an agent control your
music](HELP.md#letting-an-agent-control-your-music).

### How do agents control my music?

You point an MCP client (like Claude Desktop, Claude Code, or Cursor) at Baton's local address
and token, then ask the agent for what you want: *"play a focus mix," "what's this song, and
like it," "make a playlist of this month's likes."* The agent calls Baton's tools to do it.
Because the tools mirror Baton's own actions, an agent can only do things you could do
yourself. See [What an agent can do](HELP.md#what-an-agent-can-do).

### Do I need an agent to use Baton?

No. Baton is a complete, click-to-play music player on its own. Agent control is an optional
extra. See [What Baton is, and what it isn't](HELP.md#what-baton-is-and-what-it-isnt).

### Can I control Baton from my phone?

Yes, in two ways. The iPhone app is Baton itself on your phone: it plays the same library from
the same server, with your likes and playlists already there. See [Baton on
iPhone](HELP.md#baton-on-iphone).

Or message your Mac. Connect a Telegram or Discord bot in **Settings → Remote**, and you can
send Baton `play kind of blue`, `vol 40`, or `next` from anywhere, and tap buttons on its
replies. It runs on the same control surface agents use, so a chat message can't do anything
Baton's own buttons can't. The steps are in [Controlling Baton from Telegram or
Discord](HELP.md#controlling-baton-from-telegram-or-discord).

### Why does it say "nothing matched" for music I know I have?

Because a plain search only matches text in titles, artists and albums, and a mood is rarely a
title. Ask for "lazy music" and nothing is called that, even though the chillout is sitting
there tagged `chill` or `ambient`. Turn on **Let it look around first** in **Settings → Remote**
and it will check what your library actually calls things, then find and play it. See
[Letting it look around first](HELP.md#letting-it-look-around-first).

### Does turning that on send my library somewhere?

Parts of it, yes: that's the trade, and it's why the switch is separate and off by default.
Looking around means what it finds (song titles, artists, genres) goes to the model along with
your question, because there's no other way for it to answer. With the switch off, your library
stays put. If you point Baton at a model running on your own machine or network, nothing leaves
it in either case. See [Letting it look around first](HELP.md#letting-it-look-around-first).

### Does it remember things between conversations?

Only what you tell it and how you correct it, and only when "let it look around" is on. Standing
preferences ("no vocals while I'm working", "those playlists are my partner's") are kept in a
plain file you can open, always alongside the words you actually used. It never stores a guess
about you; there is no field in the file for one. It says so in the chat every time it writes
something, `memories` lists everything it keeps, and `forget 2` or `forget everything` removes
it. A thumbs-down you give is kept too, under **What it has learned** in the Friend Log.

Everything else it appears to know (your genres, play counts, what you've liked) isn't memory at
all: it reads that from your own server each day. See [What it
remembers](HELP.md#what-it-remembers).

### Does chat control open my Mac to the internet?

No. Baton dials *out* to Telegram or Discord and waits for them to hand it messages, exactly as
a chat app on your Mac does. Nothing listens for incoming connections, no port is opened, and
nothing needs forwarding on your router. See [Controlling Baton from Telegram or
Discord](HELP.md#controlling-baton-from-telegram-or-discord).

### Can anyone who finds my bot control my music?

No. A bot token identifies the bot, not you, so Baton doesn't treat it as permission. Every chat
has to be linked with a six-digit code shown in **Settings → Remote**: until then Baton ignores
everything it's sent, and each code works only once. After five wrong codes Baton stops
accepting any until you press **New code**. You can revoke a linked chat at any time from the
same pane. See [Controlling Baton from Telegram or
Discord](HELP.md#controlling-baton-from-telegram-or-discord).

### Can I use my own local model instead of a paid API?

Yes. Set the provider to **OpenAI-compatible** and point the base URL at your own server: vLLM,
Ollama, LM Studio, llama.cpp and LiteLLM all speak that dialect. Nothing leaves your network and
there's no per-message cost. The model does need to support tool calling, since Baton asks it to
pick from a list of commands; the **Test** button tells you in one click whether yours does. See
[Saying it in your own words](HELP.md#saying-it-in-your-own-words).

### What permissions does the Discord bot need?

Three: View Channels, Send Messages, and Read Message History (permissions value `68608` in the
invite link). It deliberately gets no Administrator and no Manage-anything: a music remote that
can only read and write messages stays a music remote even if the token leaks. You also need the
**Message Content intent** switched on for the bot (**Developer Portal → Bot**), or Discord
delivers your messages with the text removed. See [Controlling Baton from Telegram or
Discord](HELP.md#controlling-baton-from-telegram-or-discord).

### Can the bot share a channel with webhooks or other bots?

Yes. Baton ignores everything written by a bot account, so alert feeds and download
notifications in the same channel don't trigger it. Only messages from linked people do. See
[Controlling Baton from Telegram or
Discord](HELP.md#controlling-baton-from-telegram-or-discord).

### Why does my bot ignore messages in a Telegram group?

Telegram's *privacy mode*, on by default for group bots, hides ordinary messages from them: `np`
goes unseen, `/np` gets through. Either use `/`-prefixed commands in groups, or message
@BotFather `/setprivacy` and turn it off for your bot. Direct chats are unaffected. See
[Controlling Baton from Telegram or
Discord](HELP.md#controlling-baton-from-telegram-or-discord).

### Does the plain-English option send my library anywhere?

Not your library, unless you also turn on **Let it look around first**. The option is off until
you turn it on and add your own API key. Then what leaves your Mac is the sentence you typed, the
list of Baton's own commands, the track that's playing (its title, artist, album and place in
the queue) and the recent messages in that chat. Your server address and credentials never
leave it. See [Saying it in your own words](HELP.md#saying-it-in-your-own-words).

### Is agent control available today?

Yes. The control server runs while Baton is open on the Mac. It offers 41 music operations
(including a `music_build_mix` tool that assembles a mix to a length you ask for), two
behind-the-scenes audio-focus operations for ducking, `speak_summary` and `read_aloud` for
speaking, tools for documents and books while **Documents** is on, and tools for Baton's other
screens, such as podcasts, radio, downloads and shared links.

It publishes five live views (what's playing, your queue, playlists, liked music, and recent
history), and it writes a discovery file at `~/Library/Application Support/Baton/mcp.json` with
the endpoint address and token so a client can find it. The full tool catalog, resources and
examples are in [What an agent can do](HELP.md#what-an-agent-can-do).

### How do I connect Claude (or another client) to Baton?

Point an MCP client at the `url` from `mcp.json` (something like `http://127.0.0.1:8787/mcp`)
over the Streamable HTTP transport, and pass the `token` from that same file as a bearer token.
In Claude Code that's one command:

```sh
claude mcp add --transport http baton \
  http://127.0.0.1:8787/mcp \
  --header "Authorization: Bearer <token-from-mcp.json>"
```

For Cursor, put the same `mcpServers` block in `~/.cursor/mcp.json` (or `.cursor/mcp.json` for
one project) with the `url` and a `headers` `Authorization: Bearer <token>`, then enable
**baton** under **Cursor → Settings → MCP**.

Baton has to be running for the server to be live. See [Connecting an agent to
Baton](HELP.md#connecting-an-agent-to-baton) for Claude Desktop and Cursor examples, opt-in
"speak only when asked" rules, and the full details.

## The music friend

You'll find the music friend on the Mac, on the iPhone and in chat. It needs a model provider
that you set up.

### What is the music friend?

Someone to ask for music in plain language. "Something calmer", "what is this?", "play the live
version instead": it works out what you meant and does it with your library and your player,
rather than handing you search results to sort through yourself. Open it on the Mac from **Go →
Music Friend** or with **⇧⌘F**; on the iPhone it's the **Friend** tab. The full walkthrough is
[The music friend](HELP.md#the-music-friend), and there's a guided tour of the same name in
Help.

### Do I need an API key, and what does it cost?

You need one, and Baton doesn't include it. Baton ships no key and contacts no model provider
until you set one up: Anthropic, OpenAI, or a model running on your own machine. What it costs
is whatever that provider charges you; Baton adds nothing and takes nothing. Point it at a local
model and it costs nothing at all. See [The music friend](HELP.md#the-music-friend).

### How do I turn it on, on the Mac?

It lives in **Settings → Remote**, in the **Natural language** section, below the Telegram,
Discord and **Baton server** sections. That pane looks like it's only about the chat bridges,
which is why it's easy to miss. Turn on **Understand plain English**, pick a **Provider**, paste
the **API key** and press **Save** beside the field, then press **Test**. Turn on **Let it look
around first** as well, or one message becomes one command decided blind.

You don't need **Enable remote control** at the top of the pane: that's Telegram and Discord
only. On the iPhone it has a pane to itself, **Settings → Music Friend**, and the **Friend** tab
shows up once a connection test has passed. Full steps: [Turning it on, on the
Mac](HELP.md#turning-it-on-on-the-mac).

### There's no Friend tab on my iPhone.

It appears once a connection test has passed, not merely once you have filled the fields in.
Open **Settings → Music Friend**, check that **Answers come from** matches how you actually want
to answer, and press **Test connection**. A pass makes the tab appear. Baton waits for one real
request to succeed because a key with a typo in it is still a key, and a tab that opens on
"configure me first" is a promise it cannot keep. See [Turning it on, on the
iPhone](HELP.md#turning-it-on-on-the-iphone).

### Can Baton server point at my own LLM?

No, and this is the most common way to get stuck. **Baton server** means your own Baton server
(the small `baton-gateway` program you run at home), and Baton asks it for `/v1/agent`, which
only a Baton server answers. Ollama, vLLM, LiteLLM and the rest speak a model API, not that one,
so they will always fail this test however well they are running. To use a model on your own
machine, choose **Model provider** and point its base URL there, or run your Baton server and
give it `BATON_LLM_BASE_URL`. See [The two servers Baton
uses](HELP.md#the-two-servers-baton-uses).

### Which address needs a /v1 on the end?

The **model provider** does, because `/chat/completions` hangs off it. The **Baton server** does
not: give it the bare host and port, such as `http://192.0.2.10:8788`. They sit next to each
other and want opposite shapes, which is easy to miss, so Baton drops a trailing `/v1` from the
Baton server address if you paste one. See [Turning it on, on the
iPhone](HELP.md#turning-it-on-on-the-iphone).

### What does the fallback actually do?

If your Baton server cannot be reached, or turns out not to be a Baton server at all, the friend
quietly uses the model provider below instead, so a machine that is asleep does not take it
down. It does **not** make the Friend tab appear: that gate tests the route you chose. If you
have no Baton server, test as **Model provider**. See [Turning it on, on the
iPhone](HELP.md#turning-it-on-on-the-iphone).

### I set a key and it still says it can't answer.

The **Understand plain English** switch is almost certainly still off. A key with the switch off
does nothing, on either device. Plain commands are free either way: "Pause", "next", "louder"
and their like are understood directly, without asking a model anything. See [Turning it on, on
the Mac](HELP.md#turning-it-on-on-the-mac).

### Where does my data go?

To the provider you configured, and nowhere else. Every request carries your question and the
track that's playing (its title, artist, album and place in the queue). With **Let it look
around first** on, it also carries what it finds in your library while answering (song titles,
artists, genres), a short summary of your taste, what it remembers about you, and its recent
picks.

If the model runs on your own machine or network, nothing leaves it in either case. [Agent
control](#agent-control) above goes into what "look around" sends and why. See [Letting it look
around first](HELP.md#letting-it-look-around-first).

### Why is the window empty, or why does it say it can't answer?

Almost always because no model provider is set. The window says so directly when that's the
case, with a line pointing at **Settings → Remote**. It's also what "I can't answer that right
now" means when nothing else looks wrong.

If a provider *is* configured and answers still fail, the status line in **Settings → Remote**
gives the provider's own reason: usually a mistyped key, or a model name the provider doesn't
recognise. See [Turning it on, on the Mac](HELP.md#turning-it-on-on-the-mac).

### Is the friend on my Mac the same one on my phone and in Telegram?

Yes, and that's the most useful thing about it. The Mac window, the phone's Friend tab, and the
Telegram and Discord bridges are all one friend sharing one conversation, so a preference it
learns in one place holds in the others, and a thumbs-down you give here counts the same as one
you give in Telegram. See [The music friend](HELP.md#the-music-friend).

### Can I talk to it instead of typing?

Yes. On the Mac, click the microphone in the composer and talk; click it again to stop and send.
macOS asks for microphone and speech-recognition permission the first time, and if you decline,
the window says so rather than failing silently. See [The music
friend](HELP.md#the-music-friend).

### How do I correct it when it gets something wrong?

Every answer has a quiet thumbs-up and thumbs-down under it. A thumbs-down asks what went wrong
(wrong track, misunderstood, too slow, too chatty), and that correction goes into what it reads
before answering next time. The Friend Log holds the whole history: **Settings → Friend Log** on
the Mac, or the **Friend log** button at the top of the Friend tab on the iPhone. See [What it
remembers](HELP.md#what-it-remembers).

## Playback

How Baton plays your music, and the controls around it on the Mac and the iPhone.

### Does Baton do gapless?

Yes, true gapless playback. It pre-loads the next track (and prefetches streamed tracks to a
small cache) so there's no silence between songs. There's also optional crossfade, loudness
normalization and an equalizer. See [Sound quality](HELP.md#sound-quality-gapless-crossfade-loudness)
and [The equalizer](HELP.md#the-equalizer).

### Do I have to set all that up?

No. After you've played about twenty tracks, Baton picks sensible playback defaults based on how
you listen (gapless for album listeners, a gentle crossfade and autoplay for shuffle listeners),
and explains what it did. You can change any of it. See [Defaults that match how you
listen](HELP.md#defaults-that-match-how-you-listen).

### Can I scrobble?

Yes, to your Navidrome or Subsonic server, and to [ListenBrainz](https://listenbrainz.org/)
and/or [Last.fm](https://www.last.fm/) if you add your accounts. A track scrobbles once you've
played half of it, up to a four-minute cap. See [Scrobbling](HELP.md#scrobbling).

### Does Baton work offline?

Yes, for downloaded music. You can download tracks, albums, mixes, playlists and podcast
episodes and play them without re-streaming. On the Mac, **Downloads** manages them, with
play-all and shuffle, batch actions, total size on disk and **Offline mode**. On the iPhone it's
**Library → Downloads**, with its own **Offline mode** and **Retry all** for failed downloads.
Browsing new content, and streaming anything you haven't downloaded, still needs your server.
See [Downloads](HELP.md#downloads-and-offline-listening).

### Why do the player's colors change with the music?

That's Baton adapting to your artwork. The full-screen backdrop and the player's accent colors
are drawn from the current track's cover art, and fall back to Baton orange when there's no
usable color. It's purely cosmetic. See [Adaptive artwork
colors](HELP.md#adaptive-artwork-colors).

### Does Baton have widgets, or work on the lock screen?

On the iPhone, yes. The **Now Playing** widget comes in the three home-screen sizes and the
three lock-screen shapes, and the medium and large ones have Play/Pause and Next buttons.
Tapping a widget opens the full player. While music plays, a Live Activity shows what's on with
a progress bar that runs by itself, and you can see it without unlocking the phone.

**Tip:** the link `baton://player` opens the full player directly, in both apps.

On the Mac, the current track appears in the macOS Now Playing widget in Control Center like
any other player. See [Widgets, the lock screen, and Live
Activities](HELP.md#widgets-the-lock-screen-and-live-activities).

### Can I use Siri or the Shortcuts app?

On the iPhone. "Play something in Baton", "Play music in Baton" and "Resume Baton" work out
loud, and the Shortcuts app has Play songs matching, Play music, Pause music, Play or pause,
Next track, Previous track and Like the current track to build automations from. Siri can't
take the album name in the same sentence yet: it asks instead. See [Siri and
Shortcuts](HELP.md#siri-and-shortcuts).

### Can I limit what Baton uses on cellular data?

Yes, and separately from Wi-Fi. In **Settings → Sound** on the iPhone, **Wi-Fi Quality** and
**Cellular Quality** each take Original, High (320 kbps), Medium (192 kbps) or Low (128 kbps).
Wi-Fi starts on Original and cellular on High. "Cellular" covers any metered connection: mobile
data, a personal hotspot, or Low Data Mode. Downloads ignore both settings, because they're
already on the phone. See [How much data it uses](HELP.md#how-much-data-it-uses).

### Why does my iPhone ask for Face ID in Settings?

To show your music server's address and user name (**Show Server Details**), and in front of
the music friend's API key and Baton server token. A key against a paid provider is money, and
an unlocked phone in someone else's hand is already past the front door. You can use your
passcode instead, and a phone with no passcode set is let straight through. It is not an
app-wide lock: you'll never be asked just to skip a track. See [Face ID on your
keys](HELP.md#face-id-on-your-keys).

### Can I cast to speakers?

AirPlay works today. On the Mac the AirPlay picker is in the now-playing bar and the full-screen
player; on the iPhone it's in the full player's controls. Chromecast, Sonos and UPnP/DLNA
casting are planned. See [Media keys and AirPlay](HELP.md#media-keys-and-airplay).

### Is there a menu-bar controller?

Yes, on the Mac. Baton puts an item in the menu bar with the current track, Play/Pause, Next and
Previous, Mute, Like, Volume, the sleep timer, **Set Alarm…** and **Start Timer…**, plus ways to
open the main window or the mini-player. It keeps Baton (and the control server) running in the
background even when every window is closed. See [The menu-bar
controller](HELP.md#the-menu-bar-controller).

### Can Baton tell me what a podcast episode said?

Yes, if you run a transcription server. Baton sends the episode's audio to a Whisper server on
your own network and gets back a transcript with a timestamp on every line, so you can read
along and tap any line to jump there. It can also write a summary with timestamped chapter
marks.

Both are off until you set a host: **Settings → Speech → Transcription** on the Mac, **Settings
→ Transcription** on the iPhone. Neither ever happens on its own. Transcribing an episode is a
minute or two of work on a GPU, so Baton waits for you to ask. See [Transcripts and
summaries](HELP.md#transcripts-and-summaries).

## Speaking and reading aloud

On the Mac, Baton can speak an agent's summary out loud and read text from your screen. These
answers cover voices, privacy and permissions.

### Can Baton speak things out loud?

Yes. Through the `speak_summary` tool, an agent can have Baton say a short result aloud in a
natural voice, so you hear "deploy finished, all green" instead of watching a screen. With
several agents running, map a voice to each one (a category-to-voice map in **Settings →
Speech**) and you can follow a whole run by ear.

With the default settings Baton announces a summary and waits for you to press Play. To let an
agent speak straight away, turn on **Allow the agent to play it immediately** in **Settings →
Speech → Delivery**. Baton speaks through text-to-speech servers you run yourself (Kokoro for
fast preset voices, Chatterbox for cloning), and falls back to the built-in macOS voice if none
are set up. See [Speaking summaries aloud](HELP.md#speaking-summaries-aloud).

### With several agents running, how do I tell which one is speaking?

Each agent passes a short `session` name when it speaks, normally the repo it's working in, and
Baton shows that name at the top of the summary window, above the transcript. It's remembered
per connection, so the agent only sends it once, and it can change the name later if it moves
to a different area.

The name is shown rather than spoken, so you hear the summary itself and nothing else. Lines
from different agents never talk over each other, because Baton queues them and plays them in
order. The name is also kept in Spoken Summaries, so you can see who said what after the fact.
See [One voice per agent](HELP.md#one-voice-per-agent).

### Can each agent have its own voice?

Yes. In **Settings → Speech → Agent voices** you keep a list of label-and-voice pairs, as long as
you like. The label is normally the `session` name the agent sends, usually its repo, and it is
matched loosely so case and stray spaces do not matter. There is a play button on each row to
hear the voice, and **Add one Baton has heard** fills in the label from the agents that have
already spoken.

Anything not in the list speaks in a voice from outside it, the same one every time, so a
project you named never sounds like one you did not. See [One voice per
agent](HELP.md#one-voice-per-agent).

### The first word gets cut off on my Bluetooth speaker.

That's the speaker waking up. Bluetooth powers its radio down when nothing is playing and takes
a moment to come back, and that moment eats the start of the line. Baton holds a little silence
first to let it wake, and only over Bluetooth, so wired and built-in speakers are never delayed.

If you still lose the beginning, raise **Settings → Speech → Delivery → Bluetooth head start**
from its default of 0.7 seconds. Speakers differ by more than double, so some need a second or
more. See [Bluetooth speakers and the missing first
word](HELP.md#bluetooth-speakers-and-the-missing-first-word).

### Do I need to run text-to-speech servers for spoken summaries?

No. If you haven't set any up, Baton uses the built-in macOS voice, so `speak_summary` still
works. Self-hosted servers (Kokoro and Chatterbox) get you better and more varied voices, plus
voice cloning, and keep the audio on your own network. See [The voices
themselves](HELP.md#the-voices-themselves), and the setup notes in
[`docs/tts-speak-summary.md`](docs/tts-speak-summary.md).

### Can Baton read things on my screen out loud?

Yes. Select text in any app and choose **Services → Speak with Baton**, or set a **Keyboard
shortcut** in **Settings → Speech → Read aloud**. Baton speaks it in the same voices it uses for
summaries, and ducks your music underneath. It is good for an article you would rather hear than
read, or for the tail of a long build. See [Reading what's on your
screen](HELP.md#reading-whats-on-your-screen).

### Does Baton watch my screen?

No, and it cannot. Baton has no idea what is on your screen until you select something and ask
for it. There is no background monitoring and no polling: every reading happens because you
started it. A reading plays and is then gone, unless you ask Baton to keep it. There are three
ways to do that.

**File → Save Reading as Audio…** writes a single file wherever you point it. **File → Keep
Reading in Clippings** keeps the audio and the words in **Clippings** until you delete them, and
if you run a Baton server it carries them to your iPhone too. And if you stop half way through,
**File → Resume Reading** can carry on: Baton holds up to five unfinished readings for seven
days, and **Forget Them Now** under **Settings → Speech → Read aloud** clears them. See [Keeping
a reading](HELP.md#keeping-a-reading).

### Is Read aloud a screen reader?

Not in the accessibility sense, and it is not trying to be. VoiceOver reads interfaces, moving
through buttons and menus, and it does that far better. Read aloud speaks a piece of content you
have chosen. See [Reading what's on your screen](HELP.md#reading-whats-on-your-screen).

### Why does Read aloud need Accessibility permission, and can I avoid it?

You can avoid it entirely. **Services → Speak with Baton** needs no permission at all, because
the system hands the text over. The permission is only for the *keyboard shortcut*, which has to
ask the app you are in for what you have selected. Baton asks the first time you press the
shortcut and explains why. See [Ways to start a reading](HELP.md#ways-to-start-a-reading).

### Why does my clipboard flicker when I use the shortcut in Chrome?

Because Chrome will not hand over the selected text the ordinary way, so Baton copies it, reads
it, and puts your clipboard back (images and files included). It happens in a fraction of a
second, though a clipboard manager may still notice. Terminals like Ghostty share their
selection directly and need none of this. You can switch this off with **Use the clipboard when
an app will not share its selection** in **Settings → Speech → Read aloud**, at the cost of the
shortcut doing nothing in a browser. See [Why some apps need the
clipboard](HELP.md#why-some-apps-need-the-clipboard).

### Will Baton read my API keys out loud?

It tries hard not to. Before anything is spoken, Baton strips things shaped like credentials
(API keys, tokens, bearer headers, private key blocks) and says "a redacted token" instead.
Terminal output is exactly where such things sit, which is why the check runs on every reading
rather than only on some. Treat it as a good safety net rather than a guarantee. See [What
Baton does to the text before speaking
it](HELP.md#what-baton-does-to-the-text-before-speaking-it).

## Documents and audiobooks

Baton can turn a document into an audiobook, read in a voice you choose. Books are made on your
Mac or on your Baton server, and reach your other device.

### Which documents can Baton read?

PDFs, EPUB books, web pages (saved as HTML, or imported from their link), Markdown files and
plain text files. A scanned PDF, made of pictures of pages, is read with text recognition, which
can misread a word, so Baton names those pages before you start, and any page it could not read
at all. See [Listening to a document](HELP.md#listening-to-a-document).

### Can I start from a file in Finder?

Yes. Control-click it and choose **Open With → Baton**, or **Services → Make an Audiobook with
Baton**, and it opens in the Mac's import sheet. Baton never becomes the default app for these
files. See [Listening to a document](HELP.md#listening-to-a-document).

### How do I get a document onto my iPhone?

Share it to Baton from another app's share sheet (a web page in Safari works too), open it in
Baton from Files, or use the **+** menu on the Books screen: **Import a File…** or **Import a
Link…**. The phone makes the book on your Baton server, so set that up first under **Settings →
Music Friend**.

If the Baton server cannot make books, the import screen offers **Send to my Mac**, which passes
the document through your Baton server to Baton on your Mac. The Baton server keeps it for up
to two weeks, so open Baton on the Mac with Documents on before then; if it was gone first, the
Mac says it didn't arrive and you send it again. Without a Baton server it suggests
AirDropping the file to your Mac. A book made on the Mac arrives on the phone too: one made on
the Baton server is there already, and one made on the Mac itself is sent to your Baton server
as each chapter is done. See [Listening to a document](HELP.md#listening-to-a-document).

### Why did my book stop part way?

The voice host stopped answering. The book's row in Books says so, and the book carries on by
itself when the host is reachable again. Check that the host is running and that its address is
right: in **Settings → Speech** on the Mac, or the Baton server under **Settings → Music
Friend** on the iPhone. See [Listening to a document](HELP.md#listening-to-a-document).

### Does my document leave my device?

Only to your own machines, unless you say otherwise. The text goes, a sentence or two at a time,
to the voice host you set in **Settings → Speech**, or to your Baton server when the book is made
there; with the built-in voices on a Mac it never leaves the Mac. **Send to my Mac** passes the
file through your Baton server.

The Mac's narrator suggestion, recap and cast list use Apple Intelligence or a model you run
yourself first. A cloud model gets book text only if you allow it, and you can change that under
**Settings → Agents → Book text and cloud models**. Anything that looks like a password or key
is removed before any text is spoken or sent. See [Book text and cloud
models](HELP.md#book-text-and-cloud-models).

### Can I choose the narrator?

Yes, on both. On the Mac, when a model answers (Apple Intelligence, Ollama or LM Studio on this
Mac, or your Baton server's), the import sheet suggests three voices and lets you hear each in
the book's own words. On the iPhone, and on a Mac with no model answering, it offers three
voices for the book's language instead. Below them, **All voices** lists every voice the book
can be made with, with a search field and a play button on each. See [Listening to a
document](HELP.md#listening-to-a-document).

### Can I make books on my Mac without a voice server?

Yes, on a Mac with Apple silicon. Download the built-in voices once under **Settings → Speech →
Voice engine for books** (**Download (342 MB)**). They are Kokoro's 28 English voices, run by
Baton itself, and nothing leaves the Mac. See [Voices: on this Mac or on your Baton
server](HELP.md#voices-on-this-mac-or-on-your-baton-server).

### Should I use the built-in voices or a voice server?

On the Mac, **Settings → Speech → Voice engine for books** chooses. **Automatic**, the default,
uses the built-in voices whenever they are downloaded and have the book's voice, and your voice
server for the rest. On a Mac with Apple silicon we recommend downloading them: in a
side-by-side listening test they sounded the same as the server, they work offline, and the
book's text stays on the Mac. They speak English only.

**Voice server** reaches every voice your Kokoro or Chatterbox server has, including other
languages and Chatterbox's, and needs its address to answer. The iPhone has no choice to make:
its books are made on your Baton server with the voice server set in its own setup
(`BATON_TTS_KOKORO_URL`). See [Voices: on this Mac or on your Baton
server](HELP.md#voices-on-this-mac-or-on-your-baton-server).

### Can a book sound more like a person reading it?

Yes, with an expressive voice server such as Qwen3-TTS: any speech server that answers OpenAI's
speech requests. Enter its address under **Expressive voice server** in **Settings → Speech →
Voice engine for books** on the Mac, or set `BATON_TTS_OPENAI_URL` on your Baton server for the
iPhone. Its voices are listed as Expressive voices. They read a sentence at a time with a
reader's pauses, and each character in a cast is told how to sound from their gender and age.
See [Voices: on this Mac or on your Baton
server](HELP.md#voices-on-this-mac-or-on-your-baton-server).

### Can the characters have their own voices?

Yes, on the Mac and the iPhone. Turn on **Voice the dialogue** when you import a book. A model
proposes a cast, you check it and pick the voices, and Baton works out who says each line. Any
line nobody can place stays with the narrator. It is off for your first book, then starts the
way you last left it. For a book already made, **Change Voice…** gives it a cast, edits the one
it has, or turns it off. See [Voice the dialogue](HELP.md#voice-the-dialogue).

### How do I free the space a book takes?

Choose **Remove Download** in the open book, or in its menu in Books. The book keeps its row and
your place, and **Download Again** or **Render Again** brings the audio back whenever you like.
**Settings → Storage** on the Mac, or **Settings → Documents → Storage** on the iPhone, shows
what each book takes and lets you set cleanup rules. Nothing is removed until you choose a rule.
See [Book storage](HELP.md#book-storage).

### I deleted a book by mistake. Can I get it back?

For a week, yes. Open Storage in Settings, find the book under **Recently Removed**, and choose
**Restore**. On the iPhone, deleting a book asks which you mean: **Remove from this iPhone** only
takes it off that phone and leaves your Baton server's copy for your other devices, while
**Delete Everywhere** removes the server's copy too. See [Book storage](HELP.md#book-storage).

### Can a book have a cover?

Yes. An EPUB brings its own. For any other book, open its menu and choose **Find Cover…** to
pick one from Open Library (only the title and author are sent), **Make a Cover** to have Baton
draw one from the title and author, or **Choose Image…** to use a picture of your own. The cover
reaches your other device through your Baton server. See [Listening to a
document](HELP.md#listening-to-a-document).

### Why does the book have the wrong title or chapters?

Baton takes the title and author from the first page and finds chapters from their headings.
Some documents lay these out in ways it cannot recognise. The import sheet shows what it found
before you start, so you can cancel and check the file. See [Listening to a
document](HELP.md#listening-to-a-document).

### I never use this. Can I hide it?

Yes. Turn off **Documents** in **Settings → Speech** on the Mac, or in **Settings** on the
iPhone. The import items, the drop target and the book rows go away on that device at once; the
other device keeps its own setting. See [Listening to a
document](HELP.md#listening-to-a-document).

## Updates and platform

Installing Baton, keeping it up to date, and where to read more.

### How do I install Baton?

On the Mac, either grab the DMG from [batonmusic.app](https://batonmusic.app), or use Homebrew:

```sh
brew tap anatoliv/baton https://github.com/anatoliv/baton
brew trust anatoliv/baton
brew install --cask baton
```

`brew trust` is required on Homebrew 6 and later for any third-party tap; without it the install
refuses to load the cask. If Baton is already in `/Applications` from a DMG, add `--force` so
the cask can take it over. The iPhone app is on the App Store. See [Baton on
iPhone](HELP.md#baton-on-iphone).

### How do updates work?

On the Mac, Baton uses Sparkle (the standard macOS updater) and installs signed, notarized
builds from its own feed. It checks automatically unless you turn off **Automatically check for
updates** in **Settings → About → Updates**, and you can check yourself with **Check for
Updates…** in the app menu or the menu-bar menu, or **Check for Updates Now** in the same
Settings section. Download the current release from [batonmusic.app](https://batonmusic.app)
once, and it updates itself from there on. The iPhone app updates through the App Store.

If you installed with Homebrew, Sparkle still does the updating: the cask is marked
`auto_updates`, so `brew upgrade` deliberately leaves Baton alone rather than fighting the
in-app updater. `brew info --cask baton` will keep showing the version you installed until you
re-run the cask; that's expected, not a stale install. See [Updates](HELP.md#updates).

### Where can I read more?

[HELP.md](HELP.md) covers how to use every part of Baton. The docs in [`docs/`](docs/) go into
the vision, architecture, and integration details.
