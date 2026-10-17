# Baton FAQ

Short answers to the questions that come up most. For step-by-step walkthroughs, see
[HELP.md](HELP.md).

## About Baton

**What is Baton?**
A free macOS music player for your own self-hosted music library. It plays from any
[Navidrome](https://www.navidrome.org/) or Subsonic-compatible server, with real playback
depth (true gapless, crossfade, ReplayGain loudness matching, and a 10-band equalizer). It
also runs a small control server so an AI agent can search, queue, and steer your music for
you, and, through the same surface, so can a Telegram or Discord message from your phone.
The tagline is *"Conduct your music."*

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

**What are the music server and the Baton server?**
Two servers of your own, with different jobs. Your **music server** holds your library: it is
Navidrome or another Subsonic server, and you sign in to it. Your **Baton server** is an
optional small Baton program you run at home; it makes books from documents, keeps your place
and your shared settings in step between devices, and holds files for your other device. Both
can run on the same machine. Music needs only the music server. See [The two servers Baton
uses](HELP.md#the-two-servers-baton-uses).

**What music servers work with Baton?**
[Navidrome](https://www.navidrome.org/) and any Subsonic-compatible server. Baton speaks the
Subsonic API, so most self-hosted music servers in that family work.

**Does Baton have its own music catalog?**
No. Baton plays *your* library from *your* music server. It is deliberately not a streaming
catalog like Spotify or Tidal, so there's nothing to browse until you connect a music server.

**How do I connect?**
On first launch, enter your music server's URL and either a username and password or an API key.
Baton verifies the connection before it saves anything. See
[Getting connected](HELP.md#getting-connected).

**Can I connect more than one music server?**
Yes. Open Settings (press Command and comma), choose the Music Servers pane, and add them there.
Baton keeps each server's credentials separately in the Keychain, and you switch the active
one with a click. Your first single connection is carried into the list automatically. See
[Using more than one music server](HELP.md#using-more-than-one-music-server).

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
new versions, and any speech servers you set up yourself: text-to-speech for spoken summaries
and transcription for reading a podcast episode, and your Baton server if you run one. Those are
machines you run and point Baton at. Your Baton server keeps the text of documents you turn into
books, and the books' audio, on that machine until you remove them, and none of it reaches Baton's
developer. Baton has no catalog server of its own to call. There are two exceptions, and both are yours to choose. When you
share a song, it is encrypted on your device and uploaded to Baton's share service, which
counts what happens to that link (opens and plays, never who). And if you turn on **Send
crash & error reports** (Settings, About, Diagnostics, off by default), Baton sends crash and
error data to its developer through Crashbox to help fix bugs. It never sends your music, library,
server address, or account, and no IP or identifiers. Turning it on means Baton will try to send a report after a crash, but it does not confirm that the report arrived.

**Can I send a song to a friend who isn't on my server?**
Yes. Choose **Share…** in a song's menu and Baton makes a link they can play in any browser,
with no app and no account. The song is encrypted on your device and the key is in the link,
so Baton's share service can't play it. Links expire after 1, 7 or 30 days, and you can see
who listened, or revoke a link, in **Shared Links**. If your friend has Baton on their iPhone,
the link opens in Baton, where they can play it or find their own copy. To send several songs at
once, share 2 to 12 liked songs as a mixtape, which plays them in order from one link. See
[Sharing a song with a friend](HELP.md#sharing-a-song-with-a-friend).

**Is the control server a security risk?**
No, by design. Baton's control server listens only on your own Mac (loopback), so it isn't
reachable from your network, and every request must carry a secret token that Baton
generates. Both are required: an app on another machine can't reach it, and a program on your
own Mac can't drive it without the token. See
[how it's secured](HELP.md#letting-an-agent-control-your-music).

**Can Baton tell me what a podcast episode said?**
Yes, if you run a transcription server. Baton sends the episode's audio to a Whisper server on
your own network and gets back a transcript with a timestamp on every line, so you can read
along and tap any line to jump there. It can also write a summary with timestamped chapter
marks. Both are off until you set a host: **Settings → Speech → Transcription** on the Mac,
**Settings → Transcription** on iPhone. Neither ever happens on its own. Transcribing an episode is a minute or two of work on a GPU, so Baton
waits for you to ask. See [Transcripts and summaries](HELP.md#transcripts-and-summaries).

**Where does the audio go when I transcribe something?**
To the server you configured, and nowhere else. There is no hosted transcription service behind
this and no default address to fall back on, so with nothing set up the feature simply isn't
available. Summaries are stricter still: Baton refuses to send a transcript to a summarizing
model that isn't on your own network, because a transcript is the full content of what you were
listening to.

## Agent control

**What is the control server?**
Baton hosts a small server on your Mac that speaks [MCP](https://modelcontextprotocol.io/),
the Model Context Protocol, the standard way AI agents talk to tools. It exposes the same
music operations Baton's own interface uses (search, play, queue, pause and skip, like and
rate, create playlists, report what's playing), so an agent like Claude, or Tonebox, can
control your music from a natural request.

**How do agents control my music?**
You point an MCP client (like Claude Desktop, Claude Code, or Cursor) at Baton's local address and
token, then ask the agent for what you want: *"play a focus mix," "what's this song, and like
it," "make a playlist of this month's likes."* The agent calls Baton's tools to do it.
Because the tools mirror Baton's own actions, an agent can only do things you could do
yourself.

**Do I need an agent to use Baton?**
No. Baton is a complete, click-to-play music player on its own. Agent control is an extra
surface, not a requirement.

**Can I control Baton from my phone?**
Yes, by messaging it. Connect a Telegram or Discord bot in Settings, Remote, and you can send
Baton `play kind of blue`, `vol 40`, or `next` from anywhere, and tap buttons on its replies.
There's a step-by-step setup in
[Controlling Baton from Telegram or Discord](HELP.md#controlling-baton-from-telegram-or-discord).
It runs on the same control surface agents use, so a chat message can't do anything Baton's
own buttons can't.

**Why does it say "nothing matched" for music I know I have?**
Because a plain search only matches text in titles, artists and albums, and a mood is rarely a
title. Ask for "lazy music" and nothing is called that, even though the chillout is sitting
there tagged `chill` or `ambient`. Turn on **Let it look around first** (Settings, Remote) and
it will check what your library actually calls things, then find and play it. See
[Letting it look around first](HELP.md#letting-it-look-around-first).

**Does turning that on send my library somewhere?**
Parts of it, yes: that's the trade, and it's why the switch is separate and off by default.
Looking around means what it finds (song titles, artists, genres) goes to the model along with
your question, because there's no other way for it to answer. With the switch off, none of your
library ever leaves. If you point Baton at a model running on your own machine or network,
nothing leaves it in either case.

**Does it remember things between conversations?**
Only what you tell it, and only when "let it look around" is on. Standing preferences ("no
vocals while I'm working", "those playlists are my partner's") are kept in a plain file you
can open, always alongside the words you actually used. It never stores a guess about you;
there is no field in the file for one. It says so in the chat every time it writes something,
`memories` lists everything it keeps, and `forget 2` or `forget everything` removes it.
Everything else it appears to know (your genres, play counts, what you've liked) isn't
memory at all: it reads that from your own server each day.

**Does chat control open my Mac to the internet?**
No. Baton dials *out* to Telegram or Discord and waits for them to hand it messages, exactly
as a chat app on your Mac does. Nothing listens for incoming connections, no port is opened,
and nothing needs forwarding on your router.

**Can anyone who finds my bot control my music?**
No. A bot token identifies the bot, not you, so Baton doesn't treat it as permission. Every
chat has to be linked with a six-digit code shown in Settings: until then Baton ignores
everything it's sent, and each code works only once. You can revoke a linked chat at any time
from the same pane.

**Can I use my own local model instead of a paid API?**
Yes. Set the provider to **OpenAI-compatible** and point the base URL at your own server:
vLLM, Ollama, LM Studio, llama.cpp and LiteLLM all speak that dialect. Nothing leaves your
network and there's no per-message cost. The model does need to support tool calling, since
Baton asks it to pick from a list of commands; the **Test** button tells you in one click
whether yours does.

**What permissions does the Discord bot need?**
Three: View Channels, Send Messages, and Read Message History (permissions value `68608` in
the invite URL). It deliberately gets no Administrator and no Manage-anything: a music remote
that can only read and write messages stays a music remote even if the token leaks. You also
need the **Message Content intent** switched on for the bot (Developer Portal → Bot), or
Discord delivers your messages with the text removed.

**Can the bot share a channel with webhooks or other bots?**
Yes. Baton ignores everything written by a bot account, so alert feeds and download
notifications in the same channel don't trigger it. Only messages from linked people do.

**Why does my bot ignore messages in a Telegram group?**
Telegram's *privacy mode*, on by default for group bots, hides ordinary messages from them:
`np` goes unseen, `/np` gets through. Either use `/`-prefixed commands in groups, or message
@BotFather `/setprivacy` and turn it off for your bot. Direct chats are unaffected.

**Does the plain-English option send my library anywhere?**
No. It's off unless you turn it on and add your own API key, and when it is on, what leaves
your Mac is the sentence you typed plus the list of Baton's own commands. Not your library,
not your server address or credentials, not your listening history.

**Is agent control available today?**
Yes. The control server runs while Baton is open. It exposes 37 music operations (including a
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

For Cursor, put the same `mcpServers` block in `~/.cursor/mcp.json` (or `.cursor/mcp.json` for
one project) with the `url` and a `headers` `Authorization: Bearer <token>`, then enable
**baton** under Cursor → Settings → MCP.

Baton has to be running for the server to be live. See
[Connecting an agent to Baton](HELP.md#connecting-an-agent-to-baton) for Claude Desktop and
Cursor config examples, opt-in "speak only when asked" rules, and the full details.

## The music friend

**What is the music friend?**
Someone to ask for music in plain language. "Something calmer", "what is this?", "play the
live version instead": it works out what you meant and does it with your library and your
player, rather than handing you search results to sort through yourself. Open it on the Mac
from **Go, Music Friend** or with **⌘⇧F**; on iPhone it's the **Friend** tab. The full
walkthrough is [The music friend](HELP.md#the-music-friend), and there's a guided tour of the
same name in Help.

**Do I need an API key, and what does it cost?**
You need one, and Baton doesn't include it. Baton ships no key and contacts no model provider
until you set one up: Anthropic, OpenAI, or a model running on your own machine. What it
costs is whatever that provider charges you; Baton adds nothing and takes nothing. Point it at
a local model and it costs nothing at all.

**How do I turn it on, on the Mac?**
It lives in **Settings → Remote**, in the **Natural language** section below Telegram,
Discord, Linking and Devices. That pane looks like it's only about the chat bridges, which is
why it's easy to miss: turn on **Understand plain English**, pick a **Provider**, paste the
**API key** and press **Save** beside the field, then press **Test**. Turn on **Let it look
around first** as well, or one message becomes one command decided blind. You don't need
**Enable remote control** at the top of the pane: that's Telegram and Discord only. Full
steps: [Turning it on, on the Mac](HELP.md#turning-it-on-on-the-mac).

On iPhone it has a pane to itself, **Settings → Music Friend**, and the **Friend** tab shows
up once a connection test has passed.

**There's no Friend tab on my iPhone.**
It appears once a connection test has passed, not merely once you have filled the fields in.
Open **Settings → Music Friend**, check **Answers come from** matches how you actually want to
answer, and press **Test connection**. A pass makes the tab appear. Baton waits for one real
request to succeed because a key with a typo in it is still a key, and a tab that opens on
"configure me first" is a promise it cannot keep.

**Can Baton server point at my own LLM?**
No, and this is the most common way to get stuck. **Baton server** means your own Baton
server (the small `baton-gateway` program you run at home), and Baton asks it for `/v1/agent`,
which only a Baton server answers. Ollama, vLLM, LiteLLM and the rest speak a model API, not that one,
so they will always fail this test however well they are running. To use a model on your own
machine, choose **Model provider** and point its base URL there, or run your Baton server and
give it `BATON_LLM_BASE_URL`.

**Which address needs a /v1 on the end?**
The **model provider** does, because `/chat/completions` hangs off it. The **Baton server**
does not: give it the bare host and port, such as `http://192.0.2.10:8788`. They sit next to
each other and want opposite shapes, which is easy to miss, so Baton drops a trailing `/v1`
from the Baton server address if you paste one.

**What does the fallback actually do?**
If your Baton server cannot be reached, or turns out not to be a Baton server at all, the friend quietly
uses the model provider below instead, so a machine that is asleep does not take it down. It
does **not** make the Friend tab appear: that gate tests the route you chose. If you have no
Baton server, test as **Model provider**.

**I set a key and it still says it can't answer.**
The **Understand plain English** toggle is almost certainly still off. A key with the toggle
off does nothing, on either platform.

Plain commands are free either way. "Pause", "next", "louder" and their like are understood
directly, without asking a model anything.

**Where does my data go?**
To the provider you configured, and nowhere else. With **Let it look around first** off (the
default), only your question is sent. With it on, what it finds in your library while
answering (song titles, artists, genres) goes along with the question, because there is no
other way for it to answer. If the model runs on your own machine or network, nothing leaves
it in either case. [Agent control](#agent-control) above goes into what "look around" sends
and why.

**Why is the window empty, or why does it say it can't answer?**
Almost always because no model provider is set. The window says so directly when that's the
case, with a line pointing at **Settings, Remote**. It's also what "I can't answer that right
now" means when nothing else looks wrong.

If a provider *is* configured and answers still fail, the status line in **Settings, Remote**
gives the provider's own reason: usually a mistyped key, or a model name the provider doesn't
recognise.

**Is the friend on my Mac the same one on my phone and in Telegram?**
Yes, and that's the most useful thing about it. The Mac window, the phone's Friend tab, and
the Telegram and Discord bridges are all one friend sharing one conversation, so a preference
it learns in one place holds in the others, and a thumbs-down you give here counts the same as
one you give in Telegram.

**Can I talk to it instead of typing?**
Yes. Click the microphone in the composer and talk; click it again to stop and send. macOS
asks for microphone and speech-recognition permission the first time, and if you decline, the
window says so rather than failing silently.

**How do I correct it when it gets something wrong?**
Every answer has a quiet thumbs-up and thumbs-down under it. A thumbs-down asks what went
wrong (wrong track, misunderstood, too slow, too chatty), and that correction goes into what
it reads before answering next time. **Settings, Friend Log** on the Mac holds the whole
history.

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

**Does Baton have widgets, or work on the lock screen?**
On iPhone, yes. The **Now Playing** widget comes in the three home-screen sizes and the three
lock-screen and StandBy shapes, and while music is playing a Live Activity shows what's on
with a progress bar that runs by itself, requiring no unlocking. On the Mac, the current track appears
in the macOS Now Playing widget in Control Center like any other player. See
[Widgets, the lock screen, and Live Activities](HELP.md#widgets-the-lock-screen-and-live-activities).

**Can I use Siri or the Shortcuts app?**
On iPhone. "Play something in Baton" and "Resume Baton" work out loud, and the Shortcuts app
has Play, Pause, Play or pause, Next, Previous, Like the current track, and Play songs
matching to build automations from. Siri can't take the album name in the same sentence yet:
it asks instead. See [Siri and Shortcuts](HELP.md#siri-and-shortcuts).

**Can I limit what Baton uses on cellular data?**
Yes, and separately from Wi-Fi. **Settings → Sound** on iPhone has **Wi-Fi Quality** and
**Cellular Quality**, each set to Original, High (320 kbps), Medium (192 kbps) or Low
(128 kbps). Leave Wi-Fi on Original for your FLACs and put cellular on Medium, and the phone
sorts itself out. Downloads ignore both: they're already on the phone.

**Why does my iPhone ask for Face ID in Settings?**
Only in front of the music friend's API key and Baton server token, because a key against a paid
provider is money and an unlocked phone in someone else's hand is already past the front door.
It falls back to your passcode, and a phone with nothing enrolled is let straight through. It
is not an app-wide lock: you'll never be asked just to skip a track.

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

**With several agents running, how do I tell which one is speaking?**
Each agent passes a short `session` name when it speaks, normally the repo it's
working in, and Baton shows that name at the top of the summary window, above the
transcript. It's remembered per connection, so the agent only sends it once, and it
can change the name later if it moves to a different area. The name is shown rather
than spoken, so you hear the summary itself and nothing else. Lines from different
agents never talk over each other, because Baton queues them and plays them in order.
The name is also kept in Spoken Summaries, so you can see who said what after the fact.

**Can each agent have its own voice?**
Yes. In **Settings → Speech → Agent voices** you keep a list of label-and-voice pairs, as
long as you like. The label is normally the `session` name the agent sends, usually its
repo, and it is matched loosely so case and stray spaces do not matter. There is a play
button on each row to hear the voice. **Add one Baton has heard** fills in the label from
the agents that have already spoken. Anything not in the list speaks in a voice from
outside it, the same one every time, so a project you named never sounds like one you
did not.

**The first word gets cut off on my Bluetooth speaker.**
That's the speaker waking up. Bluetooth powers its radio down when nothing is playing
and takes a moment to come back, and that moment eats the start of the line. Baton
holds a little silence first to let it wake, and only over Bluetooth, so wired and
built-in speakers are never delayed. If you still lose the beginning, raise
**Settings → Speech → Delivery → Bluetooth head start** from its default of 0.7
seconds. Speakers differ by more than double, so some need a second or more.

**Do I need to run text-to-speech servers for spoken summaries?**
No. If you haven't set any up, Baton uses the built-in macOS voice, so `speak_summary` still
works. Self-hosted servers (Kokoro and Chatterbox) get you better and more varied voices, plus
voice cloning, and keep the audio on your own network. Setup is in
[`docs/tts-speak-summary.md`](docs/tts-speak-summary.md).

**Can Baton read things on my screen out loud?**
Yes. Select text in any app and choose Services → Speak with Baton, or set a keyboard shortcut
in Settings → Speech → Read aloud. Baton speaks it in the same voices it uses for summaries,
and ducks your music underneath. It is good for an article you would rather hear than read, or
for the tail of a long build. See
[Reading what's on your screen](HELP.md#reading-whats-on-your-screen).

**Does Baton watch my screen?**
No, and it cannot. Baton has no idea what is on your screen until you select something and ask
for it. There is no background monitoring and no polling: every reading happens because you
started it. Readings are not saved either: one plays, and then it is gone. Three exceptions, all of them things you ask for by name. File → Save Reading as Audio… writes a single file wherever you point it and nowhere else. File → Keep Reading in Clippings keeps that same audio inside Baton, where it appears in the Clippings list along with the words that were read, so you can find it later by a phrase from the middle of it; it stays until you delete it, and deleting it from that list removes the audio and the text together. And if you stop half way through an article, Baton keeps your place so File → Resume Reading can carry on: up to five of those, for seven days, holding the cleaned text you heard rather than the raw selection. Settings → Speech → Read aloud says how many are being held and forgets them on request. None of the three leaves your Mac.

**Is Read aloud a screen reader?**
Not in the accessibility sense, and it is not trying to be. VoiceOver reads interfaces, moving
through buttons and menus, and it does that far better. Read aloud speaks a piece of content
you have chosen.

**Why does Read aloud need Accessibility permission, and can I avoid it?**
You can avoid it entirely. Services → Speak with Baton needs no permission at all, because the
system hands the text over. The permission is only for the *keyboard shortcut*, which has to
ask the app you are in for what you have selected. Baton asks the first time you press the
shortcut and explains why.

**Why does my clipboard flicker when I use the shortcut in Chrome?**
Because Chrome will not hand over the selected text the ordinary way, so Baton copies it,
reads it, and puts your clipboard back (images and files included). It happens in a fraction
of a second, though a clipboard manager may still notice. Terminals like Ghostty share their
selection directly and need none of this. You can switch the fallback off in Settings → Speech
→ Read aloud, at the cost of the shortcut doing nothing in a browser.

**Will Baton read my API keys out loud?**
It tries hard not to. Before anything is spoken, Baton strips things shaped like credentials
(API keys, tokens, bearer headers, private key blocks) and says "a redacted token" instead.
Terminal output is exactly where such things sit, which is why the check runs on every reading
rather than only on some. Treat it as a good safety net rather than a guarantee.

## Documents and audiobooks

**Which documents can Baton read?**
PDFs, EPUB books, web pages (saved as HTML, or imported from their link), Markdown files and
plain text files. A scanned PDF, made of pictures of pages, is read with text recognition, which
can misread a word, so Baton names those pages before you start, and any page it could not read
at all. See [Listening to a document](HELP.md#listening-to-a-document).

**Can I start from a file in Finder?**
Yes. Control-click it and choose Open With → Baton, or Services → Make an Audiobook with Baton,
and it opens in the Mac's import sheet. Baton never becomes the default app for these files.

**How do I get a document onto my iPhone?**
Share it to Baton from another app's share sheet (a web page in Safari works too), open it in
Baton from Files, or use the + menu on the Books screen to import a file or a link. The phone makes the book on your Baton server, so set that up first under
Settings, Music Friend, Baton server. If the Baton server cannot make books, the import screen
offers Send to my Mac, and Baton on the Mac opens the document to import; without a Baton server it
suggests AirDropping the file to your Mac. A book made on the Mac arrives on the phone too: one
made on the Baton server is there already, and one made on the Mac itself is sent to your Baton
server as each chapter is done.

**Why did my book stop part way?**
The voice host stopped answering. The book's row in Books says so, and the book carries on
by itself when the host is reachable again. Check that the host is running and that its address
in Settings → Speech on the Mac, or the Baton server under Settings on the phone, is right.

**Does my document leave my device?**
Only to your own machines, unless you say otherwise. The text goes, a sentence or two at a time,
to the voice host you set in Settings → Speech, or to your Baton server when the book is made
there; with the built-in voices on a Mac it never leaves the Mac. Send to my Mac leaves the file
on your Baton server only until your Mac imports or discards it. The Mac's narrator suggestion,
recap and cast list use Apple Intelligence or a model you run yourself first. A cloud model gets
book text only if you allow it, and you can change that in Settings → Agents under Book text and
cloud models. Anything that looks like a password or key is removed before any text is spoken or
sent. See [Book text and cloud models](HELP.md#book-text-and-cloud-models).

**Can I choose the narrator?**
On the Mac, yes. When a model answers (Apple Intelligence, Ollama or LM Studio on this Mac, or
your Baton server's), the import sheet suggests three voices and lets you hear each in the book's
own words. Without one, and on the phone, Baton uses the default voice for the book's language,
the one set in Settings → Speech.

**Can I make books on my Mac without a voice server?**
Yes, on a Mac with Apple silicon. Download the built-in voices once under Settings → Speech →
Voice engine for books (342 MB). They are Kokoro's 28 English voices, run by Baton itself, and
nothing leaves the Mac. See [Voices: on this Mac or on your Baton
server](HELP.md#voices-on-this-mac-or-on-your-baton-server).

**Should I use the built-in voices or a voice server?**
On the Mac, Settings → Speech → Voice engine for books chooses. Automatic, the default, uses the
built-in voices first whenever they are downloaded and have the book's voice, and your voice
server for the rest. On a Mac with Apple silicon we recommend downloading them: in a
side-by-side listening test they sounded the same as the server, they work offline, and the
book's text stays on the Mac. They speak English only. Voice server reaches every voice your
Kokoro or Chatterbox server has, including other languages and Chatterbox's, and needs its
address to answer. The iPhone has no choice to make: its
books are made on your Baton server with the voice server set in its own setup
(`BATON_TTS_KOKORO_URL`). See [Voices: on this Mac or on your Baton
server](HELP.md#voices-on-this-mac-or-on-your-baton-server).

**Can a book sound more like a person reading it?**
Yes, with an expressive voice server such as Qwen3-TTS: any speech server that answers OpenAI's
speech requests. Enter its address under Expressive voice server in Settings → Speech → Voice
engine for books on the Mac, or set `BATON_TTS_OPENAI_URL` on your Baton server for the iPhone.
Its voices are listed as Expressive voices. They read a sentence at a time with a reader's
pauses, and each character in a cast is told how to sound from their gender and age. See [An
expressive voice server](HELP.md#voices-on-this-mac-or-on-your-baton-server).

**Can the characters have their own voices?**
Yes, on the Mac and the iPhone. Turn on Voice the dialogue when you import a book. A model
proposes a cast, you check it and pick the voices, and Baton works out who says each line. Any
line nobody can place stays with the narrator. It is off for your first book, then starts the way
you last left it. For a book already made, Change Voice… gives it a cast, edits the one it has,
or turns it off.
See [Voice the dialogue](HELP.md#voice-the-dialogue).

**How do I free the space a book takes?**
Choose Remove Download in the open book, or in its menu in Books. The book keeps its row and your place,
and Download Again or Render Again brings the audio back whenever you like. Settings → Storage on
the Mac, or Settings → Documents → Storage on the iPhone, shows what each book takes and lets you
set cleanup rules. Nothing is removed until you choose a rule. See
[Book storage](HELP.md#book-storage).

**I deleted a book by mistake. Can I get it back?**
For a week, yes. Open Storage in Settings and find the book under Recently Removed, then choose
Restore.

**Can a book have a cover?**
Yes. An EPUB brings its own. For any other book, open its menu and choose **Find Cover…** to pick
one from Open Library (only the title and author are sent), **Make a Cover** to have Baton draw
one from the title and author, or **Choose Image…** to use a picture of your own. The cover
reaches your other device through your Baton server.

**Why does the book have the wrong title or chapters?**
Baton takes the title and author from the first page and finds chapters from their headings.
Some documents lay these out in ways it cannot recognise. The import sheet shows what it found
before you start, so you can cancel and check the file.

**I never use this. Can I hide it?**
Yes. Turn off **Documents** under Settings → Speech on the Mac, or under Settings on the iPhone.
The import items, the drop target and the book rows go away on that device at once; the
other device keeps its own setting.

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

**How do I install Baton?**
Either grab the DMG from [batonmusic.app](https://batonmusic.app), or use Homebrew:

```sh
brew tap anatoliv/baton https://github.com/anatoliv/baton
brew trust anatoliv/baton
brew install --cask baton
```

`brew trust` is required on Homebrew 6 and later for any third-party tap; without it the
install refuses to load the cask. If Baton is already in `/Applications` from a DMG, add
`--force` so the cask can take it over.

**How do updates work?**
Baton uses Sparkle (the standard macOS updater). There's a **Check for Updates** item in the
app menu, and Baton checks its own feed and installs signed, notarized builds. Download the
current release from [batonmusic.app](https://batonmusic.app); it updates itself from there
on.

If you installed with Homebrew, Sparkle still does the updating: the cask is marked
`auto_updates`, so `brew upgrade` deliberately leaves Baton alone rather than fighting the
in-app updater. `brew info --cask baton` will keep showing the version you installed until you
re-run the cask; that's expected, not a stale install.

**Where can I read more?**
[HELP.md](HELP.md) covers how to use every part of Baton. The docs in [`docs/`](docs/) go into
the vision, architecture, and integration details.

## Can I try Baton without a server?

Yes. Choose **Try the demo** on the first-run screen and Baton opens a small library built
into the app: real tracks, played through the real engine, with nothing going over the
network. Connect your own music server, such as Navidrome, whenever you like; on iPhone that's
**Settings → Connect to Navidrome**, on the Mac it's **Settings → Music Servers**.

## How do I get my Mac's settings onto my iPhone?

**Settings → Set up from a Mac** on the phone. Scanning the code your Mac shows is the
quickest (nothing to type, not even a passphrase), but it needs both devices on the same
network. If they aren't, export a settings file from the Mac and import it on the phone
instead. Either way your music server's address, sign-in, equalizer and the rest come across.

Your likes, ratings, playlists and play counts never needed this: they live on your
music server and both apps read and write them as the same user, so they are already
the same everywhere.

**Do my podcasts and radio stations follow me between devices?**
Yes, by two different routes. **Radio stations** live on your music server alongside your music, so
they're simply the same on every device with nothing to set up. **Podcast subscriptions**
can't work that way (Navidrome has no podcast API, so Baton follows RSS feeds itself), and
they travel with your other settings through your Baton server instead (see
[shared settings](#what-are-shared-settings-and-do-i-need-a-baton-server) below).

Both directions work, including removals: unsubscribe from a show on the Mac and it goes on
the phone too, rather than reappearing next time the two talk. Baton records *when* you
subscribed or unsubscribed to each show, so a device that has been switched off for a week
can't undo something you deleted yesterday.

How far you are into an episode is still per-device.

## What are shared settings, and do I need a Baton server?

You don't need one. Baton works exactly as it always has without it, on both devices. Shared
settings is the optional upgrade that keeps your preferences in step *after* the one-time
transfer above, so changing the equalizer on the Mac changes it on the phone too.

It needs a **Baton server**: a small Baton program you run yourself, included in this
repository under `gateway/`, where it is called the Baton gateway. It runs on macOS and Linux,
and the natural place for it is whatever machine already runs your music server. Point both devices at its address with a token you invent, and they keep each
other current. The Mac does it at launch, when you switch back to it, and on a slow
heartbeat; the phone does the same. Setup is in
[Shared settings between your devices](HELP.md#shared-settings-between-your-devices), and the
Baton server's own options are in [`gateway/README.md`](gateway/README.md).

**What actually travels?**
The equalizer, crossfade, gapless, autoplay, repeat, loudness, radio bans, podcast
subscriptions, your search history, and the music friend's provider, model and base URL. What
stays on the device is anything that describes *that device* rather than you: the download
folder, offline mode, demo mode, and how far into an episode you are.

**Does my API key travel?**
Not through shared settings: keys live in the Keychain and never enter the shared file. The
*pairing code* is what moves secrets, and it moves all of them: your server passwords, your
ListenBrainz and Last.fm tokens, your discovery keys, the Baton server token and the music friend's
API key, every one of them encrypted. Pair a phone and you should not have to paste anything.
The switch that lets Baton look outside your library stays per-device though: that one is
consent, and a phone shouldn't inherit it.

**What happens if I change the same thing on both devices?**
The newer change wins, one setting at a time rather than one device at a time, so two devices
changing different things never overwrite each other. Lists work differently: search history
and podcast subscriptions are merged rather than replaced, so nothing disappears because the
other device synced more recently.

**Where are my settings actually stored?**
In a plain JSON file on the machine running your Baton server, which you can open and read.
It's written to disk rather than held in memory, so restarting the Baton server doesn't lose
anything.
