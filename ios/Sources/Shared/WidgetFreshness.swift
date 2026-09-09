import Foundation

/// How long a published now-playing snapshot is worth believing.
///
/// The app pushes a snapshot on every track and pause change and nothing else ever moves
/// the widget: the timeline policy is `.never` and the Live Activity was pushed with
/// `staleDate: nil`. So if the app is jetsammed, force-quit or crashes mid-track, the home
/// screen and the Lock Screen go on claiming Baton is playing that song for as long as the
/// phone stays up. The snapshot has carried `updatedAt` the whole time and nothing read it
/// (I-F11).
///
/// Compiled into both the app and the widget extension, which share no module — the same
/// arrangement as `NowPlayingActivityAttributes`.
enum WidgetFreshness {
    /// After this much silence a snapshot stops being treated as live. Long enough to sit
    /// through a side of a record without the widget second-guessing a healthy app, short
    /// enough that a crash is not still being reported at bedtime.
    static let window: TimeInterval = 30 * 60

    /// Whether a snapshot published at `updatedAt` should still be shown as playback.
    ///
    /// `asOf` is the entry's own date rather than "now" on purpose: WidgetKit renders a
    /// timeline entry ahead of the moment it displays it, so asking the wall clock at render
    /// time answers a question about the wrong instant.
    static func isStale(updatedAt: Date, asOf: Date) -> Bool {
        asOf.timeIntervalSince(updatedAt) >= window
    }

    /// The instant a snapshot published at `updatedAt` goes stale. The timeline schedules a
    /// second entry here, which is what lets the widget go quiet with the app not running.
    static func staleMoment(after updatedAt: Date) -> Date {
        updatedAt.addingTimeInterval(window)
    }

    /// What to hand `ActivityContent(state:staleDate:)`.
    ///
    /// While playing with a known duration, the card is truthful until the track ends, so
    /// that plus a minute of slack is the honest answer. Paused, or on a stream with no
    /// duration, there is nothing to count down and the plain window applies.
    static func activityStaleDate(
        from now: Date, elapsed: TimeInterval, duration: TimeInterval, isPlaying: Bool
    ) -> Date {
        let remaining = duration > 0 ? max(0, duration - elapsed) : 0
        let ahead = (isPlaying && remaining > 0) ? remaining + 60 : window
        // A stream reporting a nonsense duration must not push the stale date into next week.
        return now.addingTimeInterval(min(max(ahead, 60), 6 * 60 * 60))
    }
}
