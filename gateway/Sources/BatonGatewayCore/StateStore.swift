import Foundation

/// The shared preference document, plus the number that says which write produced it.
///
/// The document itself is opaque here on purpose: the gateway has never understood a preference
/// entry and does not start now. What it adds is an ordering. Two devices used to resolve a
/// conflict by comparing `Date()` values each had stamped with its own clock, and the gateway
/// stored whatever arrived, so a device an hour ahead won every argument about a key until the
/// other device edited past that future time (S-F17). Worse, the PUT is a whole-file replace: a
/// device that read the document, merged, and pushed had no way to notice that the other device
/// had written in between, so the second push silently threw the first one away.
///
/// A revision fixes the second half outright. Every successful PUT produces a new one, a GET says
/// which one the body it just handed over belongs to, and a PUT that names an older revision is
/// refused with `409 Conflict` instead of being applied. The client's answer to a 409 is to read
/// the document again and re-merge, which is the same work it was going to do on the next sync
/// anyway.
///
/// **A PUT that names no revision is still accepted.** Older builds do not send the header, and a
/// gateway that started refusing them would break sync for every device that had not been updated
/// yet, which is a worse failure than the race this exists to close.
public struct StateStore: Sendable {
    /// Sent on every `GET /v1/state` and `PUT /v1/state` response, and read from the PUT request.
    public static let revisionHeader = "X-Baton-State-Revision"

    /// The gateway's own clock, sent with the document so a client can express its timestamps in
    /// the one clock both devices share rather than in its own. See `PreferenceSync`.
    public static let serverTimeHeader = "X-Baton-Server-Time"

    /// The headers every `/v1/state` answer carries.
    ///
    /// The time is seconds since 1970 rather than an HTTP date, because the client wants an
    /// interval and not a calendar: it subtracts its own clock from this one and carries the
    /// difference. A formatted date would make that a parse with a locale in it, for no gain.
    public static func responseHeaders(revision: Int, now: Date = Date()) -> [String: String] {
        [
            revisionHeader: String(revision),
            serverTimeHeader: String(format: "%.3f", now.timeIntervalSince1970),
        ]
    }

    private let fileURL: URL

    /// Beside the document rather than inside it: the body is written back verbatim by clients
    /// that know nothing about a revision, so a number kept inside it would be echoed back stale
    /// on every push and would have to be stripped before the client could read the document at
    /// all.
    private var revisionURL: URL { fileURL.appendingPathExtension("revision") }

    public init(fileURL: URL) { self.fileURL = fileURL }

    /// The document as it stands, and the revision it belongs to. A gateway nobody has written to
    /// answers `{}` at revision 0, which is the first device's normal case rather than an error.
    public func read() -> (body: String, revision: Int) {
        let body = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "{}"
        return (body, revision)
    }

    /// The current revision. An absent or unreadable sidecar reads as 0, which costs one refused
    /// PUT and a re-read on the client rather than silently accepting a write it should not.
    public var revision: Int {
        guard let text = try? String(contentsOf: revisionURL, encoding: .utf8),
              let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0
        else { return 0 }
        return value
    }

    public enum WriteOutcome: Equatable, Sendable {
        case written(revision: Int)
        /// The client named a revision that is no longer current; `current` is what it should read.
        case stale(current: Int)
        case failed
    }

    /// Replaces the document. `expected` is the revision the client believes it is replacing;
    /// `nil` means it did not say, which an older client never will.
    public func write(_ body: Data, ifRevision expected: Int?) -> WriteOutcome {
        let current = revision
        if let expected, expected != current { return .stale(current: current) }

        // The revision moves first, and that order is deliberate. If the body write then fails the
        // number is ahead of the document, so the next client PUT is refused once and re-reads,
        // which is recoverable. The other order leaves the number behind a document that has
        // already changed, and the next stale PUT is accepted and overwrites it, which is not.
        let next = current + 1
        do {
            try Data("\(next)\n".utf8).write(to: revisionURL, options: .atomic)
            try body.write(to: fileURL, options: .atomic)
        } catch {
            return .failed
        }
        return .written(revision: next)
    }
}
