import Foundation
import Observation
import OSLog

private let podcastProgressLog = Logger(subsystem: "io.tonebox.baton", category: "PodcastProgress")

/// Per-episode listening progress for client-side podcasts: how far you got, and whether an
/// episode is finished. This is what makes podcasts *resumable* — the one content type where
/// "pick up where I left off" is essential — and drives the played/unplayed UI plus the
/// "auto-remove finished download" hygiene. Keyed by the episode's enclosure URL, the same
/// string used as its playback song id, so the player can look progress up directly.
///
/// Global (progress isn't server-specific) and persisted as JSON in Application Support, next
/// to the subscriptions. See [[baton-podcasts]].
@MainActor
@Observable
final class PodcastProgressStore {
    /// One episode's progress. `position` is seconds into the audio; `played` means finished.
    struct Progress: Codable, Equatable {
        var position: Double
        var duration: Double?
        var played: Bool
    }

    /// episodeID (enclosure URL string) → progress.
    private(set) var progress: [String: Progress] = [:]

    /// An episode counts as finished within this many seconds of the end, or at this fraction —
    /// whichever comes first — so a show's outro/credits don't block "played".
    private static let finishTailSeconds = 30.0
    private static let finishFraction = 0.97
    /// Below this many seconds in, there's nothing worth resuming (treat as start).
    private static let resumeFloorSeconds = 5.0
    /// Don't offer to resume within this window of the end — just start fresh next time.
    private static let resumeTailSeconds = 15.0

    private let storeURL: URL
    private var loaded = false

    init(directory: URL? = nil) {
        let dir = directory ?? PodcastProgressStore.defaultDirectory()
        storeURL = dir.appendingPathComponent("podcast-progress.json")
    }

    // MARK: - Load / persist

    /// Versioned, corruption-safe backing for per-episode progress (W-12). Writing through
    /// it synchronously and in-order also fixes the prior fire-and-forget `Task.detached`
    /// writes, which could land an older snapshot over a newer one (POD-01). The file is a
    /// small dict; an atomic write every ~5 s on the main actor is negligible.
    private var store: VersionedStore<[String: Progress]> {
        VersionedStore(fileURL: storeURL, keepBackup: true)
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let saved = store.load() { progress = saved }
    }

    private func persist() {
        store.save(progress)
    }

    // MARK: - Queries

    func isPlayed(id: String) -> Bool { progress[id]?.played ?? false }

    /// The offset to resume playback from, or nil when the episode is unplayed-from-start,
    /// finished, or too close to either end to bother.
    func resumeOffset(id: String) -> Double? {
        guard let entry = progress[id], !entry.played, entry.position > Self.resumeFloorSeconds else { return nil }
        if let duration = entry.duration, entry.position > duration - Self.resumeTailSeconds { return nil }
        return entry.position
    }

    /// 0…1 fraction listened, for a progress bar. A played episode is 1; an untouched one nil.
    func fraction(id: String) -> Double? {
        guard let entry = progress[id] else { return nil }
        if entry.played { return 1 }
        guard let duration = entry.duration, duration > 0 else { return nil }
        return min(1, max(0, entry.position / duration))
    }

    /// Seconds remaining, when known and partway through (nil at start / when finished).
    func remaining(id: String) -> Double? {
        guard let entry = progress[id], !entry.played,
              entry.position > Self.resumeFloorSeconds,
              let duration = entry.duration, duration > 0 else { return nil }
        return max(0, duration - entry.position)
    }

    // MARK: - Mutations

    /// Records playback progress. Marks the episode played once it crosses the finish
    /// threshold (near the end), clearing the resume position so a replay starts fresh.
    /// Returns true if this call *transitioned* the episode to played (for one-shot hygiene).
    @discardableResult
    func record(id: String, position: Double, duration: Double?) -> Bool {
        let wasPlayed = progress[id]?.played ?? false
        let finished = Self.isFinished(position: position, duration: duration)
        progress[id] = Progress(
            position: finished ? 0 : max(0, position),
            duration: duration ?? progress[id]?.duration,
            played: finished
        )
        persist()
        return finished && !wasPlayed
    }

    func markPlayed(id: String) {
        let duration = progress[id]?.duration
        progress[id] = Progress(position: 0, duration: duration, played: true)
        persist()
    }

    func markUnplayed(id: String) {
        let duration = progress[id]?.duration
        progress[id] = Progress(position: 0, duration: duration, played: false)
        persist()
    }

    /// Forgets an episode's progress entirely — used when unsubscribing so a removed show
    /// leaves no orphaned rows.
    func remove(ids: [String]) {
        guard ids.contains(where: { progress[$0] != nil }) else { return }
        for id in ids { progress[id] = nil }
        persist()
    }

    /// Whether a position/duration pair counts as "finished".
    static func isFinished(position: Double, duration: Double?) -> Bool {
        guard let duration, duration > 1 else { return false }
        return position >= duration - finishTailSeconds || position / duration >= finishFraction
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Baton", isDirectory: true)
    }
}
