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

    // MARK: - The move onto VersionedStore (S-F14 / TBX-5354)

    /// Exactly what the pre-`VersionedStore` `save()` wrote: a raw array, no envelope.
    ///
    ///     let encoder = JSONEncoder()
    ///     encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    ///     try encoder.encode(exchanges).write(to: url, options: .atomic)
    private func writeLegacyFile(_ exchanges: [FriendExchange], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(exchanges).write(to: url, options: .atomic)
    }

    func testReadsAFileWrittenByTheOldCodeUnchanged() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("friend-log-legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var rated = exchange("play something quiet")
        rated.rating = .down
        rated.fault = .wrongTrack
        let legacy = [rated, exchange("no, quieter", played: ["A", "B"])]
        try writeLegacyFile(legacy, to: url)

        let log = FriendFeedbackLog(url: url)
        XCTAssertEqual(log.exchanges, legacy, "an upgrade must read the log the old build wrote")

        // And the write that follows keeps every one of them.
        log.record(exchange("something else"))
        let reopened = FriendFeedbackLog(url: url)
        XCTAssertEqual(reopened.exchanges.count, 3)
        XCTAssertEqual(Array(reopened.exchanges.suffix(2)), legacy)
        XCTAssertNil(reopened.exchanges.first?.rating, "the newly recorded exchange is unrated")
        XCTAssertEqual(reopened.exchanges[1].fault, .wrongTrack, "the rating did not survive")
    }

    func testACorruptFileIsQuarantinedRatherThanOverwritten() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("friend-log-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("music-friend-log.json")
        let damaged = Data(#"[{"id":"8B0E","request":"play some"#.utf8) // truncated mid-write
        try damaged.write(to: url)

        let log = FriendFeedbackLog(url: url)
        XCTAssertTrue(log.exchanges.isEmpty, "unreadable bytes cannot be presented as a log")
        log.record(exchange("the mutation that used to delete them"))

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let aside = try XCTUnwrap(names.first { $0.hasPrefix("music-friend-log.json.corrupt-") },
                                  "the damaged bytes were not kept: \(names)")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(aside)), damaged,
                       "the quarantined copy must be the original bytes, byte for byte")
        // The live file is a healthy envelope again, and the rescue is a separate file rather
        // than the fixed `.corrupt` name the old code reused for every corruption it met.
        XCTAssertEqual(FriendFeedbackLog(url: url).exchanges.count, 1)
    }
}
