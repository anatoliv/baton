import Foundation

/// The line under a podcast episode: when it came out, and how much of it is left.
///
/// There were three of these — the Mac's client-RSS list, the Mac's server-podcast list,
/// and the phone's — and they disagreed on every part of it. The same 40-second trailer read
/// "0 min" on the phone and "1 min" on the Mac. The two Mac copies used different date
/// formatters. Only two of the three ever said "Played". And the remaining-time threshold
/// was `> 60` in one place and absent in another, so an episode with 45 seconds to go
/// showed "0 min left" on one screen and its full length on another.
///
/// None of that is a bug anyone would file. It is just an app that looks like nobody used it.
public enum PodcastEpisodeMeta {
    /// Builds the line. Returns nil when there is nothing worth saying, so callers can skip
    /// the row rather than render an empty one.
    ///
    /// - Parameters:
    ///   - publishDate: when the episode was published, if known.
    ///   - duration: total length in seconds.
    ///   - remaining: seconds left, when the episode is partway through.
    ///   - isPlayed: whether it has been finished.
    public static func line(publishDate: Date?,
                            duration: Int?,
                            remaining: TimeInterval?,
                            isPlayed: Bool) -> String? {
        var parts: [String] = []
        if let publishDate { parts.append(dateFormatter.string(from: publishDate)) }

        // In-progress beats total length: once you have started something, how much is
        // left is the only number you want. The one-minute floor keeps a nearly-finished
        // episode from reading "0 min left", which looks like it is stuck.
        if let remaining, remaining >= Self.remainingFloor {
            parts.append("\(PlayTime.spoken(Int(remaining)) ?? "1 min") left")
        } else if isPlayed {
            parts.append("Played")
        } else if let spoken = PlayTime.spoken(duration) {
            parts.append(spoken)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Below this, "left" is noise — the episode is effectively over and the row should say
    /// so by other means (the progress bar, or nothing at all).
    public static let remainingFloor: TimeInterval = 60

    /// One formatter, created once. `DateFormatter` is expensive to build and one of these
    /// was being constructed inside a view body, per row.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// The server sends ISO-8601; the client feed parser hands back a `Date`. Kept here so
    /// the two Mac screens stop carrying separate parsers for the same field.
    public static func parseISODate(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) { return date }
        // Fall back to a leading YYYY-MM-DD, which is what the old Mac code did.
        let prefix = String(raw.prefix(10))
        let short = DateFormatter()
        short.dateFormat = "yyyy-MM-dd"
        short.timeZone = TimeZone(identifier: "UTC")
        return short.date(from: prefix)
    }
}
