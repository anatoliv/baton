import XCTest
@testable import Baton

/// Help search, end to end, against the guides the app actually ships.
///
/// There were already tests for this. `HelpGuideTests` proved the parser produces a
/// "Scrobbling" topic, and `HelpSearchScrobbleTests` proved the matcher matches "scrobb".
/// Both passed, in every build, while Help search in the running app returned **"No
/// results" for every word anyone typed**.
///
/// They passed because both test the *shared* layer, where a topic's id is only ever
/// compared with itself. The bug was in the seam: this window copied the shared topic's
/// fields and re-derived an id with the same formula over a different enum —
/// `HelpGuide.Kind.help` has the raw value `"Guide"`, the window's `Guide.help` has
/// `"help"` — so scores came back keyed `"Guide#scrobbling"` and were looked up under
/// `"help#scrobbling"`. Nothing ever matched.
///
/// So these tests run the pipeline the *window* runs: load from the app bundle, parse,
/// rank. A unit test one layer down cannot see this class of bug, which is exactly why it
/// survived long enough to be reported by hand.
@MainActor
final class HelpSearchPipelineTests: XCTestCase {
    private func topics() -> [BatonHelpView.Topic] {
        BatonHelpView.allTopicsForTesting()
    }

    /// The guides have to actually be in the bundle. If this fails, every other assertion
    /// here is meaningless, and search in the app is empty for a completely different
    /// reason than the one above.
    func testTheBundledGuidesLoad() {
        let all = topics()
        XCTAssertGreaterThan(all.count, 30, "the bundled guides did not load")
        XCTAssertTrue(all.contains { $0.title == "Scrobbling" },
                      "HELP.md parsed without its Scrobbling section")
    }

    /// The reported symptom, as a test.
    func testSearchingForAPartialWordFindsItsTopic() {
        let hits = BatonHelpView.ranked(topics(), query: "scrobb")
        XCTAssertTrue(hits.contains { $0.title == "Scrobbling" },
                      "searching \"scrobb\" found nothing — the id seam is broken again")
    }

    /// The question that was never answered while the bug was open: does *any* term work?
    /// It has to be more than one word, or a single lucky match hides a total failure.
    func testOrdinaryWordsAllFindSomething() {
        for word in ["queue", "podcast", "equalizer", "download", "radio", "playlist",
                     "gapless", "shortcut", "later", "folder"] {
            XCTAssertFalse(BatonHelpView.ranked(topics(), query: word).isEmpty,
                           "\"\(word)\" returned no results")
        }
    }

    /// Both guides have to be searchable, not just the one whose enum case happened to
    /// line up. The FAQ's raw values differed by case alone (`"faq"` vs `"FAQ"`), which is
    /// the same bug wearing a subtler hat.
    func testTheFAQIsSearchableToo() {
        let hits = BatonHelpView.ranked(topics(), query: "scrobb")
        XCTAssertTrue(hits.contains { $0.guideIsFAQForTesting },
                      "no FAQ topic was searchable")
    }

    /// A topic's identity is the shared topic's identity. If these ever diverge again,
    /// every lookup keyed on one and made from the other silently returns nothing.
    func testTopicIdentityIsTheSharedIdentity() {
        for topic in topics() {
            XCTAssertEqual(topic.id, topic.shared.id,
                           "a Topic grew an id of its own again")
        }
    }

    /// Nonsense finds nothing — otherwise "it always returns results" would pass the
    /// tests above without search working at all.
    func testAnUnmatchableQueryStillReturnsNothing() {
        XCTAssertTrue(BatonHelpView.ranked(topics(), query: "zzqqxwv").isEmpty)
    }
}

private extension BatonHelpView.Topic {
    var guideIsFAQForTesting: Bool { shared.guide == .faq }
}
