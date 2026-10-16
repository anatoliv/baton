import BatonSubsonicModels
import Foundation

/// What the player does with a book chapter: resume where the listener was, remember where they
/// are, and notice the end of the book. The same hooks podcasts use, so there is no second
/// resume mechanism.
///
/// Shared by both apps: the position and the finished mark live in the shared
/// `ClippingLedger`, which `PreferenceSync` merges per book through the gateway, so the Mac and
/// the iPhone must write it the same way. The Mac adds its own queue builder for its shelf.
@MainActor
public enum BookPlayback {
    /// The offset to start a chapter at, when the synced position is inside it. A position in the
    /// last few seconds counts as the end, so the chapter starts over rather than ending at once.
    public static func resumeOffset(for song: NavidromeSong, clippings: ClippingStore) -> TimeInterval? {
        guard let item = clippings.item(forSongID: song.id), let documentID = item.clipping.documentID,
              let record = clippings.ledger.document(documentID), !record.finished,
              record.chapterIndex == item.clipping.chapterIndex,
              let seconds = record.seconds, seconds > 1 else { return nil }
        if let duration = item.clipping.durationSeconds, seconds > duration - 5 { return nil }
        return seconds
    }

    /// Note the position, and at the end of the last chapter that the book is finished. Returns
    /// the finished book's document id, so the caller can tell the renderer too. A finished book
    /// played again past its first minute is unfinished here and in the synced ledger; the home
    /// server's finished mark is left alone, since it only starts the audio's retention clock.
    ///
    /// `chapterCount` is the book's, from its render job: the last chapter to have *landed* is
    /// not the last chapter while the rest still renders. Without a job, the landed ones are all
    /// there is.
    @discardableResult
    public static func record(_ song: NavidromeSong, time: TimeInterval, duration: TimeInterval,
                              chapterCount: Int?, clippings: ClippingStore, now: Date = Date()) -> String? {
        guard let item = clippings.item(forSongID: song.id), let documentID = item.clipping.documentID,
              let index = item.clipping.chapterIndex else { return nil }
        var ledger = clippings.ledger
        // A finished book played again: once the replay passes its first minute, the book is
        // being listened to, not merely sampled, so it stops being finished and the next Play
        // resumes here. Before the position moves, because the rule is about crossing.
        if let previous = ledger.document(documentID), previous.finished,
           replayPassesThreshold(from: previous, to: (index, time), documentID: documentID, clippings: clippings) {
            ledger.setFinished(false, documentID: documentID, at: now)
        }
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

    /// How far into a finished book a replay has to get before the book counts as unfinished.
    public static let replayUnfinishSeconds: TimeInterval = 60

    /// Whether this progress tick carries a finished book's replay past its first minute.
    ///
    /// A crossing, from below the threshold to at or above it, rather than "anywhere past it":
    /// right after the book finishes, the ledger holds the end of the last chapter, and a tick
    /// that comes straight after (the last chapter starting once more, as the TBX-10974 walk saw
    /// on the iPhone) must not undo the finish it just recorded. Play on a finished book starts
    /// at chapter 1, so a real replay always passes through the first minute.
    static func replayPassesThreshold(from previous: ClippingLedger.DocumentRecord,
                                      to current: (chapterIndex: Int, seconds: TimeInterval),
                                      documentID: String, clippings: ClippingStore) -> Bool {
        guard let fromChapter = previous.chapterIndex, let fromSeconds = previous.seconds else { return false }
        let before = secondsIntoBook(chapterIndex: fromChapter, seconds: fromSeconds,
                                     documentID: documentID, clippings: clippings)
        let after = secondsIntoBook(chapterIndex: current.chapterIndex, seconds: current.seconds,
                                    documentID: documentID, clippings: clippings)
        return before < replayUnfinishSeconds && after >= replayUnfinishSeconds
    }

    /// A position as seconds from the start of the book: the lengths of the chapters before it
    /// that are on this device, plus the offset in its own chapter. A chapter not here counts as
    /// nothing, which can only make the book look less far along.
    static func secondsIntoBook(chapterIndex: Int, seconds: TimeInterval, documentID: String,
                                clippings: ClippingStore) -> TimeInterval {
        let before = clippings.chapters(ofDocument: documentID)
            .filter { ($0.clipping.chapterIndex ?? .max) < chapterIndex }
            .compactMap(\.clipping.durationSeconds)
            .reduce(0, +)
        return before + seconds
    }

    /// Where Play starts in a book's playable chapters (in reading order): the synced chapter,
    /// or the first once the book is finished or nothing has been heard. A synced chapter whose
    /// audio is not here starts the book from the beginning rather than somewhere unexpected.
    public static func startIndex(in playable: [ClippingStore.Item],
                                  position: (chapterIndex: Int, seconds: Double)?, finished: Bool) -> Int {
        guard !finished, let position,
              let start = playable.firstIndex(where: { $0.clipping.chapterIndex == position.chapterIndex })
        else { return 0 }
        return start
    }

    /// What Play queues for a book, and where in it to start: the chosen chapter, or
    /// with none chosen the synced one (from the start once the book is finished). The chapters
    /// here before the start come first, so Previous reaches them; after the start, only the
    /// unbroken run of chapters that are here. The rest join in reading order as they arrive
    /// (`BookContinuation`), so a chapter is never skipped because it was late.
    ///
    /// `chapters` are the book's chapters in Clippings, in any order.
    public static func queue(chapters: [ClippingStore.Item], position: (chapterIndex: Int, seconds: Double)?,
                             finished: Bool, fromChapter chosen: Int? = nil) -> (songs: [NavidromeSong], startIndex: Int) {
        let playable = chapters.filter(\.isPresent)
            .sorted { ($0.clipping.chapterIndex ?? 0) < ($1.clipping.chapterIndex ?? 0) }
        var start = startIndex(in: playable, position: position, finished: finished)
        if let chosen, let index = playable.firstIndex(where: { $0.clipping.chapterIndex == chosen }) { start = index }
        guard playable.indices.contains(start) else { return ([], 0) }
        let run = BookContinuation.presentRun(playable, from: playable[start].clipping.chapterIndex ?? 0)
        return ((playable[..<start] + run).map(\.asSong), start)
    }
}

/// What a tap on a clipping that is not part of a book plays: it and the readings
/// after it in the list. A book's chapters are left out, since a book plays as its own queue,
/// in reading order, from its own row.
public enum ClippingQueue {
    /// Every reading in `items` that can be played, in list order.
    public static func readings(_ items: [ClippingStore.Item]) -> [NavidromeSong] {
        items.filter { !$0.clipping.isBookChapter && $0.isPresent }.map(\.asSong)
    }

    /// The reading `item` and the readings after it.
    public static func readings(from item: ClippingStore.Item, in items: [ClippingStore.Item]) -> [NavidromeSong] {
        let songs = readings(items)
        guard let index = songs.firstIndex(where: { $0.id == item.asSong.id }) else { return [] }
        return Array(songs[index...])
    }
}
