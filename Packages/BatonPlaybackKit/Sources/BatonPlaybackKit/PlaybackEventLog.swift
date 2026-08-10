import BatonSubsonicModels
import Foundation

/// What was played, and for how long before you moved on.
///
/// `MusicPlayHistory` records that a track was played and when — which answers "what have I
/// been listening to" and cannot answer "did they actually like it". A track played to the
/// end and a track skipped after nine seconds are the same entry there, and they are the two
/// most different signals a listener produces.
///
/// This fills that gap for the music friend: it is the difference between "you played this"
/// and "you put this on and immediately turned it off", which is exactly what a suggestion
/// engine needs and exactly what `FriendFeedbackLog.skippedQuickly` already noticed for the
/// friend's *own* picks. This widens it to everything.
///
/// **In memory, session-scoped, deliberately.** Persisting it would mean a new on-disk
/// format holding listening behaviour — a privacy surface and a migration — for something an
/// agent asks about within a session. `MusicPlayHistory` remains the durable record.
/// How soon after a track starts a skip means "not this".
///
/// Ten seconds because no track is ten seconds long, so this is somebody reaching for the
/// button rather than a track ending. It lives in its own nonisolated type because both
/// readers need it from different isolation: `PlaybackEventLog.Event` is a value type, and
/// `FriendFeedbackLog` (BatonAgentKit, which depends on this package) reads it too. Two
/// copies of "how soon is too soon" would drift, and the two places that ask the question
/// must agree or the friend's log and the play events disagree about the same skip.
public enum QuickSkip {
    public static let window: TimeInterval = 10
}

@MainActor
@Observable
public final class PlaybackEventLog {
    public struct Event: Identifiable, Sendable {
        public let id = UUID()
        public let songID: String
        public let title: String
        public let artist: String?
        public let startedAt: Date
        /// Seconds of audio actually heard, not wall-clock: a paused track is not a listened one.
        public let listenedSeconds: Double
        /// The track's full length, so a consumer can judge *proportion* — thirty seconds of
        /// a ninety-second interlude is a very different act from thirty seconds of an hour.
        public let durationSeconds: Double
        public let reason: Reason

        public enum Reason: String, Sendable {
            /// Ran to its natural end.
            case finished
            /// Next/previous, or a jump elsewhere in the queue.
            case skipped
            /// The queue was replaced or playback stopped.
            case interrupted
        }

        /// How much of it was heard. Nil when the duration is unknown (a live stream).
        public var completion: Double? {
            guard durationSeconds > 0 else { return nil }
            return min(1, listenedSeconds / durationSeconds)
        }

        /// The signal worth acting on: started, and abandoned almost at once.
        ///
        /// Ten seconds matches `FriendFeedbackLog.quickSkipWindow`, and for the same reason
        /// — no track is ten seconds long, so this is somebody reaching for the button
        /// rather than a track ending.
        public var wasAbandonedImmediately: Bool {
            reason == .skipped && listenedSeconds <= QuickSkip.window
        }
    }

    /// Newest first. Capped: this is a session's tail, not an archive.
    public private(set) var events: [Event] = []
    private let limit = 200

    public init() {}

    public func record(song: NavidromeSong, startedAt: Date,
                       listenedSeconds: Double, reason: Event.Reason) {
        // Sub-second entries are queue churn — building a queue, correcting a mis-tap —
        // not listening, and recording them would bury the real signal in noise.
        guard listenedSeconds >= 1 else { return }
        events.insert(Event(
            songID: song.id,
            title: song.title,
            artist: song.artist,
            startedAt: startedAt,
            listenedSeconds: listenedSeconds,
            durationSeconds: Double(song.duration ?? 0),
            reason: reason
        ), at: 0)
        if events.count > limit { events.removeLast(events.count - limit) }
    }

    public func clear() { events = [] }
}
