import BatonDocuments
import BatonPlaybackKit
import BatonSpeech
import Foundation
import Observation

/// "Previously…" (M8.4): when a book is picked up again after a break, a short spoken recap of
/// what has been heard, then the book carries on. The offer rule, the spoiler boundary, the
/// prompt, the router call and the cleaning are `Recap` in BatonDocuments, shared with the
/// iPhone; this is the Mac's sources, banner and speaking.
///
/// The recap goes through `ModelRouter`, which decides: local sources always, and a cloud
/// source only when the person allowed it chapters in Settings (M4.6, `ModelConsentLedger`).
/// Without that, no chapter of a book leaves the person's machines.
enum ResumeRecap {
    /// Whether to offer one: an unfinished book with a position, last played long enough ago,
    /// with enough heard to recap (`Recap.shouldOffer`).
    static func shouldOffer(book: BookShelf.Book, prepared: PreparedBook, lastPlayed: Date?, now: Date = Date()) -> Bool {
        Recap.shouldOffer(book: prepared, synced: book.position, chapterDuration: BookText.chapterDuration(book),
                          finished: book.finished, lastPlayed: lastPlayed, now: now)
    }

    /// The recap, written by the first source the router may use that answers, cleaned for
    /// the ear; nil when none did, so the book simply plays. A cloud source is used only with
    /// `consent` for chapters.
    static func write(prepared: PreparedBook, position: BookPosition, sources: [ModelSource],
                      consent: ModelConsent = ModelConsent(),
                      executor: @escaping ModelRouter.Executor) async -> (text: String, source: String)? {
        await Recap.write(book: prepared, position: position, sources: sources, consent: consent, executor: executor)
    }

    /// Why no recap was written, in one line: with a cloud source waiting for consent, the
    /// line names it and where to allow it.
    static func noRecapLine(sources: [ModelSource], consent: ModelConsent) -> String {
        let waiting = ModelRouter(sources: sources, consent: consent).awaitingConsent(for: .recap)
        guard let cloud = waiting.first else {
            return "No model on this Mac or the Baton server wrote a recap, so the book plays as it is."
        }
        return "No model on this Mac or the Baton server wrote a recap, and \(CloudModelConsent.notAllowedClause(cloud, .chapter)), so the book plays as it is."
    }

    /// "It has been a while since you heard The Machine Stops."
    static func offerText(for book: BookShelf.Book) -> String { Recap.offerText(title: book.title) }
}

/// The offer as the Clippings list shows it: made when Play is pressed on a book due a recap,
/// written and spoken on "Hear Recap", dropped on "Just Play".
@MainActor
@Observable
final class BookRecapOffer {
    enum State: Equatable {
        case offered
        case writing
        case speaking
        case failed(String)
    }

    struct Offer {
        let book: BookShelf.Book
        let prepared: PreparedBook
        let position: BookPosition
    }

    private(set) var offer: Offer?
    private(set) var state: State = .offered
    /// The recap as spoken, kept so the banner can show it while it plays.
    private(set) var text: String?

    /// Offer a recap for `book` if one is due. Returns whether it was offered, so the caller
    /// plays at once when it was not.
    @discardableResult
    func consider(_ book: BookShelf.Book, prepared: PreparedBook?, lastPlayed: Date?, now: Date = Date()) -> Bool {
        guard let prepared, ResumeRecap.shouldOffer(book: book, prepared: prepared, lastPlayed: lastPlayed, now: now) else {
            offer = nil
            return false
        }
        offer = Offer(book: book, prepared: prepared, position: BookText.position(in: prepared, book: book))
        state = .offered
        text = nil
        return true
    }

    func dismiss() {
        offer = nil
        state = .offered
        text = nil
    }

    /// Write the recap and hand it to `speak`, which returns once it has been said (or could
    /// not be). Then `thenPlay` runs, recap or not: a model that stays silent costs a message,
    /// never the book.
    ///
    /// `consent` is what the person allowed cloud sources on this Mac, read from the ledger
    /// unless a caller passes its own.
    func hear(sources: [ModelSource], executor: @escaping ModelRouter.Executor,
              consent: ModelConsent = CloudModelConsent.ledger().consent,
              speak: @escaping (String) async -> Bool, thenPlay: @escaping () -> Void) async {
        guard let offer else { return }
        state = .writing
        guard let recap = await ResumeRecap.write(prepared: offer.prepared, position: offer.position,
                                                  sources: sources, consent: consent, executor: executor) else {
            state = .failed(ResumeRecap.noRecapLine(sources: sources, consent: consent))
            thenPlay()
            return
        }
        text = recap.text
        state = .speaking
        let spoken = await speak(recap.text)
        if !spoken { state = .failed("The recap could not be spoken, so the book plays as it is.") }
        thenPlay()
        if spoken { dismiss() }
    }
}
