import Foundation

/// What an open book's main button does, and how far along the book is, on the Mac and the
/// iPhone alike.
///
/// The button used to be Play or Resume whatever the player was doing, and always queued the
/// book again from its saved place. While the book played that place lagged behind the
/// playhead, so pressing "Resume" on a book that was already playing jumped it back, and there
/// was no way to pause it from the book. Now, while one of the book's chapters is the one in
/// the player, the button is the player's own Pause or Resume and touches nothing else; only a
/// book that is not in the player is queued from its place (with the TBX-10993 place pull and
/// the "Previously…" offer).
public enum BookTransport {
    public enum Action: Equatable, Sendable {
        /// This book is playing: pause the player.
        case pause
        /// This book is in the player and paused: carry on from the playhead.
        case resumePlayer
        /// This book is not in the player and has a place to go back to: queue it from there.
        case resumeFromPlace
        /// This book is not in the player and has no place (or is finished): play from the start.
        case play

        /// The button's words.
        public var title: String {
            switch self {
            case .pause: return "Pause"
            case .resumePlayer, .resumeFromPlace: return "Resume"
            case .play: return "Play"
            }
        }

        /// The button's symbol, the same pair the transports morph between.
        public var symbol: String { self == .pause ? "pause.fill" : "play.fill" }

        /// Whether the action is the player's own toggle rather than queuing the book.
        public var togglesPlayer: Bool { self == .pause || self == .resumePlayer }
    }

    /// The source a book plays under, so the shared collection rule (`CollectionPlayState`,
    /// TBX-11066) knows it: one per book, by its document id. `.song` rather than a kind of its
    /// own, because the source travels in the saved and handed-off queue, and a kind an older
    /// build does not know would fail to decode there.
    public static func source(documentID: String, title: String) -> StreamingPlaybackController.QueueSource {
        .init(label: title, kind: .song, id: documentID)
    }

    /// The main button from where the book stands in the player (the shared rule): Pause while
    /// it plays, Resume while it is paused there, else Resume from its place or Play.
    public static func action(_ state: CollectionPlayState, finished: Bool, hasPosition: Bool) -> Action {
        switch state {
        case .playing: return .pause
        case .paused: return .resumePlayer
        case .idle: return action(isLoaded: false, isPlaying: false, finished: finished, hasPosition: hasPosition)
        }
    }

    /// The main button for a book. `isLoaded`: the book is the collection in the player,
    /// playing or paused. `isPlaying`: the player is playing.
    public static func action(isLoaded: Bool, isPlaying: Bool, finished: Bool, hasPosition: Bool) -> Action {
        if isLoaded { return isPlaying ? .pause : .resumePlayer }
        return !finished && hasPosition ? .resumeFromPlace : .play
    }

    /// A tap (or double-click) on a chapter row. The chapter in the player toggles it, as a music
    /// row that is playing does, instead of queuing the book again from the saved place, which
    /// lags behind the playhead and jumped the chapter back. Nil: play the book from that chapter.
    public static func chapterTap(isCurrentChapter: Bool, isPlaying: Bool) -> Action? {
        guard isCurrentChapter else { return nil }
        return isPlaying ? .pause : .resumePlayer
    }

    /// The place to show the book's progress from: the live playhead while one of its chapters
    /// is in the player (`loadedChapter`, `playhead` seconds into it), else the saved place.
    /// The saved place is written every few seconds and on pause, so while the book plays it
    /// trails the playhead; the owner saw "0% heard" on a book ten minutes into chapter 1.
    public static func place(loadedChapter: Int?, playhead: Double,
                             saved: (chapterIndex: Int, seconds: Double)?) -> (chapterIndex: Int, seconds: Double)? {
        guard let loadedChapter else { return saved }
        return (loadedChapter, max(0, playhead))
    }

    /// How far through the book a place is, 0...1: the lengths of the chapters before it plus
    /// the seconds into its own chapter, over the length of every chapter given. `chapters` are
    /// (index, seconds) for the chapters whose length is known here. A book that is finished
    /// and not being heard again (`live` false) reads as 1.
    public static func fraction(chapters: [(index: Int, seconds: Double)],
                                place: (chapterIndex: Int, seconds: Double)?,
                                finished: Bool, live: Bool = false) -> Double {
        if finished && !live { return 1 }
        let total = chapters.map(\.seconds).reduce(0, +)
        guard let place, total > 0 else { return 0 }
        let before = chapters.filter { $0.index < place.chapterIndex }.map(\.seconds).reduce(0, +)
        return min(1, max(0, (before + place.seconds) / total))
    }

    /// "12% heard"; under one percent heard but started, "Under 1% heard" rather than a
    /// "0% heard" that reads as nothing.
    public static func heardText(_ fraction: Double) -> String {
        let percent = Int((fraction * 100).rounded())
        return percent == 0 && fraction > 0 ? "Under 1% heard" : "\(percent)% heard"
    }
}
