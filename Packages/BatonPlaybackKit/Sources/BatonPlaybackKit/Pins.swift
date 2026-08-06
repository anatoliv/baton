import Foundation
import Observation
import OSLog
import BatonSubsonicKit
import BatonSubsonicModels

private let pinLog = Logger(subsystem: "io.tonebox.baton", category: "Pins")

// MARK: - Model

/// A saved-for-later reference to any media type in the player. Distinct from **Liked** (a
/// server-side taste star, songs/albums/artists only) and the transient **Queue**: a pin is a
/// local, cross-type "come back to this" shortlist that can hold podcasts and radio too. Each
/// pin carries a display snapshot (title/subtitle/art) so the Later list renders instantly and
/// offline, plus a typed reference (`kind` + `refID`) used to play it.
public struct PinnedItem: Identifiable, Codable, Hashable {
    public enum Kind: String, Codable, CaseIterable, Identifiable {
        case song, album, artist, playlist, podcastEpisode, podcastChannel, radioStation
        public var id: String { rawValue }
        public var label: String {
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
        public var icon: String {
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

    public var kind: Kind
    /// The entity id used to resolve + play (song id, album id, episode enclosure URL, …).
    public var refID: String
    public var title: String
    public var subtitle: String?
    /// Direct artwork URL (podcasts/radio), preferred over `coverArtID`.
    public var artworkURL: URL?
    /// Subsonic cover-art id (songs/albums/artists/playlists).
    public var coverArtID: String?
    public var pinnedAt: Date

    /// Stable identity — one pin per (kind, entity), so re-pinning is idempotent.
    public var id: String { "\(kind.rawValue):\(refID)" }

    /// A `NavidromeSong` reconstructed from the snapshot, for the directly-playable kinds
    /// (song / podcast episode). The controller resolves the stream from the id.
    public var asSong: NavidromeSong {
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
    public static func song(_ s: NavidromeSong) -> PinnedItem {
        .init(kind: .song, refID: s.id, title: s.title, subtitle: s.artist,
              artworkURL: s.artworkURL, coverArtID: s.coverArtID, pinnedAt: Date())
    }
    public static func album(_ a: NavidromeAlbum) -> PinnedItem {
        .init(kind: .album, refID: a.id, title: a.name, subtitle: a.artist,
              artworkURL: nil, coverArtID: a.coverArtID, pinnedAt: Date())
    }
    public static func artist(_ a: NavidromeArtist) -> PinnedItem {
        .init(kind: .artist, refID: a.id, title: a.name, subtitle: nil,
              artworkURL: nil, coverArtID: a.coverArtID, pinnedAt: Date())
    }
    public static func playlist(_ p: NavidromePlaylist) -> PinnedItem {
        .init(kind: .playlist, refID: p.id, title: p.name, subtitle: "\(p.songCount) tracks",
              artworkURL: nil, coverArtID: p.coverArtID, pinnedAt: Date())
    }
    public static func episode(_ e: PodcastEpisode, channel: PodcastChannel) -> PinnedItem {
        .init(kind: .podcastEpisode, refID: e.enclosureURL.absoluteString, title: e.title,
              subtitle: channel.title, artworkURL: e.imageURL ?? channel.imageURL, coverArtID: nil, pinnedAt: Date())
    }
    public static func channel(_ c: PodcastChannel) -> PinnedItem {
        .init(kind: .podcastChannel, refID: c.id, title: c.title, subtitle: c.episodes.first?.title,
              artworkURL: c.imageURL, coverArtID: nil, pinnedAt: Date())
    }
    public static func station(_ s: NavidromeRadioStation) -> PinnedItem {
        .init(kind: .radioStation, refID: s.id, title: s.name, subtitle: s.streamURL?.host,
              artworkURL: nil, coverArtID: nil, pinnedAt: Date())
    }
}

// MARK: - Store

/// Owns the pinned ("Later") items — a single global, JSON-persisted list.
@MainActor
@Observable
public final class PinStore {
    public private(set) var pins: [PinnedItem] = []

    private let storeURL: URL
    private var loaded = false

    public init(directory: URL? = nil) {
        let dir = directory ?? PinStore.defaultDirectory()
        storeURL = dir.appendingPathComponent("pins.json")
    }

    /// Pins newest-first (for the Later list).
    public var ordered: [PinnedItem] { pins.sorted { $0.pinnedAt > $1.pinnedAt } }

    public func isPinned(_ id: String) -> Bool { pins.contains { $0.id == id } }

    /// Pins the item, or removes it if already pinned — the toggle behind every bookmark.
    public func toggle(_ item: PinnedItem) {
        if let index = pins.firstIndex(where: { $0.id == item.id }) {
            pins.remove(at: index)
        } else {
            pins.append(item)
        }
        persist()
    }

    public func unpin(id: String) {
        pins.removeAll { $0.id == id }
        persist()
    }

    public func clear() {
        pins.removeAll()
        persist()
    }

    // MARK: Persistence

    public func loadIfNeeded() {
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
