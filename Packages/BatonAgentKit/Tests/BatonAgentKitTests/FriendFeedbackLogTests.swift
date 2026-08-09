import XCTest
@testable import BatonAgentKit

/// The log is the substrate for improving the music friend, so the things that make it
/// *useful* — not merely storable — are what is pinned here.
@MainActor
final class FriendFeedbackLogTests: XCTestCase {

    private func makeLog(limit: Int = 500) -> FriendFeedbackLog {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("friend-log-\(UUID().uuidString).json")
        return FriendFeedbackLog(url: url, limit: limit)
    }

    private func exchange(_ request: String, played: [String] = []) -> FriendExchange {
        FriendExchange(surface: .phone, request: request, reply: "ok", played: played)
    }

    func testNewestFirstAndPersisted() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("friend-log-\(UUID().uuidString).json")
        let log = FriendFeedbackLog(url: url)
        log.record(exchange("play something quiet"))
        log.record(exchange("no, quieter"))

        XCTAssertEqual(log.exchanges.first?.request, "no, quieter",
                       "a log a person reads wants the newest at the top")

        // Reopened from disk, because a log that dies with the process cannot inform
        // anything a fortnight later, which is the whole point.
        let reopened = FriendFeedbackLog(url: url)
        XCTAssertEqual(reopened.exchanges.count, 2)
        XCTAssertEqual(reopened.exchanges.first?.request, "no, quieter")
    }

    /// Rating happens *after* the fact — the wrong track is usually only obviously wrong a
    /// verse later — so it has to reach back to an exchange already recorded.
    func testRatingReachesBackAndSurvivesAReopen() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("friend-log-\(UUID().uuidString).json")
        let log = FriendFeedbackLog(url: url)
        log.record(exchange("play my trance", played: ["Something Wrong"]))
        let id = try! XCTUnwrap(log.exchanges.first?.id)

        XCTAssertTrue(log.rate(id, .down, fault: .wrongTrack, note: "I meant Classic Trance"))

        let reopened = FriendFeedbackLog(url: url)
        XCTAssertEqual(reopened.exchanges.first?.fault, .wrongTrack)
        XCTAssertEqual(reopened.exchanges.first?.note, "I meant Classic Trance",
                       "the person's own words are the most valuable thing in the record")
    }

    /// A thumbs-up must not carry a fault. "Good, but wrong track" is not a thing, and
    /// storing it would poison every tally built on faults.
    func testAThumbsUpCarriesNoFault() {
        let log = makeLog()
        log.record(exchange("play something"))
        let id = log.exchanges[0].id
        log.rate(id, .up, fault: .wrongTrack)
        XCTAssertNil(log.exchanges[0].fault)
    }

    /// The tally is what answers "what should I fix next", so it has to be ordered by
    /// how often something goes wrong rather than by when it did.
    func testTheTallyRanksFaultsByFrequency() {
        let log = makeLog()
        for text in ["a", "b", "c", "d"] { log.record(exchange(text)) }
        let ids = log.exchanges.map(\.id)
        log.rate(ids[0], .down, fault: .misunderstood)
        log.rate(ids[1], .down, fault: .wrongTrack)
        log.rate(ids[2], .down, fault: .wrongTrack)
        log.rate(ids[3], .up)

        XCTAssertEqual(log.faultTally.first?.fault, .wrongTrack)
        XCTAssertEqual(log.faultTally.first?.count, 2)
    }

    /// Capped, and it drops the *oldest*. A log that grows without limit stops being read
    /// and starts being a liability.
    func testItKeepsTheNewestWithinItsCap() {
        let log = makeLog(limit: 3)
        for text in ["1", "2", "3", "4", "5"] { log.record(exchange(text)) }
        XCTAssertEqual(log.exchanges.count, 3)
        XCTAssertEqual(log.exchanges.map(\.request), ["5", "4", "3"])
    }

    /// The log screen shows what it *did*, not just what it said — "played the wrong thing"
    /// is unactionable a week later without it.
    func testResolutionSaysWhatHappened() {
        let played = FriendExchange(surface: .mac, request: "x", reply: "y",
                                    played: ["A", "B", "C", "D"])
        XCTAssertEqual(played.resolution, "played A, B, C +1 more")

        let acted = FriendExchange(surface: .telegram, request: "x", reply: "y",
                                   actions: [.init(tool: "music_search", arguments: "q: trance", succeeded: true)])
        XCTAssertEqual(acted.resolution, "music_search")

        let answered = FriendExchange(surface: .mcp, request: "what's playing", reply: "Yello")
        XCTAssertEqual(answered.resolution, "answered")
    }
}
