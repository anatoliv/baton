import BatonPlaybackKit
import AppKit
import MarkdownUI
import SwiftUI

// Supporting content and views for the in-app Help window: the
// guided-tour and What's New models and their data, the "Open Settings"
// button, and the two detail-pane players. `BatonHelpView` owns the
// window, navigation, and search. Modeled on Tonebox's help center,
// adapted to Baton's stack (no design-token module, no embedder).

// MARK: - Settings deep-link

/// Opens the Baton Settings window straight to a specific pane, the same
/// way `BatonAppCommands` opens the Equalizer: write the selection, then
/// open the window.
@MainActor
func openBatonSettings(_ category: BatonSettingsCategory, using openWindow: OpenWindowAction) {
    UserDefaults.standard.set(category.rawValue, forKey: BatonSettingsView.selectionKey)
    openWindow(id: BatonSettingsView.windowID)
    NSApp.activate(ignoringOtherApps: true)
}

// MARK: - Guided-tour model

/// A guided, multi-step walkthrough rendered in the Help detail pane.
struct HelpTour: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let steps: [HelpTourStep]
}

/// One step of a `HelpTour`.
struct HelpTourStep: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    /// Markdown body, rendered with the shared Help theme.
    let body: String
    /// Settings pane this step invites the reader to open, if any.
    var settings: BatonSettingsCategory?
}

// MARK: - What's New model

// The Mac carried a near-copy of `ReleaseNote` — same three fields, same three change
// kinds — and this file is edited on *every* release because the publish gate refuses a
// release without a What's New entry. A duplicated model touched that often is a model
// that drifts. The names stay as aliases so the 174 existing entries below and the
// freshness tests keep reading the way they always have.
typealias HelpWhatsNewRelease = ReleaseNote
typealias HelpWhatsNewChange = ReleaseNote.Change
typealias HelpWhatsNewChangeKind = ReleaseNote.Kind

extension ReleaseNote.Kind {
    /// The badge colour. Lives here, not in the package: a package that imports SwiftUI to
    /// describe a changelog is doing someone else's job.
    var tint: Color {
        switch self {
        case .added: .green
        case .improved: .blue
        case .fixed: Color.warningTint
        }
    }
}

// MARK: - Guided-tour content

extension HelpTour {
    /// The guided tours offered in the Help sidebar. Each is a short,
    /// linear walkthrough that ends with the reader able to do the thing.
    static let all: [HelpTour] = [
        HelpTour(
            id: "get-connected",
            title: "Get connected and playing",
            subtitle: "From a fresh install to your library playing in Baton.",
            symbol: "cable.connector",
            tint: .batonOrange,
            steps: [
                HelpTourStep(
                    symbol: "hand.wave",
                    title: "What you'll do",
                    body: """
                    Baton plays music from a server you run, so the first \
                    step is pointing it at that server. This short tour goes \
                    from an empty window to your library playing.

                    Leave any time by picking another topic in the sidebar.
                    """
                ),
                HelpTourStep(
                    symbol: "server.rack",
                    title: "Add your server",
                    body: """
                    Enter your **server URL** (for example \
                    `https://music.example.com`) and sign in with either a \
                    **username and password** or an **API key**. Baton checks \
                    the connection before it saves anything, and stores your \
                    credentials in the macOS Keychain.

                    Already connected? Add or switch servers any time in \
                    Settings, under Servers.
                    """,
                    settings: .servers
                ),
                HelpTourStep(
                    symbol: "music.note.list",
                    title: "Find your way around",
                    body: """
                    The left rail is your way in: **Home** for tap-to-play \
                    shelves, **Search** across songs, albums, and artists, \
                    **Mixes** that Baton builds from your listening, plus \
                    **Albums**, **Artists**, **Playlists**, and **Liked**.
                    """
                ),
                HelpTourStep(
                    symbol: "play.circle",
                    title: "Play, like, and rate",
                    body: """
                    Click anything to play it. Tap the **heart** to like a \
                    track or set a **star rating**, both stored on your \
                    server so they follow you to any Subsonic client. The bar \
                    at the bottom is your transport, queue, and sleep timer.
                    """
                ),
                HelpTourStep(
                    symbol: "checkmark.seal",
                    title: "You're set",
                    body: """
                    That's the whole loop: connect, browse, play. Baton even \
                    picks sensible playback defaults from how you listen once \
                    you've played a few tracks. Explore gapless, crossfade, \
                    and the equalizer in Settings whenever you like.
                    """,
                    settings: .playback
                ),
            ]
        ),
        HelpTour(
            id: "agent-control",
            title: "Let an agent control your music",
            subtitle: "Connect Claude or another MCP client to drive playback.",
            symbol: "sparkles",
            tint: .purple,
            steps: [
                HelpTourStep(
                    symbol: "network",
                    title: "What this does",
                    body: """
                    Baton runs a small **control server** on your Mac that \
                    speaks MCP, the protocol AI agents use to talk to tools. \
                    With it, an agent like Claude can search your library, \
                    build a queue, start playback, rate tracks, and make \
                    playlists, all from a natural request.

                    You never need this to use Baton by hand, it's an extra \
                    surface on top.
                    """
                ),
                HelpTourStep(
                    symbol: "lock.shield",
                    title: "It's already on, and secured",
                    body: """
                    The server starts with Baton and listens only on your own \
                    Mac (`127.0.0.1`), so nothing on your network can reach \
                    it. Every request must carry a secret token Baton \
                    generates. Both are required together.
                    """
                ),
                HelpTourStep(
                    symbol: "doc.text",
                    title: "Find the endpoint and token",
                    body: """
                    Baton writes a discovery file at \
                    `~/Library/Application Support/Baton/mcp.json` while it's \
                    running. It holds the **endpoint URL** (something like \
                    `http://127.0.0.1:8787/mcp`) and the **token**.
                    """
                ),
                HelpTourStep(
                    symbol: "link",
                    title: "Add it to your AI client",
                    body: """
                    In Claude Desktop or Claude Code, add an MCP server of the \
                    **Streamable HTTP** type pointing at that URL, and pass \
                    the token as a **bearer token**. Both values come \
                    straight out of `mcp.json`.
                    """
                ),
                HelpTourStep(
                    symbol: "checkmark.seal",
                    title: "You're connected",
                    body: """
                    Now ask the agent for what you want: *"play a focus \
                    mix," "what's this song, and like it," "make a playlist of \
                    this month's likes."* Keep Baton running (the menu-bar \
                    item keeps it alive with no window open) and the agent can \
                    drive it any time.
                    """
                ),
            ]
        ),
        HelpTour(
            id: "music-friend",
            title: "Your music friend",
            subtitle: "Ask for music in plain language, on any of your screens.",
            symbol: "bubble.left.and.bubble.right",
            tint: .orange,
            steps: [
                HelpTourStep(
                    symbol: "quote.bubble",
                    title: "What it's for",
                    body: """
                    Ask for what you want the way you'd say it to a person: \
                    *"something calmer," "what is this?," "play the live \
                    version instead."* It works out what you meant, then does \
                    it with your library and this Mac's player.

                    Open it with **Go, Music Friend**, or press **⌘⇧F**.
                    """
                ),
                HelpTourStep(
                    symbol: "key",
                    title: "You bring the brain",
                    body: """
                    Baton ships no API key and contacts no model provider until \
                    you set one up in **Settings, Remote** — Anthropic, OpenAI, \
                    or a model running on your own machine. Until then the \
                    window will say it has nothing to answer with.

                    That's also the answer to what it costs: whatever your \
                    provider charges. Baton adds nothing on top, and a local \
                    model costs nothing at all.
                    """
                ),
                HelpTourStep(
                    symbol: "bolt",
                    title: "Plain commands stay plain",
                    body: """
                    "Pause", "next", "louder" and their like are understood \
                    directly and answer immediately, without asking a model \
                    anything. The obvious things stay instant and free; the \
                    model is for requests that actually need thinking about.
                    """
                ),
                HelpTourStep(
                    symbol: "mic",
                    title: "Or just say it",
                    body: """
                    The composer has a microphone: click it, talk, click again \
                    to send. macOS asks for microphone and speech permission \
                    the first time, and if you decline, the window tells you \
                    rather than appearing to listen.
                    """
                ),
                HelpTourStep(
                    symbol: "rectangle.on.rectangle",
                    title: "One friend, every screen",
                    body: """
                    This window, the **Friend** tab on iPhone, and the Telegram \
                    and Discord bridges are all the *same* friend having one \
                    conversation. What it learns about you at your desk it \
                    knows on the train, and a thumbs-down you give here counts \
                    the same as one you give in Telegram.
                    """
                ),
                HelpTourStep(
                    symbol: "hand.thumbsdown",
                    title: "Tell it when it's wrong",
                    body: """
                    Every answer carries a quiet thumbs-up and thumbs-down. A \
                    thumbs-down asks what went wrong — wrong track, \
                    misunderstood, too slow, too chatty — and that correction \
                    goes into what it reads before answering next time.

                    **Settings, Friend Log** holds the whole history.
                    """
                ),
            ]
        ),
    ]
}

// MARK: - What's New content

extension HelpWhatsNewRelease {
    /// Release notes shown in the What's New panel, newest first.
    ///
    /// This list rots silently — it sat at 0.8.1 while 0.9.1 shipped, so three releases of
    /// user-visible change never reached the one surface built to announce them. Nothing
    /// enforced it. `WhatsNewFreshnessTests` now fails when the newest entry falls behind
    /// the shipping version, and `scripts/check-release.sh` blocks a release without one.
    static let all: [HelpWhatsNewRelease] = [
        HelpWhatsNewRelease(
            version: "0.16.24",
            date: "August 2026",
            highlight: "Music that stopped after the Mac slept starts again on its own, instead of showing \u{201C}playing\u{201D} while nothing comes out.",
            changes: [
                HelpWhatsNewChange(.fixed,
                    "Leaving Baton open overnight could leave it stuck: the transport said it "
                    + "was playing, the track sat at 0:00, and there was no sound. Pressing "
                    + "pause and play again did not help, and neither did skipping to another "
                    + "track \u{2014} only quitting and reopening did. macOS switches off the audio "
                    + "hardware when the Mac sleeps and does not always tell an app it has done "
                    + "so, and Baton went on believing it was playing."),
                HelpWhatsNewChange(.fixed,
                    "Baton now watches the playhead rather than only the buffer ahead of it. "
                    + "When audio is ready to play and the position stops moving, it restarts "
                    + "its audio output and carries on from where it was, using the audio it "
                    + "had already downloaded rather than fetching it again."),
                HelpWhatsNewChange(.improved,
                    "If that recovery cannot get sound flowing again, Baton now says so instead "
                    + "of sitting silent. A stall it cannot fix is at least one you can see."),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.23",
            date: "August 2026",
            highlight: "A radio station and a track can no longer play at the same time \u{2014} on the phone they did, and on the Mac there was one way in.",
            changes: [
                HelpWhatsNewChange(.fixed,
                    "On the iPhone, tuning an internet-radio station stopped the music, but "
                    + "starting a track did not stop the station: tap a song while one was on "
                    + "the air and you heard both. The Mac has always ended the broadcast when "
                    + "a track starts; the phone was never taught to."),
                HelpWhatsNewChange(.fixed,
                    "Resuming mid-track no longer comes up underneath a live stream. Pressing "
                    + "play from anywhere that isn't radio-aware \u{2014} the phone's mini player, "
                    + "a resume sent over the chat or MCP control surface \u{2014} used to restart "
                    + "the library without the station noticing."),
                HelpWhatsNewChange(.improved,
                    "The phone now follows the Mac for the rest of it too: the play and next "
                    + "keys on your headphones, lock screen and car drive the station while it "
                    + "holds the output rather than the queue behind it, and a sleep timer "
                    + "takes the station off the air along with the music."),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.22",
            date: "August 2026",
            highlight: "Lyrics no longer open with a line out of the file's own header, and where that header set a timing offset it is finally used.",
            changes: [
                HelpWhatsNewChange(.fixed,
                    "A lyric sheet could open with a line like [offset:-47682] above the first "
                    + "verse. That is part of the header an LRC file carries about itself, "
                    + "alongside the artist and the running time, and your server hands it "
                    + "over with everything else, so Baton showed it as though the song said "
                    + "it. The header is removed now. Section markers you actually wrote, like "
                    + "[Chorus], are left alone."),
                HelpWhatsNewChange(.improved,
                    "Where that header sets a timing offset, the offset is now applied to the "
                    + "scroll-along instead of being thrown away with the rest of the header. "
                    + "On the file that prompted this it was 47 seconds, which is the "
                    + "difference between lyrics that follow the song and lyrics that do not."),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.21",
            date: "August 2026",
            highlight: "Every service you can configure now tells you whether it is actually answering, and a song transcribes to its lyric again.",
            changes: [
                HelpWhatsNewChange(.added,
                    "Settings now says whether each service is actually answering. The music "
                    + "server, both speech hosts, the transcription host, ListenBrainz, "
                    + "Last.fm and the shared-settings gateway are all checked when you open "
                    + "the screen, and again whenever you ask. A green light always means a "
                    + "request that just happened, never that a key is filled in. Editing an "
                    + "address clears it, because it belonged to the address that was "
                    + "checked."),
                HelpWhatsNewChange(.fixed,
                    "A refused password and a server that is not there now read differently. "
                    + "They need different things from you: one is a credential to paste "
                    + "again, the other is a network to go and look at. Reporting both as not "
                    + "connected is how you spend an evening re-typing a password that was "
                    + "always correct."),
                HelpWhatsNewChange(.fixed,
                    "Scrobbling to ListenBrainz used to show a green tick for anything at all "
                    + "in the token field, so a token with a character missing looked exactly "
                    + "like a working account. Baton now asks ListenBrainz. Last.fm is asked "
                    + "too, which catches a session you revoked from their own settings page."),
                HelpWhatsNewChange(.fixed,
                    "Transcribing a song works again. The last release stopped asking the "
                    + "recogniser to skip non-speech audio when the track was music, on the "
                    + "theory that the filter was throwing the singing away. On one host that "
                    + "turned a four-minute song into four hundred repetitions of the word I, "
                    + "which Baton then correctly discarded, leaving a track full of vocals "
                    + "reported as having no speech in it. The filter is back on. If songs "
                    + "come out badly for you, the recogniser is the thing to change: WhisperX "
                    + "reads sung vocals, plain faster-whisper mostly does not."),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.20",
            date: "August 2026",
            highlight: "A song no longer transcribes to a wrong sentence, summaries work on iPhone, and the transcript guide is findable by its own name.",
            changes: [
                HelpWhatsNewChange(.fixed,
                    "Transcribing a song used to produce nonsense. Speech recognition does not "
                    + "go quiet over music, it invents: one track came back as the word Yeah "
                    + "repeated down the whole panel. Baton now asks the recogniser to skip "
                    + "everything that is not speech, and refuses to show a result that covers "
                    + "almost none of the track \u{2014} Riders on the Storm produced a single "
                    + "1.7-second fragment of a seven-minute song, reading as a garbled line of "
                    + "the lyric. It says there is no speech in the track instead, and points "
                    + "you at the Lyrics panel, which is what you wanted for a song."),
                HelpWhatsNewChange(.added,
                    "iPhone can summarize an episode now. The sheet could show a summary but "
                    + "gave you no way to make one, so on the phone it was a feature you could "
                    + "only ever look at."),
                HelpWhatsNewChange(.improved,
                    "The transcript guide is called Transcripts and summaries. It was filed "
                    + "under Reading what was said, which is a fine sentence and a poor label: "
                    + "the word transcript appeared nowhere in the heading, so scanning the "
                    + "contents for it found nothing."),
                HelpWhatsNewChange(.improved,
                    "The Transcription setting on iPhone has a Learn more link, and the guide "
                    + "now gives both settings paths rather than only the Mac's."),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.18",
            date: "August 2026",
            highlight: "Podcasts can be read as well as heard: a timed transcript, tappable to jump anywhere, and a summary with chapter marks.",
            changes: [
                HelpWhatsNewChange(.added,
                    "A Transcript panel in the full-screen player, and a transcript button on "
                    + "iPhone. Send a podcast episode to a Whisper server you run and Baton "
                    + "keeps what comes back: every line carries a timestamp, the current one "
                    + "highlights and scrolls as the episode plays, and tapping any line jumps "
                    + "there. An hour of talk was the one thing in a library you could not skim."),
                HelpWhatsNewChange(.added,
                    "Summarize writes an overview plus timestamped sections that work as "
                    + "chapter marks, each one tappable. It summarizes the episode ten minutes "
                    + "at a time and then summarizes those, which is what lets a model with a "
                    + "small context handle a long episode at all."),
                HelpWhatsNewChange(.added,
                    "Two new agent tools, music_transcript and music_summarize_track, so you "
                    + "can ask what an episode said about something without listening to it "
                    + "again. Both take a start and end time, so an agent reads the part it "
                    + "needs instead of the whole hour."),
                HelpWhatsNewChange(.improved,
                    "Transcription stays off until you set a host in Settings, Speech, and "
                    + "it never runs on its own. There is no background pass over your "
                    + "library and nothing when you subscribe to a feed. Summarizing "
                    + "refuses a model that is not on your own network, because a "
                    + "transcript is everything that was said in something you listened to."),
                HelpWhatsNewChange(.improved,
                    "When the transcription server cannot be reached, the panel says "
                    + "unavailable rather than showing an error. On a phone away from home "
                    + "that is the ordinary state of affairs, not a fault."),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.17",
            date: "August 2026",
            highlight: "Find More Like This asks only the services you choose, and the audio engine loses a long list of bugs.",
            changes: [
                HelpWhatsNewChange(.added,
                    "Find More Like This has a switch for each service now. A key used to be "
                    + "the only way to turn one on, so having a Last.fm key and not wanting "
                    + "Last.fm results was unsayable, and there was no way at all to leave "
                    + "MusicBrainz out. On iPhone there was nowhere to enter a key, which left two "
                    + "of the four sources permanently off. Keys have moved to the Keychain, "
                    + "and a Test button says whether one works before you save it."),
                HelpWhatsNewChange(.fixed,
                    "The music friend was being told the artist was Optional(\"Debussy\"). "
                    + "Every request carries a line about what is playing, and it passed the "
                    + "artist through unwrapped, so the friend read the debugger\u{2019}s "
                    + "spelling of the name, or nothing at all when a tag was missing. The "
                    + "placeholder [unknown] was reaching the like, rate and similar-songs "
                    + "replies the same way."),
                HelpWhatsNewChange(.improved,
                    "Music ducking under a spoken summary is a slope now. It used to drop "
                    + "the instant the voice started and jump back the instant it finished, "
                    + "and because the music keeps playing through both moments, you heard "
                    + "each one."),
                HelpWhatsNewChange(.improved,
                    "Spoken summaries come out of the speaker you chose. The output picker "
                    + "moved music and nothing else, so routing Baton to a kitchen speaker "
                    + "and asking for a summary still played it out of the laptop."),
                HelpWhatsNewChange(.fixed,
                    "All of these need the experimental audio engine switched on in Settings, "
                    + "Playback. Mute did nothing from any of the "
                    + "four places that offer it. Changing the output device while paused "
                    + "froze the playhead. The per-app output picker appeared for podcasts "
                    + "and downloads, which it cannot route. A device change re-downloaded "
                    + "audio already on disk. A dead stream could hang, or cost half a minute "
                    + "of silence before the queue moved on. And seeking inside a track the "
                    + "server does not transcode re-fetched it from the beginning, which on "
                    + "an hour-long set made those tracks close to unplayable."),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.16",
            date: "August 2026",
            highlight: "Help search works, lyrics turn up, and you can look past your own library.",
            changes: [
                HelpWhatsNewChange(.fixed,
                    "Searching Help found nothing. Not \u{201C}nothing for that word\u{201D} \u{2014} "
                    + "nothing for any word, in every version that has shipped with the Help "
                    + "window. Type \u{201C}scrobb\u{201D} now and you get Scrobbling."),
                HelpWhatsNewChange(.improved,
                    "Lyrics turn up far more often. A track tagged \u{201C}Wearing My Shoes "
                    + "(Louis Bailar\u{2019}s radio Chillout)\u{201D} by \u{201C}Aura feat. Dani "
                    + "Senior\u{201D} is filed as a slightly different remix by just "
                    + "\u{201C}Aura\u{201D}, and an exact match can\u{2019}t survive that. Baton "
                    + "now searches as well, and only accepts a match whose length agrees \u{2014} "
                    + "so the right words scroll against the right song, or none do. Separately, "
                    + "songs played from an album or the queue were never looked up at all."),
                HelpWhatsNewChange(.added,
                    "Find More Like This, on any track. \u{201C}More like this\u{201D} has always "
                    + "meant your own library; this asks the public catalogues what else is out "
                    + "there, and hands you a link. Ask the music friend for it too. Off until "
                    + "you turn it on in Settings, Playback: it sends the artist and title and "
                    + "nothing else, and two of its four sources need no account at all."),
                HelpWhatsNewChange(.improved,
                    "Unsubscribing from a podcast now travels between your Mac and your iPhone. "
                    + "It used to be handed straight back by whichever device still had the "
                    + "show. Subscribing already worked, and still does."),
                HelpWhatsNewChange(.improved,
                    "Help covers what the app actually does. Later had no page at all; Folders "
                    + "predated the browser it became; Scrobbling explained itself thoroughly "
                    + "without ever saying what it is for. There is a guided tour of the music "
                    + "friend, the friend\u{2019}s window has a way into Help, and Settings\u{2019} "
                    + "Agents and Friend Log panes are documented."),
                HelpWhatsNewChange(.fixed,
                    "On iPhone: the full-screen player no longer pushes the star rating off the "
                    + "bottom edge, and the Downloads row counts downloads rather than the "
                    + "things you saved for later."),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.15",
            date: "August 2026",
            highlight: "No more \u{201C}Unknown\u{201D}, and titles read the way they were written.",
            changes: [
                HelpWhatsNewChange(.improved,
                    "An artist Baton doesn\u{2019}t know is simply not shown, instead of the "
                    + "word \u{201C}Unknown\u{201D} sitting under the title. The line is left "
                    + "out entirely, so the title gets the space."),
                HelpWhatsNewChange(.fixed,
                    "Titles imported from YouTube carried odd full-width lookalikes where "
                    + "quotes, pipes and slashes belong \u{2014} a downloader substitutes them "
                    + "because those characters can\u{2019}t go in a filename, and the "
                    + "filenames became tags. They read normally now. Nothing else about a "
                    + "title is changed: emoji, capitals and long names are yours."),
                HelpWhatsNewChange(.improved,
                    "The music friend says \u{201C}Clair de Lune is paused\u{201D} rather than "
                    + "\u{201C}Clair de Lune by [unknown] is paused\u{201D}."),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.14",
            date: "August 2026",
            highlight: "Talk to your music friend, and it talks back.",
            changes: [
                HelpWhatsNewChange(.added,
                    "The music friend window has a microphone. Click it, say what you want, "
                    + "and click again to send \u{2014} the music ducks while you speak and "
                    + "comes back after. If you asked out loud, the answer is read back to "
                    + "you; if you typed it, it is not."),
                HelpWhatsNewChange(.improved,
                    "Mixes shaped by mood now use tempo measured from your own audio, not "
                    + "just the BPM tag your server happened to have. Most libraries tag "
                    + "almost nothing, so \u{201C}something upbeat\u{201D} used to reorder a "
                    + "handful of tracks and leave the rest alone. Baton measures tracks it "
                    + "already has on disk, and never downloads anything to do it."),
                HelpWhatsNewChange(.fixed,
                    "A thumbs-up or thumbs-down in the friend window is remembered when you "
                    + "reopen it, and an answer the friend gives on its own \u{2014} after "
                    + "picking between options for you \u{2014} now appears in the "
                    + "conversation instead of nowhere."),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.13",
            date: "August 2026",
            highlight: "The music friend comes to the Mac.",
            changes: [
                HelpWhatsNewChange(.added,
                    "Talk to your music friend in its own window \u{2014} Go \u{203A} Music "
                    + "Friend, or Command-Shift-F. Ask for something to play, ask what this "
                    + "is, or tell it what you are in the mood for, and it drives this Mac's "
                    + "player. It is the same friend that has been answering on Telegram and "
                    + "Discord all along, so it already knows what you listen to, and what "
                    + "you rate here counts the same as what you rate there."),
                HelpWhatsNewChange(.improved,
                    "Plain commands like \u{201C}pause\u{201D} or \u{201C}next\u{201D} are "
                    + "understood directly and answer instantly, without asking a model."),
                HelpWhatsNewChange(.fixed,
                    "With gapless playback on, removing the track queued up next could leave "
                    + "its audio playing under the following track's name. Baton was "
                    + "matching the queued track by its position, and removing a track "
                    + "shifts a different song into that position."),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.12",
            date: "August 2026",
            highlight: "The listening trend stops drawing dashes on a quiet week.",
            changes: [
                HelpWhatsNewChange(.fixed,
                    "History's trend strip drew a mark for every day you played nothing, "
                    + "so a week with a single play came out as a row of dashes with one "
                    + "block at the end. Quiet days are quiet now, along a single baseline "
                    + "\u{2014} and the strip stays out of the way entirely until there is "
                    + "more than one day's listening to show."),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.11",
            date: "August 2026",
            highlight: "Housekeeping \u{2014} nothing on screen changes in this one.",
            changes: [
                HelpWhatsNewChange(.improved,
                    "Baton now keeps the alphabetical index your server sends with its "
                    + "artist and folder lists, instead of rebuilding one from the names. "
                    + "The iPhone app uses it today; on the Mac this is groundwork, and "
                    + "nothing you can see has changed."),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.10",
            date: "August 2026",
            highlight: "The doors the Mac never had, and a brand that was never registered.",
            changes: [
                HelpWhatsNewChange(.fixed,
                    "Baton's orange was compiled into the app and never named as the accent, "
                    + "so every selection, link and control fell back to system blue \u{2014} "
                    + "beside orange badges."),
                HelpWhatsNewChange(.added,
                    "Shortcuts and Siri. The Mac had no App Intents at all, so Baton could be "
                    + "driven by an agent over its own socket but not by a two-step Shortcut. "
                    + "Play, pause, next, previous, like, and play-by-search."),
                HelpWhatsNewChange(.added,
                    "A `baton://` link opens the Mac app now, the way it already opened the "
                    + "phone. Drag a track onto a playlist in the sidebar or onto the queue "
                    + "button \u{2014} drag worked only *inside* a list before."),
                HelpWhatsNewChange(.added,
                    "A Friend Log in Settings. Every Telegram and Discord exchange has been "
                    + "recorded since the log shipped; there was simply no way to read one or "
                    + "tell it that it was wrong. Now there is, with what it has learned "
                    + "listed and removable."),
                HelpWhatsNewChange(.added,
                    "Lyrics from LRCLIB when your files have none \u{2014} off by default, "
                    + "since it is the one lookup that leaves your own server. And a "
                    + "System/Light/Dark setting: the library window was always dark while "
                    + "Settings followed the system, so the app disagreed with itself."),
                HelpWhatsNewChange(.improved,
                    "Arrow keys work in the grids, which are the default layout and were "
                    + "keyboard-dead. The focus ring is back for the whole window \u{2014} one "
                    + "line was suppressing it everywhere. VoiceOver announces the toasts that "
                    + "confirm queueing and downloading, and reads sidebar selection and counts."),
                HelpWhatsNewChange(.improved,
                    "Cover art is cached and decoded once. Every grid card was decoding the "
                    + "same image twice, across twenty screens, with no cache behind it."),
                HelpWhatsNewChange(.fixed,
                    "An hour-long mix showed a nonsense time \u{2014} 70:23 instead of 1:10:23 "
                    + "\u{2014} in the player, the track lists, and what the friend said back in "
                    + "chat."),
                HelpWhatsNewChange(.fixed,
                    "Queueing the same song twice made the queue reorder and delete the wrong "
                    + "rows, and starting a radio played your seed track twice."),
                HelpWhatsNewChange(.fixed,
                    "Hovering a volume or scrub slider swallowed every scroll event in the "
                    + "application, including in other windows."),
                HelpWhatsNewChange(.fixed,
                    "Continue listening showed a placeholder note for every podcast episode "
                    + "whose artwork was fine two screens away."),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.9",
            date: "August 2026",
            highlight: "Skip to the next track and the playhead starts where it should.",
            changes: [
                HelpWhatsNewChange(.fixed, "Clicking next while a track was playing loaded the new one but "
                        + "left the playhead part-way along, showing a position the new track "
                        + "had never reached. The experimental engine was fixed for this in "
                        + "0.16.6; the standard player had the same bug and kept it."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.8",
            date: "August 2026",
            highlight: "Correctness in the experimental engine, and a music friend that learns.",
            changes: [
                HelpWhatsNewChange(.fixed, "On the experimental audio engine: a stream that ended early "
                        + "could advance the queue mid-song with no recovery, pausing and "
                        + "immediately choosing another track left the new one silent, and "
                        + "a pause during loading was ignored while the app showed paused."
                ),
                HelpWhatsNewChange(.added, "The music friend keeps a record of what it was asked and what it "
                        + "did, and learns from a thumbs-down sent over Telegram or Discord. "
                        + "What you tell it you meant becomes something it remembers, "
                        + "alongside everything else in Baton's memory."
                ),
                HelpWhatsNewChange(.fixed, "Your stall timeout setting had no effect while the experimental "
                        + "engine was playing, and its retry counters never reset after a "
                        + "successful track."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.7",
            date: "August 2026",
            highlight: "The experimental engine no longer works while you are not listening.",
            changes: [
                HelpWhatsNewChange(.improved, "With the experimental audio engine on, Baton kept its audio "
                        + "pipeline running while paused, rendering silence for as long as "
                        + "the app was open — measurably more power paused than playing. "
                        + "The pipeline now sleeps when nothing is playing, and the level "
                        + "meter stops when the engine is not the one playing."
                ),
                HelpWhatsNewChange(.improved, "The equalizer now says where it actually applies: on the "
                        + "standard player it affects downloaded tracks, and music streamed "
                        + "from your server is untouched. That has always been true and was "
                        + "never stated — Settings used to claim the opposite."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.6",
            date: "August 2026",
            highlight: "An experimental audio engine, and a radio that no longer repeats itself.",
            changes: [
                HelpWhatsNewChange(.added, "Settings \u{2192} Advanced \u{2192} Experimental audio engine plays "
                        + "music streamed from your server through Baton's own pipeline. It is "
                        + "what makes the equalizer work on streamed music \u{2014} on the "
                        + "standard player the equalizer has only ever affected downloads. It "
                        + "also lets Baton send its own audio to a chosen speaker without moving "
                        + "every other app's. It costs noticeably more power, so it is off unless "
                        + "you turn it on."
                ),
                HelpWhatsNewChange(.fixed, "Starting a radio from a track listed that track twice at the top of "
                        + "the queue, with the playing indicator on both rows. The same fix "
                        + "removes it from the Related and Because You Liked shelves, which were "
                        + "quietly including the track you were already listening to."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.5",
            date: "August 2026",
            highlight: "The bars move with the music, and the heart is everywhere it should be.",
            changes: [
                HelpWhatsNewChange(.improved, "The bars on the playing track now follow the music itself rather "
                        + "than looping — a bassline pushes the left bar, a hi-hat flicks the "
                        + "right one."
                ),
                HelpWhatsNewChange(.improved, "Albums and artists can be liked, not just songs. The heart appears "
                        + "on any cover you point at, and on the Liked screen you can now "
                        + "un-like from the cover instead of hunting through a menu."
                ),
                HelpWhatsNewChange(.improved, "Hearts stay out of the way until you point at something, so a "
                        + "shelf of liked music is artwork again rather than a row of badges."
                ),
                HelpWhatsNewChange(.fixed, "The button that appears when you point at a cover now shows what "
                        + "pressing it will do \u{2014} pause while that track is playing, "
                        + "play otherwise. It used to offer to play the track you were "
                        + "already listening to."
                ),
                HelpWhatsNewChange(.fixed, "Radio cards no longer jump as the pointer crosses them; they ease "
                        + "like every other screen."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.4",
            date: "August 2026",
            highlight: "Folders, rebuilt as a proper part of the app.",
            changes: [
                HelpWhatsNewChange(.improved, "Folders now works like Albums and Artists: filter and sort, a list "
                        + "or a grid, hover to play, right-click for the full set of actions, "
                        + "and select several at once to queue, download or save them as a "
                        + "playlist."
                ),
                HelpWhatsNewChange(.fixed, "Playing a folder now plays everything inside it, subfolders "
                        + "included. Before, a folder whose music sat in album subfolders "
                        + "played nothing at all."
                ),
                HelpWhatsNewChange(.fixed, "Opening Folders no longer strands the window there \u{2014} the "
                        + "sidebar highlight moved but the page never changed, and it stayed "
                        + "that way after a restart."
                ),
                HelpWhatsNewChange(.improved, "\u{201C}Playing from\u{201D} in the player opens the folder you "
                        + "started, the way it already opened albums and artists."
                ),
                HelpWhatsNewChange(.improved, "Podcasts, Radio and Downloads highlight under the pointer the same "
                        + "way every other screen does."
                ),
                HelpWhatsNewChange(.fixed, "Clearing filter history in Settings now clears every screen's, and "
                        + "those filters travel between your Mac and iPhone. Ten screens were "
                        + "quietly missing from both."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.3",
            date: "August 2026",
            highlight: "Shuffle you can see, and cards that all behave alike.",
            changes: [
                HelpWhatsNewChange(.improved, "The Shuffle action shows whether shuffle is on, and choosing it "
                        + "again stops shuffling. Stopping part-way through a record keeps "
                        + "playing from where you are instead of starting it again."
                ),
                HelpWhatsNewChange(.improved, "The now-playing badge on a card moves while music is running and "
                        + "holds still when it isn\u{2019}t \u{2014} previously it looked the "
                        + "same either way."
                ),
                HelpWhatsNewChange(.fixed, "One mark for the playing track everywhere. Rows showed a speaker "
                        + "while cards showed a moving waveform \u{2014} the same state drawn "
                        + "two ways, sometimes on the same screen."
                ),
                HelpWhatsNewChange(.fixed, "Every card on Home now lifts the same way under the pointer. "
                        + "\u{201C}Jump back in\u{201D} and \u{201C}Continue listening\u{201D} "
                        + "didn\u{2019}t lift at all, and the mix cards lifted about a third as "
                        + "far as everything else."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.2",
            date: "August 2026",
            highlight: "Search history that follows you to the phone.",
            changes: [
                HelpWhatsNewChange(.added, "The Search field's history is now shared with your iPhone, and the "
                        + "phone keeps one too. A query typed on either device is one click "
                        + "away on the other."
                ),
                HelpWhatsNewChange(.added, "Search now also remembers the albums and artists you opened, shown "
                        + "under \u{201C}Recently Opened\u{201D} before you type \u{2014} usually "
                        + "the faster way back, since what you wanted was the record rather "
                        + "than the words you used to find it. Shared with the phone as well."
                ),
                HelpWhatsNewChange(.improved, "The shared lists merge rather than overwrite. Last-write-wins is "
                        + "right for a setting and wrong for a list \u{2014} it would drop "
                        + "everything searched on the quieter device the moment the other one "
                        + "synced."
                ),
                HelpWhatsNewChange(.fixed, "Shared settings now sync on their own \u{2014} at launch, when you "
                        + "switch to Baton, and periodically. Before, the Mac only ever synced "
                        + "when you pressed \u{201C}Sync now\u{201D} in Settings, so anything "
                        + "changed on your iPhone sat there until you happened to go and press "
                        + "a button you had no reason to press."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.1",
            date: "August 2026",
            highlight: "Stops you can hear.",
            changes: [
                HelpWhatsNewChange(.improved, "Pausing, stopping and resuming now actually sound like fades. The "
                        + "previous ramp was short and linear \u{2014} which the ear reads as a "
                        + "cut, because perceived loudness is logarithmic and a linear ramp "
                        + "drops most of its level in the last few milliseconds. It is longer "
                        + "now, shaped to how loudness is really heard, and resuming eases back "
                        + "in rather than snapping on."
                ),
                HelpWhatsNewChange(.fixed, "Changing the volume while a track was fading out snapped it back to "
                        + "full volume for the rest of the fade."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.16.0",
            date: "2026",
            highlight: "Browse by folder, hear what the queue is playing from, and a track that could never be silenced can be again.",
            changes: [
                HelpWhatsNewChange(.added, "Folders \u{2014} browse the library the way it sits on disk, not the "
                        + "way the tags describe it. Open a folder for its subfolders and "
                        + "tracks in file order, and play any folder top to bottom."
                ),
                HelpWhatsNewChange(.added, "Up Next says what is feeding it \u{2014} \u{201C}Playing from "
                        + "Albums\u{201D}. Baton has always known; the panel never said."
                ),
                HelpWhatsNewChange(.added, "Podcast subscriptions travel between this Mac and your iPhone. "
                        + "Subscribe on one and the other picks it up; each device still "
                        + "fetches its own episodes rather than inheriting a stale list."
                ),
                HelpWhatsNewChange(.added, "Albums can sort by year."
                ),
                HelpWhatsNewChange(.fixed, "A crossfade could leave a second track playing that nothing could "
                        + "stop \u{2014} every song chosen afterwards played on top of it. Two "
                        + "pieces of state could disagree about whether a fade was running; "
                        + "now the player itself is the authority."
                ),
                HelpWhatsNewChange(.improved, "Pausing and stopping fade over about a tenth of a second instead of "
                        + "cutting mid-waveform, which is what made them click \u{2014} most "
                        + "audible on bass and on good headphones."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.15.1",
            date: "2026",
            highlight: "Fixes for 0.15.0 \u{2014} the pairing code now appears, and the app ships with its entitlements intact.",
            changes: [
                HelpWhatsNewChange(.fixed, "\u{201C}Show pairing code\u{201D} did nothing. The code was being generated "
                        + "correctly \u{2014} the screen simply never redrew to show it."
                ),
                HelpWhatsNewChange(.fixed, "0.15.0 was signed without its entitlements, so the shipped app ran "
                        + "outside the sandbox it was built for. Releases are now signed with "
                        + "them and refuse to publish if they are missing."
                ),
                HelpWhatsNewChange(.fixed, "0.14.0 and 0.15.0 carried the same build number, so anyone on 0.14.0 "
                        + "was never offered the update. Fixed, and the release now checks."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.15.0",
            date: "2026",
            highlight: "Baton is on your iPhone now \u{2014} and setting it up takes one scan.",
            changes: [
                HelpWhatsNewChange(.added, "Settings \u{2192} Remote \u{2192} Devices shows a pairing code. Point the "
                        + "iPhone app at it and the phone is set up: server, sign-in and your "
                        + "scrobble accounts, without typing any of it on a phone keyboard. The "
                        + "code lasts ninety seconds, works once, and this Mac asks you to "
                        + "approve the device by name before it sends anything."
                ),
                HelpWhatsNewChange(.added, "Shared settings. Your equalizer, crossfade, loudness, radio bans and "
                        + "music-friend setup can follow you between this Mac and your iPhone "
                        + "through your Baton gateway. Optional \u{2014} leave it blank and nothing "
                        + "changes. Your likes, ratings, playlists and play counts already "
                        + "travelled: those live on your Navidrome server."
                ),
                HelpWhatsNewChange(.added, "Baton on Apple Watch. Download to the wrist and leave the phone behind."
                ),
                HelpWhatsNewChange(.improved, "The playback engine, the Subsonic client and the music-friend agent now "
                        + "live in shared frameworks that the Mac, the iPhone and the gateway all "
                        + "run. One implementation means a fix here is a fix everywhere, and the "
                        + "two apps can no longer drift apart in how they behave."
                ),
                HelpWhatsNewChange(.improved, "Downloads verify what they received before trusting it \u{2014} a truncated "
                        + "transcode or a server error dressed up as audio is caught and retried "
                        + "instead of poisoning your library."
                ),
                HelpWhatsNewChange(.fixed, "A stalled stream now recovers on its own instead of sitting silent, and "
                        + "Baton reaches servers behind a reverse proxy that needs custom headers."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.14.0",
            date: "2026",
            highlight: "Your chat remote knows what you listen to, and remembers what you tell it.",
            changes: [
                HelpWhatsNewChange(.added, "Ask it \u{201C}what kind of music do I listen to?\u{201D} and it answers "
                        + "properly \u{2014} your biggest genres, what you\u{2019}ve played most and how "
                        + "often, what you\u{2019}ve liked. It reads that from your own server each "
                        + "day and keeps none of it, so \u{201C}surprise me\u{201D} now comes from your "
                        + "collection instead of a coin flip."
                ),
                HelpWhatsNewChange(.added, "Tell it something that matters \u{2014} \u{201C}no vocals while I\u{2019}m "
                        + "working\u{201D}, \u{201C}the gothic playlists are my partner\u{2019}s\u{201D} \u{2014} "
                        + "and it keeps it. Always with the words you actually used, never a "
                        + "guess about you, and it tells you in the chat every time it writes "
                        + "one. Send `memories` to see everything it keeps, `forget 2` to remove "
                        + "one. There\u{2019}s a switch and a delete-all button in Settings, Remote."
                ),
                HelpWhatsNewChange(.added, "It has the occasional view. When something\u{2019}s worth mentioning \u{2014} "
                        + "that\u{2019}s the 34th play of this one \u{2014} it says so in passing and then "
                        + "plays what you asked for anyway. Never refuses, never lectures, and "
                        + "mentions any one thing at most once a day."
                ),
                HelpWhatsNewChange(.improved, "It sees far more of your library than it used to. Two thirds of what "
                        + "it asked for about your liked songs was being thrown away before it "
                        + "arrived; now it isn\u{2019}t, so recommendations have something to stand on."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.13.1",
            date: "2026",
            highlight: "Fixes a crash when the chat remote looks around your library.",
            changes: [
                HelpWhatsNewChange(.fixed, "With \u{201C}Let it look around first\u{201D} switched on, the first "
                        + "message you sent quit Baton instead of answering it. Nothing was "
                        + "lost and nothing had left your Mac \u{2014} it stopped while gathering "
                        + "the list of things it can do. If you turned the setting on in "
                        + "0.13.0 and gave up on it, it works now."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.13.0",
            date: "2026",
            highlight: "Your chat remote can look through your library before it answers.",
            changes: [
                HelpWhatsNewChange(.added, "Switch on \u{201C}Let it look around first\u{201D} in Settings \u{2192} "
                        + "Remote and plain-English requests stop being one blind guess. Ask for "
                        + "\u{201C}lazy music\u{201D} and instead of \u{201C}nothing matched\u{201D} it "
                        + "checks what your library actually calls things, finds the chillout "
                        + "you tagged \u{201C}chill\u{201D}, and plays it \u{2014} telling you that\u{2019}s "
                        + "what it did."
                ),
                HelpWhatsNewChange(.added, "When two answers are both reasonable \u{2014} two artists sharing a "
                        + "name, a six-hour mix beside a forty-minute set \u{2014} it offers them as "
                        + "buttons instead of guessing. Tap one, or type \u{201C}2\u{201D}. Say "
                        + "nothing and it starts the one it recommended rather than leaving you "
                        + "in silence."
                ),
                HelpWhatsNewChange(.added, "Six new things it (and any connected AI assistant) can read: your "
                        + "genres, your liked songs, similar tracks, artist details, and albums "
                        + "browsed by newest, most-played or random. That\u{2019}s what makes "
                        + "\u{201C}what should I put on?\u{201D} answerable."
                ),
                HelpWhatsNewChange(.improved, "\u{201C}search for dido\u{201D} searched for the word \u{201C}for\u{201D} "
                        + "too, quietly hiding every Dido album and artist. It now drops the "
                        + "word the verb implies."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.12.9",
            date: "2026",
            highlight: "Asking a chat remote for your playlists is useful again.",
            changes: [
                HelpWhatsNewChange(.improved, "With a big library, \u{201C}list my playlists\u{201D} answered with "
                        + "twenty-five near-identical rows and \u{201C}and 296 more\u{201D} \u{2014} a "
                        + "wall of text you could not act on. It now gives the count and how "
                        + "to open one, including that part of a name is enough: "
                        + "\u{201C}playlist trance\u{201D} finds the first match. Short lists are "
                        + "still printed in full."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.12.8",
            date: "2026",
            highlight: "The help now walks you through Telegram and Discord setup properly.",
            changes: [
                HelpWhatsNewChange(.improved, "Step-by-step walkthroughs for connecting both chat services, "
                        + "written from real setups: the Discord intent that silently breaks "
                        + "everything when missed, the exact invite permissions and why so few, "
                        + "and why a Telegram group bot ignores unprefixed messages. In this "
                        + "Help window and at baton.tonebox.io."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.12.7",
            date: "2026",
            highlight: "The chat remote now knows what\u{2019}s playing.",
            changes: [
                HelpWhatsNewChange(.added, "\u{201C}Add this artist to the queue\u{201D}, \u{201C}who is this\u{201D}, "
                        + "\u{201C}what album is this from\u{201D} \u{2014} references to the current "
                        + "track now resolve, because the player\u{2019}s state travels with every "
                        + "plain-English request. The full 106-query evaluation now routes "
                        + "correctly in every run."
                ),
                HelpWhatsNewChange(.improved, "The bot shows \u{201C}typing\u{2026}\u{201D} while a plain-English request "
                        + "is being worked out, so a local model taking a few seconds no longer "
                        + "looks like a dropped message."
                ),
                HelpWhatsNewChange(.fixed, "Very long replies were refused outright by Telegram and Discord, so "
                        + "the message never arrived at all. Replies are now trimmed to fit, "
                        + "cut on a whole line with a visible mark. Playing a playlist or a "
                        + "built mix also answers in plain words now, instead of a field dump."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.12.6",
            date: "2026",
            highlight: "A blocked local network no longer claims you\u{2019}re offline.",
            changes: [
                HelpWhatsNewChange(.fixed, "When macOS blocks an app from your local network, it reports it as "
                        + "\u{201C}The Internet connection appears to be offline\u{201D} \u{2014} which is "
                        + "plainly untrue when the chat message asking the question just arrived "
                        + "over the internet. Reaching a model on your own network now names the "
                        + "real cause and where to allow it, and a host that simply isn\u{2019}t "
                        + "answering is told apart from one you aren\u{2019}t permitted to reach."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.12.5",
            date: "2026",
            highlight: "Queueing by voice now lands in the right place.",
            changes: [
                HelpWhatsNewChange(.improved, "\u{201C}Add the Beatles to the queue\u{201D}, \u{201C}queue up Led "
                        + "Zeppelin\u{201D} and \u{201C}play Bowie next\u{201D} mean three "
                        + "different things, and plain English now tells them apart instead of "
                        + "sometimes replacing what you were listening to. Measured across "
                        + "forty-odd real phrasings against a local model, the routing went from "
                        + "35 in 39 to 42 in 43."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.12.4",
            date: "2026",
            highlight: "\u{201C}Play the second one\u{201D} now does what you meant.",
            changes: [
                HelpWhatsNewChange(.fixed, "A message starting with a command word was always taken literally, so "
                        + "\u{201C}play the second one\u{201D} searched for a song by that name and found "
                        + "nothing. When a literal reading comes up empty and plain English is "
                        + "switched on, Baton now asks what you meant \u{2014} with the conversation in "
                        + "hand, so a reference to what was just listed resolves."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.12.3",
            date: "2026",
            highlight: "Follow-up messages now know what you were just talking about.",
            changes: [
                HelpWhatsNewChange(.added, "Ask a chat remote to \u{201C}show me tracks for Dido\u{201D} and then "
                        + "\u{201C}play the second one\u{201D}, and it works. Each chat "
                        + "remembers its last few exchanges, so a follow-up refers to what was "
                        + "just listed instead of searching for the words you typed."
                ),
                HelpWhatsNewChange(.improved, "That memory is deliberately short: it lives only while Baton runs, "
                        + "covers a few recent exchanges, expires after a quiet half hour, and "
                        + "is separate for every chat. Send \u{201C}forget\u{201D} to clear it "
                        + "whenever you like."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.12.2",
            date: "2026",
            highlight: "Plain English can now run on any model \u{2014} including one on your own hardware.",
            changes: [
                HelpWhatsNewChange(.added, "Natural language now speaks two API dialects, so you can point Baton "
                        + "at whichever model you like: Anthropic, or anything serving the "
                        + "OpenAI chat-completions shape \u{2014} OpenAI, Groq, Together, "
                        + "OpenRouter, and self-hosted vLLM, Ollama, LM Studio or LiteLLM."
                ),
                HelpWhatsNewChange(.added, "A model running on your own machine or network is now a first-class "
                        + "option: nothing leaves your network, and there is no per-message cost. "
                        + "It needs to support tool calling, which the new Test button will tell "
                        + "you in one click."
                ),
                HelpWhatsNewChange(.added, "A Test button beside the connection settings sends one real request "
                        + "the same way a chat message would, so a pass means the next message "
                        + "will work \u{2014} not merely that something answered. When it fails it "
                        + "names the field to fix, rather than relaying a provider\u{2019}s "
                        + "internal wording."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.12.1",
            date: "2026",
            highlight: "Setting up a chat remote now tells you what to do next.",
            changes: [
                HelpWhatsNewChange(.fixed, "After connecting a Telegram or Discord bot, the Remote pane said "
                        + "\u{201C}No chats authorized yet\u{201D} without showing the link code "
                        + "you need to send \u{2014} it was further down the pane, below the other "
                        + "service. The code now sits with the message, where you read it."
                ),
                HelpWhatsNewChange(.improved, "When plain English is on and the model runs out of room before it "
                        + "picks a command, Baton now says so, instead of reporting that it "
                        + "couldn\u{2019}t understand a request that was perfectly clear."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.12.0",
            date: "2026",
            highlight: "Conduct your music from Telegram or Discord.",
            changes: [
                HelpWhatsNewChange(.added, "Baton can now take commands from a chat app, so the stereo answers "
                        + "to your phone from the couch or the far end of a train line. Connect "
                        + "a Telegram or Discord bot in Settings \u{2192} Remote and send it "
                        + "\u{201C}play kind of blue\u{201D}, \u{201C}vol 40\u{201D}, or "
                        + "\u{201C}next\u{201D} \u{2014} replies carry buttons, so skipping a "
                        + "track is a tap."
                ),
                HelpWhatsNewChange(.added, "Optionally, say it in your own words. Turn on plain English and "
                        + "\u{201C}put on something mellow\u{201D} or \u{201C}make me a "
                        + "40-minute driving mix\u{201D} work too. It needs an API key you "
                        + "provide, and stays off until you add one."
                ),
                HelpWhatsNewChange(.improved, "Nothing about this opens your Mac to the internet: Baton dials out "
                        + "and waits, so no port is opened and nothing needs forwarding. A chat "
                        + "controls nothing until you link it with a code Baton shows you \u{2014} "
                        + "a bot token on its own grants nobody anything."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.11.6",
            date: "2026",
            highlight: "Your listening history now reflects what you actually listened to.",
            changes: [
                HelpWhatsNewChange(.improved, "Baton now tells your server how much of a track actually played. "
                        + "Servers can only see how much was downloaded, and a long track "
                        + "downloads completely within minutes however briefly you stay \u{2014} so "
                        + "anything built on listening statistics was counting a few minutes of "
                        + "a long mix as having heard all of it."
                ),
                HelpWhatsNewChange(.fixed, "Tracks buffered ahead for gapless playback are now marked as such, so "
                        + "a track you never heard is no longer recorded as a complete play."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.11.5",
            date: "2026",
            highlight: "No more silent gaps between tracks after resuming or seeking.",
            changes: [
                HelpWhatsNewChange(.fixed, "After resuming a queue part-way through a track, or seeking in a long "
                        + "one, the next track could begin with about twenty seconds of silence "
                        + "before it recovered. The new track was being told it had already "
                        + "played most of the way through."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.11.4",
            date: "2026",
            highlight: "Seeking in a long mix now works however many times you do it.",
            changes: [
                HelpWhatsNewChange(.fixed, "0.11.3 fixed clicking the playbar in a long track, but only for the "
                        + "first few clicks \u{2014} after that it could still skip to the next "
                        + "track. Seeking again now always gets a fresh attempt."
                ),
                HelpWhatsNewChange(.fixed, "A long track no longer appears to get longer each time you seek in it, "
                        + "which made later clicks land somewhere other than where you aimed."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.11.3",
            date: "2026",
            highlight: "Clicking the playbar in a long mix goes where you clicked.",
            changes: [
                HelpWhatsNewChange(.fixed, "Clicking partway into a long DJ set or podcast could skip to the next "
                        + "track instead of seeking. A server encoding a track on the fly "
                        + "can\u{2019}t be jumped around in until it has finished, and Baton "
                        + "mistook that for the track ending. It now asks the server to start "
                        + "the stream where you clicked, and no longer treats a stream running "
                        + "out early as a track finishing."
                ),
                HelpWhatsNewChange(.improved, "Tracks your server can send as-is \u{2014} MP3 and AAC \u{2014} are no "
                        + "longer converted on the way to you. They start faster, sound closer to "
                        + "the original, and can be scrubbed freely from the first play."
                ),
                HelpWhatsNewChange(.fixed, "Reopening Baton mid-way through a long track now resumes at the right "
                        + "place, and toggling the equaliser no longer restarts the track."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.11.2",
            date: "2026",
            highlight: "Ask an assistant for the previous track and you get the previous track.",
            changes: [
                HelpWhatsNewChange(.improved, "An assistant asking for Previous now always steps back a track, "
                        + "however far into the current one you are. The back button in the app "
                        + "is unchanged \u{2014} it still restarts the current track first, the way "
                        + "every music player does."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.11.1",
            date: "2026",
            highlight: "Asking an assistant for the previous track now goes to the previous track.",
            changes: [
                HelpWhatsNewChange(.fixed, "Previous restarts the current track when you are more than a few "
                        + "seconds in \u{2014} right for a button, wrong for an assistant, whose "
                        + "request always arrives later than that. It can now ask to step back "
                        + "properly. The button behaves exactly as before."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.11.0",
            date: "2026",
            highlight: "Your server can now tell which playlist a track was played from.",
            changes: [
                HelpWhatsNewChange(.added, "Baton tags each stream request with the playlist, album or search "
                        + "it came from. Servers that don\u{2019}t care ignore it; ones that keep "
                        + "listening statistics can finally tell whether a playlist is working, "
                        + "rather than guessing from which tracks it happens to contain."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.10.4",
            date: "2026",
            highlight: "Internal reliability work \u{2014} nothing to see, which is the point.",
            changes: [
                HelpWhatsNewChange(.fixed, "Fixed a test that could fail at random on a busy machine and block a "
                        + "release for no real reason."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.10.3",
            date: "2026",
            highlight: "Genre cards stopped all showing a guitar.",
            changes: [
                HelpWhatsNewChange(.improved, "Each genre now picks an icon that suits it \u{2014} a waveform for Trance, "
                        + "a moon for Gothic, a controller for video-game music \u{2014} instead of "
                        + "every card showing the same pair of guitars."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.10.2",
            date: "2026",
            highlight: "The last two mix cards caught up with the rest.",
            changes: [
                HelpWhatsNewChange(.fixed, "Favorites Radio and Favorites Inbox were still showing a plain "
                        + "colour block while every other card had artwork. Both now have their "
                        + "own, and the fallback used by any future card is dimmer so it no "
                        + "longer stands out."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.10.1",
            date: "2026",
            highlight: "Every mix card now has its own artwork, not just the generated ones.",
            changes: [
                HelpWhatsNewChange(.improved, "Most Played, Just Added, Top Rated, On Repeat, Forgotten Favorites and "
                        + "Discover each got a bespoke backdrop, so the Mixes tab reads as one "
                        + "set rather than two."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.10.0",
            date: "2026",
            highlight: "Every generated playlist now has its own artwork.",
            changes: [
                HelpWhatsNewChange(.improved, "Focus, Daily and Deep Cuts cards each carry a bespoke backdrop chosen "
                        + "to match what the playlist is for \u{2014} steady light trails for Momentum, "
                        + "a desert ember for Lift, cold morning glass for Fresh."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.9.9",
            date: "2026",
            highlight: "A mix can now carry its own artwork.",
            changes: [
                HelpWhatsNewChange(.added, "Individual mixes can use a bespoke image instead of the generated "
                        + "backdrop. Focus \u{00B7} Deep uses one; every other card keeps its "
                        + "generated mesh."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.9.8",
            date: "2026",
            highlight: "Mix cards have their own artwork.",
            changes: [
                HelpWhatsNewChange(.improved, "Every mix card now carries a soft mesh-gradient backdrop that is unique "
                        + "to that mix and identical every time you open the app, so cards are "
                        + "recognisable at a glance. Nothing is downloaded to draw them."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.9.7",
            date: "2026",
            highlight: "Groundwork for better-looking mix cards.",
            changes: [
                HelpWhatsNewChange(.improved, "Reworked how mix cards draw their backdrop."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.9.6",
            date: "2026",
            highlight: "Playlists your server builds for you now have a home on the Mixes tab.",
            changes: [
                HelpWhatsNewChange(.added, "A \u{201C}From Your Server\u{201D} section on Mixes surfaces playlists that a "
                        + "nightly job or smart-playlist rule generates for you, so they aren\u{2019}t "
                        + "lost among hundreds of hand-made playlists in the sidebar."
                ),
                HelpWhatsNewChange(.fixed, "Genre mixes no longer offer a card for tags that describe nothing. A "
                        + "library where almost every file is tagged \u{201C}Music\u{201D} was showing that "
                        + "as a genre \u{2014} which just offered you the whole library."
                ),
                HelpWhatsNewChange(.improved, "Renamed the built-in \u{201C}Fresh Additions\u{201D} mix to \u{201C}Just Added\u{201D}, so it "
                        + "isn\u{2019}t confused with a server-generated playlist called \u{201C}Fresh\u{201D}."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.9.5",
            date: "2026",
            highlight: "Searching for a track with an accent or a stroked letter now finds it.",
            changes: [
                HelpWhatsNewChange(.fixed, "Searches containing characters like \u{00F8}, \u{00E9} or \u{00F6} returned nothing, "
                        + "because the server indexes a plain-letter version of every title. "
                        + "Baton now matches the way the server actually stores text, so "
                        + "\u{201C}\u{00F8}neheart\u{201D} or \u{201C}Ti\u{00EB}sto\u{201D} find their tracks."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.9.4",
            date: "2026",
            highlight: "Reliability work \u{2014} no new buttons, fewer ways for things to go wrong.",
            changes: [
                HelpWhatsNewChange(.improved, "Hardened the assistant control surface against awkward libraries: "
                        + "titles containing semicolons, plus signs or accented characters, "
                        + "duplicate track names, and files with no duration."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.9.3",
            date: "2026",
            highlight: "Skipping a track now sounds like a transition instead of a cut.",
            changes: [
                HelpWhatsNewChange(.improved, "Pressing Next or Previous blends briefly into the new track rather "
                        + "than cutting. The track you skipped to appears immediately \u{2014} only "
                        + "the sound crossfades."
                ),
                HelpWhatsNewChange(.improved, "Crossfade starts preparing the next track earlier, so the fade is the "
                        + "length you set even when a track takes a moment to load."
                ),
                HelpWhatsNewChange(.added, "What\u{2019}s New is now in the menu bar, next to Check for Updates \u{2014} "
                        + "so you can see what changed without opening a window."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.9.2",
            date: "2026",
            highlight: "These release notes are back up to date \u{2014} and can\u{2019}t quietly fall behind again.",
            changes: [
                HelpWhatsNewChange(.added, "What\u{2019}s New now covers the releases it had silently skipped, and a "
                        + "release can no longer be published without its entry."
                ),
                HelpWhatsNewChange(.fixed, "When the music server is unreachable, playing specific tracks now "
                        + "reports the connection problem instead of claiming the tracks don\u{2019}t exist."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.9.1",
            date: "2026",
            highlight: "Tracks now join smoothly even when the next one is still loading.",
            changes: [
                HelpWhatsNewChange(.fixed, "Crossfade no longer fades into silence. The outgoing track now holds "
                        + "its volume until the next one is actually audible, which matters when "
                        + "your server transcodes on the fly and a track takes a moment to start."
                ),
                HelpWhatsNewChange(.added, "An assistant connected over MCP can set the crossfade length, so you "
                        + "can just ask for longer or shorter transitions."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.9.0",
            date: "2026",
            highlight: "An assistant driving Baton can now be precise about what it plays \u{2014} "
                + "and tell you honestly when it couldn\u{2019}t do what you asked.",
            changes: [
                HelpWhatsNewChange(.fixed, "Building a mix no longer quietly ignores the genre or mood you asked "
                        + "for. If nothing in your library matches, it now says so instead of "
                        + "returning your liked songs as though they were the mix."
                ),
                HelpWhatsNewChange(.added, "An assistant can read a playlist back, so it can check what it just "
                        + "built instead of hoping."
                ),
                HelpWhatsNewChange(.improved, "Playlists and playback can be addressed by exact track, so adding "
                        + "\u{201C}that one song\u{201D} no longer sweeps in every similar title."
                ),
                HelpWhatsNewChange(.fixed, "Searches containing a semicolon or a plus sign no longer fail or "
                        + "silently look for the wrong thing."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.8.2",
            date: "2026",
            highlight: "Baton is now installable with Homebrew.",
            changes: [
                HelpWhatsNewChange(.added, "Install and update with \u{201C}brew install --cask baton\u{201D}."
                ),
                HelpWhatsNewChange(.improved, "When an assistant speaks a summary, it now says which assistant is "
                        + "speaking."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.8.1",
            date: "2026",
            highlight: "A small polish to keep these release notes clearer.",
            changes: [
                HelpWhatsNewChange(.improved, "What\u{2019}s New entries can now include a screenshot, so a new "
                        + "feature is easy to recognize at a glance."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.8.0",
            date: "2026",
            highlight: "The item you\u{2019}re playing now stands out at a glance, and you can "
                + "jump straight to it from the full-screen player.",
            image: "WhatsNew080",
            changes: [
                HelpWhatsNewChange(.improved, "The album, playlist, artist, or song you\u{2019}re playing shows as "
                        + "selected (an outline on cards, a highlight in lists), with a speaker "
                        + "badge that appears only while it\u{2019}s actually playing."
                ),
                HelpWhatsNewChange(.added, "In the full-screen player, tap \u{201C}Playing from\u{201D} to open "
                        + "the album, playlist, or artist you\u{2019}re playing."
                ),
                HelpWhatsNewChange(.improved, "Open an album, playlist, or your Liked songs and the playing track "
                        + "scrolls into view on its own, so you don\u{2019}t have to hunt for it."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.7.1",
            date: "2026",
            highlight: "Custom actions now run on any item \u{2014} songs, albums, artists, "
                + "playlists \u{2014} and across a selection, not just single podcast episodes.",
            changes: [
                HelpWhatsNewChange(.added, "Run a custom action from the \u{201C}Actions\u{201D} menu on any "
                        + "song, album, artist, or playlist, filled with that item\u{2019}s "
                        + "details \u{2014} not only podcast episodes."
                ),
                HelpWhatsNewChange(.added, "Run an action across a whole selection from the batch bar (Liked, "
                        + "Downloads, and podcast episodes). A selection over 25 asks first, "
                        + "so a select-all can\u{2019}t fire hundreds of requests by accident."
                ),
                HelpWhatsNewChange(.added, "For library tracks, an action can send the audio\u{2019}s stream or "
                        + "download URL \u{2014} but only if you turn on \u{201C}Allow "
                        + "credentialed URLs\u{201D} for that action, since those URLs carry "
                        + "your server login. Off by default."
                ),
                HelpWhatsNewChange(.improved, "The voice category field offers a dropdown of common categories, "
                        + "while still letting you type your own."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.7.0",
            date: "2026",
            highlight: "Custom actions are far easier to get right: test one from its editor, "
                + "pick its icon from a list, and see exactly why a request failed.",
            changes: [
                HelpWhatsNewChange(.added, "A Test button in the action editor sends one request with sample "
                        + "values \u{2014} without saving \u{2014} and shows the result, so you "
                        + "can confirm an action works instead of discovering it later on a "
                        + "real episode."
                ),
                HelpWhatsNewChange(.added, "Pick an action\u{2019}s icon from a searchable list of symbols with a "
                        + "live preview, instead of typing an exact symbol name. A name that "
                        + "doesn\u{2019}t exist now says so rather than showing nothing."
                ),
                HelpWhatsNewChange(.improved, "A failed action tells you why \u{2014} the server\u{2019}s own "
                        + "explanation, or the HTTP status \u{2014} instead of just "
                        + "\u{201C}failed\u{201D}, and stays on screen long enough to read."
                ),
                HelpWhatsNewChange(.fixed, "An action whose header had no name, or whose saved value could no "
                        + "longer be read, sent no header at all and failed with an "
                        + "unexplained authorization error. Both are now caught and named "
                        + "\u{2014} in the editor, and before the request is sent."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.6.9",
            date: "2026",
            highlight: "Housekeeping: podcast bookkeeping stays a sensible size, and the "
                + "MCP examples in Help show what Baton actually reports.",
            changes: [
                HelpWhatsNewChange(.fixed, "Baton remembers your server\u{2019}s podcast episodes so it can resume "
                        + "them. That list had no ceiling and grew for the life of the install; "
                        + "it\u{2019}s now capped, and episodes you\u{2019}re part-way through "
                        + "are never dropped."
                ),
                HelpWhatsNewChange(.fixed, "The agent-setup examples in Help showed a stale app version. They now "
                        + "make clear the value is whichever build you\u{2019}re running."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.6.8",
            date: "2026",
            highlight: "Baton now tells agents which version it actually is.",
            changes: [
                HelpWhatsNewChange(.fixed, "The MCP server reported Baton as version \u{201C}0.1.0\u{201D} to every "
                        + "connected agent \u{2014} in the connection handshake and in the "
                        + "discovery file agents read \u{2014} no matter which version was "
                        + "actually running. It now reports the real one."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.6.7",
            date: "2026",
            highlight: "Try the Navidrome demo server from Settings too — not just on the very "
                + "first screen.",
            changes: [
                HelpWhatsNewChange(.added, "Settings \u{2192} Servers \u{2192} Add Server now offers \u{201C}Try "
                        + "the demo server\u{201D}, the same one-click prefill as the first-run "
                        + "connect screen. Previously it was reachable only before you\u{2019}d "
                        + "connected anything, so there was no easy way to add the demo "
                        + "alongside your own library."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.6.6",
            date: "2026",
            highlight: "A fix for the full-screen player\u{2019}s artwork sitting still when it "
                + "should be gently breathing.",
            changes: [
                HelpWhatsNewChange(.fixed, "Opening the full-screen player while paused, then pressing play, left "
                        + "the artwork frozen instead of slowly breathing. It now starts and "
                        + "stops with playback \u{2014} and still holds completely still when "
                        + "Reduce Motion is on."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.6.5",
            date: "2026",
            highlight: "A big accessibility and keyboard release: browse with the arrow keys, "
                + "honour Reduce Motion, refresh the library with \u{2318}R — and podcasts that "
                + "remember where you left off on any server.",
            changes: [
                HelpWhatsNewChange(.added, "Keyboard navigation in song lists — \u{2191}/\u{2193} move through "
                        + "Liked, Search, album and playlist tracks; Return plays, "
                        + "\u{2318}Return plays next."
                ),
                HelpWhatsNewChange(.added, "Baton now respects the system Reduce Motion setting: the breathing "
                        + "artwork, equalizer bars, and hover zoom all hold still, while "
                        + "hover and selection stay clearly visible."
                ),
                HelpWhatsNewChange(.added, "Go → Refresh Library (\u{2318}R) refetches albums, artists, "
                        + "playlists, liked songs, stations, and podcast feeds — for a server "
                        + "whose content changed while Baton was open."
                ),
                HelpWhatsNewChange(.added, "A \u{201C}Continue listening\u{201D} shelf on Home puts every "
                        + "part-finished podcast episode first, showing how much is left."
                ),
                HelpWhatsNewChange(.added, "Playback → Like Current Track (\u{2303}\u{2318}L), plus Like in the "
                        + "menu-bar player."
                ),
                HelpWhatsNewChange(.added, "Get Info (\u{2318}I) shows a track\u{2019}s codec, bitrate, bit "
                        + "depth, sample rate, year, play count, and download location."
                ),
                HelpWhatsNewChange(.added, "The scroll wheel now works on the volume slider and the scrubber — "
                        + "scroll to change volume or seek."
                ),
                HelpWhatsNewChange(.added, "Hide sidebar sections you don\u{2019}t use (right-click the rail); "
                        + "show the track title in the menu bar; drag the equalizer curve "
                        + "directly to shape a band."
                ),
                HelpWhatsNewChange(.added, "Never used Navidrome? The connect screen can fill in a public demo "
                        + "server so you can try Baton before setting anything up."
                ),
                HelpWhatsNewChange(.improved, "Internet radio now appears properly in the menu-bar player and the "
                        + "mini player — both show the station and control it, instead of a "
                        + "stale library track."
                ),
                HelpWhatsNewChange(.improved, "Podcasts on servers with their own podcast support (gonic, Airsonic) "
                        + "now resume where you left off, show listening progress, and can be "
                        + "marked played — matching Baton\u{2019}s own subscriptions."
                ),
                HelpWhatsNewChange(.improved, "VoiceOver can read and adjust the position and volume sliders "
                        + "everywhere they appear, and the main transport buttons announce "
                        + "themselves properly."
                ),
                HelpWhatsNewChange(.improved, "A playback error now offers Retry, not just Skip; the queue popover "
                        + "shows how many tracks and how long remain, resizes, and removes a "
                        + "row with the Delete key."
                ),
                HelpWhatsNewChange(.improved, "Clearing everything from Later now asks first, and podcast feeds "
                        + "refresh from a button in the header rather than only after "
                        + "selecting a show."
                ),
                HelpWhatsNewChange(.fixed, "Cover art no longer re-downloads every time a row or card is "
                        + "redrawn — browsing large libraries is faster and thumbnails "
                        + "stop flickering."
                ),
                HelpWhatsNewChange(.fixed, "Podcast episodes are no longer scrobbled to Last.fm or ListenBrainz "
                        + "as music when they come from the server\u{2019}s own subscriptions."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.6.4",
            date: "2026",
            highlight: "Replay a spoken summary — the last one anytime, or any recent one from a new history list.",
            changes: [
                HelpWhatsNewChange(.added, "Playback → Replay Last Summary (\u{2303}\u{2318}R) re-speaks the "
                        + "most recent spoken summary anytime — even after the "
                        + "speaking HUD has closed."
                ),
                HelpWhatsNewChange(.added, "Playback → Recent Summaries opens a Spoken Summaries "
                        + "window listing your last 50, each with Replay (in its "
                        + "original voice) and Copy."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.6.3",
            date: "2026",
            highlight: "Move your whole Baton setup to another Mac — export your settings and import them safely.",
            changes: [
                HelpWhatsNewChange(.added, "Settings → About → Back up & restore: export your "
                        + "preferences (playback, equalizer, layouts, spoken-summary "
                        + "voices, webhooks, and your server list) to a file, and "
                        + "import them on another Mac."
                ),
                HelpWhatsNewChange(.added, "Optionally include server passwords and scrobbler logins "
                        + "— doing so encrypts the file with a passphrase you set, so "
                        + "your secrets never travel in the clear."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.6.2",
            date: "2026",
            highlight: "Tune how quickly playback recovers from a stalled connection.",
            changes: [
                HelpWhatsNewChange(.added, "Settings → Playback → Stall timeout: choose how long "
                        + "playback waits on a stalled stream before it recovers. "
                        + "Lower it to recover faster on a flaky, filtered, or VPN "
                        + "network; raise it to tolerate a legitimately slow connection."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.6.1",
            date: "2026",
            highlight: "Playback recovers from a stalled connection instead of spinning forever — a fix for flaky, filtered, or VPN networks.",
            changes: [
                HelpWhatsNewChange(.fixed, "Playback no longer hangs on an endless buffering spinner "
                        + "when the connection is slow or blocked (a VPN, or corporate "
                        + "network filtering). Baton now detects the stall, retries the "
                        + "track where it left off, and moves on if it can't recover."
                ),
                HelpWhatsNewChange(.improved, "In-app Help now walks through setting up spoken-summary "
                        + "voices (Kokoro and Chatterbox) step by step, and covers "
                        + "connecting Cursor as an agent."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.6.0",
            date: "2026",
            highlight: "A floating speaking HUD you can move anywhere, richer library metadata across every screen, and sonic-aware mixes.",
            changes: [
                HelpWhatsNewChange(.added, "A floating speaking HUD: spoken-summary controls now "
                        + "live in a resizable, always-on-top mini-player card that "
                        + "follows you across Spaces and works even when the main "
                        + "window is closed \u{2014} with an auto-scrolling transcript, "
                        + "\u{00B1}10s seek, and Play / Pause / Replay."
                ),
                HelpWhatsNewChange(.added, "Richer library metadata: Genre, Year, and format/quality "
                        + "now appear as real, aligned columns in the Liked and "
                        + "Search lists and on album and song cards, and full "
                        + "multi-artist names show everywhere a track appears."
                ),
                HelpWhatsNewChange(.added, "New ways to narrow and order: filter the Albums browser "
                        + "by genre and liked, and sort a mix by play count."
                ),
                HelpWhatsNewChange(.improved, "Sonic-aware mixes \u{2014} music_build_mix and the "
                        + "built-in mixes now order tracks by tempo and space out "
                        + "the same artist, for a smoother listen."
                ),
                HelpWhatsNewChange(.fixed, "Rating or liking a track from an agent now updates the "
                        + "stars and heart in the UI right away, instead of waiting "
                        + "for a reload."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.5.0",
            date: "2026",
            highlight: "Take control of a spoken summary — pause, resume, or stop it, with a live progress bar.",
            changes: [
                HelpWhatsNewChange(.added, "A speaking HUD appears while a summary plays, with "
                        + "Pause / Resume and Stop — so a long read no longer has "
                        + "to run to the end."
                ),
                HelpWhatsNewChange(.added, "Pause / Resume / Stop Speaking are in the Playback menu "
                        + "too (Stop is \u{2303}\u{2318}.), and the HUD shows a "
                        + "progress bar for server-synthesized audio."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.4.0",
            date: "2026",
            highlight: "Drive Baton from the keyboard and the menu bar — a Go menu, ⌘F search, Space to play, and a tidier status menu.",
            changes: [
                HelpWhatsNewChange(.added, "A Go menu to jump to any section (⌘1–8), plus Now "
                        + "Playing (⌘0) and Toggle Sidebar (⌃⌘S). ⌘F jumps to "
                        + "Search, and Space plays/pauses."
                ),
                HelpWhatsNewChange(.added, "The Audio menu gained quick Gapless / Crossfade toggles "
                        + "and a Loudness picker next to the Equalizer."
                ),
                HelpWhatsNewChange(.improved, "The menu-bar controller no longer stretches to the width "
                        + "of a long track title, hides a blank \u{201C}Unknown\u{201D} "
                        + "artist, and adds Mute plus Settings, Check for Updates, "
                        + "and About."
                ),
                HelpWhatsNewChange(.added, "A configurable duck level (Settings → Playback) controls "
                        + "how far the music dims for a spoken summary or while an "
                        + "agent dictates."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.3.0",
            date: "2026",
            highlight: "Decide how spoken summaries reach you — announce right away, or wait quietly as a notification or banner.",
            changes: [
                HelpWhatsNewChange(.added, "Settings → Speech → Delivery: choose whether an "
                        + "agent's spoken summary is announced immediately or "
                        + "waits, and pick where it shows up — a macOS "
                        + "notification, an in-app banner, or both."
                ),
                HelpWhatsNewChange(.added, "A safety gate — off by default — controls whether an "
                        + "agent may speak a summary immediately without your "
                        + "confirmation, so a leaked token can't play audio at you."
                ),
                HelpWhatsNewChange(.improved, "speak_summary now reports every surface a summary "
                        + "reached (spoken, notified, banner), so an agent knows "
                        + "exactly what happened."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.2.0",
            date: "2026",
            highlight: "Filter Search and Liked by what you love, and three playback fixes from real-world use.",
            changes: [
                HelpWhatsNewChange(.added, "Filter Search and Liked results by liked state and "
                        + "star rating — a funnel next to Sort narrows songs and "
                        + "albums to just what you're looking for."
                ),
                HelpWhatsNewChange(.fixed, "Autoplay now keeps a continuous radio going at the end "
                        + "of the queue even on servers without similarity data, "
                        + "falling back to fresh tracks from your library."
                ),
                HelpWhatsNewChange(.fixed, "Turning the equalizer on or off now takes effect "
                        + "immediately on the playing track."
                ),
                HelpWhatsNewChange(.improved, "Settings, Agents adds a ready-to-paste MCP client "
                        + "configuration so any agent that speaks MCP over HTTP "
                        + "can connect with one copy."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.1.0",
            date: "2026",
            highlight: "The first standalone Baton: your self-hosted library, played with real depth, and controllable by an AI agent.",
            changes: [
                HelpWhatsNewChange(.added, "Plays any Navidrome or Subsonic-compatible server, "
                        + "with a full library browser: Home, Search, Mixes, "
                        + "Albums, Artists, Playlists, Liked, and History."
                ),
                HelpWhatsNewChange(.added, "Deep playback: true gapless, crossfade, ReplayGain "
                        + "loudness matching, and a 10-band parametric equalizer."
                ),
                HelpWhatsNewChange(.added, "Podcasts (server-hosted and by RSS feed), internet "
                        + "radio with live track info, and a Downloads manager "
                        + "with a global Offline mode."
                ),
                HelpWhatsNewChange(.added, "Multiple servers with quick switching, a floating "
                        + "mini-player, a menu-bar controller, media-key and "
                        + "AirPlay support, and scrobbling to ListenBrainz and "
                        + "Last.fm."
                ),
                HelpWhatsNewChange(.added, "An MCP control server so an AI agent can search, "
                        + "queue, and steer playback, build a mix to a length "
                        + "you ask for, and speak short summaries aloud."
                ),
                HelpWhatsNewChange(.added, "This in-app Help center: browse the full guide and "
                        + "FAQ, search by keyword, and take a guided tour. Open "
                        + "it any time with \u{2318}?."
                ),
                HelpWhatsNewChange(.added, "Auto-update via Sparkle: a Check for Updates item in "
                        + "the app menu and an Updates section in Settings, About."
                ),
                HelpWhatsNewChange(.added, "Opt-in crash reporting (Sentry): off by default and "
                        + "scrubbed of personal data, in Settings, About, "
                        + "Diagnostics. It never sends your music, library, or "
                        + "server address."
                ),
            ]
        ),
    ]
}

// MARK: - Open-Settings button

/// An inline button that opens the Settings window straight to the pane
/// the surrounding help text is describing.
struct HelpSettingsButton: View {
    let category: BatonSettingsCategory

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openBatonSettings(category, using: openWindow)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: category.symbol)
                Text("Open Settings: \(category.label)")
                    .fontWeight(.medium)
            }
            .padding(.horizontal, HelpTokens.Space.snug)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .foregroundStyle(HelpTokens.accent)
        .background(HelpTokens.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: HelpTokens.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: HelpTokens.Radius.control)
                .strokeBorder(HelpTokens.accent.opacity(0.3))
        )
    }
}

// MARK: - Guided-tour player

/// The detail-pane player for a guided tour: a progress bar, the current
/// step's content, and Back / Next controls.
struct TourDetailView: View {
    let tour: HelpTour
    let markdownTheme: Theme
    let onFinish: () -> Void

    @State private var stepIndex = 0

    private var step: HelpTourStep {
        tour.steps[min(stepIndex, tour.steps.count - 1)]
    }

    private var isLastStep: Bool {
        stepIndex >= tour.steps.count - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        progressBar
                        stepCard
                    }
                    .id("tour-step-top")
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HelpTokens.Space.pane)
                    .padding(.vertical, HelpTokens.Space.wide)
                }
                .onChange(of: stepIndex) {
                    proxy.scrollTo("tour-step-top", anchor: .top)
                }
            }
            Divider()
            footer
        }
        .onChange(of: tour.id) { stepIndex = 0 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: HelpTokens.Space.row6) {
            HStack(alignment: .center, spacing: HelpTokens.Space.tight) {
                Label(tour.title, systemImage: tour.symbol)
                    .font(HelpTokens.Fonts.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: HelpTokens.Space.tight)
                Text("GUIDED TOUR")
                    .font(HelpTokens.Fonts.tiny.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .frame(height: HelpTokens.rowHeight)
            Text(tour.subtitle)
                .font(HelpTokens.Fonts.small)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: HelpTokens.rowHeight)
        }
        .padding(.horizontal, HelpTokens.Space.regular)
        .padding(.vertical, HelpTokens.Space.medium)
    }

    private var progressBar: some View {
        HStack(spacing: 5) {
            ForEach(tour.steps.indices, id: \.self) { index in
                Capsule()
                    .fill(index <= stepIndex ? tour.tint : Color.primary.opacity(0.12))
                    .frame(height: 4)
            }
        }
    }

    private var stepCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: step.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(tour.tint)
                    .frame(width: 52, height: 52)
                    .background(tour.tint.opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Step \(stepIndex + 1) of \(tour.steps.count)")
                        .font(HelpTokens.Fonts.tiny.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(step.title)
                        .font(.system(size: 19, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Markdown(step.body)
                .markdownTheme(markdownTheme)
                .textSelection(.enabled)
            if let category = step.settings {
                HelpSettingsButton(category: category)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .id(stepIndex)
        .transition(.opacity)
    }

    private var footer: some View {
        HStack {
            Button {
                withAnimation(HelpTokens.paneCurve) { stepIndex -= 1 }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
            }
            .disabled(stepIndex == 0)

            Spacer()

            if isLastStep {
                Button(action: onFinish) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                        Text("Finish")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(tour.tint)
            } else {
                Button {
                    withAnimation(HelpTokens.paneCurve) { stepIndex += 1 }
                } label: {
                    HStack(spacing: 4) {
                        Text("Next")
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(tour.tint)
            }
        }
        .padding(.horizontal, HelpTokens.Space.pane)
        .padding(.vertical, HelpTokens.Space.element)
    }
}

// MARK: - What's New panel

/// The detail-pane panel that lists release notes, newest first.
struct WhatsNewDetailView: View {
    let releases: [HelpWhatsNewRelease]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(releases.enumerated()), id: \.element.id) { index, release in
                        releaseCard(release, isLatest: index == 0)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HelpTokens.Space.pane)
                .padding(.vertical, HelpTokens.Space.wide)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: HelpTokens.Space.row6) {
            HStack(alignment: .center, spacing: HelpTokens.Space.tight) {
                Label("What's New", systemImage: "sparkles")
                    .font(HelpTokens.Fonts.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: HelpTokens.Space.tight)
                Text("RELEASE NOTES")
                    .font(HelpTokens.Fonts.tiny.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .frame(height: HelpTokens.rowHeight)
            Text("Every version of Baton, newest first.")
                .font(HelpTokens.Fonts.small)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: HelpTokens.rowHeight)
        }
        .padding(.horizontal, HelpTokens.Space.regular)
        .padding(.vertical, HelpTokens.Space.medium)
    }

    private func releaseCard(
        _ release: HelpWhatsNewRelease,
        isLatest: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Version \(release.version)")
                    .font(.system(size: 17, weight: .bold))
                if isLatest {
                    Text("LATEST")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(.white)
                        .padding(.horizontal, HelpTokens.Space.row6)
                        .padding(.vertical, 2)
                        .background(Color.green, in: Capsule())
                }
                Spacer()
                Text(release.date)
                    .font(HelpTokens.Fonts.small)
                    .foregroundStyle(.secondary)
            }
            Text(release.highlight)
                .font(HelpTokens.Fonts.small)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let image = release.image {
                Image(image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                    .accessibilityLabel("Screenshot of what's new in \(release.version)")
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                ForEach(release.changes) { change in
                    changeRow(change)
                }
            }
        }
        .padding(HelpTokens.Space.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: HelpTokens.Radius.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HelpTokens.Radius.card)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private func changeRow(_ change: HelpWhatsNewChange) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(change.kind.label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(change.kind.tint)
                .padding(.horizontal, HelpTokens.Space.row6)
                .padding(.vertical, 2)
                .background(change.kind.tint.opacity(0.14), in: Capsule())
                .frame(width: 72, alignment: .leading)
                .padding(.top, 1)
            Text(change.text)
                .font(HelpTokens.Fonts.small)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
