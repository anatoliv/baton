import BatonPlaybackKit
import XCTest
@testable import BatonMobile

/// Every "Learn more" in Settings must open Help at a topic that exists.
///
/// Settings copy is deliberately short now, with the full explanation one tap away in the
/// guide. That trade only works if the tap lands: a link pointing at a heading someone
/// later renamed opens Help at nothing, and no other test in the project would notice.
/// This is the same failure mode as What's New, which sat three releases stale until
/// something was made to fail over it.
@MainActor
final class SettingsHelpLinkTests: XCTestCase {
    private var topics: [HelpGuide.Topic] {
        HelpGuide.topics(help: HelpView.markdown("HELP"), faq: HelpView.markdown("FAQ"))
    }

    func testTheGuidesAreActuallyInTheBundle() {
        XCTAssertGreaterThan(topics.count, 20,
                             "the prebuild step copies HELP.md and FAQ.md in — without them every link below is vacuous")
    }

    func testEverySettingsHelpTopicResolves() {
        let slugs = Set(topics.map(\.slug))

        for topic in SettingsHelpTopic.all {
            XCTAssertTrue(slugs.contains(topic),
                          "Settings links to '\(topic)', which is not a heading in HELP.md or FAQ.md")
        }
    }

    /// A topic that resolves but has nothing under it is a link to a blank screen.
    func testEveryLinkedTopicHasSomethingToRead() {
        for slug in SettingsHelpTopic.all {
            guard let topic = topics.first(where: { $0.slug == slug }) else { continue }
            XCTAssertGreaterThan(topic.body.count, 80, "'\(slug)' is too short to be worth a tap")
        }
    }

    /// The contents list is built from these, so a duplicate slug would show the same
    /// row twice and make deep links ambiguous.
    func testTopicSlugsAreUniqueWithinAGuide() {
        for guide in HelpGuide.Kind.allCases {
            let slugs = topics.filter { $0.guide == guide }.map(\.slug)
            XCTAssertEqual(Set(slugs).count, slugs.count,
                           "duplicate headings in \(guide.resource).md: \(Dictionary(grouping: slugs, by: { $0 }).filter { $0.value.count > 1 }.keys)")
        }
    }
}
