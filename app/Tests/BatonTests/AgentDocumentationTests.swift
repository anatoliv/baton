import XCTest
@testable import Baton

/// The docs describe a tool catalog; the catalog is code. Nothing compared them,
/// so they drifted: `music_get_playlist` and `music_set_crossfade` shipped and
/// went unmentioned in both the bundled help and the public help page for
/// several releases, and the headline count ("28 music operations") was wrong in
/// three places at once.
///
/// A tool an agent can call but nobody documented is a feature that effectively
/// does not exist, so this compares them on every build.
@MainActor
final class AgentDocumentationTests: XCTestCase {
    /// The repo-root guides are the canonical copies — a build phase syncs them
    /// into `Sources/Baton/Resources`, so editing the synced copy is silently
    /// undone. Read the source of truth, not the copy.
    private func repoFile(_ name: String) throws -> String {
        // …/app/Tests/BatonTests/ThisFile.swift → repo root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BatonTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .deletingLastPathComponent()  // repo root
        let url = root.appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private var publishedToolNames: [String] {
        BatonMCPToolCatalog.definitions().compactMap { $0["name"] as? String }
    }

    /// Every tool an agent can call has to be named in the user guide.
    func testEveryShippedToolIsInTheHelpGuide() throws {
        let help = try repoFile("HELP.md")
        let missing = publishedToolNames.filter { !help.contains($0) }
        XCTAssertTrue(
            missing.isEmpty,
            "undocumented in HELP.md: \(missing.sorted()) — add them to the tool catalog tables"
        )
    }

    /// The same catalog is published at baton.tonebox.io/help, and it is what
    /// someone reads *before* installing.
    func testEveryShippedToolIsOnThePublicHelpPage() throws {
        let page = try repoFile("website/help.html")
        let missing = publishedToolNames.filter { !page.contains($0) }
        XCTAssertTrue(
            missing.isEmpty,
            "undocumented in website/help.html: \(missing.sorted())"
        )
    }

    /// The counts are prose, so they rot quietly rather than failing to compile.
    func testTheAdvertisedToolCountMatchesTheCatalog() throws {
        let musicTools = publishedToolNames.filter { $0.hasPrefix("music_") }.count
        for file in ["HELP.md", "README.md", "website/help.html"] {
            let text = try repoFile(file)
            XCTAssertTrue(
                text.contains("\(musicTools) music operations")
                    || text.contains("\(musicTools) `music_*` operations")
                    || text.contains("\(musicTools) <strong>music operations")
                    || text.contains("<strong>\(musicTools) music operations</strong>"),
                "\(file) doesn't state the real count of \(musicTools) music_* tools"
            )
        }
    }

    /// Agent mode is the one setting that changes what leaves the machine, so
    /// the promise has to be stated wherever the feature is described — and it
    /// must no longer claim, unconditionally, that the library never travels.
    func testThePrivacyDifferenceIsDocumentedWhereverAgentModeIs() throws {
        for file in ["HELP.md", "FAQ.md", "website/help.html"] {
            let text = try repoFile(file)
            XCTAssertTrue(
                text.lowercased().contains("look around"),
                "\(file) never mentions agent mode"
            )
        }
        // The old unconditional promise. It was true of single-shot mode only,
        // and shipping it next to agent mode would make it a lie.
        let help = try repoFile("HELP.md")
        XCTAssertFalse(
            help.contains("never your library, your server credentials"),
            "HELP.md still carries the pre-agent-mode privacy claim"
        )
    }

    // MARK: - Help-surface coverage

    /// `website/help.html` is hand-written, not generated from `HELP.md`, so the
    /// two drift and the one that drifts silently is the one people read before
    /// installing. Measured on 2026-09-07: HELP.md had 44 sections to the public
    /// page's 15, and the iPhone app and Clippings had no public coverage at all.
    ///
    /// Requiring every section on the public page would fail on day one and be
    /// deleted by Friday. So instead each `##` in HELP.md must appear in exactly
    /// one of the two tables below: covered by a named section of the public
    /// page, or deliberately left off it with the reason written down. A new
    /// section is in neither, so it fails until someone decides which it is.
    ///
    /// Heading text is the key rather than a fuzzy match, because the two
    /// surfaces rename independently ("Downloads and offline listening" against
    /// "Downloads & offline") and a match on words would call that drift.

    /// HELP.md section → the `id` of the public-page section that covers it.
    /// Several map to one: the page is a summary, not a mirror.
    private static let coveredOnThePublicPage: [String: String] = [
        "Getting connected": "getting-connected",
        "Using more than one server": "getting-connected",
        "Baton on iPhone": "iphone",
        "Shared settings between your devices": "iphone",
        "Finding your way around": "browsing",
        "Home (For You)": "browsing",
        "Search": "browsing",
        "Mixes": "browsing",
        "Albums and artists": "browsing",
        "Playlists": "browsing",
        "Liked": "browsing",
        "History": "browsing",
        "Podcasts": "browsing",
        "Internet radio": "browsing",
        "Rating, liking, and multi-select": "browsing",
        "Downloads and offline listening": "downloads",
        "Playing music": "playing",
        "The queue, shuffle, repeat, and autoplay": "playing",
        "Sleep timer": "playing",
        "Sound quality: gapless, crossfade, loudness": "sound",
        "The equalizer": "sound",
        "Scrobbling": "scrobbling",
        "Media keys and AirPlay": "keys",
        "Keyboard shortcuts": "shortcuts",
        "Webhook actions": "actions",
        "Speaking summaries aloud": "speech",
        "Reading what's on your screen": "speech",
        "Letting an agent control your music": "agents",
        "Controlling Baton from Telegram or Discord": "remote",
        "Updates": "updates",
        "What's next": "roadmap",
        "Privacy and security": "faq",
        "Questions": "faq",
    ]

    /// HELP.md sections that are deliberately not on the public page, and why.
    /// Adding a line here is the decision "the marketing site doesn't need this",
    /// made once and on the record, rather than an omission nobody noticed.
    /// Sections of `HELP.md` that stay off `website/help.html`, each with the reason.
    ///
    /// The two surfaces are hand-written and stay that way: TBX-5064 settled that on
    /// 2026-09-07, against generating either page from the other. The measurement behind
    /// the decision was that 33 of 44 sections were already covered and the 11 below each
    /// had a reason, so the "637 lines against 2492" gap is depth rather than coverage.
    ///
    /// A reason here is load-bearing, not a comment. It is what a future reader uses to
    /// decide whether an omission still holds, so it has to describe the world as it is:
    /// where the material actually lives, or that it lives nowhere. Two entries below
    /// failed that test when the decision was taken.
    private static let deliberatelyNotOnThePublicPage: [String: String] = [
        "Contents": "the page has its own on-this-page nav",
        "What Baton is, and what it isn't": "the page's hero and FAQ answer this in the reader's first ten seconds",
        "Browsing by folder": "detail of a browsing surface the page summarises in one section",
        "Later": "detail of a browsing surface the page summarises in one section",
        "Clippings": "in-app workflow, nothing a reader decides to install over",
        "Adaptive artwork colors": "cosmetic, and visible in the screenshots on the landing page",
        "Finding music you don't have": "in-app workflow, nothing a reader decides to install over",
        // These two read as settled and were not. Both said "large enough to want its own
        // page", which implies a page that does not exist. Measured 2026-09-07: the music
        // friend is covered, on the landing page rather than here; transcripts are covered
        // nowhere public at all. Same reason, two different situations, and only one of
        // them is fine.
        "The music friend": "covered on the landing page instead; see coveredElsewherePublicly, "
            + "which checks that claim rather than repeating it",
        "Transcripts and summaries": "ACCEPTED GAP: described on no public page. "
            + "index.html 0 mentions, help.html has no section for it. Kept off knowingly "
            + "when TBX-5064 chose two hand-written surfaces, not overlooked. Revisit if "
            + "transcripts start selling the app.",
        "Settings reference": "an exhaustive reference belongs in the bundled guide, not the shop window",
        "Troubleshooting": "the bundled guide is the copy someone reaches for once something is wrong",
    ]

    /// Omissions whose stated reason is "it is covered on another public page", and the
    /// file plus the phrase that has to be there for that to be true.
    ///
    /// A reason in the table above is only worth having if it describes the world as it is.
    /// The first version of this one said "covered on the landing page instead (index.html,
    /// 5 mentions)" — a hard number nothing checked, in a table whose entire job is to be
    /// trustworthy. Delete the section from `index.html` and the reason keeps asserting it
    /// is there, which is the precise failure the reason was rewritten to remove. A claim
    /// that something exists elsewhere is checkable, so it gets checked.
    private static let coveredElsewherePublicly: [String: (file: String, phrase: String)] = [
        "The music friend": ("website/index.html", "music friend"),
    ]

    func testAnOmissionClaimingCoverageElsewhereActuallyHasIt() throws {
        for (section, where_) in Self.coveredElsewherePublicly {
            XCTAssertNotNil(
                Self.deliberatelyNotOnThePublicPage[section],
                "\(section) is listed in coveredElsewherePublicly but is not an omission"
            )
            let text = try repoFile(where_.file).lowercased()
            XCTAssertTrue(
                text.contains(where_.phrase.lowercased()),
                """
                "\(section)" is kept off website/help.html on the grounds that \
                \(where_.file) covers it, and \(where_.file) no longer mentions \
                "\(where_.phrase)". Either put it back, or move the section into \
                deliberatelyNotOnThePublicPage with a reason that is true.
                """
            )
        }
    }

    /// Every `##` in HELP.md is either covered on the public page or on the
    /// written-down omissions list. New sections default to failing.
    func testEveryHelpSectionIsCoveredOnThePublicPageOrDeliberatelyNot() throws {
        let sections = try helpSectionTitles()
        XCTAssertGreaterThan(sections.count, 30, "HELP.md section parse looks wrong")

        let covered = Self.coveredOnThePublicPage
        let omitted = Self.deliberatelyNotOnThePublicPage

        let unclassified = sections.filter { covered[$0] == nil && omitted[$0] == nil }
        XCTAssertTrue(
            unclassified.isEmpty,
            """
            HELP.md sections with no decision recorded about the public page: \
            \(unclassified.sorted()).
            website/help.html is hand-written, so it does not pick these up on its own. \
            Either write the section on the public page and map it in \
            `coveredOnThePublicPage`, or record why it stays off in \
            `deliberatelyNotOnThePublicPage`.
            """
        )

        // Both tables have to age with HELP.md, or they quietly describe a
        // document that no longer exists.
        let known = Set(covered.keys).union(omitted.keys)
        let stale = known.subtracting(sections)
        XCTAssertTrue(
            stale.isEmpty,
            "no longer a section in HELP.md, so drop or rename these entries: \(stale.sorted())"
        )

        // And a section can't be claimed as covered by a part of the page that
        // has since been renamed or deleted.
        let page = try repoFile("website/help.html")
        let missingAnchors = Set(covered.values).filter { !page.contains("id=\"\($0)\"") }
        XCTAssertTrue(
            missingAnchors.isEmpty,
            "website/help.html has no section with id \(missingAnchors.sorted()), "
                + "but coveredOnThePublicPage says HELP.md sections live there"
        )
    }

    /// The public page is where someone decides whether to buy the phone app, so
    /// the store link is worth pinning on its own rather than trusting the
    /// section-level check above to imply it.
    func testThePublicPageLinksToTheiPhoneAppOnTheAppStore() throws {
        let page = try repoFile("website/help.html")
        XCTAssertTrue(
            page.contains("apps.apple.com/app/id6798304294"),
            "website/help.html doesn't link to Baton Music on the App Store"
        )
        XCTAssertTrue(
            page.contains("iOS 18"),
            "website/help.html doesn't state the iPhone app's minimum iOS version"
        )
    }

    /// Top-level headings of HELP.md, in document order, ignoring fenced code.
    private func helpSectionTitles() throws -> [String] {
        var inFence = false
        return try repoFile("HELP.md").split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> String? in
                let text = String(line)
                if text.hasPrefix("```") {
                    inFence.toggle()
                    return nil
                }
                guard !inFence, text.hasPrefix("## "), !text.hasPrefix("### ") else { return nil }
                return String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
    }
}
