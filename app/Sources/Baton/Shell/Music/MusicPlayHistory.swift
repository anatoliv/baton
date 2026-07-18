import Foundation
import Observation

/// Local listening history for the music player — records each track as it starts and
/// exposes "Recently played" plus simple stats (top tracks / artists over a window).
/// Persisted in UserDefaults, capped so it never grows unbounded. Purely local; it
/// complements the server's play counts without depending on them.
@MainActor
@Observable
final class MusicPlayHistory {
    /// One play: the track (snapshot for display) + when it started.
    struct Entry: Codable, Identifiable, Hashable {
        let song: NavidromeSong
        let playedAt: Date
        var id: String { "\(song.id)-\(playedAt.timeIntervalSince1970)" }
    }

    private(set) var entries: [Entry] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored static let storageKey = "tonebox.music.playHistory"
    /// Keep the log bounded — plenty for "recently played" and a few weeks of stats.
    @ObservationIgnored static let maxEntries = 1000

    init(defaults: UserDefaults = .standard, clock: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.clock = clock
        load()
    }

    /// Record a track starting to play. Collapses an immediate repeat (replay / seek-to-0
    /// re-fires) so the same track back-to-back within a minute isn't logged twice.
    func record(_ song: NavidromeSong) {
        let now = clock()
        if let last = entries.first, last.song.id == song.id, now.timeIntervalSince(last.playedAt) < 60 {
            return
        }
        entries.insert(Entry(song: song, playedAt: now), at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        save()
    }

    func clear() {
        entries.removeAll()
        defaults.removeObject(forKey: Self.storageKey)
    }

    /// Distinct recently-played tracks, most-recent first (one row per track).
    var recentlyPlayed: [NavidromeSong] {
        var seen = Set<String>()
        return entries.compactMap { seen.insert($0.song.id).inserted ? $0.song : nil }
    }

    /// Most-played tracks since `since`, as (song, count), highest first.
    func topTracks(since: Date, limit: Int = 25) -> [(song: NavidromeSong, count: Int)] {
        rank(since: since, key: { $0.song.id }, represent: { $0.song }, limit: limit)
    }

    /// Most-played artists since `since`, as (name, count), highest first.
    func topArtists(since: Date, limit: Int = 25) -> [(artist: String, count: Int)] {
        let recent = entries.filter { $0.playedAt >= since }
        var counts: [String: Int] = [:]
        for e in recent {
            let name = (e.song.artist ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            counts[name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(limit).map { (artist: $0.key, count: $0.value) }
    }

    /// Total plays since `since` — the headline stat.
    func playCount(since: Date) -> Int { entries.reduce(0) { $0 + ($1.playedAt >= since ? 1 : 0) } }

    // MARK: - Ranking helper

    private func rank<Value>(
        since: Date, key: (Entry) -> String, represent: (Entry) -> Value, limit: Int
    ) -> [(song: Value, count: Int)] {
        let recent = entries.filter { $0.playedAt >= since }
        var counts: [String: Int] = [:]
        var rep: [String: Value] = [:]
        for e in recent {
            let k = key(e)
            counts[k, default: 0] += 1
            if rep[k] == nil { rep[k] = represent(e) }
        }
        return counts.sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { pair in rep[pair.key].map { (song: $0, count: pair.value) } }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
