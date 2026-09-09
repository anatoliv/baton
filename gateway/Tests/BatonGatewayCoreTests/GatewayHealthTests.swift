import Foundation
import XCTest
@testable import BatonGatewayCore

/// What `/health` can now say about the device poll.
///
/// The card this comes from is not "add a field". It is that the gateway had **no way at all** to
/// tell a working long-poll from one nothing had touched in a week: the empty poll is dropped
/// from the request log by design, a poll only logs 200 when it carries a command, and
/// no command had been dispatched in the whole window — so `/v1/device/poll` appeared zero times
/// over 25,118 lines whether it ran ten thousand times or never.
///
/// So every test here is written against that question rather than against the fields. The two
/// states are built for real, driven through `awaitCommand`, and the rendered bodies are compared:
/// a test that only asserted `polls_served` exists would be the same non-check the card is about.
/// Two fixed probe results, so the poll-counter tests above can stay about poll counters.
extension HealthProbe.Report {
    /// Navidrome answered, quickly.
    static let healthy = HealthProbe.Report(outcome: .answered, elapsed: 0.084, timeout: 2)
    /// Navidrome said nothing at all inside the bound — the state TBX-5069 is about.
    static let silent = HealthProbe.Report(outcome: .timedOut, elapsed: 2.001, timeout: 2)
}

final class GatewayHealthTests: XCTestCase {

    /// A result slot the test can watch without awaiting the work that fills it.
    private actor Box<T: Sendable> {
        private var value: T?
        func set(_ newValue: T) { value = newValue }
        func get() -> T? { value }
    }

    /// Run `work` unstructured and give up on it if it never finishes — the same guard
    /// `DeviceLinkTests` explains at length. A poll that leaks its continuation never returns, so
    /// a test that awaits one directly hangs the suite instead of failing it.
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

    private func decode(_ body: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                      "the health body must be JSON")
    }

    private func deviceLink(_ body: String) throws -> [String: Any] {
        try XCTUnwrap(try decode(body)["device_link"] as? [String: Any])
    }

    // MARK: - The question the card exists to answer

    /// **The acceptance test.** One gateway has been polled; the other has not been touched since
    /// it started. Their `/health` bodies must not be able to be confused for one another.
    func testAPolledGatewayReadsDifferentlyFromOneNobodyHasPolled() async throws {
        let started = Date().addingTimeInterval(-3600)
        let idle = DeviceLink()
        let busy = DeviceLink()

        let polled = await withDeadline {
            _ = await busy.awaitCommand(timeout: 0.15)   // one hold, expiring empty — a 204
            _ = await busy.awaitCommand(timeout: 0.15)   // and the immediate re-poll after it
            return true
        }
        XCTAssertEqual(polled, true, "the polls must have returned before the body is read")

        let idleBody = GatewayHealth.body(navidrome: .healthy, startedAt: started, polls: await idle.pollStats)
        let busyBody = GatewayHealth.body(navidrome: .healthy, startedAt: started, polls: await busy.pollStats)

        XCTAssertNotEqual(idleBody, busyBody, "the two states must not render identically")

        let idleLink = try deviceLink(idleBody)
        XCTAssertEqual(idleLink["polls_served"] as? Int, 0)
        XCTAssertEqual(idleLink["device_connected"] as? Bool, false)
        XCTAssertTrue(idleLink["last_poll_seconds_ago"] is NSNull,
                      "a gateway nothing has polled must say so, not report an age of zero")
        XCTAssertEqual(idleLink["summary"] as? String,
                       "no device has polled in the 3600s this process has been up")

        let busyLink = try deviceLink(busyBody)
        XCTAssertEqual(busyLink["polls_served"] as? Int, 2)
        XCTAssertEqual(busyLink["device_connected"] as? Bool, true)
        let ago = try XCTUnwrap(busyLink["last_poll_seconds_ago"] as? Int)
        XCTAssertLessThan(ago, 5, "the poll just happened")
        XCTAssertTrue((busyLink["summary"] as? String ?? "").hasPrefix("last device poll "),
                      "the summary must name the recency, got: \(busyLink["summary"] ?? "nil")")
    }

    /// A poll that has *stopped* is the third state, and the one a stale gateway is actually in:
    /// counters non-zero, but nothing recent. `device_connected` has to fall over, or a gateway
    /// whose phone disconnected on Monday still reads as live on Friday.
    func testAGatewayThatWasPolledLongAgoDoesNotStillReadAsConnected() throws {
        let stale = DeviceLink.PollStats(
            pollsServed: 4_231, commandsDelivered: 2, waitersParked: 0, peakWaitersParked: 2,
            lastPollAt: Date().addingTimeInterval(-7 * 24 * 3600), isDeviceConnected: false
        )
        let body = GatewayHealth.body(navidrome: .healthy, startedAt: Date().addingTimeInterval(-8 * 24 * 3600),
                                      polls: stale)
        let link = try deviceLink(body)
        XCTAssertEqual(link["device_connected"] as? Bool, false)
        XCTAssertEqual(link["last_poll_seconds_ago"] as? Int, 604_800,
                       "a week-old poll must be reported as a week old")
        XCTAssertGreaterThan(link["polls_served"] as? Int ?? 0, 0,
                             "the counters still hold the history — recency is the separate signal")
    }

    // MARK: - The signal TBX-4029 needs

    /// `peak_waiters_parked` is what makes `grep -c MISUSE` → 0 mean something.
    ///
    /// The leak needed **two waiters parked at the same time**; with one it cannot fire at all.
    /// So a peak of 1 turns that zero into "never tested", and a peak of 2 turns it into a pass.
    /// The 2026-09-05 audit had no way to tell those apart, which is why TBX-4029 was reopened.
    func testPeakWaitersDistinguishesNeverTestedFromSurvivedTheTwoDeviceCase() async throws {
        let sequential = DeviceLink()
        let overlapping = DeviceLink()

        let ran = await withDeadline { () -> Bool in
            // One at a time: each hold returns before the next begins.
            _ = await sequential.awaitCommand(timeout: 0.15)
            _ = await sequential.awaitCommand(timeout: 0.15)

            // Both parked at once — the shape that used to strand the first continuation.
            async let first = overlapping.awaitCommand(timeout: 0.6)
            try? await Task.sleep(for: .milliseconds(80))
            async let second = overlapping.awaitCommand(timeout: 0.6)
            _ = await [first, second]
            return true
        }
        XCTAssertEqual(ran, true, "a parked poll never came back — its continuation was leaked")

        let sequentialStats = await sequential.pollStats
        XCTAssertEqual(sequentialStats.pollsServed, 2)
        XCTAssertEqual(sequentialStats.peakWaitersParked, 1,
                       "polls that never overlap cannot have exercised the leak")

        let overlappingStats = await overlapping.pollStats
        XCTAssertEqual(overlappingStats.peakWaitersParked, 2,
                       "two simultaneous holds must be visible after the fact")

        // And it survives into the body, which is where a person reads it.
        let body = GatewayHealth.body(navidrome: .healthy, startedAt: Date().addingTimeInterval(-60),
                                      polls: overlappingStats)
        XCTAssertEqual(try deviceLink(body)["peak_waiters_parked"] as? Int, 2)
    }

    /// The live gauge, as distinct from the counters: parked while held, back to zero once the
    /// holds return. A waiter count that only ever grew would say nothing about *now*.
    func testWaitersParkedIsLiveAndReturnsToZero() async throws {
        let link = DeviceLink()

        let parkedWhileHeld = await withDeadline { () -> Int in
            async let hold = link.awaitCommand(timeout: 0.6)
            try? await Task.sleep(for: .milliseconds(120))
            let during = await link.pollStats.waitersParked
            _ = await hold
            return during
        }

        XCTAssertEqual(parkedWhileHeld, 1, "a device holding a poll open must be visible as parked")
        let after = await link.pollStats
        XCTAssertEqual(after.waitersParked, 0, "nothing is parked once the hold has returned")
        XCTAssertEqual(after.pollsServed, 1, "the poll is still counted after it returns")
    }

    /// `polls_served` counts every hold; `commands_delivered` only the ones that carried work.
    /// The second is what the request log can already see (a poll logs 200 only with a command),
    /// so the gap between them is precisely the traffic that was invisible.
    func testCommandsDeliveredCountsOnlyThePollsThatCarriedWork() async throws {
        let link = DeviceLink()

        let ran = await withDeadline { () -> Bool in
            async let hold = link.awaitCommand(timeout: 1.0)
            try? await Task.sleep(for: .milliseconds(100))
            _ = await link.dispatch(name: "music_pause", argumentsJSON: Data("{}".utf8), timeout: 0.3)
            _ = await hold
            _ = await link.awaitCommand(timeout: 0.15)   // and one that expires empty
            return true
        }
        XCTAssertEqual(ran, true, "a parked poll never came back")

        let stats = await link.pollStats
        XCTAssertEqual(stats.pollsServed, 2)
        XCTAssertEqual(stats.commandsDelivered, 1,
                       "only the hold that received the command counts as delivered")
    }

    /// A command that arrives with nobody parked is queued and handed to the next poll — that
    /// path returns from a different branch of `awaitCommand`, and must still be counted.
    ///
    /// **The timing is explicit now** (TBX-5308, S-F12). This test used to let the second dispatch
    /// expire and then collect its command anyway, which is the defect that card is about: a
    /// command nobody is waiting for is dropped rather than played a minute later. So the dispatch
    /// is left running while the poll collects it, which is the case the counter is really about.
    func testAQueuedCommandCollectedByTheNextPollIsCountedToo() async throws {
        let link = DeviceLink()

        let ran = await withDeadline { () -> Bool in
            async let warmUp = link.awaitCommand(timeout: 0.5)
            try? await Task.sleep(for: .milliseconds(80))
            _ = await link.dispatch(name: "music_next", argumentsJSON: Data("{}".utf8), timeout: 0.3)
            _ = await warmUp

            async let dispatched: Void = { _ = await link.dispatch(
                name: "music_previous", argumentsJSON: Data("{}".utf8), timeout: 1.0) }()
            try? await Task.sleep(for: .milliseconds(80))
            _ = await link.awaitCommand(timeout: 0.5)    // takes the queued command immediately
            await dispatched
            return true
        }
        XCTAssertEqual(ran, true, "a parked poll never came back")

        let stats = await link.pollStats
        XCTAssertEqual(stats.pollsServed, 2)
        XCTAssertEqual(stats.commandsDelivered, 2,
                       "the queued-then-collected path must be counted, not just the parked one")
    }

    // MARK: - Restart amnesia, and what the route may not leak

    /// The counters are in memory and a container restart zeroes them, so `polls_served: 0` is
    /// ambiguous on its own. Uptime travels beside them and the summary states both, so a reader
    /// is never left to work out which of the two zeroes they are looking at.
    func testZeroPollsIsReadableBecauseUptimeTravelsWithIt() throws {
        let fresh = DeviceLink.PollStats(pollsServed: 0, commandsDelivered: 0, waitersParked: 0,
                                         peakWaitersParked: 0, lastPollAt: nil,
                                         isDeviceConnected: false)
        let justRestarted = try deviceLink(
            GatewayHealth.body(navidrome: .healthy, startedAt: Date().addingTimeInterval(-4), polls: fresh))
        let upForAWeek = try deviceLink(
            GatewayHealth.body(navidrome: .healthy, startedAt: Date().addingTimeInterval(-7 * 24 * 3600),
                               polls: fresh))

        XCTAssertEqual(justRestarted["summary"] as? String,
                       "no device has polled in the 4s this process has been up",
                       "four seconds of zero polls is not a finding")
        XCTAssertEqual(upForAWeek["summary"] as? String,
                       "no device has polled in the 604800s this process has been up",
                       "a week of zero polls is")
        XCTAssertNotEqual(justRestarted["summary"] as? String, upForAWeek["summary"] as? String)
        XCTAssertEqual(justRestarted["counters_since"] as? String,
                       "started_at — they reset on restart, so read them next to uptime_seconds")
    }

    /// `/health` is the one unauthenticated route (`main.swift`), so the body is pinned to an
    /// exact key set. Counts and ages are fine; a device identifier, an address or anything
    /// carrying a token is not, and a future field would have to pass through this test to land.
    func testTheUnauthenticatedBodyCarriesCountsAndNothingIdentifying() throws {
        let polls = DeviceLink.PollStats(pollsServed: 9, commandsDelivered: 1, waitersParked: 1,
                                         peakWaitersParked: 2, lastPollAt: Date(),
                                         isDeviceConnected: true)
        let body = GatewayHealth.body(navidrome: .healthy, startedAt: Date().addingTimeInterval(-90),
                                      polls: polls)

        XCTAssertEqual(Set(try decode(body).keys),
                       ["status", "started_at", "uptime_seconds", "device_link", "navidrome"])
        XCTAssertEqual(Set(try XCTUnwrap(try decode(body)["navidrome"] as? [String: Any]).keys),
                       ["reachable", "probe", "probe_ms", "probe_timeout_ms", "summary"],
                       "the probe reports timings, never the server it probed")
        XCTAssertFalse(body.lowercased().contains("http"),
                       "the probe must not name the Navidrome URL to an anonymous caller")
        XCTAssertEqual(Set(try deviceLink(body).keys),
                       ["polls_served", "commands_delivered", "waiters_parked",
                        "peak_waiters_parked", "device_connected", "last_poll_seconds_ago",
                        "counters_since", "summary"])
        for forbidden in ["token", "bearer", "authorization", "device_id", "uuid", "address"] {
            XCTAssertFalse(body.lowercased().contains(forbidden),
                           "the unauthenticated health body must not carry \(forbidden)")
        }
    }

    /// Navidrome's reachability is what `/health` said before this card, and it still says it —
    /// the same two strings, so anything already reading `status` keeps working. What changed is
    /// that they are now *derived* from the probe rather than computed beside it in the route
    ///, which is what makes the headline and the detail unable to disagree.
    func testTheExistingStatusStringsAreUnchangedAndComeFromTheProbe() throws {
        let polls = DeviceLink.PollStats(pollsServed: 0, commandsDelivered: 0, waitersParked: 0,
                                         peakWaitersParked: 0, lastPollAt: nil, isDeviceConnected: false)
        let ok = try decode(GatewayHealth.body(navidrome: .healthy, startedAt: Date(), polls: polls))
        let down = try decode(GatewayHealth.body(navidrome: .silent,
                                                 startedAt: Date(), polls: polls))
        XCTAssertEqual(ok["status"] as? String, "ok")
        XCTAssertEqual(down["status"] as? String, "navidrome-unreachable")

        XCTAssertEqual((ok["navidrome"] as? [String: Any])?["reachable"] as? Bool, true)
        XCTAssertEqual((down["navidrome"] as? [String: Any])?["reachable"] as? Bool, false)
    }

    // MARK: - What the probe is allowed to claim

    /// **The honesty test.** A two-second silence is not evidence that Navidrome is down, and the
    /// body must not read as though it were. `status` keeps its blunt string for compatibility,
    /// so the qualification has to live somewhere a reader will actually see it, next to the
    /// number that produced it.
    func testATimedOutProbeDoesNotClaimTheServerIsDown() throws {
        let polls = DeviceLink.PollStats(pollsServed: 0, commandsDelivered: 0, waitersParked: 0,
                                         peakWaitersParked: 0, lastPollAt: nil, isDeviceConnected: false)
        let body = try decode(GatewayHealth.body(navidrome: .silent, startedAt: Date(), polls: polls))
        let navidrome = try XCTUnwrap(body["navidrome"] as? [String: Any])

        XCTAssertEqual(navidrome["probe"] as? String, "timedOut")
        XCTAssertEqual(navidrome["probe_timeout_ms"] as? Int, 2000)
        XCTAssertEqual(navidrome["probe_ms"] as? Int, 2001)

        let summary = try XCTUnwrap(navidrome["summary"] as? String)
        XCTAssertTrue(summary.contains("did not answer within 2000ms"),
                      "the claim the probe can support is the one it must make: \(summary)")
        XCTAssertTrue(summary.contains("not proof it is down"),
                      "and the one it cannot support has to be disclaimed: \(summary)")
    }

    /// The third ending, which is the one most easily misread: `ping.view` authenticates, so a
    /// wrong password fails fast and lands in exactly the same `navidrome-unreachable` headline
    /// as a dead server. Two seconds of silence and an instant rejection are different findings
    /// and must not render identically.
    func testAFastRejectionReadsDifferentlyFromSilence() throws {
        let polls = DeviceLink.PollStats(pollsServed: 0, commandsDelivered: 0, waitersParked: 0,
                                         peakWaitersParked: 0, lastPollAt: nil, isDeviceConnected: false)
        let rejected = HealthProbe.Report(outcome: .failed, elapsed: 0.034, timeout: 2)
        let body = try decode(GatewayHealth.body(navidrome: rejected, startedAt: Date(), polls: polls))
        let navidrome = try XCTUnwrap(body["navidrome"] as? [String: Any])

        XCTAssertEqual(body["status"] as? String, "navidrome-unreachable",
                       "the headline is still the blunt one, which is precisely why the detail matters")
        XCTAssertEqual(navidrome["probe"] as? String, "failed")
        XCTAssertEqual(navidrome["probe_ms"] as? Int, 34)
        let summary = try XCTUnwrap(navidrome["summary"] as? String)
        XCTAssertTrue(summary.contains("credential"),
                      "a rejected ping may be a bad password, and saying so is free: \(summary)")

        let silent = try decode(GatewayHealth.body(navidrome: .silent, startedAt: Date(), polls: polls))
        XCTAssertNotEqual((silent["navidrome"] as? [String: Any])?["summary"] as? String, summary)
    }

    /// The healthy path stays a number a reader can sanity-check against the request log's own
    /// `GET /health 200 <ms>` line — if the probe says 84ms and the line says 120s, something is
    /// wrong with the fix rather than with Navidrome.
    func testAHealthyProbeReportsWhatItMeasured() throws {
        let polls = DeviceLink.PollStats(pollsServed: 0, commandsDelivered: 0, waitersParked: 0,
                                         peakWaitersParked: 0, lastPollAt: nil, isDeviceConnected: false)
        let body = try decode(GatewayHealth.body(
            navidrome: HealthProbe.Report(outcome: .answered, elapsed: 0.084, timeout: 2),
            startedAt: Date(), polls: polls))
        let navidrome = try XCTUnwrap(body["navidrome"] as? [String: Any])

        XCTAssertEqual(body["status"] as? String, "ok")
        XCTAssertEqual(navidrome["probe_ms"] as? Int, 84)
        XCTAssertEqual(navidrome["summary"] as? String, "ping answered in 84ms")
    }

    /// A clock that steps backwards must not produce a negative age or a negative uptime — the
    /// numbers are read by eye and by scripts, and both would be confused by one.
    func testClockSkewCannotProduceNegativeAges() throws {
        let now = Date()
        let polls = DeviceLink.PollStats(pollsServed: 1, commandsDelivered: 0, waitersParked: 0,
                                         peakWaitersParked: 1, lastPollAt: now.addingTimeInterval(30),
                                         isDeviceConnected: true)
        let link = try deviceLink(GatewayHealth.body(navidrome: .healthy,
                                                     startedAt: now.addingTimeInterval(60),
                                                     polls: polls, now: now))
        XCTAssertEqual(link["last_poll_seconds_ago"] as? Int, 0)
        XCTAssertEqual(try decode(GatewayHealth.body(navidrome: .healthy,
                                                     startedAt: now.addingTimeInterval(60),
                                                     polls: polls, now: now))["uptime_seconds"] as? Int, 0)
    }
}
