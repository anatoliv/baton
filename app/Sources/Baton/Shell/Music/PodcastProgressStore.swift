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
    /// `lastPlayed` (optional so older saved data decodes) orders the "Continue listening" shelf.
    struct Progress: Codable, Equatable {
        var position: Double
        var duration: Double?
        var played: Bool
        var lastPlayed: Date?
    }

    /// episodeID (enclosure URL string, or a server episode's `streamID`) → progress.
    private(set) var progress: [String: Progress] = [:]

    /// A **server-side** podcast episode, remembered so the rest of the app can recognise it.
    ///
    /// A client-side episode is self-identifying — its playback id is its enclosure URL, which
    /// `NavidromeSong.mediaKind` classifies from the id string alone. A server-side episode's id
    /// is an opaque Subsonic `streamID`, indistinguishable from a library track's. Without this
    /// registry, progress/resume would never fire for server podcasts (they'd be treated as music),
    /// and the Home "Continue listening" shelf couldn't render them. Persisted (not session-only)
    /// so resume and the shelf work on a cold launch, before the Podcasts tab is ever opened.
    struct ServerEpisode: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var channel: String
        var coverArtID: String?
        var duration: Double?
        /// When this episode was last offered by the server. Only orders eviction — deliberately
        /// excluded from `==` so a re-register with identical content isn't seen as a change and
        /// doesn't trigger a pointless rewrite of the file.
        var seenAt: Date?

        static func == (a: Self, b: Self) -> Bool {
            a.id == b.id && a.title == b.title && a.channel == b.channel
                && a.coverArtID == b.coverArtID && a.duration == b.duration
        }
    }

    /// Ceiling on remembered server episodes. A few subscriptions with deep back catalogues reach
    /// thousands, and nothing else ever removes them, so the file would grow for the life of the
    /// install. Episodes carrying listening progress are **never** evicted: dropping one would
    /// make it look like a library track again — losing resume, and scrobbling it as music.
    static let serverEpisodeLimit = 2_000

    /// streamID → server episode. Kept in its own file so the progress format stays untouched.
    private(set) var serverEpisodes: [String: ServerEpisode] = [:]

    /// An episode counts as finished within this many seconds of the end, or at this fraction —
    /// whichever comes first — so a show's outro/credits don't block "played".
    private static let finishTailSeconds = 30.0
    private static let finishFraction = 0.97
    /// Below this many seconds in, there's nothing worth resuming (treat as start).
    private static let resumeFloorSeconds = 5.0
    /// Don't offer to resume within this window of the end — just start fresh next time.
    private static let resumeTailSeconds = 15.0

    private let storeURL: URL
    private let serverEpisodesURL: URL
    private var loaded = false

    init(directory: URL? = nil) {
        let dir = directory ?? PodcastProgressStore.defaultDirectory()
        storeURL = dir.appendingPathComponent("podcast-progress.json")
        serverEpisodesURL = dir.appendingPathComponent("podcast-server-episodes.json")
    }

    // MARK: - Load / persist

    /// Versioned, corruption-safe backing for per-episode progress. Writing through
    /// it synchronously and in-order also fixes the prior fire-and-forget `Task.detached`
    /// writes, which could land an older snapshot over a newer one. The file is a
    /// small dict; an atomic write every ~5 s on the main actor is negligible.
    private var store: VersionedStore<[String: Progress]> {
        VersionedStore(fileURL: storeURL, keepBackup: true)
    }

    /// Separate backing for the server-episode registry: it's derived data (re-fetchable from the
    /// server), so it's kept out of the progress file rather than versioning that format again.
    private var serverEpisodeStore: VersionedStore<[String: ServerEpisode]> {
        VersionedStore(fileURL: serverEpisodesURL, keepBackup: false)
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let saved = store.load() { progress = saved }
        if let saved = serverEpisodeStore.load() { serverEpisodes = saved }
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

    /// Whether this playback id belongs to a known server-side podcast episode. The app treats
    /// these exactly like client-side episodes (resume, progress, no scrobbling) even though
    /// their ids look like library tracks.
    func isServerEpisode(_ id: String) -> Bool { serverEpisodes[id] != nil }

    /// In-progress **server** episodes, newest-listened first — the server half of the Home
    /// "Continue listening" shelf (the client half joins `inProgressIDs()` against subscriptions).
    func inProgressServerEpisodes() -> [ServerEpisode] {
        inProgressIDs().compactMap { serverEpisodes[$0] }
    }

    // MARK: - Mutations

    /// Remembers the server's episodes so playback can recognise them later. Called whenever the
    /// server Podcasts screen loads channels; a no-op write when nothing actually changed, so
    /// repeated tab visits don't re-persist.
    func registerServerEpisodes(_ episodes: [ServerEpisode]) {
        var changed = false
        let now = Date()
        for var episode in episodes {
            episode.seenAt = now
            if serverEpisodes[episode.id] != episode { changed = true }
            // Refresh the entry (and its seenAt) either way, so eviction order tracks what the
            // server is still offering rather than when the metadata last happened to change.
            serverEpisodes[episode.id] = episode
        }
        let evicted = pruneServerEpisodes()
        guard changed || evicted else { return }
        serverEpisodeStore.save(serverEpisodes)
    }

    /// Drops the least-recently-seen episodes that carry no progress, until back under the limit.
    /// Returns whether anything was removed. Entries with progress are exempt, so a heavy listener
    /// can exceed the limit — correctness beats the ceiling.
    @discardableResult
    private func pruneServerEpisodes() -> Bool {
        guard serverEpisodes.count > Self.serverEpisodeLimit else { return false }
        var overflow = serverEpisodes.count - Self.serverEpisodeLimit
        let evictable = serverEpisodes.values
            .filter { progress[$0.id] == nil }
            .sorted { ($0.seenAt ?? .distantPast) < ($1.seenAt ?? .distantPast) }
        for episode in evictable {
            guard overflow > 0 else { break }
            serverEpisodes[episode.id] = nil
            overflow -= 1
        }
        return true
    }

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
            played: finished,
            lastPlayed: Date()
        )
        persist()
        return finished && !wasPlayed
    }

    /// Episode ids currently mid-listen (started, not finished), newest-first — the source for the
    /// Home "Continue listening" shelf. Callers join these against their episode objects.
    func inProgressIDs() -> [String] {
        progress
            .filter { !$0.value.played && $0.value.position > Self.resumeFloorSeconds }
            .sorted { ($0.value.lastPlayed ?? .distantPast) > ($1.value.lastPlayed ?? .distantPast) }
            .map(\.key)
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
        if ids.contains(where: { serverEpisodes[$0] != nil }) {
            for id in ids { serverEpisodes[id] = nil }
            serverEpisodeStore.save(serverEpisodes)
        }
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
