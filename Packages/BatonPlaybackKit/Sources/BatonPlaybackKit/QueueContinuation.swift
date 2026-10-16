import BatonSubsonicModels
import Foundation

/// What follows the last track of a queue once it exists.
public enum QueueContinuation: Equatable, Sendable {
    /// These play next, in this order.
    case more([NavidromeSong])
    /// Nothing more is coming. With a reason, the listener is told why the queue stops here.
    case ended(String?)
}

/// Something that can say what follows a track after the queue runs out: the rest of a book
/// whose chapters are still being made or brought down. The player asks while the last track
/// plays, so the next one is usually here before the boundary, and waits at the end when it
/// is not.
@MainActor
public protocol QueueContinuationSource: AnyObject {
    /// Whether more may follow `song` once it exists. Asked often: no work, no waiting.
    func continues(after song: NavidromeSong) -> Bool
    /// What follows `song`, once it is here: awaited for as long as it is still coming.
    func continuation(after song: NavidromeSong) async -> QueueContinuation
    /// What the player says while it waits at the end of the queue, such as "Waiting for chapter 3".
    func waitingText(after song: NavidromeSong) -> String?
}

/// A book plays through to its last chapter: the chapters after the one playing are
/// asked for while it plays, brought here (downloaded from the home server, or awaited from the
/// renderer), and join the queue in reading order. A chapter that cannot come stops the book at
/// that point with the reason, rather than skipping it or playing something again.
///
/// Shared by both apps; each says where its chapters stand and how to bring one here.
@MainActor
public final class BookContinuation: QueueContinuationSource {
    /// Where one chapter of a book stands on this device.
    public enum Chapter: Equatable, Sendable {
        /// Its audio is on this device.
        case here
        /// Being made, or made and on its way here: asking brings it.
        case coming
        /// It will not come, for this reason ("it could not be made", "the home server is not answering").
        case unavailable(String)
    }

    private let clippings: ClippingStore
    private let chapters: @MainActor (_ documentID: String) -> [Chapter]?
    private let fetch: @MainActor (_ documentID: String, _ chapterIndex: Int) async -> Void
    private let pollInterval: Duration

    /// - Parameters:
    ///   - chapters: every chapter of the book in reading order, as this device knows it; nil
    ///     when it knows nothing beyond the chapters in Clippings (no render job, books off).
    ///   - fetch: bring a chapter here: collect it from the home server, or read what the
    ///     renderer has finished. Called again on every round until the chapter arrives.
    public init(clippings: ClippingStore,
                chapters: @escaping @MainActor (_ documentID: String) -> [Chapter]?,
                fetch: @escaping @MainActor (_ documentID: String, _ chapterIndex: Int) async -> Void,
                pollInterval: Duration = .seconds(3)) {
        self.clippings = clippings
        self.chapters = chapters
        self.fetch = fetch
        self.pollInterval = pollInterval
    }

    public func continues(after song: NavidromeSong) -> Bool {
        guard let (documentID, index) = place(of: song), let all = chapters(documentID) else { return false }
        return all.count > index + 1
    }

    public func waitingText(after song: NavidromeSong) -> String? {
        guard let (_, index) = place(of: song) else { return nil }
        return "Waiting for chapter \(index + 2)"
    }

    public func continuation(after song: NavidromeSong) async -> QueueContinuation {
        guard let (documentID, index) = place(of: song) else { return .ended(nil) }
        let next = index + 1
        while !Task.isCancelled {
            let here = Self.presentRun(clippings.chapters(ofDocument: documentID), from: next)
            if !here.isEmpty { return .more(here.map(\.asSong)) }
            guard let all = chapters(documentID), all.indices.contains(next) else { return .ended(nil) }
            if all[next] == .coming { await fetch(documentID, next) }
            let fetched = Self.presentRun(clippings.chapters(ofDocument: documentID), from: next)
            if !fetched.isEmpty { return .more(fetched.map(\.asSong)) }
            // Judged after asking, so a stale "not answering" from before does not stop the book.
            switch chapters(documentID).flatMap({ $0.indices.contains(next) ? $0[next] : nil }) {
            case nil:
                return .ended(nil)
            case let .unavailable(why)?:
                return .ended(Self.stopText(chapter: next, why: why))
            case .here?:
                // In the list, yet no audio file: it has gone, and waiting will not bring it.
                return .ended(Self.stopText(chapter: next, why: "its audio file has gone"))
            case .coming?:
                try? await Task.sleep(for: pollInterval)
            }
        }
        return .ended(nil)
    }

    /// "Stopped before chapter 3: it could not be made."
    public static func stopText(chapter index: Int, why: String) -> String {
        "Stopped before chapter \(index + 1): \(why)."
    }

    /// The chapters whose audio is here from `index` on, in reading order, up to the first that is
    /// not: a later chapter never plays before an earlier one has.
    public static func presentRun(_ items: [ClippingStore.Item], from index: Int) -> [ClippingStore.Item] {
        let byIndex = Dictionary(items.compactMap { item in item.clipping.chapterIndex.map { ($0, item) } },
                                 uniquingKeysWith: { first, _ in first })
        var run: [ClippingStore.Item] = []
        var at = index
        while let item = byIndex[at], item.isPresent {
            run.append(item)
            at += 1
        }
        return run
    }

    private func place(of song: NavidromeSong) -> (String, Int)? {
        guard let item = clippings.item(forSongID: song.id), let documentID = item.clipping.documentID,
              let index = item.clipping.chapterIndex else { return nil }
        return (documentID, index)
    }
}
