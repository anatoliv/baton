import XCTest
@testable import BatonAgentKit
import BatonSubsonicKit
import BatonSubsonicModels

/// The memory behind follow-ups. Bounded and forgetful on purpose: context costs
/// tokens on every request, and a stale reference is worse than none at all.
@MainActor
final class RemoteConversationLogTests: XCTestCase {
    func testKeepsExchangesOldestFirst() {
        let log = RemoteConversationLog()
        log.record(key: "k", user: "show me dido", assistant: "Songs: White Flag…")
        log.record(key: "k", user: "select one", assistant: "Playing White Flag")

        let history = log.history(for: "k")
        XCTAssertEqual(history.map(\.role), ["user", "assistant", "user", "assistant"])
        XCTAssertEqual(history.first?.text, "show me dido")
        XCTAssertEqual(history.last?.text, "Playing White Flag")
    }

    /// Unbounded history would grow the cost of every later message.
    func testOldExchangesFallOffTheBack() {
        let log = RemoteConversationLog(maxExchanges: 2)
        for i in 1...5 { log.record(key: "k", user: "msg \(i)", assistant: "reply \(i)") }

        let history = log.history(for: "k")
        XCTAssertEqual(history.count, 4, "2 exchanges = 4 turns")
        XCTAssertEqual(history.first?.text, "msg 4")
        XCTAssertFalse(history.contains { $0.text == "msg 1" })
    }

    /// A long search result is useful as a referent without being carried in
    /// full for the rest of the conversation.
    func testLongRepliesAreTruncated() {
        let log = RemoteConversationLog()
        log.record(key: "k", user: "search", assistant: String(repeating: "x", count: 5000))
        XCTAssertEqual(log.history(for: "k").last?.text.count, 1500)
    }

    /// Tomorrow's "play it again" should not resolve against last week.
    func testAQuietThreadGoesStale() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let log = RemoteConversationLog(idleTimeout: 60, now: { now })
        log.record(key: "k", user: "hi", assistant: "hello")
        XCTAssertFalse(log.history(for: "k").isEmpty)

        now = now.addingTimeInterval(61)
        XCTAssertTrue(log.history(for: "k").isEmpty, "stale context must not resurface")
    }

    func testChatsDoNotShareContext() {
        let log = RemoteConversationLog()
        log.record(key: "telegram:1", user: "a", assistant: "b")
        XCTAssertTrue(log.history(for: "telegram:2").isEmpty)
        XCTAssertTrue(log.history(for: "discord:1").isEmpty)
    }

    func testForgetClearsOneThreadOnly() {
        let log = RemoteConversationLog()
        log.record(key: "one", user: "a", assistant: "b")
        log.record(key: "two", user: "c", assistant: "d")
        log.forget(key: "one")
        XCTAssertTrue(log.history(for: "one").isEmpty)
        XCTAssertFalse(log.history(for: "two").isEmpty)
    }
}
