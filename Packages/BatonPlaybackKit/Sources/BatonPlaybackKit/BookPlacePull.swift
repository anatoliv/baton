import Foundation

/// Fetches the other device's newer place before a book's Play works out where to start
///
///
/// Each app pulls the shared ledger on launch, on coming to the front and on a ten-minute
/// heartbeat. An app that simply stays in front never does the second, so with the Mac left
/// frontmost while the phone played on, Play on the Mac started from the Mac's own older place
/// (found by the re-walk); the phone kept on screen had the same gap the other way.
/// So Play on a book first runs the app's ordinary forced sync, then starts from the merged
/// ledger.
///
/// Bounded: a slow or unreachable gateway must not hold the listener up, so after `timeout` the
/// book starts from the local place and the sync finishes (or fails) on its own. `sync` is nil
/// when the app's sync is switched off (`BATON_DEBUG_PREFERENCE_SYNC=off`) or not set up, and
/// then nothing is asked and nothing waits.
public enum BookPlacePull {
    public enum Outcome: Equatable, Sendable {
        /// The gateway answered and the ledger is merged.
        case pulled
        /// The sync ran and did not reach the gateway.
        case unreachable
        /// The sync took longer than the bound; the book starts from the local place.
        case timedOut
        /// No sync: switched off or no gateway configured.
        case off
    }

    public static let defaultTimeout: Duration = .seconds(2)

    /// Whether this Play resumes the book, and so should fetch the place first: the book's own
    /// Play or Resume (no chapter chosen), or a tap on the chapter the book is in. A tap on
    /// any other chapter starts that chapter from the top and needs no place.
    public static func resumes(fromChapter index: Int?, placeChapter: Int?) -> Bool {
        index == nil || index == placeChapter
    }

    /// Run `sync`, waiting at most `timeout`. Returns how it went; the caller then starts the
    /// book from whatever the ledger holds.
    @MainActor
    public static func run(timeout: Duration = defaultTimeout,
                           sync: (@MainActor () async -> Bool)?) async -> Outcome {
        guard let sync else { return .off }
        let gate = Gate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            gate.continuation = continuation
            Task { @MainActor in
                let reached = await sync()
                gate.finish(reached ? .pulled : .unreachable)
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                gate.finish(.timedOut)
            }
        }
    }

    /// The place a ledger holds for a book: its chapter and seconds, and whether it is finished.
    public static func place(of documentID: String, in ledger: ClippingLedger)
        -> (position: (chapterIndex: Int, seconds: Double)?, finished: Bool) {
        let record = ledger.document(documentID)
        let position = record.flatMap { r in r.chapterIndex.map { ($0, r.seconds ?? 0) } }
        return (position, record?.finished ?? false)
    }

    /// Resumes the waiting Play once, with whichever of the sync and the bound comes first.
    @MainActor
    private final class Gate {
        var continuation: CheckedContinuation<Outcome, Never>?
        func finish(_ outcome: Outcome) {
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }
}
