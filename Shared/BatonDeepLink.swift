import Foundation
import BatonShareKit

/// What a `baton://` URL asks for, decided before anything is done about it.
///
/// Split out from `BatonMobileApp.route` so the decision can be tested without a running
/// app, a configured server or a network. The bug that motivated it is exactly the kind a
/// pure function pins down: the Now Playing widget pointed at `baton://play/<id>`, which is
/// a perfectly good link that means "play this song" — build a one-item queue and start it
/// from 0:00. Tapping a display of what is *already playing* therefore destroyed the queue
/// and lost the position, and nothing about the widget's own code looked wrong.
///
/// `.presentPlayer` exists so that intent has a spelling of its own.
///
/// Shared, because the Mac now claims `baton://` too. One vocabulary or two: a link that
/// opens the player on a phone and does something else on a desktop is worse than a link
/// that only works in one place, because you cannot tell which you have.
public enum BatonDeepLink: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Show the full player. Deliberately carries no id and starts nothing: the caller is
    /// looking at what is playing and wants a closer look at it.
    case share(id: String, key: Data?)
    case mixtape(id: String, key: Data?)
    case presentPlayer
    case playSong(id: String)
    case playAlbum(id: String)

    /// Returns nil for anything this app does not claim — a foreign scheme, a host with no
    /// meaning here, or an action whose id is missing.
    public init?(url: URL) {
        if let invitation = ShareInvitation(url: url) {
            // A whole-book link has no native receiver: it belongs to the browser player
            // (`isBrowserOnlyShare`), never to the song or mixtape screens.
            guard invitation.kind != .book else { return nil }
            self = invitation.kind == .mixtape ? .mixtape(id: invitation.id, key: invitation.key) : .share(id: invitation.id, key: invitation.key)
            return
        }
        guard url.scheme == "baton" else { return nil }
        let id = url.lastPathComponent
        switch url.host() {
        case "player":
            self = .presentPlayer
        case "play" where !id.isEmpty && id != "/":
            self = .playSong(id: id)
        case "album" where !id.isEmpty && id != "/":
            self = .playAlbum(id: id)
        default:
            return nil
        }
    }

    public var description: String {
        switch self {
        case let .share(id, _): "BatonDeepLink.share(\(id), key withheld)"
        case let .mixtape(id, _): "BatonDeepLink.mixtape(\(id), key withheld)"
        case .presentPlayer: "BatonDeepLink.presentPlayer"
        case let .playSong(id): "BatonDeepLink.playSong(\(id))"
        case let .playAlbum(id): "BatonDeepLink.playAlbum(\(id))"
        }
    }
    public var debugDescription: String { description }

    /// A share link the apps hand to the browser rather than open themselves: a whole book
    /// (`/b/`, specs/book-sharing.md Phase 2), which only the web player plays.
    public static func isBrowserOnlyShare(_ url: URL) -> Bool { ShareInvitation(url: url)?.kind == .book }

    /// Whether acting on this link changes what is playing.
    ///
    /// The widget must only ever fire a link for which this is false. Stated as a property
    /// rather than left implicit so the test can assert it about `presentPlayer` directly,
    /// and so a future link has to answer the question.
    public var disturbsPlayback: Bool {
        switch self {
        case .presentPlayer, .share, .mixtape: false
        case .playSong, .playAlbum: true
        }
    }
}
