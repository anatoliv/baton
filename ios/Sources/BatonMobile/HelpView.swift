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
