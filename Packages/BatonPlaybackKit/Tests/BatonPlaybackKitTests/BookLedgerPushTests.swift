import BatonSubsonicKit
import XCTest
@testable import BatonPlaybackKit

/// A book's place goes to the other device when listening halts, in one debounced push
///. Before this it waited for the next foreground or the ten-minute heartbeat.
@MainActor
final class BookLedgerPushTests: XCTestCase {
    private var ledger = ClippingLedger()
    private var pushes = 0
    private var reachable = true

    private func pusher(delay: Duration = .milliseconds(60)) -> BookLedgerPush {
        BookLedgerPush(delay: delay, ledger: { [unowned self] in self.ledger }) { [unowned self] in
            self.pushes += 1
            return self.reachable
        }
    }

    private func move(to seconds: Double) {
        ledger.setPosition(documentID: "doc", chapterIndex: 1, seconds: seconds)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }

    func testABurstOfHaltsIsOnePushAfterTheDelay() async throws {
        let push = pusher()
        move(to: 10)
        push.schedule()   // pause
        push.schedule()   // stop
        push.schedule()   // switching away
        XCTAssertEqual(pushes, 0, "nothing goes before the delay")
        XCTAssertTrue(push.isPending)
        try await settle()
        XCTAssertEqual(pushes, 1, "one round trip covers the burst")
        XCTAssertFalse(push.isPending)
    }

    func testAnUnchangedLedgerIsNotPushedAgain() async throws {
        let push = pusher()
        move(to: 10)
        push.schedule()
        try await settle()
        push.schedule()   // pausing a song: the book ledger has not moved
        try await settle()
        XCTAssertEqual(pushes, 1)

        move(to: 20)
        push.schedule()
        try await settle()
        XCTAssertEqual(pushes, 2, "a moved position goes")
    }

    func testAPushThatDidNotLandIsTriedAtTheNextHalt() async throws {
        let push = pusher()
        reachable = false
        move(to: 10)
        push.schedule()
        try await settle()
        reachable = true
        push.schedule()
        try await settle()
        XCTAssertEqual(pushes, 2)
    }

    /// Leaving the foreground on the phone: at once, inside the background task, and in place of
    /// a pause push still waiting.
    func testFlushPushesAtOnceAndTakesThePlaceOfAWaitingPush() async throws {
        let push = pusher(delay: .seconds(30))
        move(to: 10)
        push.schedule()
        await push.flush()
        XCTAssertEqual(pushes, 1)
        XCTAssertFalse(push.isPending)
        try await settle()
        XCTAssertEqual(pushes, 1)
    }

    func testCancelDropsAWaitingPush() async throws {
        let push = pusher()
        move(to: 10)
        push.schedule()
        push.cancel()
        try await settle()
        XCTAssertEqual(pushes, 0)
    }

    /// The transport's ways of halting all reach a hook; the apps hang the push on them. The end
    /// of the queue is one: a book played to its end is when the finished mark has to travel, and
    /// the TBX-10986 walk saw the Mac finish a book and push nothing until it next synced.
    func testPauseStopAndTheEndOfTheQueueCallTheirHooks() {
        let controller = StreamingPlaybackController(defaults: UserDefaults(suiteName: ThrowawayDefaults.name("ledger-push"))!)
        var halted: [String] = []
        controller.onPause = { halted.append("pause") }
        controller.onStop = { halted.append("stop") }
        controller.pause()
        controller.stop()
        controller.endOfQueue()
        XCTAssertEqual(halted, ["pause", "stop", "stop"])
    }
}
