import AppKit
import MarkdownUI
import SwiftUI

// In-app Help window for Baton — a two-pane help center that renders the
// bundled HELP.md and FAQ.md guides with sidebar navigation, in-window
// keyword search, working cross-links, callout boxes, a What's New panel,
// and guided tours. Opened from the Help menu (⌘?). Modeled on Tonebox's
// help center, adapted to Baton (no design-token module, no on-device
// embedder — keyword search only).

// MARK: - Local design tokens

/// A tiny local token set so this file doesn't depend on a design system.
enum HelpTokens {
    static let accent = Color.batonOrange
    static let rowHeight: CGFloat = 22
    static let paneCurve = Animation.easeInOut(duration: 0.2)

    enum Space {
        static let row6: CGFloat = 6
        static let tight: CGFloat = 8
        static let medium: CGFloat = 10
        static let snug: CGFloat = 12
        static let element: CGFloat = 14
        static let regular: CGFloat = 16
        static let wide: CGFloat = 20
        static let pane: CGFloat = 24
    }

    enum Radius {
        static let control: CGFloat = 8
        static let card: CGFloat = 10
    }

    enum Fonts {
        static let title = Font.system(size: 17, weight: .semibold)
        static let small = Font.system(size: 12)
        static let tiny = Font.system(size: 10)
    }
}

// MARK: - Help window

struct BatonHelpView: View {
    /// Scene identifier for the Help window.
    static let windowID = "baton-help"
    /// Sidebar-selection id for the What's New panel.
    static let whatsNewID = "whatsnew"
    /// Prefix for sidebar-selection ids that point at a guided tour.
    private static let tourIDPrefix = "tour#"

    // MARK: Model

    /// Which bundled guide a topic comes from.
    private enum Guide: String {
        case help
        case faq

        var resource: String { self == .help ? "HELP" : "FAQ" }
        var sidebarTitle: String { self == .help ? "Help guide" : "FAQ" }
        var badge: String { self == .help ? "HELP GUIDE" : "FAQ" }
    }

    /// A GitHub-style alert kind parsed from `> [!NOTE]` blockquotes.
    enum CalloutKind {
        case note, tip, important, warning

        var label: String {
            switch self {
            case .note: "Note"
            case .tip: "Tip"
            case .important: "Important"
            case .warning: "Warning"
            }
        }

        var symbol: String {
            switch self {
            case .note: "info.circle.fill"
            case .tip: "lightbulb.fill"
            case .important: "exclamationmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .note: .blue
            case .tip: .green
            case .important: HelpTokens.accent
            case .warning: .orange
            }
        }
    }

    /// One `##`-delimited section of a guide — a single sidebar entry.
    private struct Topic: Identifiable, Hashable {
        let guide: Guide
        let title: String
        let slug: String
        /// Section Markdown with its heading line removed.
        let body: String

        var id: String { "\(guide.rawValue)#\(slug)" }
        var symbol: String { BatonHelpView.symbol(for: title) }
        var searchText: String { (title + " " + body).lowercased() }

        static func == (lhs: Topic, rhs: Topic) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// A renderable chunk of a topic — Markdown or a callout.
    private enum Block {
        case markdown(String)
        case callout(CalloutKind, String)
    }

    // MARK: State

    @State private var topics: [Topic]
    @State private var selection: String?
    @State private var query = ""

    /// Set elsewhere in the app (e.g. `HelpMenuCommands`) to deep-link the
    /// window straight to a topic when it opens.
    @AppStorage("baton.help.requestedTopic") private var requestedTopic = ""

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow

    init() {
        let loaded = Self.buildTopics()
        _topics = State(initialValue: loaded)
        _selection = State(initialValue: loaded.first?.id)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedTopic: Topic? {
        topics.first { $0.id == selection }
    }

    private var results: [Topic] {
        keywordRanked(for: trimmedQuery)
    }

    private var selectedTour: HelpTour? {
        guard let selection, selection.hasPrefix(Self.tourIDPrefix) else { return nil }
        let tourID = String(selection.dropFirst(Self.tourIDPrefix.count))
        return HelpTour.all.first { $0.id == tourID }
    }

    // MARK: Body

    var body: some View {
        // A plain HStack, not NavigationSplitView: the latter pins its
        // window to a fixed height that `.frame` can't override. An HStack
        // honors `.frame`, so the window opens at a sensible size and the
        // panes scroll.
        HStack(spacing: 0) {
            sidebar
                .frame(width: 268)
            Divider()
            detail
                .frame(maxWidth: .infinity)
        }
        .frame(
            minWidth: 760, maxWidth: .infinity,
            minHeight: 420, maxHeight: helpHeightCap
        )
        .background(HelpWindowSizer())
        .onAppear { applyRequestedTopic() }
        .onChange(of: requestedTopic) { applyRequestedTopic() }
    }

    /// Upper bound for the window height — the usable screen height, so it
    /// never opens off-screen.
    private var helpHeightCap: CGFloat {
        let usable = (NSScreen.main?.visibleFrame.height ?? 760) - 40
        return min(900, max(460, usable))
    }

    /// Honors a deep-link request, then clears it so the same topic isn't
    /// re-selected on the next change.
    private func applyRequestedTopic() {
        let slug = requestedTopic
        guard !slug.isEmpty else { return }
        if slug == Self.whatsNewID {
            query = ""
            selection = Self.whatsNewID
        } else if let target = topics.first(where: { $0.slug == slug }) {
            query = ""
            selection = target.id
        }
        requestedTopic = ""
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            List(selection: $selection) {
                if trimmedQuery.isEmpty {
                    whatsNewRow
                    Section(Guide.help.sidebarTitle) {
                        ForEach(topics.filter { $0.guide == .help }) { topicRow($0) }
                    }
                    Section("Guided tours") {
                        ForEach(HelpTour.all) { tourRow($0) }
                    }
                    Section(Guide.faq.sidebarTitle) {
                        ForEach(topics.filter { $0.guide == .faq }) { topicRow($0) }
                    }
                } else if results.isEmpty {
                    Text("No results for \u{201C}\(trimmedQuery)\u{201D}")
                        .font(HelpTokens.Fonts.small)
                        .foregroundStyle(.secondary)
                } else {
                    Section(results.count == 1 ? "1 result" : "\(results.count) results") {
                        ForEach(results) { resultRow($0) }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    /// In-window search field.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search Help & FAQ", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, HelpTokens.Space.snug)
        .padding(.vertical, HelpTokens.Space.row6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: HelpTokens.Radius.card))
        .padding(HelpTokens.Space.medium)
    }

    private func topicRow(_ topic: Topic) -> some View {
        Label(topic.title, systemImage: topic.symbol)
            .tag(topic.id)
    }

    private var whatsNewRow: some View {
        Label("What's New", systemImage: "megaphone")
            .tag(Self.whatsNewID)
    }

    private func tourRow(_ tour: HelpTour) -> some View {
        Label(tour.title, systemImage: tour.symbol)
            .tag(Self.tourIDPrefix + tour.id)
    }

    private func resultRow(_ topic: Topic) -> some View {
        HStack(spacing: 8) {
            Image(systemName: topic.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(topic.title)
                Text(topic.guide.sidebarTitle)
                    .font(HelpTokens.Fonts.tiny)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(topic.id)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if selection == Self.whatsNewID {
            WhatsNewDetailView(releases: HelpWhatsNewRelease.all)
        } else if let tour = selectedTour {
            TourDetailView(
                tour: tour,
                markdownTheme: markdownTheme,
                onFinish: { selection = topics.first?.id }
            )
        } else if let topic = selectedTopic {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(topic)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(Array(blocks(from: topic.body).enumerated()), id: \.offset) { _, block in
                                blockView(block)
                            }
                        }
                        .id("help-detail-top")
                        .textSelection(.enabled)
                        .markdownTheme(markdownTheme)
                        .environment(\.openURL, linkAction)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, HelpTokens.Space.pane)
                        .padding(.vertical, HelpTokens.Space.wide)
                    }
                    .onChange(of: selection) {
                        proxy.scrollTo("help-detail-top", anchor: .top)
                    }
                }
            }
        } else {
            VStack(spacing: HelpTokens.Space.medium) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Baton Help")
                    .font(.title3.weight(.semibold))
                Text("Pick a topic from the sidebar, or search to jump straight to an answer.")
                    .font(HelpTokens.Fonts.small)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ topic: Topic) -> some View {
        VStack(alignment: .leading, spacing: HelpTokens.Space.row6) {
            HStack(alignment: .center, spacing: HelpTokens.Space.tight) {
                Label(topic.title, systemImage: topic.symbol)
                    .font(HelpTokens.Fonts.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: HelpTokens.Space.tight)
            }
            .frame(height: HelpTokens.rowHeight)
            HStack(spacing: HelpTokens.Space.tight) {
                Text(topic.guide.badge)
                    .font(HelpTokens.Fonts.tiny.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                Spacer()
            }
            .frame(height: HelpTokens.rowHeight)
        }
        .padding(.horizontal, HelpTokens.Space.regular)
        .padding(.vertical, HelpTokens.Space.medium)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case let .markdown(text):
            Markdown(text)
        case let .callout(kind, text):
            CalloutBox(kind: kind, markdown: text)
        }
    }

    // MARK: Link handling

    /// Routes link taps: in-document `#anchor` links select the matching
    /// topic; everything else falls through to the browser.
    private var linkAction: OpenURLAction {
        OpenURLAction { url in
            if let slug = anchorSlug(from: url) {
                if let target = topics.first(where: { $0.slug == slug }) {
                    selection = target.id
                }
                return .handled
            }
            return .systemAction
        }
    }

    /// Extracts a bare anchor slug (`#getting-connected`) from a URL, or
    /// `nil` if the URL points somewhere external. Also resolves links that
    /// point at the sibling guide file (`FAQ.md#...`, `HELP.md#...`).
    private func anchorSlug(from url: URL) -> String? {
        if url.scheme == nil, let fragment = url.fragment {
            return fragment
        }
        let raw = url.absoluteString
        if raw.hasPrefix("#") {
            return String(raw.dropFirst())
        }
        // Cross-guide links like "FAQ.md#privacy-and-security" — jump to
        // the fragment's topic if we have it.
        if let hashIndex = raw.firstIndex(of: "#"),
           raw.hasSuffix(".md") == false,
           raw.contains(".md#") {
            return String(raw[raw.index(after: hashIndex)...])
        }
        return nil
    }

    // MARK: Search

    /// Keyword ranking — title matches outrank body mentions.
    private func keywordRanked(for query: String) -> [Topic] {
        let scores = keywordScores(for: query)
        return topics
            .filter { scores[$0.id] != nil }
            .sorted { (scores[$0.id] ?? 0) > (scores[$1.id] ?? 0) }
    }

    private func keywordScores(for query: String) -> [String: Int] {
        let stopwords: Set = [
            "the", "a", "an", "and", "or", "to", "of", "in", "on", "for",
            "is", "are", "do", "does", "how", "what", "where", "when",
            "why", "can", "my", "me", "it", "this", "that", "with",
            "use", "using", "app", "baton",
        ]
        let allTokens = query
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }
        guard !allTokens.isEmpty else { return [:] }

        let meaningful = allTokens.filter { !stopwords.contains($0) }
        let tokens = meaningful.isEmpty ? allTokens : meaningful

        var scores: [String: Int] = [:]
        for topic in topics {
            let title = topic.title.lowercased()
            let firstWord = title.split(separator: " ").first.map(String.init) ?? ""
            let haystack = topic.searchText
            var score = 0
            for token in tokens {
                if title.contains(token) {
                    score += 10
                    if firstWord.contains(token) { score += 5 }
                } else if haystack.contains(token) {
                    score += 1
                }
            }
            if score > 0 { scores[topic.id] = score }
        }
        return scores
    }

    // MARK: Markdown theme

    private var markdownTheme: Theme {
        Theme()
            .text {
                ForegroundColor(.primary)
                FontSize(15)
            }
            .link {
                ForegroundColor(HelpTokens.accent)
            }
            .strong {
                FontWeight(.semibold)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.86))
                BackgroundColor(Color.primary.opacity(0.08))
            }
            .heading2 { configuration in
                configuration.label
                    .markdownMargin(top: 24, bottom: 8)
                    .markdownTextStyle {
                        FontSize(20)
                        FontWeight(.semibold)
                    }
            }
            .heading3 { configuration in
                configuration.label
                    .markdownMargin(top: 18, bottom: 6)
                    .markdownTextStyle {
                        FontSize(16)
                        FontWeight(.semibold)
                    }
            }
            .paragraph { configuration in
                configuration.label
                    .lineSpacing(4)
                    .markdownMargin(top: 0, bottom: 12)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 0, bottom: 6)
            }
            .codeBlock { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
                    .padding(HelpTokens.Space.snug)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: HelpTokens.Radius.card))
                    .markdownMargin(top: 4, bottom: 12)
            }
            .table { configuration in
                configuration.label
                    .markdownMargin(top: 4, bottom: 12)
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle { FontSize(14) }
                    .padding(.horizontal, HelpTokens.Space.medium)
                    .padding(.vertical, HelpTokens.Space.row6)
                    .overlay(
                        Rectangle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
            }
            .blockquote { configuration in
                configuration.label
                    .padding(.leading, HelpTokens.Space.snug)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.2))
                            .frame(width: 3)
                    }
                    .markdownMargin(top: 4, bottom: 12)
            }
    }

    // MARK: Block parsing

    /// Splits a topic body into Markdown runs and callout boxes,
    /// recognizing GitHub-style `> [!NOTE]` alert blockquotes.
    private func blocks(from markdown: String) -> [Block] {
        var blocks: [Block] = []
        var buffer: [String] = []
        var calloutKind: CalloutKind?
        var calloutLines: [String] = []

        func flushMarkdown() {
            let text = buffer.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.markdown(text)) }
            buffer.removeAll()
        }

        func flushCallout() {
            guard let kind = calloutKind else { return }
            let text = calloutLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            blocks.append(.callout(kind, text))
            calloutLines.removeAll()
            calloutKind = nil
        }

        for line in markdown.components(separatedBy: "\n") {
            if calloutKind != nil {
                if line.hasPrefix(">") {
                    var content = String(line.drop { $0 == ">" })
                    if content.hasPrefix(" ") { content.removeFirst() }
                    calloutLines.append(content)
                    continue
                }
                flushCallout()
            }
            if let kind = calloutMarker(line) {
                flushMarkdown()
                calloutKind = kind
                continue
            }
            buffer.append(line)
        }
        flushCallout()
        flushMarkdown()
        return blocks
    }

    /// Returns the callout kind if `line` is a `> [!NOTE]` marker.
    private func calloutMarker(_ line: String) -> CalloutKind? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else { return nil }
        let marker = trimmed.dropFirst()
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        switch marker {
        case "[!NOTE]": return .note
        case "[!TIP]": return .tip
        case "[!IMPORTANT]": return .important
        case "[!WARNING]", "[!CAUTION]": return .warning
        default: return nil
        }
    }

    // MARK: Loading

    private static func buildTopics() -> [Topic] {
        var topics: [Topic] = []
        let help = parse(guide: .help, buildWelcome: true)
        if let welcome = help.welcome { topics.append(welcome) }
        topics.append(contentsOf: help.sections)
        topics.append(contentsOf: parse(guide: .faq, buildWelcome: false).sections)
        return topics
    }

    private static func parse(
        guide: Guide,
        buildWelcome: Bool
    ) -> (welcome: Topic?, sections: [Topic]) {
        let text = loadMarkdown(guide.resource)
        var preamble: [String] = []
        var sections: [Topic] = []
        var heading: String?
        var lastH2: String?
        var bodyLines: [String] = []
        var seenHeading = false

        func flush() {
            guard let heading else { return }
            if heading.caseInsensitiveCompare("Contents") != .orderedSame {
                let body = bodyLines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                sections.append(
                    Topic(guide: guide, title: heading, slug: slug(heading), body: body)
                )
            }
            bodyLines.removeAll()
        }

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                let title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                heading = title
                lastH2 = title
                seenHeading = true
            } else if line.hasPrefix("### ") {
                flush()
                let raw = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                let title = if let h2 = lastH2, !h2.isEmpty { "\(h2): \(raw)" } else { raw }
                heading = title
                seenHeading = true
            } else if seenHeading {
                bodyLines.append(line)
            } else {
                preamble.append(line)
            }
        }
        flush()

        var welcome: Topic?
        if buildWelcome {
            let intro = preamble
                .filter { !$0.hasPrefix("#") && $0.trimmingCharacters(in: .whitespaces) != "---" }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !intro.isEmpty {
                welcome = Topic(
                    guide: guide,
                    title: "Welcome to Baton",
                    slug: "welcome",
                    body: intro
                )
            }
        }
        return (welcome, sections)
    }

    /// Loads a bundled Markdown guide; falls back to a short message if the
    /// resource is missing from the app bundle.
    private static func loadMarkdown(_ resource: String) -> String {
        guard
            let url = Bundle.main.url(forResource: resource, withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "This guide could not be loaded."
        }
        return text
    }

    /// GitHub-compatible heading anchor slug, matching the `#anchor` links
    /// authored in the guides.
    private static func slug(_ heading: String) -> String {
        var out = ""
        for character in heading.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
            } else if character == " " || character == "-" {
                out.append("-")
            }
        }
        return out
    }

    /// Picks an SF Symbol for a topic from keywords in its title.
    /// `nonisolated` so `Topic` (a plain struct) can call it.
    private nonisolated static func symbol(for title: String) -> String {
        let lower = title.lowercased()
        let map: [(String, String)] = [
            ("welcome", "hand.wave"),
            ("what baton", "questionmark.circle"),
            ("getting connected", "cable.connector"),
            ("more than one server", "server.rack"),
            ("finding your way", "map"),
            ("home", "house"),
            ("search", "magnifyingglass"),
            ("mixes", "square.stack"),
            ("albums", "square.stack"),
            ("artists", "music.mic"),
            ("playlists", "music.note.list"),
            ("liked", "heart"),
            ("history", "clock.arrow.circlepath"),
            ("podcast", "mic"),
            ("radio", "dot.radiowaves.left.and.right"),
            ("downloads", "arrow.down.circle"),
            ("playing", "play.circle"),
            ("artwork colors", "paintpalette"),
            ("queue", "list.bullet"),
            ("sleep timer", "moon"),
            ("sound quality", "waveform"),
            ("equalizer", "slider.horizontal.3"),
            ("rating", "star"),
            ("scrobbling", "arrow.triangle.2.circlepath"),
            ("media keys", "keyboard"),
            ("keyboard", "keyboard"),
            ("webhook", "bolt.horizontal.circle"),
            ("speaking", "speaker.wave.2"),
            ("agent", "sparkles"),
            ("settings", "gearshape"),
            ("updates", "arrow.triangle.2.circlepath"),
            ("what's next", "map"),
            ("privacy", "lock"),
            ("troubleshooting", "wrench.and.screwdriver"),
            ("questions", "questionmark.bubble"),
            ("about", "info.circle"),
            ("servers", "server.rack"),
            ("playback", "play.circle"),
            ("agent control", "sparkles"),
        ]
        for (keyword, symbol) in map where lower.contains(keyword) {
            return symbol
        }
        return "doc.text"
    }
}

// MARK: - Callout box

/// A GitHub-style callout box (Note / Tip / Important / Warning).
private struct CalloutBox: View {
    let kind: BatonHelpView.CalloutKind
    let markdown: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(kind.tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.label)
                    .font(HelpTokens.Fonts.tiny.weight(.bold))
                    .foregroundStyle(kind.tint)
                    .textCase(.uppercase)
                Markdown(markdown)
            }
        }
        .padding(HelpTokens.Space.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: HelpTokens.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: HelpTokens.Radius.card)
                .strokeBorder(kind.tint.opacity(0.25))
        )
    }
}

// MARK: - Help menu commands

/// Replaces the standard Help menu items with ones that open the in-app
/// Help window.
struct HelpMenuCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("baton.help.requestedTopic") private var requestedTopic = ""

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Baton Help") {
                openWindow(id: BatonHelpView.windowID)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("?", modifiers: .command)
            Button("What's New in Baton") {
                requestedTopic = BatonHelpView.whatsNewID
                openWindow(id: BatonHelpView.windowID)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

// MARK: - Deep-link button

/// A compact "?" button that opens the Help window straight to a specific
/// topic. Drop it next to a feature anywhere in the app.
struct HelpTopicButton: View {
    /// The target topic's anchor slug (e.g. `getting-connected`).
    let topicSlug: String
    var label = "Open Help"

    @AppStorage("baton.help.requestedTopic") private var requestedTopic = ""
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            requestedTopic = topicSlug
            openWindow(id: BatonHelpView.windowID)
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.borderless)
        .help(label)
    }
}

// MARK: - Window sizing

/// Resizes the Help window to a comfortable size the first time it
/// appears. One-time, deferred off the layout pass.
private struct HelpWindowSizer: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView { HelpWindowSizingView() }
    func updateNSView(_: NSView, context _: Context) {}
}

private final class HelpWindowSizingView: NSView {
    private var didSize = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didSize, window != nil else { return }
        didSize = true
        DispatchQueue.main.async { [weak self] in
            guard
                let window = self?.window,
                let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            else { return }
            let size = NSSize(
                width: min(1040, visible.width),
                height: min(660, visible.height)
            )
            window.setFrame(
                NSRect(
                    x: (visible.midX - size.width / 2).rounded(),
                    y: (visible.midY - size.height / 2).rounded(),
                    width: size.width,
                    height: size.height
                ),
                display: true
            )
        }
    }
}
