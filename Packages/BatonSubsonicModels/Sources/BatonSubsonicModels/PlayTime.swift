import Foundation

/// Play time, in the shapes lists actually need.
///
/// This existed eleven times before it existed once, and the copies had already drifted:
/// the same 70-minute mix read `1:04:30` on the phone and `70:23` on the Mac, and its
/// remaining time read `-101:30` — because six Mac sites formatted `%d:%02d` with no hour
/// branch at all, so minutes just kept counting past sixty. Nothing failed; the number was
/// simply wrong, in the one place a listener looks to know where they are.
///
/// Three shapes, because a track, a collection and a sentence want different answers to
/// "how long":
///
/// - `track` — `4:21`, `1:04:30`. A position on a clock.
/// - `total` — `45m`, `6h 57m`. An evening. Never seconds; nobody plans to the second.
/// - `spoken` — `4 hr 12 min`. Prose, for when the duration sits inside a sentence.
///
/// Using one shape for all three makes track lists look like spreadsheets and album
/// totals look like timestamps, which is why the split is deliberate rather than historical.
/// Moved here from BatonPlaybackKit so the agent layer can use it without depending on the
/// audio engine. It is pure Foundation arithmetic and always was; living beside the player was
/// an accident of where it was first needed. Its own comment already called it "the shared
/// formatter", and a formatter two packages need belongs in the package both of them see.
public enum PlayTime {
    /// A single track: `4:21`, or `1:04:30` once it passes an hour (live sets, DJ mixes,
    /// long podcast episodes — this library is full of all three).
    ///
    /// Returns nil for nil, zero and negative input: a row with no duration should render
    /// nothing rather than `0:00`, which reads as a real track of no length.
    public static func track(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60, secs = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Seconds off a player clock, which are `Double`. Deliberately a *different name*
    /// rather than an overload: with both `track(Int?)` and `track(Double?)` in scope, the
    /// perfectly reasonable `track(nil)` stops compiling, and an API that punishes the
    /// obvious spelling is one people work around. Callers say what they have.
    public static func track(seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite else { return nil }
        return track(Int(seconds))
    }

    /// Time left, as the player shows it: `-1:39:15`. Same shape as `track`, with a sign.
    ///
    /// Clamped at zero rather than allowed to go positive-looking: a stream whose reported
    /// duration is slightly short of its real length would otherwise count *up* past the
    /// end, which looks like a bug even though the arithmetic is honest.
    public static func remaining(_ seconds: Int?) -> String? {
        guard let seconds else { return nil }
        guard seconds > 0 else { return "-0:00" }
        return track(seconds).map { "-" + $0 }
    }

    public static func remaining(seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite else { return nil }
        return remaining(Int(seconds))
    }

    /// A collection: `6h 57m`, or `45m` under an hour.
    public static func total(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// The same duration inside a sentence: `4 hr 12 min`, `38 min`.
    ///
    /// Rounds up to one minute rather than saying "0 min", which is what a 40-second
    /// podcast trailer used to render as — technically true and useless.
    public static func spoken(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let minutes = max(1, Int((Double(seconds) / 60.0).rounded()))
        let hours = minutes / 60, mins = minutes % 60
        if hours == 0 { return "\(mins) min" }
        return mins == 0 ? "\(hours) hr" : "\(hours) hr \(mins) min"
    }
}
