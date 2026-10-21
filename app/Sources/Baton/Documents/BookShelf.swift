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
        /// Sent to the home server by another device and adopted from its listing.
        var adopted = false
        /// When the home server removes this finished book (M6.6), from its summary's `removesAt`.
        var removesAt: Date?
        /// Being made again in another voice: the row's line while it is.
        var remaking: String?
        /// The voice change can be stopped from here (it was started on this Mac).
        var canStopRemaking = false

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
            if madeOn == .homeServer && !chapters.allSatisfy({ $0.item != nil }) { return "On the Baton server" }
            return "On this Mac"
        }

        /// "Made on the home server" for a book another device sent there, so a row
        /// nobody made from this Mac says where it came from.
        var originText: String? { adopted ? "Made on the Baton server" : nil }

        static func == (lhs: Book, rhs: Book) -> Bool {
            lhs.documentID == rhs.documentID && lhs.title == rhs.title && lhs.author == rhs.author
                && lhs.chapters == rhs.chapters && lhs.createdAt == rhs.createdAt
                && lhs.pauseReason == rhs.pauseReason && lhs.failure == rhs.failure
                && lhs.isRendering == rhs.isRendering && lhs.finished == rhs.finished && lhs.madeOn == rhs.madeOn
                && lhs.adopted == rhs.adopted && lhs.removesAt == rhs.removesAt
                && lhs.remaking == rhs.remaking && lhs.canStopRemaking == rhs.canStopRemaking
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
        var listenedFraction: Double { listenedFraction(at: position, live: false) }

        /// How far through the book `place` is. `live`: the place is the playhead of
        /// one of its chapters, so a finished book being heard again shows where it is.
        func listenedFraction(at place: (chapterIndex: Int, seconds: Double)?, live: Bool) -> Double {
            BookTransport.fraction(chapters: chapters.compactMap { chapter in
                chapter.item?.clipping.durationSeconds.map { (chapter.index, $0) }
            }, place: place, finished: finished, live: live)
        }

        /// The chapter of this book in the player, playing or paused, if one is.
        func loadedChapter(nowPlayingID: String?) -> Int? {
            guard let nowPlayingID else { return nil }
            return chapters.first { $0.item?.isLoaded(nowPlayingID: nowPlayingID) == true }?.index
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
                        ledger: ClippingLedger, changes: [BookVoiceChanges.Change] = []) -> [Entry] {
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
            let change = changes.first { $0.documentID == documentID && $0.jobID == job?.id }
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
                adopted: job?.adopted ?? false,
                removesAt: job?.summary.removesAt,
                remaking: change.map { BookVoiceChanges.statusLine($0, chapters: job?.summary.chapters, total: chapters.count) },
                canStopRemaking: change?.startedHere == true
            )))
        }
        return entries.sorted { $0.sortDate > $1.sortDate }
    }

    /// How many rows Clippings shows: the readings, not a book's chapters.
    static func readingCount(items: [ClippingStore.Item]) -> Int {
        items.filter { !$0.clipping.isBookChapter }.count
    }

    /// How many rows Books shows: each book once, whether its chapters have landed or it is
    /// still being made.
    static func bookCount(items: [ClippingStore.Item], jobs: [DocumentLibrary.Job] = []) -> Int {
        var books = Set(items.filter(\.clipping.isBookChapter).compactMap(\.clipping.documentID))
        books.formUnion(jobs.map(\.documentID))
        return books.count
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

/// The Mac's half of `BookPlayback` (BatonPlaybackKit): resume and the position writes are
/// shared with the iPhone; the queue is built from this app's shelf.
extension BookPlayback {
    /// The book's chapters here as a queue, starting at the chosen chapter, or the synced one
    /// (from the start once it is finished). After the start, chapters still being made are not
    /// skipped: the queue stops short of the first, and `continuation` adds it and the rest in
    /// order as they land while the book plays.
    static func queue(for book: BookShelf.Book, fromChapter index: Int? = nil) -> (songs: [NavidromeSong], startIndex: Int) {
        queue(chapters: book.chapters.compactMap(\.item), position: book.position,
              finished: book.finished, fromChapter: index)
    }

    /// Where each chapter of a book stands on this Mac, for `BookContinuation`: here, coming
    /// (being made, here or on the home server, made there and not yet down, or removed here and
    /// able to come back; a paused book carries on by itself), or not coming, with why. Nil for a
    /// book with no render job.
    static func continuationChapters(of book: BookShelf.Book, hasJob: Bool, canGetBack: Bool,
                                     homeServerProblem: String?) -> [BookContinuation.Chapter]? {
        guard hasJob else { return nil }
        return book.chapters.map { chapter in
            if chapter.item?.isPresent == true { return .here }
            if chapter.item != nil { return .unavailable("its audio file has gone") }
            switch chapter.state {
            case let .failed(why): return .unavailable("it could not be made (\(why))")
            case .removed where !canGetBack: return .unavailable("its audio was removed from this Mac")
            default:
                if book.madeOn == .homeServer, let homeServerProblem { return .unavailable(homeServerProblem) }
                return .coming
            }
        }
    }
}

extension BookShareDraft {
    /// A Mac book as Share… sees it: the chapters whose audio is here.
    @MainActor init(_ book: BookShelf.Book, covers: BookCovers?,
                      timing: (@MainActor (ClippingStore.Item) async -> ReadAlongTiming?)? = nil) {
        self.init(documentID: book.documentID, title: book.title, author: book.author,
                  chapters: book.chapters.map { (index: $0.index, title: $0.title, item: $0.item) },
                  coverURL: covers?.url(for: book.documentID), timing: timing)
    }
}
