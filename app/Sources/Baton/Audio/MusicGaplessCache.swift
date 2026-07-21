import Foundation
import OSLog

private let gaplessCacheLog = Logger(subsystem: "io.tonebox.baton", category: "GaplessPrefetch")

/// A tiny, ephemeral on-disk cache for the **next** gapless track. When the upcoming track
/// is a network stream (not a permanent offline download), the player prefetches it here so
/// the track boundary becomes a *local-file* handoff — truly zero-gap, even for transcoded
/// streams that AVFoundation can't pre-buffer as a queued item.
///
/// Deliberately distinct from `MusicDownloadStore` (intentional, user-visible offline
/// downloads): this cache is invisible, self-evicting (LRU, capped), and safe to clear at
/// any time. Files are keyed by song id.
@MainActor
final class MusicGaplessCache {
    private let directory: URL
    private let maxEntries: Int
    /// Byte budget: 6 raw FLACs can be hundreds of MB, so cap on size too, not just count. (AUDIO-18)
    private let maxBytes: Int64

    init(maxEntries: Int = 6, maxBytes: Int64 = 200 * 1024 * 1024, directory: URL? = nil) {
        self.maxEntries = max(1, maxEntries)
        self.maxBytes = max(1, maxBytes)
        if let directory {
            self.directory = directory
        } else {
            let base = (try? FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("Tonebox/gapless-prefetch", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private func fileURL(for songID: String) -> URL {
        // Sanitize the id into a safe filename component (Subsonic ids are alphanumeric, but
        // be defensive). The extension is cosmetic — AVURLAsset sniffs the container.
        let safe = songID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        return directory.appendingPathComponent(String(safe) + ".audio")
    }

    /// The cached local file for `songID`, if one has already been prefetched.
    func localURL(for songID: String) -> URL? {
        let url = fileURL(for: songID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Move a freshly downloaded temp file into the cache under `songID`, returning its final
    /// URL. Evicts the oldest entries beyond `maxEntries`. Returns nil if the move failed.
    func store(tempFile: URL, songID: String) -> URL? {
        let dest = fileURL(for: songID)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: tempFile, to: dest)
        } catch {
            gaplessCacheLog.error("store \(songID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        evictOld(keeping: songID)
        return dest
    }

    /// Delete the oldest files (by modification date) until at most `maxEntries` AND at most
    /// `maxBytes` remain, never evicting `keeping` (the one just stored).
    func evictOld(keeping keepID: String? = nil) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return }
        let keepName = keepID.map { fileURL(for: $0).lastPathComponent }
        func size(_ u: URL) -> Int64 { Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let sorted = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db // oldest first
        }
        var count = files.count
        var total = files.reduce(Int64(0)) { $0 + size($1) }
        for url in sorted where url.lastPathComponent != keepName {
            guard count > maxEntries || total > maxBytes else { break }
            let s = size(url)
            try? FileManager.default.removeItem(at: url)
            count -= 1
            total -= s
        }
    }

    /// Total bytes currently held in the cache (for the Settings "clear cache" affordance).
    func sizeBytes() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Empties the whole prefetch cache.
    func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
