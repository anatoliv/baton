import BatonPlaybackKit
import BatonSubsonicModels
import Foundation

/// The phone's side of book playback: Play resumes at the synced chapter, the player
/// resumes inside it, the position is written while a chapter plays, and the end of the last
/// chapter finishes the book here and on the home server. The rules are the Mac's, from the
/// shared `BookPlayback`; the position and the finished mark go in the shared `ClippingLedger`,
/// which `PreferenceSync` carries between the two apps through the gateway.
extension MobileBookShelf {
    /// The book's chapters here as a queue, and where to start: the chosen chapter, or with none
    /// chosen the synced one (from the start once the book is finished). After the start, the
    /// chapters not here yet are not skipped: the queue stops short of the first, and
    /// `bookContinuation` brings it and the rest down in order while the book plays.
    @MainActor
    static func queue(for book: Book, fromChapter index: Int? = nil) -> (songs: [NavidromeSong], startIndex: Int) {
        BookPlayback.queue(chapters: book.chapters.compactMap(\.item), position: book.position,
                           finished: book.finished, fromChapter: index)
    }

    /// Where each chapter of a book stands on this phone, for `BookContinuation`: here, coming
    /// (being made on the home server, made there and not yet down, or removed here and able to
    /// come back), or not coming, with why. Nil for a book this phone knows only from Clippings.
    @MainActor
    static func continuationChapters(of book: Book, problem: String?, canGetBack: Bool) -> [BookContinuation.Chapter]? {
        guard book.jobID != nil else { return nil }
        return book.chapters.map { chapter in
            if chapter.item?.isPresent == true { return .here }
            if chapter.item != nil { return .unavailable("its audio file has gone") }
            switch chapter.state {
            case let .failed(why): return .unavailable("it could not be made (\(why))")
            case .removed where !canGetBack: return .unavailable("its audio was removed from this iPhone")
            default:
                if let problem { return .unavailable(problem) }
                return .coming
            }
        }
    }

    /// Note where a playing chapter is (the player calls this about every five seconds and at the
    /// end of a track). Returns the document id when this finished the book.
    ///
    /// The chapter count comes from the home server's job, then the remembered chapter titles:
    /// the last chapter to have landed is not the last chapter while the rest are still made.
    @MainActor
    @discardableResult
    static func recordProgress(_ song: NavidromeSong, time: TimeInterval, duration: TimeInterval,
                               clippings: ClippingStore, homeServer: HomeServerBooks?, now: Date = Date()) -> String? {
        guard let documentID = clippings.item(forSongID: song.id)?.clipping.documentID else { return nil }
        let count = homeServer?.record(forDocument: documentID).map { record in
            homeServer?.summaries[record.jobID]?.chapters.count ?? record.chapterTitles.count
        }
        return BookPlayback.record(song, time: time, duration: duration, chapterCount: count,
                                   clippings: clippings, now: now)
    }

    /// The listener reached the end of the book: tell the home server, which starts its retention
    /// clock (M6.6) and reads back the "kept until" date. A book it never made is left alone.
    @MainActor
    static func markFinished(documentID: String, homeServer: HomeServerBooks) async {
        guard let record = homeServer.record(forDocument: documentID) else { return }
        await homeServer.markFinished(jobID: record.jobID)
    }
}

extension MobileModel {
    /// The player's resume and progress hooks: a book chapter (a local clipping file) goes to the
    /// shared book rules, everything else to podcast progress as before.
    func installPlaybackProgressHooks() {
        let progress = podcastProgress
        let clippings = clippings
        // Speech plays at the spoken-items speed, music always at 1×, the Mac's rule.
        music.isSpokenItem = { song in
            song.isPodcastEpisode || progress.isServerEpisode(song.id)
                || clippings.item(forSongID: song.id) != nil
        }
        music.resumeOffsetProvider = { song in
            if MediaKind(id: song.id) == .localFile {
                return BookPlayback.resumeOffset(for: song, clippings: clippings)
            }
            return progress.resumeOffset(id: song.id)
        }
        // A book plays on into the chapters still on the home server, brought down in reading
        // order, and stops with the reason at a chapter that cannot come.
        music.continuationSource = BookContinuation(clippings: clippings, chapters: { [weak self] documentID in
            guard let self, self.documentsSwitch.isOn,
                  let book = self.shelfBooks.first(where: { $0.documentID == documentID }) else { return nil }
            return MobileBookShelf.continuationChapters(of: book, problem: self.books.problem,
                                                        canGetBack: self.getBackTitle(book) != nil)
        }, fetch: { [weak self] documentID, index in
            guard let self, let book = self.shelfBooks.first(where: { $0.documentID == documentID }) else { return }
            if book.chapters.first(where: { $0.index == index })?.state == .removed {
                try? await self.getBack(book, chapters: [index])
            } else {
                await self.books.collect()
            }
        })
        music.onProgressUpdate = { [weak self] song, time, duration in
            if MediaKind(id: song.id) == .localFile {
                guard let self else { return }
                // The home server's chapter count only while books are on, as on the Mac.
                let homeServer = self.documentsSwitch.isOn ? self.books : nil
                if let finished = MobileBookShelf.recordProgress(song, time: time, duration: duration,
                                                                 clippings: clippings, homeServer: homeServer) {
                    Task { await MobileBookShelf.markFinished(documentID: finished, homeServer: self.books) }
                }
                return
            }
            guard song.isPodcastEpisode || progress.isServerEpisode(song.id) else { return }
            _ = progress.record(id: song.id, position: time, duration: duration > 0 ? duration : nil)
        }
    }
}
