import XCTest
@testable import BatonPlaybackKit

/// Splitting HELP.md and FAQ.md into navigable topics.
///
/// This parser used to live inside the Mac's Help window, which is why the phone rendered
/// all 1,559 lines of HELP.md as one blob and its Contents links — real Markdown anchors —
/// resolved to nothing. Shared now, so both apps list the same topics.
final class HelpGuideTests: XCTestCase {
    private let sample = """
    # Baton Help

    Baton plays your own music.

    ---

    ## Contents

    - [Getting connected](#getting-connected)

    ---

    ## Getting connected

    Point Baton at your server.

    ## Sound quality: gapless, crossfade, loudness

    Three settings.

    ### Defaults that match how you listen

    Sensible ones.
    """

    // MARK: - Splitting

    func testEachHeadingBecomesATopic() {
        let parsed = HelpGuide.parse(guide: .help, text: sample, buildWelcome: false)

        XCTAssertEqual(parsed.sections.map(\.title), [
            "Getting connected",
            "Sound quality: gapless, crossfade, loudness",
            "Defaults that match how you listen",
        ])
    }

    /// The contents list *is* the navigation this builds. Carrying it in as a topic would
    /// put a table of contents inside the table of contents.
    func testTheContentsSectionIsNotItselfATopic() {
        let parsed = HelpGuide.parse(guide: .help, text: sample, buildWelcome: false)

        XCTAssertFalse(parsed.sections.contains { $0.title.caseInsensitiveCompare("Contents") == .orderedSame })
    }

    /// A subsection titled only "Defaults that match how you listen" tells a reader
    /// nothing about which feature's defaults it means. It keeps its parent, but beside
    /// its title rather than glued to the front of it: four rows that all began
    /// "Shared settings between your d…" were a contents list nobody could navigate.
    func testSubsectionsKeepTheirParentBesideTheirTitle() {
        let parsed = HelpGuide.parse(guide: .help, text: sample, buildWelcome: false)
        let subsection = parsed.sections.last!

        XCTAssertEqual(subsection.title, "Defaults that match how you listen")
        XCTAssertEqual(subsection.parentTitle, "Sound quality: gapless, crossfade, loudness")
        XCTAssertEqual(
            subsection.qualifiedTitle,
            "Sound quality: gapless, crossfade, loudness: Defaults that match how you listen"
        )
        XCTAssertNil(parsed.sections.first?.parentTitle, "a top-level section has no parent")
    }

    /// The slug still carries the parent, so a link written for one subsection cannot
    /// land on a same-named subsection under a different heading.
    func testASubsectionSlugStillCarriesItsParent() {
        let parsed = HelpGuide.parse(guide: .help, text: sample, buildWelcome: false)

        XCTAssertEqual(
            parsed.sections.last?.slug,
            "sound-quality-gapless-crossfade-loudness-defaults-that-match-how-you-listen"
        )
    }

    // MARK: - Audience

    private let twoPlatforms = """
    ## Keyboard shortcuts
    <!-- baton:audience mac -->

    Command and everything.

    ## Baton on iPhone
    <!-- baton:audience iphone -->

    The phone.

    ### Face ID on your keys

    Inherited.

    ### Getting your Mac's setup onto your phone
    <!-- baton:audience both -->

    Both ends of the pairing.

    ## Albums and artists

    Everyone.
    """

    func testASectionSaysWhichAppItIsFor() {
        let parsed = HelpGuide.parse(guide: .help, text: twoPlatforms, buildWelcome: false)
        let byTitle = Dictionary(uniqueKeysWithValues: parsed.sections.map { ($0.title, $0.audience) })

        XCTAssertEqual(byTitle["Keyboard shortcuts"], .mac)
        XCTAssertEqual(byTitle["Baton on iPhone"], .iphone)
        XCTAssertEqual(byTitle["Face ID on your keys"], .iphone, "a subsection inherits its parent")
        XCTAssertEqual(byTitle["Getting your Mac's setup onto your phone"], .both,
                       "a subsection can override its parent")
        XCTAssertEqual(byTitle["Albums and artists"], .both, "unmarked means everyone")
    }

    /// The marker is bookkeeping. Left in the body it would be drawn as text by anything
    /// that renders raw HTML, which is not what a reader came for.
    func testTheAudienceMarkerNeverReachesTheReader() {
        let parsed = HelpGuide.parse(guide: .help, text: twoPlatforms, buildWelcome: false)

        for section in parsed.sections {
            XCTAssertFalse(section.body.contains("baton:audience"),
                           "'\(section.title)' still carries its marker")
        }
    }

    func testEachAppListsItsOwnTopicsPlusTheSharedOnes() {
        let mac = HelpGuide.topics(help: twoPlatforms, faq: "", for: .mac).map(\.title)
        let phone = HelpGuide.topics(help: twoPlatforms, faq: "", for: .iphone).map(\.title)

        XCTAssertTrue(mac.contains("Keyboard shortcuts"))
        XCTAssertFalse(mac.contains("Face ID on your keys"), "a phone-only topic on the Mac")
        XCTAssertTrue(mac.contains("Getting your Mac's setup onto your phone"),
                      "the pairing code is generated on the Mac")
        XCTAssertTrue(phone.contains("Face ID on your keys"))
        XCTAssertFalse(phone.contains("Keyboard shortcuts"), "a phone has no Command key")
        XCTAssertTrue(mac.contains("Albums and artists") && phone.contains("Albums and artists"))
    }

    func testTheIntroBecomesAWelcomeTopicWhenAsked() {
        let parsed = HelpGuide.parse(guide: .help, text: sample, buildWelcome: true)

        XCTAssertEqual(parsed.welcome?.slug, "welcome")
        XCTAssertTrue(parsed.welcome?.body.contains("plays your own music") == true)
        XCTAssertFalse(parsed.welcome?.body.contains("# Baton Help") == true, "the H1 is chrome")
    }

    func testTopicBodiesDropTheirOwnHeading() {
        let parsed = HelpGuide.parse(guide: .help, text: sample, buildWelcome: false)

        XCTAssertEqual(parsed.sections[0].body, "Point Baton at your server.")
    }

    // MARK: - Slugs

    /// The slug must equal the anchor the guide's own Contents links already use, or
    /// every one of those links lands nowhere.
    func testSlugsMatchTheAnchorsTheGuidesLinkTo() {
        XCTAssertEqual(HelpGuide.slug("Getting connected"), "getting-connected")
        XCTAssertEqual(HelpGuide.slug("What Baton is, and what it isn't"), "what-baton-is-and-what-it-isnt")
        XCTAssertEqual(HelpGuide.slug("Sound quality: gapless, crossfade, loudness"),
                       "sound-quality-gapless-crossfade-loudness")
    }

    // MARK: - Links

    func testAnAnchorLinkResolvesToItsSlug() {
        XCTAssertEqual(HelpGuide.anchorSlug(from: URL(string: "#getting-connected")!), "getting-connected")
    }

    func testACrossGuideLinkResolvesToItsFragment() {
        XCTAssertEqual(HelpGuide.anchorSlug(from: URL(string: "FAQ.md#privacy-and-security")!),
                       "privacy-and-security")
    }

    /// A real outbound link must still open in a browser rather than being swallowed.
    func testAnOrdinaryLinkIsNotTreatedAsAnAnchor() {
        XCTAssertNil(HelpGuide.anchorSlug(from: URL(string: "https://batonmusic.app")!))
    }

    // MARK: - Search

    func testATitleMatchOutranksABodyMention() {
        let topics = [
            HelpGuide.Topic(guide: .help, title: "Downloads", slug: "d", body: "Offline listening."),
            HelpGuide.Topic(guide: .help, title: "Scrobbling", slug: "s", body: "Unrelated to downloads."),
        ]

        XCTAssertEqual(HelpGuide.ranked(topics, query: "downloads").first?.slug, "d")
    }

    /// "how do I use the equalizer" is a question about the equalizer.
    func testStopwordsDoNotDrownTheRealQuery() {
        let topics = [
            HelpGuide.Topic(guide: .help, title: "The equalizer", slug: "eq", body: ""),
            HelpGuide.Topic(guide: .help, title: "Playlists", slug: "pl", body: "How do I use this"),
        ]

        XCTAssertEqual(HelpGuide.ranked(topics, query: "how do I use the equalizer").first?.slug, "eq")
    }

    func testAQueryOfNothingButStopwordsStillAnswers() {
        let topics = [HelpGuide.Topic(guide: .help, title: "How it works", slug: "h", body: "")]

        XCTAssertFalse(HelpGuide.ranked(topics, query: "how").isEmpty,
                       "dropping every token would return nothing at all")
    }

    func testAnEmptyQueryMatchesNothingRatherThanEverything() {
        let topics = [HelpGuide.Topic(guide: .help, title: "Anything", slug: "a", body: "text")]

        XCTAssertTrue(HelpGuide.ranked(topics, query: "   ").isEmpty)
    }

    // MARK: - Anchors in the shipped guides

    /// The repository root, five directories up from this file.
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func shippedTopics() throws -> [HelpGuide.Topic] {
        let help = try String(contentsOf: root.appendingPathComponent("HELP.md"), encoding: .utf8)
        let faq = try String(contentsOf: root.appendingPathComponent("FAQ.md"), encoding: .utf8)
        return HelpGuide.topics(help: help, faq: faq)
    }

    /// Every `](#…)` and `](HELP.md#…)` written in the guides, with the line it sits on.
    private func anchorLinks(in text: String, file: String) -> [(anchor: String, where: String)] {
        var found: [(String, String)] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            var rest = Substring(line)
            while let open = rest.range(of: "](") {
                let after = rest[open.upperBound...]
                guard let close = after.firstIndex(of: ")") else { break }
                let target = String(after[..<close])
                rest = after[after.index(after: close)...]
                guard let url = URL(string: target) else { continue }
                if let anchor = HelpGuide.anchorSlug(from: url) {
                    found.append((anchor, "\(file):\(index + 1)"))
                }
            }
        }
        return found
    }

    /// Every anchor link in HELP.md and FAQ.md lands on a topic.
    ///
    /// Twelve did not. Nine pointed at real `###` sections and missed only because a
    /// subsection's slug carries its parent, and three named headings that no longer
    /// exist. Both apps swallow the miss, so the tap did nothing and nothing said why.
    func testEveryAnchorInTheShippedGuidesResolves() throws {
        let topics = try shippedTopics()
        let help = try String(contentsOf: root.appendingPathComponent("HELP.md"), encoding: .utf8)
        let faq = try String(contentsOf: root.appendingPathComponent("FAQ.md"), encoding: .utf8)
        let links = anchorLinks(in: help, file: "HELP.md") + anchorLinks(in: faq, file: "FAQ.md")

        XCTAssertGreaterThan(links.count, 40, "no anchors were found at all, so this proves nothing")

        let dead = links
            .filter { HelpGuide.topic(for: $0.anchor, in: topics) == nil }
            .map { "\($0.where) #\($0.anchor)" }
        XCTAssertEqual(dead, [], "these links open nothing:\n" + dead.joined(separator: "\n"))
    }

    /// The reported symptom, as a test: four sidebar rows that all read "Shared settings
    /// between your d…" because the row drew the parent-qualified title under
    /// `lineLimit(1)` in a 268pt column. The titles are what the row draws now, so this
    /// fails if the qualification comes back.
    func testTheSharedSettingsRowsAreTellableApart() throws {
        let children = try shippedTopics().filter { $0.parentTitle == "Shared settings between your devices" }

        XCTAssertGreaterThanOrEqual(children.count, 4, "the section lost its subsections")
        XCTAssertEqual(Set(children.map(\.title)).count, children.count,
                       "two rows would draw the same text: \(children.map(\.title))")
        for child in children {
            XCTAssertFalse(child.title.hasPrefix("Shared settings"),
                           "'\(child.title)' still leads with its parent")
        }
    }

    /// The Mac's contents used to open with eight "Baton on iPhone" topics, before it
    /// reached Albums or the equalizer, and the phone listed a table of Command-key
    /// shortcuts. This is over the guides the apps actually ship, so removing a marker
    /// fails here rather than in a screenshot nobody takes.
    func testTheShippedGuidesSplitByApp() throws {
        let help = try String(contentsOf: root.appendingPathComponent("HELP.md"), encoding: .utf8)
        let faq = try String(contentsOf: root.appendingPathComponent("FAQ.md"), encoding: .utf8)
        let mac = HelpGuide.topics(help: help, faq: faq, for: .mac).map(\.title)
        let phone = HelpGuide.topics(help: help, faq: faq, for: .iphone).map(\.title)

        XCTAssertFalse(mac.contains("Face ID on your keys"), "a phone-only topic in the Mac contents")
        XCTAssertFalse(mac.contains("Widgets, the lock screen, and Live Activities"))
        XCTAssertFalse(phone.contains("Keyboard shortcuts"), "a phone has no Command key")
        XCTAssertFalse(phone.contains("Webhook actions"), "the Mac hosts the webhooks")

        XCTAssertTrue(mac.contains("Getting your Mac's setup onto your phone"),
                      "the pairing code is shown on the Mac, so the Mac needs this topic")
        for shared in ["Albums and artists", "The equalizer", "Scrobbling"] {
            XCTAssertTrue(mac.contains(shared) && phone.contains(shared), "'\(shared)' lost an app")
        }
        XCTAssertGreaterThan(mac.count, 40)
        XCTAssertGreaterThan(phone.count, 40)
    }

    /// The suffix fallback only fires when it is unambiguous.
    func testAnAmbiguousAnchorResolvesToNothingRatherThanToAGuess() {
        let topics = [
            HelpGuide.Topic(guide: .help, title: "One", slug: "first-turning-it-on", body: ""),
            HelpGuide.Topic(guide: .help, title: "Two", slug: "second-turning-it-on", body: ""),
        ]

        XCTAssertNil(HelpGuide.topic(for: "turning-it-on", in: topics))
    }

    func testAnExactSlugWinsOverASuffixMatch() {
        let topics = [
            HelpGuide.Topic(guide: .help, title: "Parent: Lyrics", slug: "playing-music-lyrics", body: ""),
            HelpGuide.Topic(guide: .help, title: "Lyrics", slug: "lyrics", body: ""),
        ]

        XCTAssertEqual(HelpGuide.topic(for: "lyrics", in: topics)?.slug, "lyrics")
    }
}
