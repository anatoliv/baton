import XCTest
@testable import BatonAgentKit

/// Rating from a chat bridge, and the reason a bare thumb has to be handled before the
/// parser ever sees it.
@MainActor
final class FriendRemoteFeedbackTests: XCTestCase {

    private func makeLog() -> FriendFeedbackLog {
        FriendFeedbackLog(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remote-log-\(UUID().uuidString).json"))
    }

    /// A thumbs-down message carrying words keeps them. What someone types straight after a
    /// bad answer is usually the most useful sentence in the record — more useful than any
    /// fault category, because it says what they actually meant.
    func testADownWithWordsKeepsThem() {
        let log = makeLog()
        log.record(FriendExchange(surface: .telegram, request: "play my trance", reply: "…"))
        let id = log.exchanges[0].id

        log.rate(id, .down, note: "I meant the Classic Trance playlist")

        XCTAssertEqual(log.exchanges[0].rating, .down)
        XCTAssertEqual(log.exchanges[0].note, "I meant the Classic Trance playlist")
    }

    /// A rating must find the last exchange *on its own surface*. Telegram rating whatever
    /// the phone last did would attach a complaint to an answer the person never saw.
    func testARatingFindsTheLastExchangeOnItsOwnSurface() {
        let log = makeLog()
        log.record(FriendExchange(surface: .telegram, request: "telegram question", reply: "a"))
        log.record(FriendExchange(surface: .phone, request: "phone question", reply: "b"))

        let lastTelegram = log.exchanges.first { $0.surface == .telegram }
        XCTAssertEqual(lastTelegram?.request, "telegram question",
                       "a thumb on Telegram must not rate what the phone did")
    }

    /// The learning store takes a remote thumbs-down like any other, and the correction
    /// still cites its exchange — the rule does not soften because the rating arrived over
    /// a chat bridge.
    func testRemoteRatingsTeachWithTheSameProvenance() {
        let log = makeLog()
        let learning = FriendLearningStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remote-learn-\(UUID().uuidString).json"))
        log.record(FriendExchange(surface: .discord, request: "something for the gym", reply: "…"))
        let id = log.exchanges[0].id
        log.rate(id, .down, fault: .wrongTrack, note: "not ambient, something with a beat")

        let learned = learning.learn(from: log.exchanges[0])

        XCTAssertEqual(learned?.exchangeID, id)
        XCTAssertEqual(learned?.request, "something for the gym")
        XCTAssertTrue(learned?.promptLine.contains("not ambient") ?? false)
    }
}
