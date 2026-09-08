import Foundation

/// A one-attempt fuse around optional diagnostics initialization.
///
/// Crash reporting is never part of Baton's business path. A missing, slow, or
/// malformed endpoint may make diagnostics unavailable, but it must not create a
/// launch retry loop or block playback, navigation, downloads, or settings.
final class ReportingAttemptGate: @unchecked Sendable {
    enum Outcome: Equatable {
        case idle
        case started
        case failed
    }

    private let lock = NSLock()
    private var outcome: Outcome = .idle

    func runOnce(_ initialize: () throws -> Void) -> Outcome {
        lock.lock()
        guard outcome == .idle else {
            let existing = outcome
            lock.unlock()
            return existing
        }
        // Reserve the only attempt before calling out. A concurrent caller sees
        // `.failed` and returns instead of creating a second SDK client.
        outcome = .failed
        lock.unlock()

        do {
            try initialize()
            lock.lock()
            outcome = .started
            lock.unlock()
            return .started
        } catch {
            return .failed
        }
    }

    func current() -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }

    /// Only an explicit user disable may permit another attempt. No timer,
    /// reachability callback, or automatic provider fallback calls this.
    func resetAfterExplicitDisable() {
        lock.lock()
        outcome = .idle
        lock.unlock()
    }
}

/// A thread-safe hard ceiling on events admitted during one process lifetime.
final class ReportingBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var admitted = 0

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    func admit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard admitted < limit else { return false }
        admitted += 1
        return true
    }
}
