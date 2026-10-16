import BatonDocuments
import BatonPlaybackKit
import Foundation

extension MobileBookShelf {
    /// A book as storage sees it. Every phone book was made on the home server, so it can come
    /// back while the server has it or its shaped book is saved here.
    @MainActor
    static func stored(_ book: Book, homeServer: HomeServerBooks, ledger: ClippingLedger) -> StoredBook {
        let present = book.chapters.compactMap(\.item).filter(\.isPresent)
        let listening = StoredBook.listening(book.documentID, ledger: ledger, present: present)
        let record = book.jobID.flatMap(homeServer.record(forJob:))
        return StoredBook(documentID: book.documentID, title: book.title, author: book.author, present: present,
                          missing: book.missing, createdAt: book.createdAt, finishedAt: listening.finishedAt,
                          lastPlayedAt: listening.lastPlayedAt, inProgress: listening.inProgress,
                          homeServerJobID: book.jobID, canGetBack: record.map(homeServer.canGetBack) ?? false)
    }

    /// Delete Book…: the chapters are held for Recently removed. Delete Everywhere
    /// then asks the home server to delete the book and the record goes. Remove from this
    /// iPhone leaves the home server's copy for the other devices, which may have adopted it,
    /// and hides the book here so the next listing does not adopt it again.
    @MainActor
    static func delete(_ book: Book, everywhere: Bool, homeServer: HomeServerBooks, cleanup: BookCleanup,
                       ledger: ClippingLedger) async {
        cleanup.delete(stored(book, homeServer: homeServer, ledger: ledger), everywhere: everywhere)
        guard everywhere else { return homeServer.hide(documentID: book.documentID) }
        guard let jobID = book.jobID else { return }
        await homeServer.cancel(jobID: jobID)
    }
}

/// The phone's side of book storage (M6.3 to M6.5): its books as `StoredBook`s for the shared
/// `BookCleanup`, and what brings removed audio back. Every book here was made on the home
/// server, so "back" is a download from it, or, once the server has removed the book, the
/// saved book sent to be made again.
extension MobileModel {
    /// Every book on this phone, as Clippings shows it.
    var shelfBooks: [MobileBookShelf.Book] {
        MobileBookShelf.books(items: clippings.items, records: books.records, summaries: books.summaries,
                              ledger: clippings.ledger, changes: books.voiceChanges.all)
    }

    func stored(_ book: MobileBookShelf.Book) -> StoredBook {
        MobileBookShelf.stored(book, homeServer: books, ledger: clippings.ledger)
    }

    var storedBooks: [StoredBook] { shelfBooks.map(stored) }

    /// Run this phone's storage rules now. Returns the books whose download went.
    @discardableResult
    func applyStorageRules(now: Date = Date()) -> [String] {
        guard documentsSwitch.isOn else { return [] }
        return bookCleanup.applyRules(storedBooks, now: now)
    }

    /// "Download Again" while the home server has the book, "Render Again" once it has removed
    /// it. Nil when nothing is missing or it cannot come back.
    func getBackTitle(_ book: MobileBookShelf.Book) -> String? {
        guard !book.missing.isEmpty, let jobID = book.jobID, let record = books.record(forJob: jobID),
              books.canGetBack(record) else { return nil }
        return record.serverRemoved == true ? "Render Again" : "Download Again"
    }

    func getBack(_ book: MobileBookShelf.Book, chapters: [Int]? = nil) async throws {
        guard let jobID = book.jobID else { return }
        try await books.downloadAgain(jobID: jobID, chapters: chapters)
        bookCleanup.cameBack(book.documentID)
        books.watchIfNeeded { }
    }

    /// Remove a book's download from this phone (all of it, or `chapters`), keeping the book.
    @discardableResult
    func offload(_ book: MobileBookShelf.Book, chapters: [Int]? = nil) -> Int {
        bookCleanup.offload(stored(book), chapters: chapters)
    }

    /// Delete a book from this phone, or everywhere. Its chapters wait a week in Recently
    /// removed, held here, so Restore never needs the home server's copy. "Everywhere" asks the
    /// home server to delete the book and tells the other devices through the shared ledger;
    /// removing it from this phone leaves the home server's copy, which the other devices adopt
    ///, and keeps it hidden here.
    func deleteBook(_ book: MobileBookShelf.Book, everywhere: Bool) async {
        await MobileBookShelf.delete(book, everywhere: everywhere, homeServer: books, cleanup: bookCleanup,
                                     ledger: clippings.ledger)
    }

    /// Free space on this phone, as iOS counts it for things the person asked for.
    var freeBytes: Int? { BookCleanup.freeBytes(at: URL(fileURLWithPath: NSHomeDirectory())) }
}
