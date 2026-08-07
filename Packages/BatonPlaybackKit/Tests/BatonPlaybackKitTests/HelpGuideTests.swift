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
            "Sound quality: gapless, crossfade, loudness: Defaults that match how you listen",
        ])
    }

    /// The contents list *is* the navigation this builds. Carrying it in as a topic would
    /// put a table of contents inside the table of contents.
    func testTheContentsSectionIsNotItselfATopic() {
        let parsed = HelpGuide.parse(guide: .help, text: sample, buildWelcome: false)

        XCTAssertFalse(parsed.sections.contains { $0.title.caseInsensitiveCompare("Contents") == .orderedSame })
    }

    /// A subsection titled only "Defaults that match how you listen" tells a reader
    /// nothing about which feature's defaults it means.
    func testSubsectionsCarryTheirParentsName() {
        let parsed = HelpGuide.parse(guide: .help, text: sample, buildWelcome: false)

        XCTAssertTrue(parsed.sections.last!.title.hasPrefix("Sound quality"))
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
        XCTAssertNil(HelpGuide.anchorSlug(from: URL(string: "https://baton.tonebox.io")!))
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
}
