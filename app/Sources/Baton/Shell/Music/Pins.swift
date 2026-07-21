import Foundation
import Observation
import OSLog
import SwiftUI

private let pinLog = Logger(subsystem: "io.tonebox.baton", category: "Pins")

// MARK: - Model

/// A saved-for-later reference to any media type in the player. Distinct from **Liked** (a
/// server-side taste star, songs/albums/artists only) and the transient **Queue**: a pin is a
/// local, cross-type "come back to this" shortlist that can hold podcasts and radio too. Each
/// pin carries a display snapshot (title/subtitle/art) so the Later list renders instantly and
/// offline, plus a typed reference (`kind` + `refID`) used to play it.
struct PinnedItem: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case song, album, artist, playlist, podcastEpisode, podcastChannel, radioStation
        var id: String { rawValue }
        var label: String {
            switch self {
            case .song: "Song"
            case .album: "Album"
            case .artist: "Artist"
            case .playlist: "Playlist"
            case .podcastEpisode: "Episode"
            case .podcastChannel: "Podcast"
            case .radioStation: "Radio"
            }
        }
        var icon: String {
            switch self {
            case .song: "music.note"
            case .album: "square.stack"
            case .artist: "music.mic"
            case .playlist: "music.note.list"
            case .podcastEpisode: "mic"
            case .podcastChannel: "mic.fill"
            case .radioStation: "dot.radiowaves.left.and.right"
            }
        }
    }

    var kind: Kind
    /// The entity id used to resolve + play (song id, album id, episode enclosure URL, …).
    var refID: String
    var title: String
    var subtitle: String?
    /// Direct artwork URL (podcasts/radio), preferred over `coverArtID`.
    var artworkURL: URL?
    /// Subsonic cover-art id (songs/albums/artists/playlists).
    var coverArtID: String?
    var pinnedAt: Date

    /// Stable identity — one pin per (kind, entity), so re-pinning is idempotent.
    var id: String { "\(kind.rawValue):\(refID)" }

    /// A `NavidromeSong` reconstructed from the snapshot, for the directly-playable kinds
    /// (song / podcast episode). The controller resolves the stream from the id.
    var asSong: NavidromeSong {
        var song = NavidromeSong(
            id: refID, title: title, artist: subtitle, album: nil,
            duration: nil, coverArtID: coverArtID
        )
        song.artworkURL = artworkURL
        return song
    }
}

// MARK: - Factories

extension PinnedItem {
    static func song(_ s: NavidromeSong) -> PinnedItem {
        .init(kind: .song, refID: s.id, title: s.title, subtitle: s.artist,
              artworkURL: s.artworkURL, coverArtID: s.coverArtID, pinnedAt: Date())
    }
    static func album(_ a: NavidromeAlbum) -> PinnedItem {
        .init(kind: .album, refID: a.id, title: a.name, subtitle: a.artist,
              artworkURL: nil, coverArtID: a.coverArtID, pinnedAt: Date())
    }
    static func artist(_ a: NavidromeArtist) -> PinnedItem {
        .init(kind: .artist, refID: a.id, title: a.name, subtitle: nil,
              artworkURL: nil, coverArtID: a.coverArtID, pinnedAt: Date())
    }
    static func playlist(_ p: NavidromePlaylist) -> PinnedItem {
        .init(kind: .playlist, refID: p.id, title: p.name, subtitle: "\(p.songCount) tracks",
              artworkURL: nil, coverArtID: p.coverArtID, pinnedAt: Date())
    }
    static func episode(_ e: PodcastEpisode, channel: PodcastChannel) -> PinnedItem {
        .init(kind: .podcastEpisode, refID: e.enclosureURL.absoluteString, title: e.title,
              subtitle: channel.title, artworkURL: e.imageURL ?? channel.imageURL, coverArtID: nil, pinnedAt: Date())
    }
    static func channel(_ c: PodcastChannel) -> PinnedItem {
        .init(kind: .podcastChannel, refID: c.id, title: c.title, subtitle: c.episodes.first?.title,
              artworkURL: c.imageURL, coverArtID: nil, pinnedAt: Date())
    }
    static func station(_ s: NavidromeRadioStation) -> PinnedItem {
        .init(kind: .radioStation, refID: s.id, title: s.name, subtitle: s.streamURL?.host,
              artworkURL: nil, coverArtID: nil, pinnedAt: Date())
    }
}

// MARK: - Store

/// Owns the pinned ("Later") items — a single global, JSON-persisted list.
@MainActor
@Observable
final class PinStore {
    private(set) var pins: [PinnedItem] = []

    private let storeURL: URL
    private var loaded = false

    init(directory: URL? = nil) {
        let dir = directory ?? PinStore.defaultDirectory()
        storeURL = dir.appendingPathComponent("pins.json")
    }

    /// Pins newest-first (for the Later list).
    var ordered: [PinnedItem] { pins.sorted { $0.pinnedAt > $1.pinnedAt } }

    func isPinned(_ id: String) -> Bool { pins.contains { $0.id == id } }

    /// Pins the item, or removes it if already pinned — the toggle behind every bookmark.
    func toggle(_ item: PinnedItem) {
        if let index = pins.firstIndex(where: { $0.id == item.id }) {
            pins.remove(at: index)
        } else {
            pins.append(item)
        }
        persist()
    }

    func unpin(id: String) {
        pins.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        pins.removeAll()
        persist()
    }

    // MARK: Persistence

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder().decode([PinnedItem].self, from: data) {
            pins = saved
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(pins).write(to: storeURL, options: .atomic)
        } catch {
            pinLog.error("persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Baton", isDirectory: true)
    }
}

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
