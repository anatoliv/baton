import SwiftUI

// MARK: - Playback resolution

/// Resolves a pin to playback. Directly-playable kinds (song / episode / station) start
/// immediately; collection kinds (album / playlist / artist / podcast) load their tracks first.
@MainActor
enum PinPlayback {
    static func play(_ pin: PinnedItem, _ model: MusicModel) {
        let source = StreamingPlaybackController.QueueSource(label: pin.title, kind: .playlist, id: pin.refID)
        switch pin.kind {
        case .song, .podcastEpisode:
            model.music.play([pin.asSong], source: source)
        case .radioStation:
            if let station = model.internetRadio.stations.first(where: { $0.id == pin.refID }) {
                model.internetRadio.play(station)
            } else {
                model.music.postToast("Station unavailable", symbol: "exclamationmark.triangle")
            }
        case .podcastChannel:
            guard let channel = model.podcastSubscriptions.channels.first(where: { $0.id == pin.refID }) else {
                model.music.postToast("Podcast unavailable", symbol: "exclamationmark.triangle"); return
            }
            // Episodes are stored newest-first; play a whole show oldest-first so a serialized
            // podcast runs in chronological order.
            let songs = channel.episodes.reversed().map { $0.asSong(channelTitle: channel.title, artwork: $0.imageURL ?? channel.imageURL) }
            playOrToast(songs, source, model)
        case .album:
            Task { playOrToast(await model.musicLibrary.albumSongs(id: pin.refID), source, model) }
        case .playlist:
            Task { playOrToast(await model.musicLibrary.playlist(id: pin.refID)?.songs ?? [], source, model) }
        case .artist:
            Task { playOrToast(await model.musicLibrary.artistSongs(id: pin.refID), source, model) }
        }
    }

    private static func playOrToast(
        _ songs: [NavidromeSong], _ source: StreamingPlaybackController.QueueSource, _ model: MusicModel
    ) {
        if songs.isEmpty {
            model.music.postToast("Nothing to play", symbol: "exclamationmark.triangle")
        } else {
            model.music.play(songs, source: source)
        }
    }
}

// MARK: - Pin toggle menu button

/// A reusable "Save to Later / Remove from Later" menu button, dropped into any row's context
/// menu so every media type gets the same pin affordance. `model` is passed explicitly (not via
/// `@Environment`) because SwiftUI does not reliably propagate observable environment objects
/// into context-menu / `Menu` content — the same reason the album/artist menu builders take it.
struct PinMenuButton: View {
    let item: PinnedItem
    let model: MusicModel

    var body: some View {
        let pinned = model.pins.isPinned(item.id)
        Button {
            model.pins.toggle(item)
            model.music.postToast(pinned ? "Removed from Later" : "Saved to Later",
                                  symbol: pinned ? "bookmark.slash" : "bookmark.fill")
        } label: {
            Label(pinned ? "Remove from Later" : "Save to Later", systemImage: pinned ? "bookmark.slash" : "bookmark")
        }
    }
}
