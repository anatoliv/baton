import Foundation
import XCTest
@testable import BatonGatewayCore

/// The device long-poll.
///
/// Found in production rather than by reading: `docker logs baton-gateway` on the gateway host carried
/// four of these over a single uptime —
///
///     SWIFT TASK CONTINUATION MISUSE: awaitCommand(timeout:) leaked its continuation!
///
/// `waitingDevice` was one slot and `awaitCommand` assigned into it, so a second device polling
/// while the first was parked overwrote that continuation without resuming it. The first poll
/// never returned. Two devices is the ordinary case — the Mac and the phone both hold this open
/// whenever both are running — so the slot was being clobbered as a matter of routine.
///
/// **Everything here runs under `withDeadline`, and that is not decoration.** A leaked
/// continuation cannot be caught by awaiting the call that leaks it, because that call never
/// returns — the first two drafts of this file did not fail against the old code, they *hung*,
/// and `swift test` had to be killed by hand twice. A test that hangs on regression is worse
/// than no test: on the gate it stops being a signal and becomes a stall to be waited out.
///
/// As written it fails in about ten seconds, naming the leak, with the runtime's own
/// `SWIFT TASK CONTINUATION MISUSE` line alongside it. Verified by reverting the fix.
final class DeviceLinkTests: XCTestCase {

    /// A result slot the test can watch without awaiting the work that fills it.
    private actor Box<T: Sendable> {
        private var value: T?
        func set(_ newValue: T) { value = newValue }
        func get() -> T? { value }
    }

    /// Run `work` **unstructured**, and give up on it if it never finishes.
    ///
    /// The obvious version of this — a `withTaskGroup` racing the work against a sleep — cannot
    /// work here, and finding that out is half the value of this file. A task group awaits every
    /// child at scope exit, and `cancelAll()` cannot finish a task suspended on a continuation
    /// nobody will ever resume, so the group blocks for ever and takes the suite with it. Against
    /// the old code `swift test` had to be killed twice, at five minutes and then at three.
    ///
    /// Detaching and polling a box leaves the leaked task exactly where the bug leaves it — stuck
    /// — while the test walks away and fails with a sentence.
    private func withDeadline<T: Sendable>(
        _ seconds: Double = 5,
        _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        let box = Box<T>()
        Task.detached { await box.set(await work()) }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let value = await box.get() { return value }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// The leak itself. Two devices park, one command arrives, and **both** calls must return —
    /// one with the command, one empty when its own hold expires.
    func testASecondPollDoesNotStrandTheFirst() async {
        let link = DeviceLink()

        let outcome = await withDeadline {
            async let first = link.awaitCommand(timeout: 1.5)
            try? await Task.sleep(for: .milliseconds(120))
            async let second = link.awaitCommand(timeout: 1.5)
            try? await Task.sleep(for: .milliseconds(120))
            _ = await link.dispatch(name: "music_pause", argumentsJSON: Data("{}".utf8), timeout: 0.3)
            return await [first, second]
        }

        guard let results = outcome else {
            return XCTFail("a parked poll never came back — its continuation was leaked")
        }
        XCTAssertEqual(results.count, 2, "every parked poll must return")
        let delivered = results.compactMap { $0 }
        XCTAssertEqual(delivered.count, 1, "exactly one device should receive the command")
        XCTAssertEqual(delivered.first?.name, "music_pause")
    }

    /// Each waiter is expired by its own timer. `expirePoll` used to resume whatever happened to
    /// be waiting, so a device that parked first could end a later device's hold early — and,
    /// once more than one can be parked, could resume a continuation that was already resumed.
    func testEachPollExpiresOnItsOwnSchedule() async {
        let link = DeviceLink()

        let elapsed = await withDeadline { () -> TimeInterval? in
            async let quick = link.awaitCommand(timeout: 0.3)
            try? await Task.sleep(for: .milliseconds(60))
            async let slow = link.awaitCommand(timeout: 2.0)

            let started = Date()
            let quickResult = await quick
            let took = Date().timeIntervalSince(started)

            // Release the long hold so nothing is left parked behind this test.
            _ = await link.dispatch(name: "music_resume", argumentsJSON: Data("{}".utf8), timeout: 0.3)
            _ = await slow

            return quickResult == nil ? took : nil
        }

        guard let elapsed = elapsed as? TimeInterval else {
            return XCTFail("the short hold did not expire on its own — it returned late, or not at all")
        }
        XCTAssertLessThan(elapsed, 1.5, "the short hold must not wait on the long one")
    }

    /// A command arriving with nobody parked queues, and the next poll takes it — **while the
    /// caller is still waiting for it**.
    ///
    /// The timing used to be implicit and is now stated (TBX-5308, S-F12): the dispatch and the
    /// poll overlap, because a command is only worth delivering while somebody is still listening
    /// for the answer. The old version of this test let the dispatch expire first and then
    /// collected the command anyway, which is precisely the defect the card is about.
    func testACommandWithNoDeviceWaitingIsQueuedForTheNextPoll() async {
        let link = DeviceLink()

        let queued = await withDeadline { () -> DeviceLink.Command? in
            // Park and release one poll first: `dispatch` refuses unless a device has polled
            // recently, which is what makes "no device is listening" answerable honestly.
            async let warmUp = link.awaitCommand(timeout: 0.3)
            try? await Task.sleep(for: .milliseconds(60))
            _ = await link.dispatch(name: "music_next", argumentsJSON: Data("{}".utf8), timeout: 0.3)
            _ = await warmUp

            // The dispatch is left running: nothing is parked, so the command is queued and this
            // call waits a second for its answer while the poll below collects it.
            async let dispatched: Void = { _ = await link.dispatch(
                name: "music_previous", argumentsJSON: Data("{}".utf8), timeout: 1.0) }()
            try? await Task.sleep(for: .milliseconds(60))
            let collected = await link.awaitCommand(timeout: 1.0)
            await dispatched
            return collected
        }

        XCTAssertEqual((queued as? DeviceLink.Command)?.name, "music_previous",
                       "a queued command is handed to the next poll")
    }

    // MARK: - Expiry (TBX-5308, S-F12)

    /// A command whose caller has given up must not be played a minute later.
    ///
    /// `dispatch` waited 20 s and `expireResult` removed only the `pendingResults` entry, so the
    /// command itself stayed in the queue for ever: the agent answered "The device didn't answer
    /// in time" and the next poll started the music anyway.
    func testACommandNobodyIsWaitingForAnyMoreIsNotDelivered() async {
        let link = DeviceLink()

        let outcome = await withDeadline { () -> (String?, Int) in
            async let warmUp = link.awaitCommand(timeout: 0.3)
            try? await Task.sleep(for: .milliseconds(60))
            _ = await link.dispatch(name: "music_next", argumentsJSON: Data("{}".utf8), timeout: 0.3)
            _ = await warmUp

            // Nothing is parked, so this queues — and this time it is allowed to expire.
            let answer = await link.dispatch(name: "music_play", argumentsJSON: Data("{}".utf8), timeout: 0.3)
            let collected = await link.awaitCommand(timeout: 0.3)
            return (collected?.name, await link.queuedCommandCount)
        }

        guard let (delivered, queued) = outcome as? (String?, Int) else {
            return XCTFail("a parked poll never came back")
        }
        XCTAssertNil(delivered, "an expired command must not be handed to a later poll")
        XCTAssertEqual(queued, 0, "and must not be left in the queue either")
    }

    /// Turns that nobody collects must not pile up without bound.
    func testTheQueueStaysBounded() async {
        let link = DeviceLink()

        let queued = await withDeadline { () -> Int in
            async let warmUp = link.awaitCommand(timeout: 0.3)
            try? await Task.sleep(for: .milliseconds(60))
            _ = await link.dispatch(name: "music_next", argumentsJSON: Data("{}".utf8), timeout: 0.3)
            _ = await warmUp

            // Thirty commands, none collected. Each dispatch is left running so they are all
            // still live: without a ceiling, all thirty would sit in the queue.
            return await withTaskGroup(of: Void.self, returning: Int.self) { group in
                for index in 0 ..< 30 {
                    group.addTask {
                        _ = await link.dispatch(name: "music_play_\(index)",
                                                argumentsJSON: Data("{}".utf8), timeout: 0.4)
                    }
                }
                try? await Task.sleep(for: .milliseconds(150))
                let peak = await link.queuedCommandCount
                await group.waitForAll()
                return peak
            }
        }

        guard let peak = queued as? Int else { return XCTFail("the dispatches never settled") }
        XCTAssertLessThanOrEqual(peak, 16, "the queue must be bounded, saw \(peak)")
        XCTAssertGreaterThan(peak, 0, "and must still be queueing, or this asserts nothing")
    }
}
