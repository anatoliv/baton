import Foundation

/// HELP.md and FAQ.md, split into the topics both apps navigate by.
///
/// The guides are single Markdown files at the repo root — the same text the website
/// publishes and a prebuild step copies into each app bundle, so there is exactly one
/// place to edit them. What differs is how each app *reads* them, and until now only the
/// Mac read them as anything other than one long document: it split them by heading,
/// listed the topics in a sidebar, searched them, and jumped to one on request. The phone
/// rendered all 1,559 lines of HELP.md as a single blob, so its Contents links — which are
/// real Markdown anchors — did nothing at all when tapped.
///
/// That parser lived inside the Mac's view. This is it, moved somewhere both apps can
/// reach, so the phone gets the same topics and neither app can drift from the other.
public enum HelpGuide {
    public enum Kind: String, CaseIterable, Sendable {
        case help = "Guide"
        case faq = "FAQ"

        /// Bundle resource name (`HELP.md`, `FAQ.md`).
        public var resource: String { self == .help ? "HELP" : "FAQ" }
    }

    /// One `##`/`###`-delimited section: a single entry in the contents.
    public struct Topic: Identifiable, Hashable, Sendable {
        public let guide: Kind
        public let title: String
        /// GitHub-style anchor — what a `[link](#slug)` in the guide points at.
        public let slug: String
        /// The section's Markdown, heading line removed.
        public let body: String

        public var id: String { "\(guide.rawValue)#\(slug)" }
        public var searchText: String { (title + " " + body).lowercased() }

        public init(guide: Kind, title: String, slug: String, body: String) {
            self.guide = guide
            self.title = title
            self.slug = slug
            self.body = body
        }

        public static func == (lhs: Topic, rhs: Topic) -> Bool { lhs.id == rhs.id }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    // MARK: - Parsing

    /// Every topic in both guides, in reading order.
    public static func topics(help: String, faq: String) -> [Topic] {
        var all: [Topic] = []
        let parsedHelp = parse(guide: .help, text: help, buildWelcome: true)
        if let welcome = parsedHelp.welcome { all.append(welcome) }
        all.append(contentsOf: parsedHelp.sections)
        all.append(contentsOf: parse(guide: .faq, text: faq, buildWelcome: false).sections)
        return all
    }

    public static func parse(
        guide: Kind,
        text: String,
        buildWelcome: Bool
    ) -> (welcome: Topic?, sections: [Topic]) {
        var preamble: [String] = []
        var sections: [Topic] = []
        var heading: String?
        var lastH2: String?
        var bodyLines: [String] = []
        var seenHeading = false

        func flush() {
            guard let heading else { return }
            // "Contents" is the navigation this replaces — carrying it in as a topic
            // would list a table of contents inside the table of contents.
            if heading.caseInsensitiveCompare("Contents") != .orderedSame {
                let body = bodyLines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                sections.append(Topic(guide: guide, title: heading, slug: slug(heading), body: body))
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
                // Qualified by its parent, so "The now-playing bar" doesn't sit in the
                // contents with nothing saying it belongs to "Playing music".
                heading = if let h2 = lastH2, !h2.isEmpty { "\(h2): \(raw)" } else { raw }
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
                welcome = Topic(guide: guide, title: "Welcome to Baton", slug: "welcome", body: intro)
            }
        }
        return (welcome, sections)
    }

    /// A heading's anchor, matching the slugs the guides' own Contents links use.
    public static func slug(_ heading: String) -> String {
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

    // MARK: - Links

    /// The topic a link in the rendered guide points at, if any.
    ///
    /// The guides link to each other and to their own sections. Without this the Contents
    /// list is decorative: every entry is a `#slug` that no renderer resolves on its own.
    public static func anchorSlug(from url: URL) -> String? {
        if url.scheme == nil, let fragment = url.fragment { return fragment }
        let raw = url.absoluteString
        if raw.hasPrefix("#") { return String(raw.dropFirst()) }
        // Cross-guide links like "FAQ.md#privacy-and-security".
        if let hash = raw.firstIndex(of: "#"), !raw.hasSuffix(".md"), raw.contains(".md#") {
            return String(raw[raw.index(after: hash)...])
        }
        return nil
    }

    // MARK: - Search

    /// Topics matching a query, best first.
    public static func ranked(_ topics: [Topic], query: String) -> [Topic] {
        let scores = scores(topics, query: query)
        return topics
            .filter { scores[$0.id] != nil }
            .sorted { (scores[$0.id] ?? 0) > (scores[$1.id] ?? 0) }
    }

    public static func scores(_ topics: [Topic], query: String) -> [String: Int] {
        // Dropped because they match everything: someone typing "how do I use crossfade"
        // means "crossfade", and scoring the rest buries it.
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

        // A query of nothing but stopwords still deserves an answer.
        let meaningful = allTokens.filter { !stopwords.contains($0) }
        let tokens = meaningful.isEmpty ? allTokens : meaningful

        var scores: [String: Int] = [:]
        for topic in topics {
            let title = topic.title.lowercased()
            let firstWord = title.split(separator: " ").first.map(String.init) ?? ""
            var score = 0
            for token in tokens {
                if title.contains(token) {
                    score += 10
                    if firstWord.contains(token) { score += 5 }
                } else if topic.searchText.contains(token) {
                    score += 1
                }
            }
            if score > 0 { scores[topic.id] = score }
        }
        return scores
    }

    // MARK: - Deep links

    /// Where one app asks the other half of itself to open a particular topic.
    ///
    /// Already how the Mac's Help menu jumps straight to a section; the phone now uses it
    /// to send you from a setting to the paragraph that explains it.
    public static let requestedTopicKey = "baton.help.requestedTopic"

    /// Ask Help to open `slug` the next time it appears.
    public static func requestTopic(_ slug: String, defaults: UserDefaults = .standard) {
        defaults.set(slug, forKey: requestedTopicKey)
    }
}

/// Where things actually are in the Mac app, for the phone to tell you about.
///
/// The phone gives directions to a UI it cannot see, and both of the first attempts were
/// wrong: it sent people to "Settings → Export settings", which does not exist (export is
/// in **About → Back up & restore**), and to "Remote → Devices", where the section is
/// called **Link a device**. Instructions that name the wrong menu are worse than none —
/// they send someone hunting through an app for something that was never there.
///
/// Written down once so the four places that quote them agree, and pinned by
/// `MacSetupPathTests` on the Mac side, where the labels actually live.
public enum MacSetupPath {
    /// Settings pane names, as the Mac's sidebar spells them.
    public static let remotePane = "Remote"
    public static let aboutPane = "About"

    /// Section headings within those panes.
    public static let pairingSection = "Link a device"
    public static let backupSection = "Back up & restore"

    /// The controls themselves.
    public static let pairingButton = "Show pairing code"
    public static let exportButton = "Export…"

    /// "Settings → Remote → Link a device → Show pairing code"
    public static var pairing: String {
        "Settings → \(remotePane) → \(pairingSection) → \(pairingButton)"
    }

    /// "Settings → About → Back up & restore → Export…"
    public static var export: String {
        "Settings → \(aboutPane) → \(backupSection) → \(exportButton)"
    }
}

/// Navidrome's own public demo server.
///
/// Baton has two ways to be tried without a server, and they answer different questions.
/// The bundled demo library proves the *app* works — four tracks, no network, nothing to
/// configure. It cannot show you what Baton is actually for, which is a real library on a
/// real server: browsing thousands of albums, artwork arriving over a connection, search
/// against an index rather than four files, and the failure modes that only exist when a
/// server is involved.
///
/// This is the Navidrome project's public instance, which they publish for exactly this.
/// Verified against the live host before shipping: Navidrome 0.63.2, OpenSubsonic, real
/// Creative Commons music (the netBloc compilations).
///
/// Not a secret, and deliberately not treated like one: the credentials are `demo`/`demo`,
/// published on Navidrome's own site. The password still goes through the Keychain like any
/// other, because the code path that stores a server password should not have a special
/// case in it.
public enum NavidromePublicDemo {
    public static let url = "https://demo.navidrome.org"
    public static let username = "demo"
    public static let password = "demo"

    /// It is someone else's server, and it can be down, slow or reset without warning.
    /// Saying so up front is the difference between "the demo is offline" and "Baton is
    /// broken".
    public static let caveat =
        "Navidrome's own public server, with a few thousand Creative Commons tracks. "
        + "It's not ours, so it can be slow or offline — but it's a real library over a "
        + "real connection, which the built-in demo isn't."
}
