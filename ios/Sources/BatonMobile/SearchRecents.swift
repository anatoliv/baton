import Foundation
import BatonSubsonicModels

/// The albums and artists you opened from search, most recent first.
///
/// Search had no memory: every session started from a blank field, and the thing you
/// looked for yesterday cost the same typing today. What's stored is the *entity* you
/// opened — not the query string — because "Dido → 3 albums" is what you wanted, and the
/// string you typed to get there is trivia.
///
/// Songs are deliberately not recorded. Tapping a song in search *plays* it; recording it
/// would fill the list with one-off plays and crowd out the artists and albums that are
/// actually worth returning to.
@MainActor
@Observable
final class SearchRecents {
    struct Entry: Identifiable, Codable, Equatable {
        enum Kind: String, Codable { case album, artist }
        let kind: Kind
        let id: String
        let title: String
        var subtitle: String?
        var coverArtID: String?
    }

    private(set) var entries: [Entry] = []

    static let storageKey = "baton.search.recents"
    /// Enough to be useful, few enough to scan. Amperfy keeps a similar handful.
    static let cap = 10

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func record(album: NavidromeAlbum) {
        record(Entry(kind: .album, id: album.id, title: album.name,
                     subtitle: album.artist, coverArtID: album.coverArtID))
    }

    func record(artist: NavidromeArtist) {
        let subtitle = artist.albumCount.map { "\($0) album\($0 == 1 ? "" : "s")" }
        record(Entry(kind: .artist, id: artist.id, title: artist.name,
                     subtitle: subtitle, coverArtID: artist.coverArtID))
    }

    /// Re-opening something moves it to the top rather than duplicating it — the list is
    /// "what I come back to", and a duplicate says nothing a promotion doesn't.
    private func record(_ entry: Entry) {
        entries.removeAll { $0.kind == entry.kind && $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > Self.cap { entries = Array(entries.prefix(Self.cap)) }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Rebuilds the navigable entity. The detail screens fetch their own truth from the
    /// id; what's stored is only enough to draw the row and open the door.
    func album(for entry: Entry) -> NavidromeAlbum? {
        guard entry.kind == .album else { return nil }
        return NavidromeAlbum(id: entry.id, name: entry.title,
                              artist: entry.subtitle, coverArtID: entry.coverArtID)
    }

    func artist(for entry: Entry) -> NavidromeArtist? {
        guard entry.kind == .artist else { return nil }
        return NavidromeArtist(id: entry.id, name: entry.title, coverArtID: entry.coverArtID)
    }
}
