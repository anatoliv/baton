import AVFoundation
import Foundation

/// Owns the **gapless prefetch machinery** — the in-flight download tasks, the ephemeral disk
/// cache, and the downloader — extracted from `StreamingPlaybackController` as a collaborator
///. Downloading the (transcoded) next stream to a local file lets the boundary hand off
/// from a file for a truly zero-gap transition even on streams AVFoundation won't pre-buffer.
///
/// The controller keeps the transport-core parts that this can't own: the preloaded item lives
/// *inside the main `AVQueuePlayer`'s* queue, and the swap-to-local + boundary reconciliation
/// mutate the transport's current index/state. So this owns only what's self-contained — the
/// tasks + cache + downloader — behind a narrow prefetch / reap / cancel interface. The
/// Wi-Fi-only gate and logging stay with the controller (they read user prefs + reachability).
@MainActor
final class GaplessPrefetcher {
    private var tasks: [String: Task<Void, Never>] = [:]
    private let cache: MusicGaplessCache
    private let downloader: @MainActor (URL, String) async -> URL?

    init(cache: MusicGaplessCache, downloader: @escaping @MainActor (URL, String) async -> URL?) {
        self.cache = cache
        self.downloader = downloader
    }

    /// An already-cached local file for a song, if a prefetch has landed — preferred over the
    /// live stream when preloading the next item.
    func cachedURL(for songID: String) -> URL? { cache.localURL(for: songID) }

    /// Whether a prefetch is already in flight for this song (so the caller doesn't start a second).
    func isPrefetching(_ songID: String) -> Bool { tasks[songID] != nil }

    var cacheSizeBytes: Int64 { cache.sizeBytes() }
    func clearCache() { cache.clear() }

    /// Download the queued next stream to the cache; on success, call `onReady` on the main actor
    /// so the caller can swap the streaming item for the local file. No-op if a prefetch for this
    /// song is already running. The caller applies the Wi-Fi-only policy before calling.
    func prefetch(
        songID: String,
        from streamURL: URL,
        index: Int,
        onReady: @escaping @MainActor (_ songID: String, _ index: Int, _ localURL: URL) -> Void
    ) {
        guard tasks[songID] == nil else { return }
        let downloader = self.downloader
        tasks[songID] = Task { @MainActor [weak self] in
            let local = await downloader(streamURL, songID)
            guard let self else { return }
            self.tasks[songID] = nil
            guard let local else { return }
            onReady(songID, index, local)
        }
    }

    /// Cancel in-flight prefetches for songs that are no longer the planned next (e.g. after
    /// rapid skipping), so stale full-file downloads don't pile up competing with the live stream.
    func reap(keeping plannedID: String?) {
        for (id, task) in tasks where id != plannedID {
            task.cancel()
            tasks[id] = nil
        }
    }

    /// Cancel every in-flight prefetch (queue cleared / stopped).
    func cancelAll() {
        for (_, task) in tasks { task.cancel() }
        tasks.removeAll()
    }
}
