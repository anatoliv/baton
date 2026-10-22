import BatonDocuments
import BatonPlaybackKit
import Foundation

/// Clippings as the phone's list shows them: readings as they always were, and each book as one
/// row that expands into its chapters (`specs/document-clippings.md`, *A book is a group of
/// clippings*). The Mac's `BookShelf` does the same for books it makes itself; the phone only
/// ever has home-server books, so this reads the shared `HomeServerBooks` records and summaries.
///
/// Pure, so the grouping is tested without a view. A book appears as soon as it is submitted,
/// before any chapter has landed, because "making chapter 1, 40%" is what someone who just
/// imported a file wants to see.
enum MobileBookShelf {
    struct Book: Identifiable, Equatable {
        struct Chapter: Identifiable, Equatable {
            enum State: Equatable {
                case ready, queued, rendering(Double), encoding, failed(String)
                /// Rendered once, but the clipping is gone from this phone.
                case removed
            }
            let index: Int
            var title: String
            var item: ClippingStore.Item?
            var state: State
            var id: Int { index }

            var stateText: String {
                switch state {
                case .ready:
                    if item?.isPresent == false { return "the audio file has gone" }
                    return item?.clipping.durationSeconds.map(MobileBookShelf.durationText) ?? ""
                case .queued: return "waiting"
                case let .rendering(progress): return "\(Int((progress * 100).rounded()))%"
                case .encoding: return "finishing"
                case .failed: return "failed"
                case .removed: return "removed from this phone"
                }
            }
        }

        let documentID: String
        var jobID: String?
        var title: String
        var author: String?
        var chapters: [Chapter]
        var createdAt: Date
        var pauseReason: String?
        var failure: String?
        var isRendering: Bool
        var position: (chapterIndex: Int, seconds: Double)?
        var finished: Bool
        /// Sent to the home server by another device and adopted from its listing.
        var adopted = false
        /// Of an adopted book: a Mac made it and uploaded it whole, rather than the
        /// home server rendering it.
        var madeOnMac = false
        /// Being made again in another voice: the row's line while it is.
        var remaking: String?
        /// The voice change can be stopped from here (it was started on this phone).
        var canStopRemaking = false

        var id: String { documentID }

        /// Where a book another device sent was really made: "Made on your
        /// Mac" for one the Mac made and uploaded, "Made on the Baton server" for one the home
        /// server rendered, so a row nobody made from this phone says where it came from.
        var originText: String? {
            guard adopted else { return nil }
            return madeOnMac ? "Made on your Mac" : "Made on the Baton server"
        }

        static func == (lhs: Book, rhs: Book) -> Bool {
            lhs.documentID == rhs.documentID && lhs.jobID == rhs.jobID && lhs.title == rhs.title && lhs.author == rhs.author
                && lhs.chapters == rhs.chapters && lhs.createdAt == rhs.createdAt
                && lhs.pauseReason == rhs.pauseReason && lhs.failure == rhs.failure
                && lhs.isRendering == rhs.isRendering && lhs.finished == rhs.finished && lhs.adopted == rhs.adopted
                && lhs.madeOnMac == rhs.madeOnMac
                && lhs.remaking == rhs.remaking && lhs.canStopRemaking == rhs.canStopRemaking
                && lhs.position?.chapterIndex == rhs.position?.chapterIndex
                && lhs.position?.seconds == rhs.position?.seconds
        }

        var readyChapters: [Chapter] { chapters.filter { $0.item?.isPresent == true } }
        var readySeconds: Double { readyChapters.compactMap { $0.item?.clipping.durationSeconds }.reduce(0, +) }
        var isComplete: Bool { chapters.allSatisfy { $0.item != nil } }

        /// "3 chapters · 1 h 22 m", or while rendering "2 of 3 chapters ready · 54 m".
        var summaryText: String {
            let ready = chapters.filter { $0.item != nil }.count
            let count = chapters.count == 1 ? "1 chapter" : "\(chapters.count) chapters"
            let length = readySeconds > 0 ? " · \(MobileBookShelf.durationText(readySeconds))" : ""
            return ready == chapters.count ? count + length : "\(ready) of \(count) ready" + length
        }

        /// Where the book's audio is: here once every chapter has come down, on the home server
        /// while it is still being made or collected there.
        var storedText: String {
            if isOffloaded { return "Download removed" }
            return isComplete ? "On this phone" : "On the Baton server"
        }

        /// Every chapter was made, and none of their audio is on this phone now (M6.3).
        var isOffloaded: Bool { !chapters.isEmpty && chapters.allSatisfy { $0.state == .removed } }

        /// Chapters made once whose audio is not on this phone now.
        var missing: [Int] { chapters.filter { $0.state == .removed }.map(\.index) }

        /// One line under the book: why it is waiting, or what it is making.
        var statusLine: (text: String, isProblem: Bool)? {
            if let pauseReason {
                return ("Paused: \(pauseReason). It carries on by itself when the voice server answers.", true)
            }
            if let failure { return ("Stopped: \(failure)", true) }
            if let remaking { return (remaking, false) }
            guard isRendering, let next = chapters.first(where: { $0.item == nil && $0.state != .removed }) else { return nil }
            let of = "chapter \(next.index + 1) of \(chapters.count)"
            switch next.state {
            case let .rendering(progress): return ("Making \(of), \(Int((progress * 100).rounded()))%", false)
            case .encoding: return ("Finishing \(of)", false)
            default: return ("Waiting to make \(of)", false)
            }
        }

        /// How far through the book the listener is, 0...1, from the synced position.
        var listenedFraction: Double { listenedFraction(at: position, live: false) }

        /// How far through the book `place` is. `live`: the place is the playhead of
        /// one of its chapters, so a finished book being heard again shows where it is.
        func listenedFraction(at place: (chapterIndex: Int, seconds: Double)?, live: Bool) -> Double {
            BookTransport.fraction(chapters: readyChapters.compactMap { chapter in
                chapter.item?.clipping.durationSeconds.map { (chapter.index, $0) }
            }, place: place, finished: finished, live: live)
        }

        /// The chapter of this book in the player, playing or paused, if one is.
        func loadedChapter(nowPlayingID: String?) -> Int? {
            guard let nowPlayingID else { return nil }
            return chapters.first { $0.item?.isLoaded(nowPlayingID: nowPlayingID) == true }?.index
        }
    }

    /// Every book this phone knows: remembered on the home server, or present as chapters in
    /// Clippings, newest first. Readings (clippings that are not chapters) are left to the list.
    static func books(items: [ClippingStore.Item], records: [HomeServerBooks.Record],
                      summaries: [String: BookJob.Summary], ledger: ClippingLedger,
                      changes: [BookVoiceChanges.Change] = []) -> [Book] {
        let chaptersByBook = Dictionary(grouping: items.filter(\.clipping.isBookChapter)) { $0.clipping.documentID ?? "" }
        var documentIDs = Set(chaptersByBook.keys)
        documentIDs.formUnion(records.map(\.documentID))

        var books: [Book] = []
        for documentID in documentIDs {
            let landed = chaptersByBook[documentID] ?? []
            let record = records.first { $0.documentID == documentID }
            let summary = record.flatMap { summaries[$0.jobID] }
            let byIndex = Dictionary(landed.map { ($0.clipping.chapterIndex ?? 0, $0) }, uniquingKeysWith: { a, _ in a })

            var chapters: [Book.Chapter]
            if let summary {
                chapters = summary.chapters.map { chapter in
                    let item = byIndex[chapter.index]
                    let state: Book.Chapter.State
                    switch (item, chapter.state) {
                    case (.some, _): state = .ready
                    case (nil, "ready"): state = .removed
                    case (nil, "rendering"): state = .rendering(chapter.progress)
                    case (nil, "encoding"): state = .encoding
                    case (nil, "failed"): state = .failed(chapter.reason ?? "failed")
                    default: state = .queued
                    }
                    return Book.Chapter(index: chapter.index, title: chapter.title, item: item, state: state)
                }
            } else if let record {
                // Sent, no word back yet: every chapter waits, those already here are ready.
                chapters = record.chapterTitles.enumerated().map { index, title in
                    Book.Chapter(index: index, title: title, item: byIndex[index], state: byIndex[index] == nil ? .queued : .ready)
                }
            } else {
                chapters = landed.map { Book.Chapter(index: $0.clipping.chapterIndex ?? 0,
                                                     title: $0.clipping.chapterTitle ?? $0.clipping.title, item: $0, state: .ready) }
                    .sorted { $0.index < $1.index }
            }

            let first = landed.first?.clipping
            let position = ledger.document(documentID)
            let status = summary?.status
            let change = changes.first { $0.documentID == documentID && $0.jobID == record?.jobID }
            books.append(Book(
                documentID: documentID,
                jobID: record?.jobID,
                title: summary?.title ?? record?.title ?? first?.documentTitle ?? first?.title ?? "Untitled",
                author: summary?.author ?? record?.author ?? first?.author,
                chapters: chapters,
                createdAt: summary?.createdAt ?? record?.createdAt ?? landed.map(\.clipping.createdAt).min() ?? .distantPast,
                pauseReason: status == .paused ? summary?.pauseReason : nil,
                failure: status == .failed ? chapters.compactMap { if case let .failed(why) = $0.state { why } else { nil } }.first : nil,
                isRendering: status == .rendering || status == .paused || (summary == nil && record != nil),
                position: position.flatMap { r in r.chapterIndex.map { ($0, r.seconds ?? 0) } },
                finished: position?.finished ?? false,
                adopted: record?.adopted == true,
                madeOnMac: record?.madeOnMac == true || summary?.uploaded == true,
                remaking: change.map { BookVoiceChanges.statusLine($0, chapters: summary?.chapters, total: chapters.count) },
                canStopRemaking: change?.startedHere == true))
        }
        return books.sorted { $0.createdAt > $1.createdAt }
    }

    /// "1 h 22 m", "45 m", "40 s", the same shape as the import estimate.
    static func durationText(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "\(Int(seconds.rounded())) s" }
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m" : "\(minutes) m"
    }
}

extension BookShareDraft {
    /// An iPhone book as Share… sees it: the chapters whose audio is here.
    @MainActor init(_ book: MobileBookShelf.Book, covers: BookCovers?,
                      timing: (@MainActor (ClippingStore.Item) async -> ReadAlongTiming?)? = nil) {
        self.init(documentID: book.documentID, title: book.title, author: book.author,
                  chapters: book.chapters.map { (index: $0.index, title: $0.title, item: $0.item) },
                  coverURL: covers?.url(for: book.documentID), timing: timing)
    }
}
