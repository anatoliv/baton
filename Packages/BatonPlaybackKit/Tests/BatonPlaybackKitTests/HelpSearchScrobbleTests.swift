import XCTest
@testable import BatonPlaybackKit

/// The in-app Help search returned "No results" for "scrobb" while HELP.md carries a full
/// Scrobbling section. Parser and scorer both look correct by inspection, so this pins which
/// half is lying.
final class HelpSearchScrobbleTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func allTopics() throws -> [HelpGuide.Topic] {
        let help = try String(contentsOf: root.appendingPathComponent("HELP.md"), encoding: .utf8)
        let faq = try String(contentsOf: root.appendingPathComponent("FAQ.md"), encoding: .utf8)
        return HelpGuide.topics(help: help, faq: faq)
    }

    func testTheScrobblingTopicIsParsed() throws {
        let titles = try allTopics().map(\.title)
        XCTAssertTrue(titles.contains("Scrobbling"), "parsed titles: \(titles.prefix(40))")
    }

    func testPartialWordFindsIt() throws {
        let topics = try allTopics()
        for query in ["scrobb", "scrobbling", "scrobble", "last.fm", "listenbrainz", "play count"] {
            let scores = HelpGuide.scores(topics, query: query)
            let hits = topics.filter { scores[$0.id] != nil }.map(\.title)
            XCTAssertFalse(hits.isEmpty, "\"\(query)\" found nothing")
        }
    }
}
