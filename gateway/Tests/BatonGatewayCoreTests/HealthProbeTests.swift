#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import BatonSubsonicKit
import Foundation
import XCTest
@testable import BatonGatewayCore

/// `bind(2)` under its own name: bare `bind` inside a closure resolves to a Swift instance method
/// rather than the C function, and the compiler says so.
#if canImport(Darwin)
private let systemBind = Darwin.bind
#else
private let systemBind = Glibc.bind
#endif

/// The bound on `/health`'s Navidrome ping.
///
/// The defect this comes from is a *latency* defect, and the only way to see it is to make
/// Navidrome stop answering. Everything here therefore runs against a **blackhole**: a real TCP
/// listener on 127.0.0.1 that the test never accepts from. The kernel completes the handshake, so
/// the connection succeeds and the request is written — and then nothing ever comes back, which is
/// precisely the shape of a sleeping NAS or a container with no route out. A test that pointed at
/// a closed port would get an instant refusal and prove nothing at all about waiting.
final class HealthProbeTests: XCTestCase {

    // MARK: - A server that accepts and never answers

    /// A listening socket nothing accepts from. Connections to it establish and then hang.
    private final class Blackhole {
        let port: UInt16
        private let descriptor: Int32

        init() throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Failure.socket }
            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0                       // let the kernel pick a free one
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    systemBind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(fd, 16) == 0 else { close(fd); throw Failure.bind }

            var assigned = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &assigned) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &length)
                }
            }
            guard named == 0 else { close(fd); throw Failure.bind }
            descriptor = fd
            port = UInt16(bigEndian: assigned.sin_port)
        }

        deinit { close(descriptor) }

        enum Failure: Error { case socket, bind }
    }

    /// A `NavidromeClient` pointed at the blackhole, on the session shape the gateway's health
    /// client uses. `perAttempt` is the URLSession request timeout, i.e. the transport's own
    /// patience — deliberately separate from the probe's wall clock, because the two are what
    /// this card is about telling apart.
    private func blackholedClient(port: UInt16, perAttempt: TimeInterval) -> NavidromeClient {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = perAttempt
        config.timeoutIntervalForResource = perAttempt * 4
        #if !os(Linux)
        config.waitsForConnectivity = false
        #endif
        let credentials = NavidromeCredentials(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            username: "probe", secret: "probe", authMode: .tokenSalt
        )
        return NavidromeClient(credentials: credentials, session: URLSession(configuration: config))
    }

    // MARK: - The acceptance test

    /// **This is the card.** Against a Navidrome that answers nothing, the ping must come back at
    /// the probe's deadline rather than at the transport's.
    ///
    /// The control in the same test is what makes it mean something: the identical client, called
    /// the way `/health` used to call it, is still waiting when the bounded one has long since
    /// answered — and it does not stop at one request timeout either, because `performJSON`
    /// retries an idempotent GET once. That doubling is why the observed hang was ~120s rather
    /// than URLSession's ~60s default, and it is exactly why a per-request timeout alone would
    /// have been the wrong place to put this.
    func testAPingAtABlackholeAnswersAtTheProbeDeadlineNotTheTransportOne() async throws {
        let blackhole = try Blackhole()
        let client = blackholedClient(port: blackhole.port, perAttempt: 1.2)

        let bounded = await HealthProbe.run(timeout: 0.5) { try await client.ping() }

        XCTAssertEqual(bounded.outcome, .timedOut,
                       "a server that never answers must be reported as a timeout, not a failure")
        XCTAssertFalse(bounded.reachable)
        XCTAssertLessThan(bounded.elapsed, 1.2,
                          "the probe returned at \(bounded.elapsed)s — later than its own deadline, "
                          + "which means the bound is not the thing deciding when /health answers")

        // The control: the same call with no bound at all. If this finished as fast as the probe,
        // the test above would be passing for the wrong reason.
        let started = Date()
        try? await client.ping()
        let unbounded = Date().timeIntervalSince(started)

        XCTAssertGreaterThan(unbounded, 2.0,
                             "the unbounded call took \(unbounded)s — the blackhole is answering "
                             + "something, so this test is not measuring what it claims")
        XCTAssertGreaterThan(unbounded, bounded.elapsed * 2,
                             "bounded \(bounded.elapsed)s vs unbounded \(unbounded)s")
    }

    /// The bound is a wall clock over the *whole* call, retry included — which a
    /// `timeoutIntervalForRequest` is not. Two attempts at 1.2s plus the 300ms backoff is 2.7s of
    /// transport patience; the probe still answers in half a second.
    func testTheBoundSurvivesTheClientsInternalRetry() async throws {
        let blackhole = try Blackhole()
        let client = blackholedClient(port: blackhole.port, perAttempt: 1.2)

        let report = await HealthProbe.run(timeout: 0.5) { try await client.ping() }

        XCTAssertLessThan(report.elapsed, 1.2,
                          "returned in \(report.elapsed)s, i.e. after the first attempt gave up — "
                          + "the deadline is not in front of the retry")
        XCTAssertEqual(report.timeout, 0.5, "the report must carry the bound it was held to")
    }

    // MARK: - The other two endings

    /// A server that answers is not delayed by any of this: the probe returns as soon as the call
    /// does, and the elapsed time is the call's, not the timeout's.
    func testAnAnsweringCheckReturnsImmediatelyAndIsNotDelayedByTheBound() async throws {
        let started = Date()
        let report = await HealthProbe.run(timeout: 30) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let wall = Date().timeIntervalSince(started)

        XCTAssertEqual(report.outcome, .answered)
        XCTAssertTrue(report.reachable)
        XCTAssertLessThan(wall, 1.0, "a healthy probe waited \(wall)s behind a 30s bound")
        XCTAssertGreaterThan(report.elapsed, 0.01, "the elapsed time must be the call's own")
    }

    /// A refusal is a different finding from a silence, and the report has to keep them apart —
    /// `/health`'s body says so in words, and this is where the distinction is made.
    func testAFastFailureIsReportedAsFailedRatherThanTimedOut() async throws {
        struct Refused: Error {}
        let report = await HealthProbe.run(timeout: 5) { throw Refused() }

        XCTAssertEqual(report.outcome, .failed)
        XCTAssertFalse(report.reachable)
        XCTAssertLessThan(report.elapsed, 1.0, "a thrown error must not wait out the bound")
    }

    /// Both endings arriving at once used to be the way this shape breaks: whoever loses the race
    /// must be dropped silently, because resuming a `CheckedContinuation` twice traps. Run enough
    /// of them at the boundary that a missing gate would show up.
    func testAWorkerFinishingExactlyAtTheDeadlineResumesOnlyOnce() async throws {
        for _ in 0 ..< 25 {
            let report = await HealthProbe.run(timeout: 0.05) {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertTrue(report.outcome == .answered || report.outcome == .timedOut
                            || report.outcome == .failed)
        }
    }

    /// A zero or negative bound is a caller's mistake, not a licence to wait forever.
    func testANonPositiveTimeoutStillReturns() async throws {
        let report = await HealthProbe.run(timeout: 0) {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        XCTAssertEqual(report.outcome, .timedOut)
        XCTAssertLessThan(report.elapsed, 1.0)
    }
}
