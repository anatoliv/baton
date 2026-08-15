import BatonPlaybackKit
import MarkdownUI
import SwiftUI

/// In-app Help: the same HELP.md and FAQ.md the repo root carries and the website
/// publishes, copied into the bundle by a prebuild step so they can never drift from the
/// docs we actually edit.
///
/// This used to render all 1,559 lines of HELP.md as a single `Markdown(text)` in a
/// ScrollView. Two things followed. Finding anything meant scrolling past everything, and
/// the guide's own Contents list — which is real Markdown, `[Getting connected](#getting-connected)`
/// — did nothing at all when tapped, because no renderer resolves in-document anchors on
/// its own and nothing here handled them.
///
/// Now it is a contents list of topics, each pushing its own short screen. The back button
/// is the return to contents, which is why there is no custom control for it: a phone
/// already has one, and inventing a second would be the wrong answer to "avoid long
/// scrolling". `HelpGuide` does the splitting, so these are the same topics the Mac's
/// Help window lists.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var topics: [HelpGuide.Topic] = []
    @State private var query = ""
    /// The stack is owned here rather than inherited, so a deep link can push a topic by
    /// appending to it. Both entry points — the Help & FAQ row and a Settings footer's
    /// "Learn more" — present this modally for the same reason: a pushed Help that also
    /// wanted to push its own topics needed two navigation destinations for one type in
    /// one stack, and SwiftUI honours whichever it likes.
    @State private var path: [HelpGuide.Topic] = []
    /// Set by anything that wants Help opened at a particular place — a Settings row's
    /// "Learn more", or the Mac's Help menu on the other platform.
    @AppStorage(HelpGuide.requestedTopicKey) private var requestedTopic = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(HelpGuide.Kind.allCases, id: \.self) { guide in
                    let matching = shown.filter { $0.guide == guide }
                    if !matching.isEmpty {
                        Section(guide == .help ? "Guide" : "FAQ") {
                            ForEach(matching) { topic in
                                NavigationLink(value: topic) { Text(topic.title) }
                            }
                        }
                    }
                }
                if shown.isEmpty, !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search help")
            .searchKeyboardDismissal()
            .navigationDestination(for: HelpGuide.Topic.self) { topic in
                HelpTopicView(topic: topic, topics: topics) { path.append($0) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .task {
            topics = HelpGuide.topics(help: Self.markdown("HELP"), faq: Self.markdown("FAQ"))
            consumeDeepLink()
        }
        .onChange(of: requestedTopic) { _, _ in consumeDeepLink() }
    }

    private var shown: [HelpGuide.Topic] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? topics : HelpGuide.ranked(topics, query: trimmed)
    }

    /// Opens the requested topic, then clears the request so re-opening Help doesn't
    /// silently jump there again.
    private func consumeDeepLink() {
        guard !requestedTopic.isEmpty, !topics.isEmpty else { return }
        if let target = topics.first(where: { $0.slug == requestedTopic }) {
            path = [target]
        }
        requestedTopic = ""
    }

    static func markdown(_ resource: String) -> String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "This guide didn't make it into this build." }
        return text
    }
}

/// One topic. Short enough to read without hunting, and its links work.
private struct HelpTopicView: View {
    let topic: HelpGuide.Topic
    /// Needed to resolve a link to another section into something to push.
    let topics: [HelpGuide.Topic]
    /// Pushing is the stack owner's job, so a followed link lands in the same history
    /// the back button walks.
    let follow: (HelpGuide.Topic) -> Void

    var body: some View {
        ScrollView {
            Markdown(topic.body)
                .markdownTextStyle(\.text) { FontSize(15) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(topic.title)
        .navigationBarTitleDisplayMode(.inline)
        // The guides cross-reference each other constantly. Left to the system these
        // open Safari at a URL that doesn't exist, or do nothing at all.
        .environment(\.openURL, OpenURLAction { url in
            guard let slug = HelpGuide.anchorSlug(from: url),
                  let target = topics.first(where: { $0.slug == slug })
            else { return .systemAction }
            follow(target)
            return .handled
        })
    }
}

/// What's New — one card per release, newest first.
///
/// This drew one large card per *change*, each with its own gradient tile, which made five
/// lines of news into a page of scrolling. The Mac has always done it the other way: a card
/// per release, a headline sentence, then a tight list where each line carries a small
/// New / Improved / Fixed tag. Same structure here now.
///
/// The notes themselves were also three releases stale — the screen said "Baton 0.3.5" over
/// a list describing 0.3.0 — which is exactly the rot `WhatsNewFreshnessTests` was written
/// to stop on the Mac. The phone now has the same guard.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    static let currentVersion = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// Last version whose notes were shown. Empty on a fresh install, which is
    /// why a first launch shows nothing — a new user needs onboarding, not a
    /// changelog.
    @AppStorage("baton.whatsNew.lastShownVersion") private static var lastShown = ""

    static var shouldShow: Bool {
        !lastShown.isEmpty && lastShown != currentVersion
    }

    static func markShown() { lastShown = currentVersion }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Self.releases) { release in
                        ReleaseCard(release: release, isLatest: release.id == Self.releases.first?.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .navigationTitle("What's New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { Self.markShown(); dismiss() }
                }
            }
        }
    }

    /// One release: header, headline, then the itemised list.
    private struct ReleaseCard: View {
        let release: ReleaseNote
        let isLatest: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Version \(release.version)").font(.headline)
                    if isLatest {
                        Text("LATEST")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green, in: Capsule())
                    }
                    Spacer()
                    Text(release.date).font(.caption).foregroundStyle(.secondary)
                }
                Text(release.highlight)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(release.changes) { change in
                        HStack(alignment: .top, spacing: 10) {
                            Text(change.kind.label.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.4)
                                .foregroundStyle(tint(for: change.kind))
                                .frame(width: 58, alignment: .leading)
                                .padding(.top, 3)
                            Text(change.text)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
        }

        /// Same three colours the Mac uses, so a "Fixed" line looks like a "Fixed" line
        /// whichever app you read it in.
        private func tint(for kind: ReleaseNote.Kind) -> Color {
            switch kind {
            case .added: .green
            case .improved: .blue
            case .fixed: .orange
            }
        }
    }

    /// Newest first. `WhatsNewFreshnessTests` fails when the top entry falls behind the
    /// shipping version — this list sat at 0.3.0 while 0.3.5 was on people's phones.
    static let releases: [ReleaseNote] = [
        ReleaseNote(
            version: "0.3.45",
            date: "August 2026",
            highlight: "Transcripts are reachable on every track, not only podcast episodes.",
            changes: [
                .init(.fixed, "The Transcript button on the player was hidden for anything that wasn't a podcast episode, so on the phone the feature simply did not exist for the music in your library, and there was no way to find out otherwise. It is shown for everything now, as the Mac's Transcript panel always has been. Nothing starts a transcription on its own, so the button was never the expensive part."),
                .init(.improved, "The transcript sheet says what it is looking at before it offers. On a song it now reads that this isn't spoken-word audio and that you can still transcribe it, rather than offering to transcribe this episode."),
            ]
        ),
        ReleaseNote(
            version: "0.3.44",
            date: "August 2026",
            highlight: "Settings now tells you whether each service is actually answering, rather than only what you typed into it.",
            changes: [
                .init(.added, "The transcription host is checked. The address just sat there before, with nothing on the phone able to say whether anything was listening at it, so the first sign of a wrong one was a podcast that never transcribed. It is asked when you open Settings and again whenever you tap the row."),
                .init(.fixed, "Scrobbling showed a green tick for anything at all in the ListenBrainz token field. A token with a character missing looked exactly like a working account, and the only place the difference appeared was a profile page with no listens on it. Baton now asks ListenBrainz whether the token is real. Last.fm is asked too, which catches a session you revoked from their own settings page \u{2014} that used to go on reading as connected while every scrobble was refused."),
                .init(.improved, "A refused password and a server that is not there now read differently, everywhere a connection is shown. They need different things from you: one is a credential to paste again, the other is a network to go and look at."),
                .init(.fixed, "Transcribing a song works again. The last release stopped asking the recogniser to skip non-speech audio when the track was music, and on one recogniser that turned a four-minute song into hundreds of repetitions of the word I, which Baton then discarded, leaving a track full of vocals reported as having no speech in it."),
            ]
        ),
        ReleaseNote(
            version: "0.3.43",
            date: "August 2026",
            highlight: "You can add a discovery key on the phone at last, and pick which services get asked.",
            changes: [
                .init(.added, "Find More Like This has a switch for each service, and somewhere to put a key. The key field only ever existed on the Mac, so the two sources that need an account could never be switched on from the phone at all, while the results sheet went on listing them as available. A key was also the only way to turn a source on, so having a Last.fm key and not wanting Last.fm results was unsayable, and there was no way at all to leave MusicBrainz out. Keys live in the Keychain now, and a Test button says whether one works before you save it."),
                .init(.fixed, "The music friend was being told the artist was Optional(\u{201C}Debussy\u{201D}). Every request carries a line about what is playing, and it passed the artist through unwrapped, so the friend read the debugger\u{2019}s spelling of the name, or nothing at all when a tag was missing. The placeholder [unknown] was reaching the like, rate and similar-songs replies the same way."),
                .init(.fixed, "All of these need the experimental audio engine switched on in Settings, Advanced. Mute did nothing. A route change while paused froze the playhead, so unplugging headphones and carrying on left the track stuck. A route change also threw away audio already on the phone and fetched it again. A dead stream could hang, or cost half a minute of silence before the queue moved on. And seeking inside a track your server does not transcode re-fetched it from the beginning, which on a long set made those tracks close to unplayable."),
            ]
        ),
        ReleaseNote(
            version: "0.3.42",
            date: "August 2026",
            highlight: "The player fits the screen, and lyrics actually turn up.",
            changes: [
                .init(.fixed, "The full-screen player pushed its bottom row past the edge of the screen \u{2014} on a smaller iPhone the star rating sat under the home indicator, or below it. The stack now shares its spare room top and bottom instead of pooling it in one place, and keeps a proper margin under the last control. Checked on the smallest iPhone and at the large accessibility text sizes."),
                .init(.improved, "Lyrics turn up far more often. A track tagged \u{201C}Wearing My Shoes (Louis Bailar\u{2019}s radio Chillout)\u{201D} by \u{201C}Aura feat. Dani Senior\u{201D} is filed under a slightly different remix name by just \u{201C}Aura\u{201D}, and an exact match cannot survive that. Baton now searches as well, and accepts a match only when the track length agrees \u{2014} so the right words scroll against the right song, or none do. Songs played from an album or the queue were never looked up at all before."),
                .init(.added, "Find More Like This, on any track. \u{201C}More like this\u{201D} has always meant the music you already have; this asks the public catalogues what else is out there and hands you a link. The music friend can do it too. Off until you turn it on in Settings: it sends the artist and title and nothing else, and two of its four sources need no account."),
                .init(.improved, "Unsubscribing from a podcast now travels between your iPhone and your Mac. It used to be handed straight back by whichever device still had the show."),
                .init(.fixed, "The Downloads row in Library counted the things you had saved for later rather than the things you had downloaded."),
            ]
        ),
        ReleaseNote(
            version: "0.3.41",
            date: "August 2026",
            highlight: "No more \u{201C}Unknown\u{201D} under the title.",
            changes: [
                .init(.improved, "An artist Baton doesn\u{2019}t know is simply not shown now, instead of the word \u{201C}Unknown\u{201D} sitting under the track title. The line is left out entirely, so the title gets the room."),
                .init(.fixed, "Titles imported from YouTube carried odd full-width lookalikes where quotes, pipes and slashes belong. A downloader substitutes those because they cannot go in a filename, and the filenames became tags. They read normally now. Emoji, capitals and long names are left exactly as they are \u{2014} those are yours."),
            ]
        ),
        ReleaseNote(
            version: "0.3.40",
            date: "August 2026",
            highlight: "Mixes shaped by mood now listen to your music.",
            changes: [
                .init(.improved, "Ask for something upbeat or something calmer and Baton uses tempo measured from your own audio, not just the BPM tag your server happened to have. Most libraries tag almost nothing, so those requests used to reorder a handful of tracks and leave the rest alone. It measures only tracks already on your device, and never downloads anything to do it."),
                .init(.improved, "The music friend on the Mac gained a microphone and spoken replies, so both apps now work the same way. What you rate in either still counts once."),
            ]
        ),
        ReleaseNote(
            version: "0.3.39",
            date: "August 2026",
            highlight: "Your music friend is on the Mac now too, and it is the same one.",
            changes: [
                .init(.added, "Baton on the Mac has a music friend window of its own. It is the same friend you talk to here: what it has learned about you it knows in both places, and a thumbs-down you give on one counts on the other."),
                .init(.improved, "Help gained a section about the music friend, covering the phone, the Mac and the Telegram and Discord bridges in one place."),
            ]
        ),
        ReleaseNote(
            version: "0.3.38",
            date: "August 2026",
            highlight: "Remove the track that's up next and the right one still plays.",
            changes: [
                .init(.fixed, "With gapless on, removing the track queued up next could leave its audio playing under the following track's name: the player showed one song and sounded another. Baton was matching the queued track by its position in the queue, and a removal shifts a different song into that position."),
            ]
        ),
        ReleaseNote(
            version: "0.3.37",
            date: "August 2026",
            highlight: "Scroll down and the bottom of the screen gets out of the way.",
            changes: [
                .init(.improved, "Scrolling down collapses the tab bar to the current tab's icon and tucks the mini player in beside it, so browsing a long list gives you one compact row instead of two stacked bars. Scroll up or tap to bring both back. The tabs themselves never change, and iPad keeps its own layout."),
                .init(.improved, "In that compact row the mini player keeps the artwork, the title and play/pause, and lets the next and close buttons go. It has about two-thirds of the width there, and those are the parts worth keeping."),
            ]
        ),
        ReleaseNote(
            version: "0.3.36",
            date: "August 2026",
            highlight: "Every list you can filter now puts the keyboard away the same way.",
            changes: [
                .init(.improved, "Typing to filter Albums, Artists, Folders, Genres, Playlists, Liked, Radio or Help all behave alike: scroll the list and the keyboard goes, which also brings back the tab bar it was covering. Each of those screens used to have its own idea, and three of them had no idea at all."),
                .init(.fixed, "Clearing a filter with the small x dropped the keyboard instead of leaving you typing, on the screens that manage their own search field."),
                .init(.improved, "At the largest accessibility text sizes the A\u{2013}Z letters down the edge are hidden rather than shrunk. They cannot grow without eating the list they point at, and every one of those screens now has a filter, which is the better way through a long list at that size."),
                .init(.fixed, "The send and microphone buttons in Music Friend had no names, so VoiceOver read the send button as \u{201C}arrow up circle fill\u{201D}."),
            ]
        ),
        ReleaseNote(
            version: "0.3.35",
            date: "August 2026",
            highlight: "The keyboard stops taking a row of the screen with it.",
            changes: [
                .init(.improved, "Typing in Search or in Music Friend no longer puts a \u{201C}Done\u{201D} bar above the keyboard. Drag the results or the conversation downward to put the keyboard away, tap the conversation in Music Friend, or press Search on the keyboard itself. The bar was a fourth way to do what those already did, and it cost a row of the screen every time you typed."),
            ]
        ),
        ReleaseNote(
            version: "0.3.34",
            date: "August 2026",
            highlight: "Square artist artwork, and one button where there were three outlines.",
            changes: [
                .init(.improved, "Artist pictures are square now, wherever they appear. The round crop crossed the edges off the group shots it was meant to flatter \u{2014} and artists were the only circular artwork in the app."),
                .init(.fixed, "The grid/list control drew a box inside the toolbar's own box, with a third around whichever side was selected. It is a single button showing the layout you would switch to, which also makes it a bigger thing to hit."),
            ]
        ),
        ReleaseNote(
            version: "0.3.33",
            date: "August 2026",
            highlight: "Genres reads like the rest of the library, and Artists fills the screen again.",
            changes: [
                .init(.improved, "Genres is a list now, like Folders. It was a grid of cards where an icon took a third of each one and the names were squeezed into what was left \u{2014} long genres came out as \u{201C}Castlevania\u{2026}\u{201D}. Full width, full names."),
                .init(.fixed, "Artists in grid layout showed one enormous circle at a time on smaller iPhones. Two columns again, and the tiles are the same ones the rest of the app uses \u{2014} which also gives them their artwork shadow and reads as a single item to VoiceOver."),
            ]
        ),
        ReleaseNote(
            version: "0.3.32",
            date: "August 2026",
            highlight: "Filter any long list, and an A\u{2013}Z rail that matches what it points at.",
            changes: [
                .init(.added, "Filter albums, genres and playlists by typing, the way Artists, Folders and Liked already could. Albums is the biggest list in the app and had no way to narrow it at all \u{2014} the header says how many of your albums match while you type."),
                .init(.fixed, "The A\u{2013}Z letters on Artists and Folders were built from track names rather than from your server's own index, so on a library with more than one alphabet they ran in an order the rows underneath them did not follow. Baton now uses the index the server already computed, which matches the list by definition."),
                .init(.fixed, "Genres and the Albums and Artists tabs of Liked drew A\u{2013}Z letters over lists that were not in alphabetical order \u{2014} genres are ordered by how much music you have in them \u{2014} so tapping a letter jumped somewhere arbitrary. Those lists have a filter instead."),
                .init(.fixed, "The letters sat on top of the arrows at the end of each row, because the rail was given less room than it takes up."),
            ]
        ),
        ReleaseNote(
            version: "0.3.31",
            date: "August 2026",
            highlight: "The A\u{2013}Z letters stop sitting on top of your lists.",
            changes: [
                .init(.fixed, "The A\u{2013}Z rail down the right edge of Artists, Folders, Liked, Playlists and Genres drew on top of the rows, with the letters landing on the arrows at the end of each line. The lists now leave the rail a column of its own."),
            ]
        ),
        ReleaseNote(
            version: "0.3.30",
            date: "August 2026",
            highlight: "Widgets that show your artwork, and a lock screen that keeps time.",
            changes: [
                .init(.fixed, "Tapping the Now Playing widget opened the app and restarted the track from the beginning, throwing away your queue. It takes you to the player now, which is what a tap on \u{201C}what is playing\u{201D} should do."),
                .init(.fixed, "The Lock Screen clock drifted behind podcasts played faster than 1\u{00D7}, falling further behind the longer an episode ran. Baton was telling iOS the wrong playback speed."),
                .init(.added, "The widget draws your cover art, in lock screen and StandBy sizes as well as on the Home Screen, with play/pause and next you can tap without opening the app."),
                .init(.added, "Skip back and forward 15 seconds on the Lock Screen for podcasts, and like the current track from there or from CarPlay."),
                .init(.added, "Playback speed for podcasts in the player itself, instead of only from the show\u{2019}s page."),
                .init(.added, "Separate Wi\u{2011}Fi and cellular streaming quality. Baton has always been able to ask the server for a smaller stream and never did."),
                .init(.added, "Lyrics from LRCLIB when your files have none \u{2014} off by default, since it is the one lookup that leaves your own server."),
                .init(.improved, "Podcasts, Radio, Artists and Playlists in grid layout were missing their content, their refresh and their add button entirely."),
                .init(.improved, "Cover art is cached properly, so scrolling a large library stops re-downloading and re-decoding artwork it just showed."),
                .init(.improved, "The player fits at the largest text sizes instead of pushing the transport off the screen, and the mini bar\u{2019}s buttons are thumb-sized."),
                .init(.improved, "VoiceOver reads an album as one item rather than three, and your server address is behind a biometric check as the screen always claimed."),
                .init(.fixed, "Queueing the same song twice made the queue reorder and delete the wrong rows."),
                .init(.fixed, "Downloads updates while you watch it, and shows what is still downloading."),
                .init(.fixed, "A track over an hour long showed a nonsense time everywhere it appeared."),
                .init(.improved, "The player closes with a chevron rather than a \u{201C}Done\u{201D} button. Nothing was being finished \u{2014} the music keeps playing and the player drops back into the mini bar, which is what the arrow says and what the Mac has always done."),
                .init(.improved, "The Music Friend\u{2019}s composer lines up with the mini player and the tab bar below it. It was a full-width bar sitting under two floating capsules, so the send button looked like it was hanging off the edge."),
                .init(.added, "The A\u{2013}Z rail is on Liked, Playlists and Genres now, not just Albums, Artists and Folders. Liked is the list that grows without bound and was the one long alphabetical list with no way to jump."),
            ]
        ),
        ReleaseNote(
            version: "0.3.29",
            date: "August 2026",
            highlight: "Tell the music friend when it gets it wrong.",
            changes: [
                .init(.added, "A thumbs up or down under each of the friend's answers. A thumbs-down asks which of four things went wrong \u{2014} wrong track, misunderstood, too slow, too chatty \u{2014} because \u{201C}bad\u{201D} is not something anyone can act on."),
                .init(.added, "A Friend log, from the list button at the top of the Friend screen. Every conversation, what the friend actually did about it, what it was looking at when it chose, and whether you skipped the track straight away. Faults are counted so you can see what goes wrong most."),
                .init(.added, "It learns. Tell it \u{201C}I meant the Classic Trance playlist\u{201D} and that becomes something it knows about you, listed in the log and removable with a swipe."),
                .init(.improved, "The like heart moved to the bottom-right corner of the artwork in the player, where the Mac has always kept it \u{2014} and it no longer appears on every row of a list where everything is liked."),
                .init(.fixed, "The Lock Screen card could name a different track than the system did, when a track advanced on its own."),
                .init(.fixed, "On the experimental engine: pausing and immediately picking another track left the new one silent, a pause during loading was ignored while the app showed paused, and a stream that ended early could skip to the next track mid-song."),
            ]
        ),
        ReleaseNote(
            version: "0.3.28",
            date: "August 2026",
            highlight: "The experimental engine stops working when you stop listening.",
            changes: [
                .init(.improved, "With the experimental audio engine on, Baton kept its audio pipeline running while paused \u{2014} rendering silence for as long as the app was open. Measured on the Mac, paused cost more power than actually playing music. It now lets the pipeline sleep when nothing is playing."),
                .init(.improved, "The level meter no longer runs when the engine is not the one playing. It was analysing silence about forty times a second, for the life of the app."),
                .init(.improved, "Baton asks iOS for larger audio buffers, which roughly quarters how often the system has to wake up to feed it. Long-form music does not need the low latency a game or an instrument does."),
            ]
        ),
        ReleaseNote(
            version: "0.3.27",
            date: "August 2026",
            highlight: "A crash after phone calls, on the experimental engine.",
            changes: [
                .init(.fixed, "With the experimental audio engine on, a phone call could leave Baton unable to play again \u{2014} the next track you tapped could take the app down with it, often minutes later and with no obvious connection to the call. An interruption stops the audio engine, and nothing was starting it back up."),
                .init(.improved, "The equalizer now says where it actually applies. On the standard player it affects downloaded tracks only \u{2014} music streamed from your server is untouched, which has always been true and was never stated. Turn on the experimental audio engine to equalize streams too."),
            ]
        ),
        ReleaseNote(
            version: "0.3.26",
            date: "August 2026",
            highlight: "A volume control, at last.",
            changes: [
                .init(.added, "The full player has a volume slider. Baton has always had its own level \u{2014} the Mac has carried a slider for it all along \u{2014} but on the phone there was no way to see or change it, so if you asked the music friend to turn the music down there was nothing to turn it back up with."),
                .init(.fixed, "Starting a radio from a track listed that track twice at the top of the queue, with the playing indicator on both rows."),
                .init(.fixed, "Radios started by asking the music friend now skip tracks you have kept out of radios, like every other way of starting one."),
            ]
        ),
        ReleaseNote(
            version: "0.3.25",
            date: "August 2026",
            highlight: "Pausing is quiet again, and the lock screen stops collecting cards.",
            changes: [
                .init(.fixed, "On the experimental audio engine, pausing faded the music out and then let a fraction of a second back in at full volume before it stopped. The fade hands the volume back when it finishes, which is silent on the standard player because it has genuinely stopped \u{2014} the new engine still had a little audio in flight."),
                .init(.fixed, "Baton could leave more than one \u{201C}now playing\u{201D} card on the Lock Screen, with only the newest one updating. A card outlives the app that started it, so after reopening Baton it started a second one beside the first. It now adopts the card that is already there."),
                .init(.improved, "That Lock Screen card is quieter \u{2014} plainer text, one muted icon instead of two bright ones. It is a label, not an announcement."),
            ]
        ),
        ReleaseNote(
            version: "0.3.24",
            date: "August 2026",
            highlight: "The playhead no longer jumps when you skip to the next track.",
            changes: [
                .init(.fixed, "On the experimental audio engine, pressing Next briefly threw the progress bar to somewhere in the middle of the new track before it snapped back to the start. The old track's position was still being published by the system player's clock while the new engine played the new track \u{2014} two things writing one number. The system player now stands down while the engine is playing."),
            ]
        ),
        ReleaseNote(
            version: "0.3.23",
            date: "August 2026",
            highlight: "The experimental engine switch now actually does something.",
            changes: [
                .init(.fixed, "Turning on the experimental audio engine did nothing until you next launched Baton, so music kept playing through the standard player and equalizer presets stayed silent on streamed music \u{2014} which looked like a broken equalizer rather than a switch that wasn't connected. It now applies straight away, to whatever is playing, which is what the text under it always claimed."),
            ]
        ),
        ReleaseNote(
            version: "0.3.22",
            date: "August 2026",
            highlight: "An equalizer that works on music streamed from your server.",
            changes: [
                .init(.added, "Settings \u{2192} Advanced \u{2192} Experimental audio engine. Baton plays music streamed from your server through its own audio pipeline instead of the system player. This is what makes the equalizer and the moving bars work on streamed music \u{2014} until now they only ever affected downloaded tracks, on every version of Baton there has been. Podcasts, downloads and radio keep using the standard player. It is off by default, and while it is on, gapless and crossfade are skipped, so track changes are plain cuts."),
                .init(.improved, "It is genuinely experimental: it is new, it is off unless you turn it on, and if anything about it sounds wrong, turning it off puts you back on the player Baton has always used."),
            ]
        ),
        ReleaseNote(
            version: "0.3.21",
            date: "August 2026",
            highlight: "One mark for the playing track, everywhere.",
            changes: [
                .init(.fixed, "Up Next showed a speaker beside the playing track while the same track in search results showed moving bars. Every list in the app now uses the same mark, and it moves only while music is actually playing."),
            ]
        ),
        ReleaseNote(
            version: "0.3.20",
            date: "August 2026",
            highlight: "Real music in the demo, and a shuffle button that tells you where it stands.",
            changes: [
                .init(.improved, "The demo library is now a real recording — four movements of Bach's Goldberg Variations, played by Kimiko Ishizaka and released into the public domain. It replaces the synthesized tones that were there to avoid a licensing problem."),
                .init(.improved, "The Shuffle button shows whether shuffle is on, and pressing it again stops shuffling. Stopping part-way through an album keeps playing from where you are rather than starting the record again."),
                .init(.improved, "The mark beside the playing track is now moving bars rather than a still symbol, so a glance tells you whether music is running or paused."),
                .init(.improved, "An album page now says how many tracks, how long, what year and what genre; its artist opens the artist; and Download, Like, Play Next and Add to Queue moved into a menu so the track listing starts higher up the screen."),
                .init(.improved, "The music friend's message box is rounded like everything around it."),
            ]
        ),
        ReleaseNote(
            version: "0.3.19",
            date: "August 2026",
            highlight: "Shuffle that stays on, grids where you want them, and a player that fits the iPad.",
            changes: [
                .init(.added, "Artists, Playlists, Liked, Podcasts and Radio can each be shown as a grid or a list, the way Albums already could and the way the Mac has always offered. Each screen remembers your choice."),
                .init(.improved, "On iPad the player is a properly proportioned capsule instead of a band spanning the whole screen, cards are drawn at a size that suits the canvas, and text no longer runs the full width of a 13-inch display."),
                .init(.improved, "The search field matches the filter fields elsewhere in the app, and the music friend's message box is Baton's own rather than the stock iOS one."),
                .init(.fixed, "Pressing Shuffle on an album, artist, playlist or mix now turns shuffle on, instead of quietly playing a shuffled queue while the player's own shuffle button still read \"off\"."),
                .init(.improved, "The now-playing mark in track lists animates while music is actually playing and holds still when it isn't. Before, playing and paused looked identical."),
            ]
        ),
        ReleaseNote(
            version: "0.3.18",
            date: "August 2026",
            highlight: "Mix cards that look like the Mac's.",
            changes: [
                .init(.improved, "Mix cards now carry the same artwork as the Mac — the painted backdrops for Most Played, Just Added, Top Rated and the rest, and the same generated one for genre and server mixes. The phone was drawing a flat colour tile of its own invention."),
                .init(.improved, "The art and the code that draws it are now shared between the two apps, so a card can't look like one product on the Mac and another on the phone."),
            ]
        ),
        ReleaseNote(
            version: "0.3.17",
            date: "August 2026",
            highlight: "Album art you can see all of.",
            changes: [
                .init(.improved, "Artwork that isn't square is shown whole instead of cropped to the tile — over a softly blurred copy of itself, the way the Mac has always drawn its cards. A 16:9 thumbnail was losing its outer thirds on the phone."),
                .init(.improved, "Album grids, artist and album headers, and the full-screen player all draw this way. Small row thumbnails are unchanged."),
            ]
        ),
        ReleaseNote(
            version: "0.3.16",
            date: "August 2026",
            highlight: "Search remembers what you typed — on both devices.",
            changes: [
                .init(.added, "Search now keeps the queries you typed, not just the albums and artists you opened. Tap one to run it again."),
                .init(.added, "Both lists are shared with your Mac. A search made there is one tap away here, and the other way round."),
                .init(.improved, "The shared lists are merged rather than overwritten, so a search made on one device is never dropped because the other synced more recently."),
                .init(.improved, "Albums and artists you opened are remembered per server, so signing in to a second library doesn't show you rows that lead nowhere."),
            ]
        ),
        ReleaseNote(
            version: "0.3.15",
            date: "August 2026",
            highlight: "How long everything is, and a listening history that counts every device.",
            changes: [
                .init(.added, "Track lists show each song's length — search results, playlists, folders, liked songs, downloads, history and an album's track listing."),
                .init(.added, "Up Next shows how long each track runs and totals what's still to play: \"11 tracks left · 49m\"."),
                .init(.added, "Albums in list view and liked albums show their total play time alongside the artist and year."),
                .init(.added, "History now reads from your server by default, so Recent includes what you played on the Mac. Switch to \"This iPhone\" for the on-device log, which still works with no connection."),
                .init(.fixed, "Disconnecting from Settings left you looking at the settings of a server you had just disconnected from, instead of the setup screen."),
                .init(.improved, "Pausing, stopping and resuming now actually sound like fades. The previous ramp was short and linear, which the ear reads as a cut — in a car it was inaudible. It is longer now, shaped to how loudness is actually perceived, and resuming eases back in instead of snapping on."),
                .init(.fixed, "Changing the volume while a track was fading out snapped it back to full volume for the rest of the fade."),
                .init(.fixed, "Signing in to a different server inherited the previous account's History scope."),
            ]
        ),
        ReleaseNote(
            version: "0.3.14",
            date: "August 2026",
            highlight: "Browsing that scales to a real library — jump by letter, browse by folder, and make the Library list yours.",
            changes: [
                .init(.added, "An A–Z rail on Albums, Artists and Folders. Drag it to jump — 2,604 albums is no longer a flick marathon."),
                .init(.added, "Folders: browse the library the way it sits on disk, on both the Mac and the phone. Play any folder top to bottom."),
                .init(.added, "Go to Album and Go to Artist from the player and any song's menu. The player was a dead end."),
                .init(.added, "Search remembers the albums and artists you opened — they wait under the empty search field."),
                .init(.added, "Edit the Library tab: hide sections you never use, reorder the rest."),
                .init(.added, "The queue says what's feeding it — \"Playing from Albums\" — on both apps."),
                .init(.improved, "Playlists show their play time and sort by name, songs or length; a filter field inside big playlists."),
                .init(.improved, "The player shows the stream's format and bitrate, and tapping the duration shows time remaining."),
                .init(.improved, "Albums can be a grid or a dense list, and sort by year. A keep-screen-awake switch in Settings."),
            ]
        ),
        ReleaseNote(
            version: "0.3.13",
            date: "August 2026",
            highlight: "A stuck track that nothing could stop, softer stops, and podcasts that follow you.",
            changes: [
                .init(.fixed, "A crossfade could leave a second track playing that no button could silence — every song you picked afterwards played on top of it. It can't happen now."),
                .init(.improved, "Pausing and stopping fade over about a tenth of a second instead of cutting mid-waveform, which is what made them click."),
                .init(.added, "Podcast subscriptions travel between your Mac and your phone. Subscribe on one and the other picks it up; episodes are still fetched fresh on each device."),
            ]
        ),
        ReleaseNote(
            version: "0.3.12",
            date: "August 2026",
            highlight: "The album grid lines up again.",
            changes: [
                .init(.fixed, "Covers that aren't square — a lot of them, in a real library — made their grid cell wider than the column, so rows went ragged and album titles ran off the edge. Every cell is now the same square, whatever shape the artwork is."),
            ]
        ),
        ReleaseNote(
            version: "0.3.11",
            date: "August 2026",
            highlight: "Trying the public demo server is one tap, and it tells you when that server is down.",
            changes: [
                .init(.improved, "\"Use Navidrome's public demo server\" now checks the server and signs you in, instead of filling the form and leaving you to press Connect."),
                .init(.added, "If their server isn't answering, Baton says so — and offers the built-in demo, which needs no connection at all."),
            ]
        ),
        ReleaseNote(
            version: "0.3.10",
            date: "August 2026",
            highlight: "The microphone no longer crashes the app.",
            changes: [
                .init(.fixed, "Tapping the microphone in Music Friend crashed Baton outright. It asks for permission on a background queue, and the reply was being handled as though it were on the main one."),
                .init(.improved, "Settings moved out of the tab bar into Home's top-right corner, so Search is no longer hidden behind a \"More\" menu when the Friend tab is on."),
            ]
        ),
        ReleaseNote(
            version: "0.3.9",
            date: "August 2026",
            highlight: "You can put the keyboard away again.",
            changes: [
                .init(.fixed, "Music Friend and Search had no way to dismiss the keyboard — and since the keyboard covers the tab bar, no way off the screen either. Drag the list down, tap the background, or use Done above the keyboard."),
            ]
        ),
        ReleaseNote(
            version: "0.3.8",
            date: "August 2026",
            highlight: "The queue gets a screen, ratings show what they are, and Settings tells you whether your server is actually answering.",
            changes: [
                .init(.added, "Settings shows whether your server is really connected — checked by asking it, not by assuming. It tells a refused password apart from a server that isn't there."),
                .init(.improved, "Up Next opens as its own screen. It used to share the player with the artwork and controls, leaving about one and a half rows visible — not enough to reorder anything."),
                .init(.fixed, "The rating control showed a single star whatever a song scored, and its menu marked nothing as chosen. Five tappable stars now, as on the Mac; tap the star you're on to clear it."),
                .init(.fixed, "A song's context menu now marks its current rating and says the score rather than a bare \"Rate\"."),
            ]
        ),
        ReleaseNote(
            version: "0.3.7",
            date: "August 2026",
            highlight: "The quick ways to get set up are where you can actually see them.",
            changes: [
                .init(.fixed, "Setting up from a Mac and trying Navidrome's public demo server sat below the sign-in form, so the two routes for people with nothing to type were the hardest things on the screen to find. Both are at the top now."),
            ]
        ),
        ReleaseNote(
            version: "0.3.6",
            date: "August 2026",
            highlight: "Settings that explain themselves, Help you can navigate, and a public demo server to try Baton against.",
            changes: [
                .init(.added, "Try Baton against Navidrome's own public demo server — no server of your own required."),
                .init(.added, "Help is a searchable list of topics now, instead of one very long page. Its contents links work."),
                .init(.added, "Every group of settings says in plain words what it does, with a link to the full explanation."),
                .init(.added, "The player gained a Related panel — songs your server thinks belong with this one."),
                .init(.added, "Downloads shows what failed and offers to retry, plus how much space they use."),
                .init(.fixed, "The equalizer's presets did nothing. Choosing one now actually changes the sound."),
                .init(.fixed, "The preset row went blank whenever you moved a slider. It names the curve you have."),
                .init(.fixed, "Connecting to a server from Settings opened a screen with no way back out."),
                .init(.fixed, "Setting up from a Mac pointed at menus that don't exist."),
            ]
        ),
        ReleaseNote(
            version: "0.3.5",
            date: "August 2026",
            highlight: "Every screen opens the same way, with the space given back to your music.",
            changes: [
                .init(.improved, "Home, Albums, Library, Search and Settings all share one header and open at the same height — about a tenth of the screen reclaimed."),
                .init(.improved, "Each screen's header says what's on it: how many albums, how many playlists, which server."),
                .init(.fixed, "The mini player drew a second background inside the system one, leaving its rounded ends unpainted."),
            ]
        ),
        ReleaseNote(
            version: "0.3.4",
            date: "August 2026",
            highlight: "Bringing your Mac's setup across, without the file hunt.",
            changes: [
                .init(.added, "Settings → Set up from a Mac offers both scanning a code and importing a file, and says what each one needs."),
                .init(.fixed, "The pairing scanner was only reachable during first-run setup, so a phone that was already connected could never get to it."),
            ]
        ),
        ReleaseNote(
            version: "0.3.0",
            date: "August 2026",
            highlight: "Pair with a Mac, and settings that follow you between devices.",
            changes: [
                .init(.added, "Set up by scanning a code your Mac shows — no typing a server address or a password."),
                .init(.added, "Equalizer, crossfade, radio bans and your music friend's setup can travel between devices through your Baton gateway."),
                .init(.added, "Face ID guards your music friend's API key and gateway token. Playing music never asks."),
                .init(.improved, "Every screen takes its colour from the cover that's playing, the way the Mac does."),
                .init(.improved, "All-time top tracks come from your server, so what you played on the Mac counts too."),
                .init(.fixed, "Disconnecting now really disconnects — downloads, history and accounts — and says what it will delete first."),
                .init(.fixed, "A dropped connection no longer sends you back to the sign-in screen."),
            ]
        ),
    ]
}
