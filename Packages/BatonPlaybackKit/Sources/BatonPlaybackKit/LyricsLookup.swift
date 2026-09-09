import BatonSubsonicModels
import Foundation

/// Why a lyrics lookup came back with nothing.
///
/// The lyrics path used to answer every question with the same word. A refused credential, a
/// rate limit from LRCLIB (which answers 429 and means "ask again later"), a 500 and a track
/// nobody has ever written words for all arrived at the panel as "No lyrics for this track",
/// and all of them were logged, if at all, at `debug`. Two of those are things the person can
/// act on and one of them is not even about this track.
///
/// So the kind of failure is carried out of the fetch rather than thrown away at it. Only the
/// two actionable kinds reach the screen: a refused sign in means fix the server, and a rate
/// limit means wait. Everything else is logged at the level the rest of this client logs a
/// failed request and still shows the ordinary empty state, because "the network hiccuped
/// while you had the panel open" is not worth a sentence in a lyrics sheet.
public enum LyricsFailure: Equatable, Sendable {
    /// The sign in was refused: a wrong password, a revoked key, a locked Keychain, or a
    /// reverse proxy answering 401 or 403.
    case refused
    /// The lyrics service asked us to slow down (HTTP 429).
    case rateLimited
    /// Anything else: offline, a timeout, a 500, a body that did not parse.
    case unavailable

    /// The one line shown in place of the empty state. Nil for the kinds that stay in the log.
    public var message: String? {
        switch self {
        case .refused:
            #if os(macOS)
            return "Lyrics could not load. Check the server sign in in Settings, Servers."
            #else
            return "Lyrics could not load. Check the server sign in in Settings, Server."
            #endif
        case .rateLimited:
            return "The lyrics service is rate limiting requests. Try again in a minute."
        case .unavailable:
            return nil
        }
    }

    /// A short heading for the phone, which puts the reason under one.
    public var title: String? {
        switch self {
        case .refused: "Sign in refused"
        case .rateLimited: "Too many lyrics requests"
        case .unavailable: nil
        }
    }

    /// Which failure to keep when the server hop and the LRCLIB hop both failed.
    ///
    /// A refused sign in is the one a person can fix, so it outranks a rate limit, which
    /// outranks a plain "did not work". Without an order the answer would depend on which
    /// request happened to finish last, which is how a fixable problem stays invisible.
    var rank: Int {
        switch self {
        case .refused: 2
        case .rateLimited: 1
        case .unavailable: 0
        }
    }
}

/// The answer to "what are this track's lyrics", with the difference between "there are none"
/// and "we could not find out" preserved.
public enum LyricsLookup: Equatable, Sendable {
    case found(NavidromeLyrics)
    /// The lookup ran and this track genuinely has no lyrics anywhere we asked.
    case none
    case failed(LyricsFailure)

    public var lyrics: NavidromeLyrics? {
        if case let .found(lyrics) = self { return lyrics }
        return nil
    }

    /// The line to show instead of the empty state, or nil to show the empty state.
    public var failureMessage: String? {
        if case let .failed(failure) = self { return failure.message }
        return nil
    }

    /// The heading that goes with `failureMessage`, where a screen wants one.
    public var failureTitle: String? {
        if case let .failed(failure) = self { return failure.title }
        return nil
    }

    /// Combines the two hops: lyrics win, then the more actionable failure, then nothing.
    static func combining(_ first: LyricsLookup, _ second: LyricsLookup) -> LyricsLookup {
        if case .found = first { return first }
        if case .found = second { return second }
        switch (first, second) {
        case let (.failed(lhs), .failed(rhs)): return .failed(lhs.rank >= rhs.rank ? lhs : rhs)
        case let (.failed(lhs), _): return .failed(lhs)
        case let (_, .failed(rhs)): return .failed(rhs)
        default: return LyricsLookup.none
        }
    }
}
