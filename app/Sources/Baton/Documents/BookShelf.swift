import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicModels
import Foundation

/// Clippings as the list shows them: readings as they always were, and each book as one row
/// that expands into its chapters (`specs/document-clippings.md`, *A book is a group of
/// clippings*).
///
/// Pure, so the grouping is tested without a view. A book appears as soon as it is submitted,
/// before any chapter has landed, because "rendering, chapter 1 at 40%" is exactly what someone
/// who just imported a file wants to see. Its chapters come from the render job while there is
/// one, and from Clippings alone once the job is gone.
enum BookShelf {
    enum Entry: Identifiable, Equatable {
        case reading(ClippingStore.Item)
        case book(Book)

        var id: String {
            switch self {
            case let .reading(item): return "reading-\(item.id)"
            case let .book(book): return "book-\(book.documentID)"
            }
        }

        var sortDate: Date {
            switch self {
            case let .reading(item): return item.clipping.createdAt
            case let .book(book): return book.createdAt
            }
        }
    }

    struct Book: Identifiable, Equatable {
        let documentID: String
        var title: String
        var author: String?
        var chapters: [Chapter]
        var createdAt: Date
        /// Set while Kokoro is unreachable: the book waits, it does not switch voice.
        var pauseReason: String?
        var failure: String?
        var isRendering: Bool
        var position: (chapterIndex: Int, seconds: Double)?
        var finished: Bool
        var madeOn: DocumentLibrary.Renderer = .thisMac
        /// When the home server removes this finished book (M6.6), from its summary's `removesAt`.
        var removesAt: Date?

        var id: String { documentID }

        /// "Kept until 2 November": the home server's retention date, shown once the book is
        /// finished, so the listener is told rather than left to work out a rule.
        var keptUntilText: String? {
            guard finished, let removesAt else { return nil }
            return BookShelf.keptUntilText(removesAt)
        }

        /// Where the book's audio is: here once every chapter has come down, on the home server
        /// while it is still being made or collected there.
        var storedText: String {
            if isOffloaded { return "Download removed" }
            if madeOn == .homeServer && !chapters.allSatisfy({ $0.item != nil }) { return "On the home server" }
            return "On this Mac"
        }

        static func == (lhs: Book, rhs: Book) -> Bool {
            lhs.documentID == rhs.documentID && lhs.title == rhs.title && lhs.author == rhs.author
                && lhs.chapters == rhs.chapters && lhs.createdAt == rhs.createdAt
                && lhs.pauseReason == rhs.pauseReason && lhs.failure == rhs.failure
                && lhs.isRendering == rhs.isRendering && lhs.finished == rhs.finished && lhs.madeOn == rhs.madeOn
                && lhs.removesAt == rhs.removesAt
                && lhs.position?.chapterIndex == rhs.position?.chapterIndex
                && lhs.position?.seconds == rhs.position?.seconds
        }

        /// Every chapter was made, and none of their audio is on this Mac now (M6.3).
        var isOffloaded: Bool { !chapters.isEmpty && chapters.allSatisfy { $0.state == .removed } }

        /// The length of what is ready.
        var readySeconds: Double { chapters.compactMap { $0.item?.clipping.durationSeconds }.reduce(0, +) }

        var bytes: Int {
            chapters.compactMap(\.item).reduce(0) { total, item in
                total + ((try? FileManager.default.attributesOfItem(atPath: item.url.path)[.size] as? Int) ?? 0)
            }
        }

        /// "3 chapters · 1 h 22 m", or while rendering "2 of 3 chapters ready · 54 m".
        var summaryText: String {
            let ready = chapters.filter { $0.item != nil }.count
            let count = chapters.count == 1 ? "1 chapter" : "\(chapters.count) chapters"
            let length = readySeconds > 0 ? " · \(BookShelf.durationText(readySeconds))" : ""
            return ready == chapters.count ? count + length : "\(ready) of \(count) ready" + length
        }

        /// How far through the book the listener is, 0...1, from the synced position.
        var listenedFraction: Double {
            if finished { return 1 }
            guard let position, readySeconds > 0 else { return 0 }
            let before = chapters.filter { $0.index < position.chapterIndex }
                .compactMap { $0.item?.clipping.durationSeconds }.reduce(0, +)
            return min(1, (before + position.seconds) / readySeconds)
        }
    }

    struct Chapter: Identifiable, Equatable {
        enum State: Equatable {
            case ready
            case queued
            case rendering(Double)
            case encoding
            case failed(String)
            /// Rendered once, but the clipping is gone from this Mac (removed here).
            case removed
        }

        let index: Int
        var title: String
        var item: ClippingStore.Item?
        var state: State

        var id: Int { index }
    }

    static func entries(items: [ClippingStore.Item], jobs: [DocumentLibrary.Job],
                        ledger: ClippingLedger) -> [Entry] {
        var entries: [Entry] = items.filter { !$0.clipping.isBookChapter }.map(Entry.reading)

        let chaptersByBook = Dictionary(grouping: items.filter(\.clipping.isBookChapter)) { $0.clipping.documentID ?? "" }
        var documentIDs = Set(chaptersByBook.keys)
        documentIDs.formUnion(jobs.map(\.documentID))

        for documentID in documentIDs {
            let landed = chaptersByBook[documentID] ?? []
            let job = jobs.first { $0.documentID == documentID }
            let byIndex = Dictionary(landed.map { ($0.clipping.chapterIndex ?? 0, $0) }, uniquingKeysWith: { a, _ in a })

            var chapters: [Chapter]
            if let summary = job?.summary {
                chapters = summary.chapters.map { chapter in
                    let item = byIndex[chapter.index]
                    let state: Chapter.State
                    switch (item, chapter.state) {
                    case (.some, _): state = .ready
                    case (nil, "ready"): state = .removed
                    case (nil, "rendering"): state = .rendering(chapter.progress)
                    case (nil, "encoding"): state = .encoding
                    case (nil, "failed"): state = .failed(chapter.reason ?? "failed")
                    default: state = .queued
                    }
                    return Chapter(index: chapter.index, title: chapter.title, item: item, state: state)
                }
            } else {
                chapters = landed.map { Chapter(index: $0.clipping.chapterIndex ?? 0,
                                                title: $0.clipping.chapterTitle ?? $0.clipping.title,
                                                item: $0, state: .ready) }
                    .sorted { $0.index < $1.index }
            }

            let first = landed.first?.clipping
            let record = ledger.document(documentID)
            let position = record.flatMap { r in r.chapterIndex.map { ($0, r.seconds ?? 0) } }
            let status = job?.summary.status
            entries.append(.book(Book(
                documentID: documentID,
                title: job?.summary.title ?? first?.documentTitle ?? first?.title ?? "Untitled",
                author: job?.summary.author ?? first?.author,
                chapters: chapters,
                createdAt: job?.summary.createdAt ?? landed.map(\.clipping.createdAt).min() ?? .distantPast,
                pauseReason: status == .paused ? job?.summary.pauseReason : nil,
                failure: status == .failed ? (chapters.compactMap { if case let .failed(why) = $0.state { why } else { nil } }.first) : nil,
                isRendering: status == .rendering || status == .paused,
                position: position,
                finished: record?.finished ?? false,
                madeOn: job?.renderer ?? .thisMac,
                removesAt: job?.summary.removesAt
            )))
        }
        return entries.sorted { $0.sortDate > $1.sortDate }
    }

    /// How many rows the list shows: each reading, and each book once.
    static func entryCount(items: [ClippingStore.Item]) -> Int {
        let books = Set(items.compactMap(\.clipping.documentID))
        return items.filter { !$0.clipping.isBookChapter }.count + books.count
    }

    /// "Kept until 2 November", with the year once it is not this one.
    static func keptUntilText(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                              locale: Locale = .current) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        var style: Date.FormatStyle = sameYear ? .dateTime.day().month(.wide) : .dateTime.day().month(.wide).year()
        style.locale = locale
        return "Kept until \(date.formatted(style))"
    }

    /// "1 h 22 m", "45 m", "40 s", the same shape as the import estimate.
    static func durationText(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "\(Int(seconds.rounded())) s" }
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m" : "\(minutes) m"
    }
}

/// What the player does with a book chapter: resume where the listener was, remember where they
/// are, and notice the end of the book. The same hooks podcasts use, so there is no second
/// resume mechanism.
@MainActor
enum BookPlayback {
    /// The offset to start a chapter at, when the synced position is inside it. A position in the
    /// last few seconds counts as the end, so the chapter starts over rather than ending at once.
    static func resumeOffset(for song: NavidromeSong, clippings: ClippingStore) -> TimeInterval? {
        guard let item = clippings.item(forSongID: song.id), let documentID = item.clipping.documentID,
              let record = clippings.ledger.document(documentID), !record.finished,
              record.chapterIndex == item.clipping.chapterIndex,
              let seconds = record.seconds, seconds > 1 else { return nil }
        if let duration = item.clipping.durationSeconds, seconds > duration - 5 { return nil }
        return seconds
    }

    /// Note the position, and at the end of the last chapter that the book is finished. Returns
    /// the finished book's document id, so the caller can tell the renderer too.
    ///
    /// `chapterCount` is the book's, from its render job: the last chapter to have *landed* is
    /// not the last chapter while the rest still renders. Without a job, the landed ones are all
    /// there is.
    @discardableResult
    static func record(_ song: NavidromeSong, time: TimeInterval, duration: TimeInterval,
                       chapterCount: Int?, clippings: ClippingStore, now: Date = Date()) -> String? {
        guard let item = clippings.item(forSongID: song.id), let documentID = item.clipping.documentID,
              let index = item.clipping.chapterIndex else { return nil }
        var ledger = clippings.ledger
        ledger.setPosition(documentID: documentID, chapterIndex: index, seconds: time, at: now)
        let atEnd = duration > 1 && time >= duration - 1
        let lastIndex = chapterCount.map { $0 - 1 }
            ?? clippings.chapters(ofDocument: documentID).compactMap(\.clipping.chapterIndex).max() ?? index
        let isLast = index == lastIndex
        var finishedNow = false
        if atEnd, isLast, ledger.document(documentID)?.finished != true {
            ledger.setFinished(true, documentID: documentID, at: now)
            finishedNow = true
        }
        clippings.ledger = ledger
        return finishedNow ? documentID : nil
    }

    /// The book's chapters as a queue, starting at the synced chapter; from the start once it is
    /// finished. Chapters whose audio is not here are left out rather than stalling the queue.
    static func queue(for book: BookShelf.Book) -> (songs: [NavidromeSong], startIndex: Int) {
        let playable = book.chapters.compactMap(\.item).filter(\.isPresent)
        let songs = playable.map(\.asSong)
        guard !book.finished, let position = book.position,
              let start = playable.firstIndex(where: { $0.clipping.chapterIndex == position.chapterIndex })
        else { return (songs, 0) }
        return (songs, start)
    }
}
