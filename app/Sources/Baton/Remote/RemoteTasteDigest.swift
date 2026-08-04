import Foundation

/// A dozen lines describing what its owner actually listens to, handed to the
/// agent with every request.
///
/// This is the cheapest large step toward a companion that knows you, and it
/// stores nothing. Play counts, ratings, likes, what you added last week — the
/// server already holds all of it and keeps it current, so the right move is to
/// *read* it per session rather than persist a copy that drifts. Nothing here
/// is inferred: every line is a count or a name the server returned.
///
/// Without it, "what kind of music do I listen to?" is unanswerable without
/// spending three turns on tool calls, "surprise me" is a coin flip, and
/// "you've played this 34 times" cannot be said at all.
@MainActor
final class RemoteTasteDigest {
    /// Rebuilt at most daily. A library changes slowly and a stale count is
    /// worse than a slightly old one only if someone is watching the number.
    static let maximumAge: TimeInterval = 24 * 60 * 60

    private var cached: String?
    private var builtAt: Date?
    private var building = false

    /// Injectable so tests don't need a server.
    var loadSummary: () async throws -> Summary = RemoteTasteDigest.loadFromNavidrome

    /// The raw facts, before they become prose.
    struct Summary: Sendable {
        var genres: [(name: String, songs: Int)] = []
        var mostPlayed: [(title: String, artist: String, plays: Int)] = []
        var likedSongs: Int = 0
        var likedArtists: [String] = []
        var recentlyAdded: [String] = []
        var playlistCount: Int = 0
        var playlistNames: [String] = []
    }

    /// The digest, or nil when there's nothing worth saying (no server, empty
    /// library, a failed load). Never throws and never blocks a reply: a
    /// missing digest costs the model some grounding, a hung one costs the
    /// person their answer.
    func current(now: Date = Date()) async -> String? {
        if let cached, let builtAt, now.timeIntervalSince(builtAt) < Self.maximumAge {
            return cached
        }
        guard !building else { return cached }
        building = true
        defer { building = false }

        guard let summary = try? await loadSummary() else { return cached }
        let rendered = Self.render(summary)
        cached = rendered
        builtAt = now
        return rendered
    }

    /// Drop the cache — after a server switch, the old library's taste is worse
    /// than none.
    func invalidate() {
        cached = nil
        builtAt = nil
    }

    // MARK: Rendering

    static func render(_ summary: Summary) -> String? {
        var lines: [String] = []

        if !summary.genres.isEmpty {
            let genres = summary.genres.prefix(6)
                .map { "\($0.name) (\($0.songs))" }.joined(separator: ", ")
            lines.append("- Genres, by size: \(genres)")
        }
        if !summary.mostPlayed.isEmpty {
            let played = summary.mostPlayed.prefix(4)
                .map { "\($0.title) — \($0.artist) (\($0.plays) plays)" }
                .joined(separator: "; ")
            lines.append("- Played most: \(played)")
        }
        if summary.likedSongs > 0 {
            var liked = "- Liked: \(summary.likedSongs) songs"
            if !summary.likedArtists.isEmpty {
                liked += ", incl. " + summary.likedArtists.prefix(3).joined(separator: ", ")
            }
            lines.append(liked)
        }
        if !summary.recentlyAdded.isEmpty {
            lines.append("- Added recently: " + summary.recentlyAdded.prefix(4).joined(separator: ", "))
        }
        if summary.playlistCount > 0 {
            var playlists = "- Playlists: \(summary.playlistCount)"
            if !summary.playlistNames.isEmpty {
                playlists += ", incl. " + summary.playlistNames.prefix(3).joined(separator: ", ")
            }
            lines.append(playlists)
        }

        guard !lines.isEmpty else { return nil }
        return """
        What the owner listens to (from their server, current as of today):
        \(lines.joined(separator: "\n"))
        These are facts, not guesses — use them to ground what you play and say.
        """
    }

    // MARK: Loading

    /// Five cheap reads the client already knows how to make. Each one is
    /// optional: a server that doesn't answer one still yields a useful digest
    /// from the rest.
    static func loadFromNavidrome() async throws -> Summary {
        let client = try NavidromeConfig.makeClient()
        var summary = Summary()

        if let genres = try? await client.getGenres() {
            summary.genres = genres
                .filter { ($0.songCount ?? 0) > 0 }
                .sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
                .prefix(8)
                .map { ($0.name, $0.songCount ?? 0) }
        }
        if let starred = try? await client.getStarred2() {
            summary.likedSongs = starred.songs.count
            summary.likedArtists = starred.artists.prefix(4).map(\.name)
            // Liked songs carry play counts, which is the closest thing the
            // Subsonic API has to a most-played-tracks list.
            summary.mostPlayed = starred.songs
                .filter { ($0.playCount ?? 0) > 0 }
                .sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
                .prefix(6)
                .map { ($0.title, $0.artist ?? "Unknown", $0.playCount ?? 0) }
        }
        if summary.mostPlayed.isEmpty,
           let frequent = try? await client.getAlbumList2(type: "frequent", size: 6) {
            summary.mostPlayed = frequent.map {
                ($0.name, $0.artist ?? "Unknown", $0.playCount ?? 0)
            }
        }
        if let newest = try? await client.getAlbumList2(type: "newest", size: 6) {
            summary.recentlyAdded = newest.map { album in
                album.artist.map { "\(album.name) — \($0)" } ?? album.name
            }
        }
        if let playlists = try? await client.getPlaylists() {
            summary.playlistCount = playlists.count
            summary.playlistNames = playlists.prefix(4).map(\.name)
        }
        return summary
    }
}
