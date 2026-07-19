import Foundation
import Observation
import OSLog

private let historyLog = Logger(subsystem: "io.tonebox.macos", category: "PlayHistory")

/// Baton's **private, on-device listening archive** — a free, local alternative to
/// Last.fm/ListenBrainz. It records each *completed* listen (fed by `ScrobbleService` once a
/// track passes the scrobble threshold, so it agrees with the external scrobblers), and exposes
/// Recently Played plus stats (top tracks / artists / albums, lifetime totals, a timestamped
/// log, and a listening trend). Nothing here ever leaves the machine; it can be exported to a
/// ListenBrainz-compatible file or cleared at will.
@MainActor
@Observable
final class MusicPlayHistory: LocalListenRecording {
    /// One completed listen: the track (snapshot for display) + when it was played.
    struct Entry: Codable, Identifiable, Hashable {
        let song: NavidromeSong
        let playedAt: Date
        var id: String { "\(song.id)-\(playedAt.timeIntervalSince1970)" }
    }

    private(set) var entries: [Entry] = []

    /// Whether local logging is on. Off ⇒ no new listens are recorded (existing history is kept
    /// until cleared). Default on — it's free and private, nothing to sign up for.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored static let storageKey = "tonebox.music.playHistory"
    @ObservationIgnored static let enabledKey = "tonebox.music.localLogEnabled"
    /// A lifetime archive, with a high safety ceiling so a runaway can't grow without bound.
    /// ~200k plays is many years of heavy listening; the oldest are dropped past it.
    @ObservationIgnored static let maxEntries = 200_000

    init(defaults: UserDefaults = .standard, clock: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.clock = clock
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        load()
    }

    // MARK: - Recording

    /// Record a completed listen at the current time. Kept for callers/tests that don't supply an
    /// explicit time; the live pipeline uses `record(_:playedAt:)` with the true start time.
    func record(_ song: NavidromeSong) {
        record(song, playedAt: clock())
    }

    /// Record a completed listen at `playedAt` (the track's start time — the canonical scrobble
    /// timestamp). Collapses an immediate repeat (replay / seek-to-0 re-fire) so the same track
    /// back-to-back within a minute isn't logged twice.
    func record(_ song: NavidromeSong, playedAt: Date) {
        guard isEnabled else { return }
        if let last = entries.first, last.song.id == song.id,
           abs(playedAt.timeIntervalSince(last.playedAt)) < 60 {
            return
        }
        insert(Entry(song: song, playedAt: playedAt))
        save()
    }

    /// Insert keeping `entries` sorted most-recent-first and bounded.
    private func insert(_ entry: Entry) {
        if let first = entries.first, entry.playedAt >= first.playedAt {
            entries.insert(entry, at: 0) // the common (live) case — newest
        } else {
            let idx = entries.firstIndex { entry.playedAt >= $0.playedAt } ?? entries.count
            entries.insert(entry, at: idx)
        }
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
    }

    func clear() {
        entries.removeAll()
        defaults.removeObject(forKey: Self.storageKey)
    }

    // MARK: - Recently played + stats

    /// Distinct recently-played tracks, most-recent first (one row per track).
    var recentlyPlayed: [NavidromeSong] {
        var seen = Set<String>()
        return entries.compactMap { seen.insert($0.song.id).inserted ? $0.song : nil }
    }

    /// Every listen ever recorded (the headline lifetime total).
    var lifetimeCount: Int { entries.count }

    /// When you first started listening (oldest entry), or nil if the archive is empty.
    var firstListenDate: Date? { entries.last?.playedAt }

    /// The most recent listens as timestamped rows (the scrollable log).
    func listenLog(limit: Int = 500) -> [Entry] { Array(entries.prefix(limit)) }

    /// Most-played tracks since `since`, as (song, count), highest first.
    func topTracks(since: Date, limit: Int = 25) -> [(song: NavidromeSong, count: Int)] {
        rank(since: since, key: { $0.song.id }, represent: { $0.song }, limit: limit)
            .map { (song: $0.value, count: $0.count) }
    }

    /// Most-played albums since `since`, as (album, count, artwork), highest first. `artwork` is a
    /// representative song so the row can show cover art.
    func topAlbums(since: Date, limit: Int = 25) -> [(album: String, count: Int, artwork: NavidromeSong)] {
        rank(since: since, key: {
            ($0.song.album ?? "").trimmingCharacters(in: .whitespaces)
        }, represent: { $0.song }, limit: limit, skipEmptyKey: true)
            .map { (album: $0.value.album ?? "", count: $0.count, artwork: $0.value) }
    }

    /// Most-played artists since `since`, as (name, count), highest first.
    func topArtists(since: Date, limit: Int = 25) -> [(artist: String, count: Int)] {
        rank(since: since, key: {
            ($0.song.artist ?? "").trimmingCharacters(in: .whitespaces)
        }, represent: { ($0.song.artist ?? "").trimmingCharacters(in: .whitespaces) },
        limit: limit, skipEmptyKey: true)
            .map { (artist: $0.value, count: $0.count) }
    }

    /// Total plays since `since` — the headline windowed stat.
    func playCount(since: Date) -> Int { entries.reduce(0) { $0 + ($1.playedAt >= since ? 1 : 0) } }

    /// Plays per calendar day since `since`, oldest-first — the listening trend. Days with no
    /// plays are included as zero so a chart doesn't collapse gaps.
    func dailyCounts(since: Date, calendar: Calendar = .current, maxDays: Int = 400) -> [(day: Date, count: Int)] {
        let today = calendar.startOfDay(for: clock())
        // Clamp the span so an unbounded `since` (e.g. .distantPast) can't spin over millions of days.
        let floor = calendar.date(byAdding: .day, value: -(maxDays - 1), to: today) ?? today
        let startDay = max(calendar.startOfDay(for: since), floor)
        guard startDay <= today else { return [] }
        var counts: [Date: Int] = [:]
        for entry in entries where entry.playedAt >= startDay {
            counts[calendar.startOfDay(for: entry.playedAt), default: 0] += 1
        }
        var out: [(day: Date, count: Int)] = []
        var day = startDay
        while day <= today {
            out.append((day: day, count: counts[day] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }

    // MARK: - Export / import

    /// The archive as portable (ListenBrainz-compatible) listens, most-recent first.
    var portableListens: [PortableListen] {
        entries.map { entry in
            PortableListen(
                listened_at: Int(entry.playedAt.timeIntervalSince1970),
                track_metadata: .init(
                    artist_name: entry.song.artist ?? "Unknown Artist",
                    track_name: entry.song.title,
                    release_name: entry.song.album
                )
            )
        }
    }

    /// Merge imported listens into the archive, skipping ones already present (same synthetic
    /// track id at the same second). Returns how many were newly added.
    @discardableResult
    func ingest(_ listens: [PortableListen]) -> Int {
        var seen = Set(entries.map { "\($0.song.id)@\(Int($0.playedAt.timeIntervalSince1970))" })
        var newEntries: [Entry] = []
        for listen in listens {
            let id = ListenArchiveIO.syntheticID(artist: listen.artist, track: listen.track)
            guard seen.insert("\(id)@\(listen.listened_at)").inserted else { continue } // skip dupes
            let song = NavidromeSong(id: id, title: listen.track, artist: listen.artist,
                                     album: listen.album, albumID: nil, duration: nil, coverArtID: nil)
            newEntries.append(Entry(song: song, playedAt: listen.date))
        }
        guard !newEntries.isEmpty else { return 0 }
        // Bulk merge: append then sort once (cheaper than inserting each in order for a big import).
        entries.append(contentsOf: newEntries)
        entries.sort { $0.playedAt > $1.playedAt }
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        save()
        historyLog.info("imported \(newEntries.count, privacy: .public) of \(listens.count, privacy: .public) listens")
        return newEntries.count
    }

    // MARK: - Ranking helper

    private func rank<Value>(
        since: Date, key: (Entry) -> String, represent: (Entry) -> Value, limit: Int,
        skipEmptyKey: Bool = false
    ) -> [(value: Value, count: Int)] {
        var counts: [String: Int] = [:]
        var rep: [String: Value] = [:]
        for entry in entries where entry.playedAt >= since {
            let k = key(entry)
            if skipEmptyKey, k.isEmpty { continue }
            counts[k, default: 0] += 1
            if rep[k] == nil { rep[k] = represent(entry) }
        }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(limit)
            .compactMap { pair in rep[pair.key].map { (value: $0, count: pair.value) } }
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
