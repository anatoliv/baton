import XCTest
@testable import BatonSubsonicModels

/// The rule that decides whether metadata reaches the screen.
///
/// The cases that matter are the ones at the edges: what must be hidden, and what must
/// survive. A filter that is too eager loses real information, which is worse than the
/// placeholder it was written to remove.
final class DisplayNameTests: XCTestCase {
    func testHidesTheImporterPlaceholders() {
        for value in ["Unknown", "unknown", "UNKNOWN", "[unknown]", "(Unknown)",
                      "Unknown Artist", "Untitled", "N/A", "none", "Default", "  Unknown  "] {
            XCTAssertNil(DisplayName.shown(value), "\(value) should not reach the screen")
        }
    }

    func testHidesEmptyAndWhitespace() {
        XCTAssertNil(DisplayName.shown(nil))
        XCTAssertNil(DisplayName.shown(""))
        XCTAssertNil(DisplayName.shown("   \n "))
    }

    /// The case that stops this being over-eager.
    ///
    /// On a compilation "Various Artists" is the true answer, not a placeholder, and an app
    /// that hides it has lost information rather than noise. Same for a band whose name
    /// merely contains one of these words.
    func testKeepsValuesThatLookLikePlaceholdersButAreNot() {
        for value in ["Various Artists", "Various", "Unknown Mortal Orchestra",
                      "The Unknown", "Default Genes", "Nonesuch"] {
            XCTAssertEqual(DisplayName.shown(value), value, "\(value) is real and must survive")
        }
    }

    func testTrimsRatherThanRejectsPaddedRealValues() {
        XCTAssertEqual(DisplayName.shown("  Dido  "), "Dido")
    }

    func testTitleWithArtistCollapsesWhenTheArtistIsAPlaceholder() {
        XCTAssertEqual(
            DisplayName.titleWithArtist(title: "Clair de Lune", artist: "Unknown"),
            "Clair de Lune",
            "the agent should not say 'by unknown' out loud"
        )
        XCTAssertEqual(
            DisplayName.titleWithArtist(title: "Clair de Lune", artist: "Debussy"),
            "Clair de Lune by Debussy"
        )
    }

    func testIsPlaceholderMirrorsShown() {
        XCTAssertTrue(DisplayName.isPlaceholder("Unknown"))
        XCTAssertFalse(DisplayName.isPlaceholder("Dido"))
    }

    // MARK: displayLine — the property the agent-facing strings share

    /// The regression this was written for.
    ///
    /// `displayLine` had its own emptiness check, and a placeholder is not empty: the MCP
    /// `music_now_playing` payload answered "Paused: [unknown] — Clair de Lune" on 0.16.15,
    /// months after the views stopped saying it. Four agent-facing strings read this one
    /// property, so this test covers all of them.
    func testDisplayLineDropsAPlaceholderArtistRatherThanPrintingIt() {
        for placeholder in ["[unknown]", "Unknown", "unknown artist", "N/A", "  "] {
            XCTAssertEqual(
                NavidromeSong(id: "1", title: "Clair de Lune", artist: placeholder).displayLine,
                "Clair de Lune",
                "\(placeholder) must not reach an agent reply"
            )
        }
        XCTAssertEqual(
            NavidromeSong(id: "1", title: "Clair de Lune", artist: nil).displayLine,
            "Clair de Lune"
        )
    }

    func testDisplayLineKeepsARealArtist() {
        XCTAssertEqual(
            NavidromeSong(id: "1", title: "So What", artist: "Miles Davis").displayLine,
            "Miles Davis — So What"
        )
    }

    /// Same tidying as the screen gets: a line read aloud or sent to a chat should not
    /// carry the fullwidth characters a downloader substituted for illegal filename ones.
    func testDisplayLineTidiesTheDownloaderEscaping() {
        XCTAssertEqual(
            NavidromeSong(id: "1", title: "Chillout \u{FF5C} Mood #21",
                          artist: "RIKO\u{FF0C} BRK").displayLine,
            "RIKO, BRK — Chillout | Mood #21"
        )
    }

    // MARK: Filename escaping (real strings, taken from the live library)

    /// These are verbatim values from the library, not invented ones.
    ///
    /// A downloader cannot put `"`, `|` or `/` in a filename, so it substitutes fullwidth
    /// lookalikes; those filenames become tags and the lookalikes reach the screen. Nobody
    /// types U+FF02 in a song title on purpose, so restoring them is lossless.
    func testRestoresTheCharactersADownloaderSubstituted() {
        XCTAssertEqual(
            DisplayName.title("FEMALE VOCAL CHILL OUT, Deep House \u{FF02}Jjos\u{FF02} Ambient & Lounge Music"),
            "FEMALE VOCAL CHILL OUT, Deep House \"Jjos\" Ambient & Lounge Music"
        )
        XCTAssertEqual(
            DisplayName.title("RELAX LOUNGE CHILLOUT \u{FF5C} New Age & Lounge \u{FF5C} Relax Ambient Music"),
            "RELAX LOUNGE CHILLOUT | New Age & Lounge | Relax Ambient Music"
        )
        XCTAssertEqual(
            DisplayName.title("Chillout \u{FF5C} Emotional \u{29F8} Intimate Mood #21"),
            "Chillout | Emotional / Intimate Mood #21"
        )
        XCTAssertEqual(
            DisplayName.artist("RIKO & GUGGA\u{FF0C} BRK (BR)"),
            "RIKO & GUGGA, BRK (BR)"
        )
    }

    /// Tidying must not become editing.
    ///
    /// Emoji, capitals and marketing padding are all things a person may have meant, and
    /// removing them is a judgement about someone's library rather than a fix to a
    /// downloader's escaping. The line is deliberately here.
    func testLeavesEmojiCapitalsAndPaddingAlone() {
        let title = "Deep Rooftop Chillout \u{1F319} Beautiful Ambient Chillout Music Mix"
        XCTAssertEqual(DisplayName.title(title), title)
        XCTAssertEqual(DisplayName.artist("AMBIENT CHILLOUT LOUNGE RELAXING MUSIC"),
                       "AMBIENT CHILLOUT LOUNGE RELAXING MUSIC")
    }

    func testCollapsesTheDoubleSpacesEscapingLeavesBehind() {
        XCTAssertEqual(DisplayName.title("Wonderful  &   Paeceful Lounge"), "Wonderful & Paeceful Lounge")
    }
}
