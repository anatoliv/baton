import Foundation

/// A liveness check that is bounded by the clock rather than by the network stack.
///
/// `/health` used to ask `NavidromeClient.ping()` and wait for whatever answer the transport
/// eventually produced. With an unreachable server that was **120 seconds** — two 60-second
/// URLSession attempts, because `dataWithOneRetry` retries an idempotent GET once — and the route
/// then correctly reported `navidrome-unreachable` long after every caller had given up. A health
/// endpoint that cannot answer inside a client's patience is not a health endpoint: "unreachable
/// after two minutes" and "this process is dead" look identical from the outside, and telling
/// those two apart is the entire job of the route.
///
/// So the deadline lives *here*, in front of the call, rather than in the client:
///
/// - **It is the outer bound, and it is the one that is promised.** A per-request
///   `timeoutInterval` is a per-*attempt* bound, and the retry multiplies it; only a wall clock
///   over the whole call can promise a number.
/// - **The losing side is abandoned, not awaited.** The deadline resumes the caller and then
///   cancels the in-flight work as a courtesy. A structured `withTaskGroup` race would still wait
///   for its children at scope exit, so a transport that ignored cancellation would reinstate
///   exactly the hang this exists to remove.
/// - **It says which of the three things happened.** Answered, failed fast, or ran out of time —
///   because "did not answer within 2s" is a much weaker claim than "the server is down", and the
///   body should not make the stronger one.
public enum HealthProbe {

    /// What one bounded probe learned, and how long it took to learn it.
    public struct Report: Sendable, Equatable {

        /// The three distinguishable endings. `failed` covers everything the transport itself
        /// rejected — refused connection, DNS, TLS, a non-2xx, bad credentials — which is why the
        /// rendered summary must not read it as proof the server is down.
        public enum Outcome: String, Sendable {
            case answered
            case failed
            case timedOut
        }

        public var outcome: Outcome
        /// Wall-clock seconds the probe took, measured around the whole call including any retry.
        public var elapsed: TimeInterval
        /// The bound that was in force, so a reader can tell 2.0s-of-2.0s from 2.0s-of-30s.
        public var timeout: TimeInterval

        /// True only when the server actually answered. A timeout is not a "no".
        public var reachable: Bool { outcome == .answered }

        public init(outcome: Outcome, elapsed: TimeInterval, timeout: TimeInterval) {
            self.outcome = outcome
            self.elapsed = elapsed
            self.timeout = timeout
        }
    }

    /// Whoever finishes first wins; the other side is dropped on the floor.
    private actor Gate {
        private var claimed = false
        func claim() -> Bool {
            if claimed { return false }
            claimed = true
            return true
        }
    }

    /// Run `check`, and return within roughly `timeout` seconds whatever the check does.
    ///
    /// `check` is expected to throw on any failure (`NavidromeClient.ping()` does). Nothing is
    /// thrown out of here: a probe that fails is a *result*, not an error.
    public static func run(
        timeout: TimeInterval,
        _ check: @escaping @Sendable () async throws -> Void
    ) async -> Report {
        let started = Date()
        let gate = Gate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Report, Never>) in
            @Sendable func finish(_ outcome: Report.Outcome) async {
                guard await gate.claim() else { return }
                continuation.resume(returning: Report(
                    outcome: outcome,
                    elapsed: Date().timeIntervalSince(started),
                    timeout: timeout
                ))
            }

            let work = Task {
                do {
                    try await check()
                    await finish(.answered)
                } catch {
                    await finish(.failed)
                }
            }

            Task {
                // An explicit small tolerance: the scheduler's default is generous, and a
                // 2-second promise that lands at 2.1s measured every time is a promise with a
                // fudge factor in it. Continuous clock, so a machine going to sleep mid-probe
                // does not stop the deadline.
                try? await Task.sleep(
                    until: .now + .milliseconds(Int(max(0, timeout) * 1000)),
                    tolerance: .milliseconds(5),
                    clock: .continuous
                )
                await finish(.timedOut)
                // Best effort only, and deliberately after the answer has gone out: URLSession
                // honours cancellation on Darwin, and if some transport somewhere does not, the
                // caller has already been served.
                work.cancel()
            }
        }
    }
}
