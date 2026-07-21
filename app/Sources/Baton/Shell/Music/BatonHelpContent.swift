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
    static let all: [HelpWhatsNewRelease] = [
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
