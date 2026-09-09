import BatonSubsonicKit
import Foundation

/// What became of a `baton://` link.
///
/// Every failing case used to be `try?` or an empty array quietly falling through, so
/// tapping a Baton link from Messages, a shortcut or a note opened the app and then nothing
/// happened at all. Offline, wrong server, deleted track and "the link never fired" were
/// indistinguishable, which is the worst kind of failure: the person cannot even tell there
/// was one.
enum DeepLinkOutcome: Equatable {
    case handled
    /// No server configured yet — including demo mode, where there is nothing to fetch from.
    case notConnected
    case songUnavailable
    case albumUnavailable

    /// What to say, or nil when there is nothing to say.
    ///
    /// Deliberately does not guess *why* a fetch failed. "Offline" and "the track is gone"
    /// look identical from here, and a confident wrong reason is worse than an honest vague
    /// one.
    var message: String? {
        switch self {
        case .handled:
            nil
        case .notConnected:
            "Connect Baton to your music server first, then open the link again."
        case .songUnavailable:
            "That track could not be loaded. It may have been removed, or your server may be unreachable."
        case .albumUnavailable:
            "That album could not be loaded. It may have been removed, or your server may be unreachable."
        }
    }
}

extension MobileModel {
    /// Carries out a link and reports what happened.
    ///
    /// What a link *means* is `BatonDeepLink`'s job and is tested as a pure function; this
    /// only acts on it, and says so when it cannot.
    @MainActor
    func open(_ link: BatonDeepLink) async -> DeepLinkOutcome {
        switch link {
        case .presentPlayer:
            requestFullPlayer()
            return .handled
        case let .playSong(id):
            guard NavidromeConfig.isConfigured else { return .notConnected }
            guard let song = try? await NavidromeConfig.makeClient().getSong(id: id) else {
                return .songUnavailable
            }
            music.play([song], source: .init(label: song.title, kind: .song, id: id))
            return .handled
        case let .playAlbum(id):
            guard NavidromeConfig.isConfigured else { return .notConnected }
            let songs = await musicLibrary.albumSongs(id: id)
            guard !songs.isEmpty else { return .albumUnavailable }
            music.play(songs, source: .init(label: "Album", kind: .album, id: id))
            return .handled
        }
    }
}
