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
    /// How many sentences make a passage when the paragraphs are not known.
    static let sentencesPerPassage = 4

    /// The book's text, chapter by chapter, from the job when this Mac holds it, else from Clippings.
    @MainActor
    static func preparedBook(for book: BookShelf.Book, library: DocumentLibrary?) -> PreparedBook? {
        if let library, let job = library.job(forDocument: book.documentID), job.renderer == .thisMac,
           let stored = library.store.load(job.id) {
            return stored.book
        }
        return fromClippings(book)
    }

    static func fromClippings(_ book: BookShelf.Book) -> PreparedBook? {
        let chapters = book.chapters.sorted { $0.index < $1.index }.map { chapter -> PreparedChapter in
            PreparedChapter(index: chapter.index, title: chapter.title,
                            segments: segments(chapter.item?.clipping.text ?? ""))
        }
        guard chapters.contains(where: { !$0.segments.isEmpty }) else { return nil }
        return PreparedBook(documentID: book.documentID, title: book.title, author: book.author, language: nil,
                            voices: VoicePlan(narrator: ""), chapters: chapters)
    }

    /// Sentences as narration segments, a few to a paragraph.
    static func segments(_ text: String) -> [SpeechSegment] {
        SentenceSplitter.sentences(text).enumerated().map { index, sentence in
            SpeechSegment(text: sentence, kind: .narration, pauseBeforeMs: 0, paragraph: index / sentencesPerPassage)
        }
    }

    /// Where the listener is in `book`: the chapter playing and how far into it, else the synced
    /// position, else the end of a finished book, else its start.
    static func position(in prepared: PreparedBook, book: BookShelf.Book,
                         playing: (chapterIndex: Int, time: Double, duration: Double)? = nil) -> BookPosition {
        if let playing, playing.duration > 0 {
            return BookPosition(chapter: playing.chapterIndex, fractionHeard: playing.time / playing.duration, in: prepared)
        }
        if let position = book.position {
            let duration = book.chapters.first { $0.index == position.chapterIndex }?.item?.clipping.durationSeconds ?? 0
            let fraction = duration > 0 ? position.seconds / duration : 0
            return BookPosition(chapter: position.chapterIndex, fractionHeard: fraction, in: prepared)
        }
        if book.finished, let last = prepared.chapters.last {
            return BookPosition(chapter: last.index, segment: last.segments.count)
        }
        return BookPosition(chapter: 0, segment: 0)
    }
}
