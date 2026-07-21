import Foundation
import OSLog

private let queueLog = Logger(subsystem: "io.tonebox.baton", category: "ScrobbleQueue")

/// An immutable snapshot of a single play, captured the moment playback begins. It holds
/// exactly what every scrobble destination needs, decoupled from the live library, so it can
/// be persisted verbatim in the offline retry queue and delivered minutes (or days) later.
///
/// The `startedAt` timestamp is the canonical scrobble time: both Last.fm and ListenBrainz
/// want *when the track started*, not when the submission is sent — so we capture it at the
/// downbeat and carry it through the threshold, the queue, and any retries unchanged.
struct Scrobble: Codable, Equatable, Sendable {
    /// The Subsonic/Navidrome media id — used for the server `scrobble` call.
    let songID: String
    let artist: String
    let track: String
    let album: String?
    /// Track length in whole seconds, when known — improves Last.fm/ListenBrainz matching.
    let durationSeconds: Int?
    /// Unix seconds when playback of this track *began*.
    let startedAt: Int

    init(song: NavidromeSong, startedAt: Date) {
        songID = song.id
        let trimmedArtist = song.artist?.trimmingCharacters(in: .whitespaces)
        artist = (trimmedArtist?.isEmpty == false ? trimmedArtist : nil) ?? "Unknown Artist"
        track = song.title
        let trimmedAlbum = song.album?.trimmingCharacters(in: .whitespaces)
        album = trimmedAlbum?.isEmpty == false ? trimmedAlbum : nil
        durationSeconds = song.duration
        self.startedAt = Int(startedAt.timeIntervalSince1970)
    }
}

/// One completed listen waiting to be delivered to a single destination, with a retry counter.
/// Identified by a stable `id` so a flush can resolve exactly the items it delivered even as
/// new plays are appended concurrently.
struct QueuedScrobble: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let destination: String
    let scrobble: Scrobble
    var attempts: Int

    init(destination: String, scrobble: Scrobble, id: String = UUID().uuidString, attempts: Int = 0) {
        self.id = id
        self.destination = destination
        self.scrobble = scrobble
        self.attempts = attempts
    }
}

/// A durable, bounded FIFO of completed listens that failed (or haven't yet been) delivered.
/// Persisted in UserDefaults so scrobbles survive quits, network outages, and — for downloaded
/// tracks played fully offline — a Navidrome server that simply isn't reachable yet.
///
/// The queue is destination-agnostic: each entry names its destination, and a flush drains one
/// destination at a time in insertion order. Growth is capped (oldest dropped, logged) and each
/// entry is retired after `maxAttempts` so a permanently-rejected listen can't wedge the queue.
@MainActor
final class ScrobbleQueue {
    private(set) var pending: [QueuedScrobble] = []

    private let defaults: UserDefaults
    static let storageKey = "tonebox.music.scrobbleQueue"
    /// Bound the backlog so a long offline stretch can't grow UserDefaults without limit.
    static let maxEntries = 500
    /// Give up on an entry after this many failed deliveries (a permanent server rejection).
    static let maxAttempts = 20

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// Append a completed listen for a destination. Drops the oldest entries if over the cap.
    func enqueue(_ scrobble: Scrobble, destination: String) {
        pending.append(QueuedScrobble(destination: destination, scrobble: scrobble))
        if pending.count > Self.maxEntries {
            let overflow = pending.count - Self.maxEntries
            pending.removeFirst(overflow)
            queueLog.error("scrobble queue over \(Self.maxEntries, privacy: .public) — dropped \(overflow, privacy: .public) oldest")
        }
        save()
    }

    /// The oldest `limit` queued items for one destination, insertion order preserved.
    func take(destination: String, limit: Int) -> [QueuedScrobble] {
        var out: [QueuedScrobble] = []
        for item in pending where item.destination == destination {
            out.append(item)
            if out.count >= limit { break }
        }
        return out
    }

    /// Remove items that were delivered successfully.
    func resolve(_ delivered: [QueuedScrobble]) {
        guard !delivered.isEmpty else { return }
        let ids = Set(delivered.map(\.id))
        pending.removeAll { ids.contains($0.id) }
        save()
    }

    /// Record a failed delivery. For a *permanent* rejection (`countsAsAttempt: true`)
    /// bump each item's attempt count, retiring any that have exhausted `maxAttempts`.
    /// For a *transient* failure (offline, timeout, 5xx — `countsAsAttempt: false`) the
    /// items stay queued with their attempt count UNCHANGED, so a long offline session
    /// can't burn through maxAttempts and permanently drop the very scrobbles the durable
    /// queue exists to protect. (W-08)
    func fail(_ items: [QueuedScrobble], countsAsAttempt: Bool = true) {
        guard !items.isEmpty else { return }
        guard countsAsAttempt else { return } // transient — leave the queue untouched
        let ids = Set(items.map(\.id))
        var retired = 0
        pending = pending.compactMap { entry in
            guard ids.contains(entry.id) else { return entry }
            var bumped = entry
            bumped.attempts += 1
            if bumped.attempts >= Self.maxAttempts {
                retired += 1
                return nil
            }
            return bumped
        }
        if retired > 0 {
            queueLog.error("retired \(retired, privacy: .public) scrobble(s) after \(Self.maxAttempts, privacy: .public) failed attempts")
        }
        save()
    }

    /// Destinations that currently have at least one queued item.
    var pendingDestinations: Set<String> { Set(pending.map(\.destination)) }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        guard let decoded = try? JSONDecoder().decode([QueuedScrobble].self, from: data) else {
            // Corrupt blob: preserve it aside rather than starting empty and overwriting the
            // queued scrobbles on the next save. (W-12)
            defaults.set(data, forKey: Self.storageKey + ".corrupt")
            queueLog.error("scrobble queue was unreadable — preserved under \(Self.storageKey, privacy: .public).corrupt; starting empty")
            return
        }
        pending = decoded
    }

    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(pending), forKey: Self.storageKey)
        } catch {
            queueLog.error("scrobble queue save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
