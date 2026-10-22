import BatonDocuments
import BatonPlaybackKit
import Foundation

/// The words of a book as the companions read them (M8.4, M8.5): the `PreparedBook` the
/// render job keeps while there is one, and otherwise the chapters' own text in Clippings,
/// which every chapter carries so the transcript can show it.
///
/// A book made on the home server, or one whose job is gone, has no prepared book on this Mac;
/// its text comes back as sentences grouped into short paragraphs, which is what the recap and
/// the agent's lookup read in either case.
enum BookText {
    /// The book's text, chapter by chapter, from the job when this Mac holds it, else from Clippings.
    @MainActor
    static func preparedBook(for book: BookShelf.Book, library: DocumentLibrary?) -> PreparedBook? {
        if let library, let job = library.job(forDocument: book.documentID), job.renderer == .thisMac,
           let stored = library.store.load(job.id) {
            return stored.book
        }
        return fromClippings(book)
    }

    /// The chapters' own words in Clippings, shaped the way both apps shape them
    /// (`Recap.book(documentID:title:author:chapters:)`, shared with the iPhone).
    static func fromClippings(_ book: BookShelf.Book) -> PreparedBook? {
        Recap.book(documentID: book.documentID, title: book.title, author: book.author,
                   chapters: book.chapters.map {
                       Recap.ChapterText(index: $0.index, title: $0.title, text: $0.item?.clipping.text ?? "",
                                         durationSeconds: $0.item?.clipping.durationSeconds)
                   })
    }

    /// Where the listener is in `book`: the chapter playing and how far into it, else the synced
    /// position, else the end of a finished book, else its start (`Recap.position`, shared).
    static func position(in prepared: PreparedBook, book: BookShelf.Book,
                         playing: (chapterIndex: Int, time: Double, duration: Double)? = nil) -> BookPosition {
        if let playing, playing.duration > 0 {
            return BookPosition(chapter: playing.chapterIndex, fractionHeard: playing.time / playing.duration, in: prepared)
        }
        return Recap.position(in: prepared, synced: book.position, chapterDuration: chapterDuration(book),
                              finished: book.finished)
    }

    /// The length of the synced chapter's audio, which turns its seconds into a share heard.
    static func chapterDuration(_ book: BookShelf.Book) -> Double? {
        guard let position = book.position else { return nil }
        return book.chapters.first { $0.index == position.chapterIndex }?.item?.clipping.durationSeconds
    }
}
