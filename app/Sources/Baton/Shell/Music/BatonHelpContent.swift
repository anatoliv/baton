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

/// One released version, shown as a card in the What's New panel.
struct HelpWhatsNewRelease: Identifiable {
    let version: String
    let date: String
    let highlight: String
    /// Optional asset-catalog image name for a screenshot shown under the highlight.
    var image: String? = nil
    let changes: [HelpWhatsNewChange]
    var id: String { version }
}

/// A single line item within a release.
struct HelpWhatsNewChange: Identifiable {
    let id = UUID()
    let kind: HelpWhatsNewChangeKind
    let text: String
}

/// The category of a What's New line item.
enum HelpWhatsNewChangeKind {
    case added, improved, fixed

    var label: String {
        switch self {
        case .added: "New"
        case .improved: "Improved"
        case .fixed: "Fixed"
        }
    }

    var tint: Color {
        switch self {
        case .added: .green
        case .improved: .blue
        case .fixed: .orange
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
            version: "0.13.0",
            date: "2026",
            highlight: "Your chat remote can look through your library before it answers.",
            changes: [
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Switch on \u{201C}Let it look around first\u{201D} in Settings \u{2192} "
                        + "Remote and plain-English requests stop being one blind guess. Ask for "
                        + "\u{201C}lazy music\u{201D} and instead of \u{201C}nothing matched\u{201D} it "
                        + "checks what your library actually calls things, finds the chillout "
                        + "you tagged \u{201C}chill\u{201D}, and plays it \u{2014} telling you that\u{2019}s "
                        + "what it did."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "When two answers are both reasonable \u{2014} two artists sharing a "
                        + "name, a six-hour mix beside a forty-minute set \u{2014} it offers them as "
                        + "buttons instead of guessing. Tap one, or type \u{201C}2\u{201D}. Say "
                        + "nothing and it starts the one it recommended rather than leaving you "
                        + "in silence."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Six new things it (and any connected AI assistant) can read: your "
                        + "genres, your liked songs, similar tracks, artist details, and albums "
                        + "browsed by newest, most-played or random. That\u{2019}s what makes "
                        + "\u{201C}what should I put on?\u{201D} answerable."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "\u{201C}search for dido\u{201D} searched for the word \u{201C}for\u{201D} "
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
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "With a big library, \u{201C}list my playlists\u{201D} answered with "
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
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "Step-by-step walkthroughs for connecting both chat services, "
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
                HelpWhatsNewChange(
                    kind: .added,
                    text: "\u{201C}Add this artist to the queue\u{201D}, \u{201C}who is this\u{201D}, "
                        + "\u{201C}what album is this from\u{201D} \u{2014} references to the current "
                        + "track now resolve, because the player\u{2019}s state travels with every "
                        + "plain-English request. The full 106-query evaluation now routes "
                        + "correctly in every run."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "The bot shows \u{201C}typing\u{2026}\u{201D} while a plain-English request "
                        + "is being worked out, so a local model taking a few seconds no longer "
                        + "looks like a dropped message."
                ),
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "Very long replies were refused outright by Telegram and Discord, so "
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
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "When macOS blocks an app from your local network, it reports it as "
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
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "\u{201C}Add the Beatles to the queue\u{201D}, \u{201C}queue up Led "
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
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "A message starting with a command word was always taken literally, so "
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
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Ask a chat remote to \u{201C}show me tracks for Dido\u{201D} and then "
                        + "\u{201C}play the second one\u{201D}, and it works. Each chat "
                        + "remembers its last few exchanges, so a follow-up refers to what was "
                        + "just listed instead of searching for the words you typed."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "That memory is deliberately short: it lives only while Baton runs, "
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
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Natural language now speaks two API dialects, so you can point Baton "
                        + "at whichever model you like: Anthropic, or anything serving the "
                        + "OpenAI chat-completions shape \u{2014} OpenAI, Groq, Together, "
                        + "OpenRouter, and self-hosted vLLM, Ollama, LM Studio or LiteLLM."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "A model running on your own machine or network is now a first-class "
                        + "option: nothing leaves your network, and there is no per-message cost. "
                        + "It needs to support tool calling, which the new Test button will tell "
                        + "you in one click."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "A Test button beside the connection settings sends one real request "
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
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "After connecting a Telegram or Discord bot, the Remote pane said "
                        + "\u{201C}No chats authorized yet\u{201D} without showing the link code "
                        + "you need to send \u{2014} it was further down the pane, below the other "
                        + "service. The code now sits with the message, where you read it."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "When plain English is on and the model runs out of room before it "
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
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Baton can now take commands from a chat app, so the stereo answers "
                        + "to your phone from the couch or the far end of a train line. Connect "
                        + "a Telegram or Discord bot in Settings \u{2192} Remote and send it "
                        + "\u{201C}play kind of blue\u{201D}, \u{201C}vol 40\u{201D}, or "
                        + "\u{201C}next\u{201D} \u{2014} replies carry buttons, so skipping a "
                        + "track is a tap."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Optionally, say it in your own words. Turn on plain English and "
                        + "\u{201C}put on something mellow\u{201D} or \u{201C}make me a "
                        + "40-minute driving mix\u{201D} work too. It needs an API key you "
                        + "provide, and stays off until you add one."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "Nothing about this opens your Mac to the internet: Baton dials out "
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
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "Baton now tells your server how much of a track actually played. "
                        + "Servers can only see how much was downloaded, and a long track "
                        + "downloads completely within minutes however briefly you stay \u{2014} so "
                        + "anything built on listening statistics was counting a few minutes of "
                        + "a long mix as having heard all of it."
                ),
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "Tracks buffered ahead for gapless playback are now marked as such, so "
                        + "a track you never heard is no longer recorded as a complete play."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.11.5",
            date: "2026",
            highlight: "No more silent gaps between tracks after resuming or seeking.",
            changes: [
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "After resuming a queue part-way through a track, or seeking in a long "
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
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "0.11.3 fixed clicking the playbar in a long track, but only for the "
                        + "first few clicks \u{2014} after that it could still skip to the next "
                        + "track. Seeking again now always gets a fresh attempt."
                ),
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "A long track no longer appears to get longer each time you seek in it, "
                        + "which made later clicks land somewhere other than where you aimed."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.11.3",
            date: "2026",
            highlight: "Clicking the playbar in a long mix goes where you clicked.",
            changes: [
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "Clicking partway into a long DJ set or podcast could skip to the next "
                        + "track instead of seeking. A server encoding a track on the fly "
                        + "can\u{2019}t be jumped around in until it has finished, and Baton "
                        + "mistook that for the track ending. It now asks the server to start "
                        + "the stream where you clicked, and no longer treats a stream running "
                        + "out early as a track finishing."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "Tracks your server can send as-is \u{2014} MP3 and AAC \u{2014} are no "
                        + "longer converted on the way to you. They start faster, sound closer to "
                        + "the original, and can be scrubbed freely from the first play."
                ),
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "Reopening Baton mid-way through a long track now resumes at the right "
                        + "place, and toggling the equaliser no longer restarts the track."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.11.2",
            date: "2026",
            highlight: "Ask an assistant for the previous track and you get the previous track.",
            changes: [
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "An assistant asking for Previous now always steps back a track, "
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
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "Previous restarts the current track when you are more than a few "
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
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Baton tags each stream request with the playlist, album or search "
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
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "Fixed a test that could fail at random on a busy machine and block a "
                        + "release for no real reason."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.10.3",
            date: "2026",
            highlight: "Genre cards stopped all showing a guitar.",
            changes: [
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "Each genre now picks an icon that suits it \u{2014} a waveform for Trance, "
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
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "Favorites Radio and Favorites Inbox were still showing a plain "
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
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "Most Played, Just Added, Top Rated, On Repeat, Forgotten Favorites and "
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
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "Focus, Daily and Deep Cuts cards each carry a bespoke backdrop chosen "
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
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Individual mixes can use a bespoke image instead of the generated "
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
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "Every mix card now carries a soft mesh-gradient backdrop that is unique "
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
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "Reworked how mix cards draw their backdrop."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.9.6",
            date: "2026",
            highlight: "Playlists your server builds for you now have a home on the Mixes tab.",
            changes: [
                HelpWhatsNewChange(
                    kind: .added,
                    text: "A \u{201C}From Your Server\u{201D} section on Mixes surfaces playlists that a "
                        + "nightly job or smart-playlist rule generates for you, so they aren\u{2019}t "
                        + "lost among hundreds of hand-made playlists in the sidebar."
                ),
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "Genre mixes no longer offer a card for tags that describe nothing. A "
                        + "library where almost every file is tagged \u{201C}Music\u{201D} was showing that "
                        + "as a genre \u{2014} which just offered you the whole library."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "Renamed the built-in \u{201C}Fresh Additions\u{201D} mix to \u{201C}Just Added\u{201D}, so it "
                        + "isn\u{2019}t confused with a server-generated playlist called \u{201C}Fresh\u{201D}."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.9.5",
            date: "2026",
            highlight: "Searching for a track with an accent or a stroked letter now finds it.",
            changes: [
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "Searches containing characters like \u{00F8}, \u{00E9} or \u{00F6} returned nothing, "
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
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "Hardened the assistant control surface against awkward libraries: "
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
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "Pressing Next or Previous blends briefly into the new track rather "
                        + "than cutting. The track you skipped to appears immediately \u{2014} only "
                        + "the sound crossfades."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "Crossfade starts preparing the next track earlier, so the fade is the "
                        + "length you set even when a track takes a moment to load."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "What\u{2019}s New is now in the menu bar, next to Check for Updates \u{2014} "
                        + "so you can see what changed without opening a window."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.9.2",
            date: "2026",
            highlight: "These release notes are back up to date \u{2014} and can\u{2019}t quietly fall behind again.",
            changes: [
                HelpWhatsNewChange(
                    kind: .added,
                    text: "What\u{2019}s New now covers the releases it had silently skipped, and a "
                        + "release can no longer be published without its entry."
                ),
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "When the music server is unreachable, playing specific tracks now "
                        + "reports the connection problem instead of claiming the tracks don\u{2019}t exist."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.9.1",
            date: "2026",
            highlight: "Tracks now join smoothly even when the next one is still loading.",
            changes: [
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "Crossfade no longer fades into silence. The outgoing track now holds "
                        + "its volume until the next one is actually audible, which matters when "
                        + "your server transcodes on the fly and a track takes a moment to start."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "An assistant connected over MCP can set the crossfade length, so you "
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
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "Building a mix no longer quietly ignores the genre or mood you asked "
                        + "for. If nothing in your library matches, it now says so instead of "
                        + "returning your liked songs as though they were the mix."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "An assistant can read a playlist back, so it can check what it just "
                        + "built instead of hoping."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "Playlists and playback can be addressed by exact track, so adding "
                        + "\u{201C}that one song\u{201D} no longer sweeps in every similar title."
                ),
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "Searches containing a semicolon or a plus sign no longer fail or "
                        + "silently look for the wrong thing."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.8.2",
            date: "2026",
            highlight: "Baton is now installable with Homebrew.",
            changes: [
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Install and update with \u{201C}brew install --cask baton\u{201D}."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "When an assistant speaks a summary, it now says which assistant is "
                        + "speaking."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.8.1",
            date: "2026",
            highlight: "A small polish to keep these release notes clearer.",
            changes: [
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "What\u{2019}s New entries can now include a screenshot, so a new "
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
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "The album, playlist, artist, or song you\u{2019}re playing shows as "
                        + "selected (an outline on cards, a highlight in lists), with a speaker "
                        + "badge that appears only while it\u{2019}s actually playing."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "In the full-screen player, tap \u{201C}Playing from\u{201D} to open "
                        + "the album, playlist, or artist you\u{2019}re playing."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "Open an album, playlist, or your Liked songs and the playing track "
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
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Run a custom action from the \u{201C}Actions\u{201D} menu on any "
                        + "song, album, artist, or playlist, filled with that item\u{2019}s "
                        + "details \u{2014} not only podcast episodes."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Run an action across a whole selection from the batch bar (Liked, "
                        + "Downloads, and podcast episodes). A selection over 25 asks first, "
                        + "so a select-all can\u{2019}t fire hundreds of requests by accident."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "For library tracks, an action can send the audio\u{2019}s stream or "
                        + "download URL \u{2014} but only if you turn on \u{201C}Allow "
                        + "credentialed URLs\u{201D} for that action, since those URLs carry "
                        + "your server login. Off by default."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "The voice category field offers a dropdown of common categories, "
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
                HelpWhatsNewChange(
                    kind: .added,
                    text: "A Test button in the action editor sends one request with sample "
                        + "values \u{2014} without saving \u{2014} and shows the result, so you "
                        + "can confirm an action works instead of discovering it later on a "
                        + "real episode."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Pick an action\u{2019}s icon from a searchable list of symbols with a "
                        + "live preview, instead of typing an exact symbol name. A name that "
                        + "doesn\u{2019}t exist now says so rather than showing nothing."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "A failed action tells you why \u{2014} the server\u{2019}s own "
                        + "explanation, or the HTTP status \u{2014} instead of just "
                        + "\u{201C}failed\u{201D}, and stays on screen long enough to read."
                ),
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "An action whose header had no name, or whose saved value could no "
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
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "Baton remembers your server\u{2019}s podcast episodes so it can resume "
                        + "them. That list had no ceiling and grew for the life of the install; "
                        + "it\u{2019}s now capped, and episodes you\u{2019}re part-way through "
                        + "are never dropped."
                ),
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "The agent-setup examples in Help showed a stale app version. They now "
                        + "make clear the value is whichever build you\u{2019}re running."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.6.8",
            date: "2026",
            highlight: "Baton now tells agents which version it actually is.",
            changes: [
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "The MCP server reported Baton as version \u{201C}0.1.0\u{201D} to every "
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
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Settings \u{2192} Servers \u{2192} Add Server now offers \u{201C}Try "
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
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "Opening the full-screen player while paused, then pressing play, left "
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
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Keyboard navigation in song lists — \u{2191}/\u{2193} move through "
                        + "Liked, Search, album and playlist tracks; Return plays, "
                        + "\u{2318}Return plays next."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Baton now respects the system Reduce Motion setting: the breathing "
                        + "artwork, equalizer bars, and hover zoom all hold still, while "
                        + "hover and selection stay clearly visible."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Go → Refresh Library (\u{2318}R) refetches albums, artists, "
                        + "playlists, liked songs, stations, and podcast feeds — for a server "
                        + "whose content changed while Baton was open."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "A \u{201C}Continue listening\u{201D} shelf on Home puts every "
                        + "part-finished podcast episode first, showing how much is left."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Playback → Like Current Track (\u{2303}\u{2318}L), plus Like in the "
                        + "menu-bar player."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Get Info (\u{2318}I) shows a track\u{2019}s codec, bitrate, bit "
                        + "depth, sample rate, year, play count, and download location."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "The scroll wheel now works on the volume slider and the scrubber — "
                        + "scroll to change volume or seek."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Hide sidebar sections you don\u{2019}t use (right-click the rail); "
                        + "show the track title in the menu bar; drag the equalizer curve "
                        + "directly to shape a band."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Never used Navidrome? The connect screen can fill in a public demo "
                        + "server so you can try Baton before setting anything up."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "Internet radio now appears properly in the menu-bar player and the "
                        + "mini player — both show the station and control it, instead of a "
                        + "stale library track."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "Podcasts on servers with their own podcast support (gonic, Airsonic) "
                        + "now resume where you left off, show listening progress, and can be "
                        + "marked played — matching Baton\u{2019}s own subscriptions."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "VoiceOver can read and adjust the position and volume sliders "
                        + "everywhere they appear, and the main transport buttons announce "
                        + "themselves properly."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "A playback error now offers Retry, not just Skip; the queue popover "
                        + "shows how many tracks and how long remain, resizes, and removes a "
                        + "row with the Delete key."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "Clearing everything from Later now asks first, and podcast feeds "
                        + "refresh from a button in the header rather than only after "
                        + "selecting a show."
                ),
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "Cover art no longer re-downloads every time a row or card is "
                        + "redrawn — browsing large libraries is faster and thumbnails "
                        + "stop flickering."
                ),
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "Podcast episodes are no longer scrobbled to Last.fm or ListenBrainz "
                        + "as music when they come from the server\u{2019}s own subscriptions."
                ),
            ]
        ),
        HelpWhatsNewRelease(
            version: "0.6.4",
            date: "2026",
            highlight: "Replay a spoken summary — the last one anytime, or any recent one from a new history list.",
            changes: [
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Playback → Replay Last Summary (\u{2303}\u{2318}R) re-speaks the "
                        + "most recent spoken summary anytime — even after the "
                        + "speaking HUD has closed."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Playback → Recent Summaries opens a Spoken Summaries "
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
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Settings → About → Back up & restore: export your "
                        + "preferences (playback, equalizer, layouts, spoken-summary "
                        + "voices, webhooks, and your server list) to a file, and "
                        + "import them on another Mac."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Optionally include server passwords and scrobbler logins "
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
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Settings → Playback → Stall timeout: choose how long "
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
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "Playback no longer hangs on an endless buffering spinner "
                        + "when the connection is slow or blocked (a VPN, or corporate "
                        + "network filtering). Baton now detects the stall, retries the "
                        + "track where it left off, and moves on if it can't recover."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "In-app Help now walks through setting up spoken-summary "
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
                HelpWhatsNewChange(
                    kind: .added,
                    text: "A floating speaking HUD: spoken-summary controls now "
                        + "live in a resizable, always-on-top mini-player card that "
                        + "follows you across Spaces and works even when the main "
                        + "window is closed \u{2014} with an auto-scrolling transcript, "
                        + "\u{00B1}10s seek, and Play / Pause / Replay."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Richer library metadata: Genre, Year, and format/quality "
                        + "now appear as real, aligned columns in the Liked and "
                        + "Search lists and on album and song cards, and full "
                        + "multi-artist names show everywhere a track appears."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "New ways to narrow and order: filter the Albums browser "
                        + "by genre and liked, and sort a mix by play count."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "Sonic-aware mixes \u{2014} music_build_mix and the "
                        + "built-in mixes now order tracks by tempo and space out "
                        + "the same artist, for a smoother listen."
                ),
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "Rating or liking a track from an agent now updates the "
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
                HelpWhatsNewChange(
                    kind: .added,
                    text: "A speaking HUD appears while a summary plays, with "
                        + "Pause / Resume and Stop — so a long read no longer has "
                        + "to run to the end."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Pause / Resume / Stop Speaking are in the Playback menu "
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
                HelpWhatsNewChange(
                    kind: .added,
                    text: "A Go menu to jump to any section (⌘1–8), plus Now "
                        + "Playing (⌘0) and Toggle Sidebar (⌃⌘S). ⌘F jumps to "
                        + "Search, and Space plays/pauses."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "The Audio menu gained quick Gapless / Crossfade toggles "
                        + "and a Loudness picker next to the Equalizer."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "The menu-bar controller no longer stretches to the width "
                        + "of a long track title, hides a blank \u{201C}Unknown\u{201D} "
                        + "artist, and adds Mute plus Settings, Check for Updates, "
                        + "and About."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "A configurable duck level (Settings → Playback) controls "
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
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Settings → Speech → Delivery: choose whether an "
                        + "agent's spoken summary is announced immediately or "
                        + "waits, and pick where it shows up — a macOS "
                        + "notification, an in-app banner, or both."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "A safety gate — off by default — controls whether an "
                        + "agent may speak a summary immediately without your "
                        + "confirmation, so a leaked token can't play audio at you."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "speak_summary now reports every surface a summary "
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
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Filter Search and Liked results by liked state and "
                        + "star rating — a funnel next to Sort narrows songs and "
                        + "albums to just what you're looking for."
                ),
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "Autoplay now keeps a continuous radio going at the end "
                        + "of the queue even on servers without similarity data, "
                        + "falling back to fresh tracks from your library."
                ),
                HelpWhatsNewChange(
                    kind: .fixed,
                    text: "Turning the equalizer on or off now takes effect "
                        + "immediately on the playing track."
                ),
                HelpWhatsNewChange(
                    kind: .improved,
                    text: "Settings, Agents adds a ready-to-paste MCP client "
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
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Plays any Navidrome or Subsonic-compatible server, "
                        + "with a full library browser: Home, Search, Mixes, "
                        + "Albums, Artists, Playlists, Liked, and History."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Deep playback: true gapless, crossfade, ReplayGain "
                        + "loudness matching, and a 10-band parametric equalizer."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Podcasts (server-hosted and by RSS feed), internet "
                        + "radio with live track info, and a Downloads manager "
                        + "with a global Offline mode."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Multiple servers with quick switching, a floating "
                        + "mini-player, a menu-bar controller, media-key and "
                        + "AirPlay support, and scrobbling to ListenBrainz and "
                        + "Last.fm."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "An MCP control server so an AI agent can search, "
                        + "queue, and steer playback, build a mix to a length "
                        + "you ask for, and speak short summaries aloud."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "This in-app Help center: browse the full guide and "
                        + "FAQ, search by keyword, and take a guided tour. Open "
                        + "it any time with \u{2318}?."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Auto-update via Sparkle: a Check for Updates item in "
                        + "the app menu and an Updates section in Settings, About."
                ),
                HelpWhatsNewChange(
                    kind: .added,
                    text: "Opt-in crash reporting (Sentry): off by default and "
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
