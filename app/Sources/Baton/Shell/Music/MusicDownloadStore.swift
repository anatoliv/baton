import Foundation
import Observation
import OSLog

private let downloadLog = Logger(subsystem: "io.tonebox.macos", category: "MusicDownloads")

/// Offline downloads for music. Fetches a track's stream to a user-chosen folder (an
/// Application Support cache by default) and serves it from disk on later plays — the
/// streaming path just prefers a local file via `localURL(for:)`.
///
/// Filenames follow a user template (`{artist} - {title}` by default) so downloads are
/// human-readable. Because the player looks tracks up by **id**, a small on-disk manifest
/// (`.tonebox-downloads.json`) maps each song id to its file. Legacy downloads named
/// `<id>.mp3` still resolve via a fallback, so switching to templated names is safe.
@MainActor
@Observable
final class MusicDownloadStore {
    static let shared = MusicDownloadStore()

    /// Song ids with a completed local download.
    private(set) var downloadedIDs: Set<String> = []
    /// Song ids currently downloading.
    private(set) var inFlight: Set<String> = []

    @ObservationIgnored static let folderKey = "tonebox.music.downloadFolder"
    @ObservationIgnored static let templateKey = "tonebox.music.downloadFilenameTemplate"
    /// Default filename template. Tokens: `{artist} {album} {title} {id}`.
    static let defaultTemplate = "{artist} - {title}"
    static let manifestName = ".tonebox-downloads.json"
    /// Sidecar manifest of lightweight track metadata, so the Downloads screen can show
    /// real titles/artists and re-play a track offline without touching the server.
    static let metaName = ".tonebox-downloads-meta.json"

    /// Where downloads are written + read. Observable so Settings reflects a change.
    private(set) var directory: URL
    /// songID → filename (relative to `directory`). Persisted alongside the files.
    @ObservationIgnored private var manifest: [String: String] = [:]
    /// songID → cached track metadata (title / artist / album / duration), written on
    /// download. Legacy downloads with no entry fall back to the parsed filename.
    @ObservationIgnored private var meta: [String: DownloadMeta] = [:]

    /// A downloaded track, resolved for display + playback by `downloadedItems()`.
    struct DownloadItem: Identifiable, Hashable {
        let id: String
        /// Absolute on-disk location of the audio file.
        let url: URL
        /// File size in bytes.
        let byteSize: Int64
        /// Best-effort display title (cached metadata, else parsed from the filename).
        let title: String
        let artist: String?
        let album: String?
        let duration: Int?
        /// Cover-art id (for the Downloads thumbnail). Nil for legacy downloads saved before
        /// the id was persisted, or externally-added files.
        let coverArtID: String?

        /// A `NavidromeSong` good enough to hand to the player — the controller resolves
        /// the local file for playback, so no server round-trip is needed. Falls back to the
        /// song id for cover art (Navidrome's getCoverArt accepts it) so the now-playing bar
        /// shows artwork even for downloads saved before the cover id was persisted.
        var song: NavidromeSong {
            NavidromeSong(
                id: id, title: title, artist: artist, album: album,
                duration: duration, coverArtID: coverArtID ?? id
            )
        }
    }

    /// Persisted metadata sidecar entry.
    private struct DownloadMeta: Codable {
        var title: String
        var artist: String?
        var album: String?
        var duration: Int?
        var coverArtID: String?
    }

    static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Tonebox/music-cache", isDirectory: true)
    }

    var isUsingCustomFolder: Bool {
        UserDefaults.standard.string(forKey: Self.folderKey) != nil
    }

    /// The filename template (persisted). Only affects **future** downloads.
    var filenameTemplate: String {
        get { UserDefaults.standard.string(forKey: Self.templateKey) ?? Self.defaultTemplate }
        set { UserDefaults.standard.set(newValue, forKey: Self.templateKey) }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.folderKey)
        directory = stored.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultDirectory()
        ensureDirectoryAndRescan()
    }

    /// Point downloads at `url` (persisted). Existing downloads elsewhere aren't moved;
    /// the "downloaded" set is re-scanned from the new folder + its manifest.
    func setDownloadFolder(_ url: URL) {
        directory = url
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
        ensureDirectoryAndRescan()
    }

    /// Revert to the default Application Support cache.
    func resetDownloadFolder() {
        UserDefaults.standard.removeObject(forKey: Self.folderKey)
        directory = Self.defaultDirectory()
        ensureDirectoryAndRescan()
    }

    // MARK: - Filename templating

    /// Render the template for a song into a safe, de-duplicated `<name>.mp3`.
    func filename(for song: NavidromeSong) -> String {
        Self.renderFilename(
            template: filenameTemplate,
            artist: song.artist, album: song.album, title: song.title, id: song.id,
            taken: manifest
        )
    }

    /// Pure filename renderer (unit-tested). Substitutes the tokens, sanitizes the
    /// result, and disambiguates with a short id suffix if a **different** song already
    /// owns the same name.
    nonisolated static func renderFilename(
        template: String,
        artist: String?, album: String?, title: String, id: String,
        taken: [String: String]
    ) -> String {
        let tokens: [(String, String)] = [
            ("{artist}", (artist ?? "").trimmingCharacters(in: .whitespaces)),
            ("{album}", (album ?? "").trimmingCharacters(in: .whitespaces)),
            ("{title}", title.trimmingCharacters(in: .whitespaces)),
            ("{id}", id),
        ]
        var base = template
        for (token, value) in tokens { base = base.replacingOccurrences(of: token, with: value) }
        base = sanitize(base)
        if base.isEmpty { base = id }

        var candidate = "\(base).mp3"
        let owner = taken.first { $0.value.caseInsensitiveCompare(candidate) == .orderedSame }?.key
        if let owner, owner != id {
            candidate = "\(base) [\(id.prefix(6))].mp3"
        }
        return candidate
    }

    /// Strip characters illegal in a filename, collapse runs of whitespace, drop leading
    /// dots (no hidden files), and bound the length.
    nonisolated static func sanitize(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars { scalars.append(illegal.contains(scalar) ? " " : scalar) }
        var s = String(scalars)
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        // Trim whitespace + dangling separator punctuation left when a token is empty
        // (e.g. "{artist} - {title}" with no artist → " - Title" → "Title"; both empty → "").
        // Also drops leading dots so downloads never become hidden files.
        let trimSet = CharacterSet(charactersIn: " -_.–—").union(.whitespaces)
        s = s.trimmingCharacters(in: trimSet)
        if s.count > 180 { s = String(s.prefix(180)).trimmingCharacters(in: trimSet) }
        return s
    }

    // MARK: - Lookup

    func localURL(for songID: String) -> URL? {
        if let name = manifest[songID] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let legacy = directory.appendingPathComponent("\(songID).mp3")
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : nil
    }

    func isDownloaded(_ songID: String) -> Bool { downloadedIDs.contains(songID) }
    func isDownloading(_ songID: String) -> Bool { inFlight.contains(songID) }

    // MARK: - Download

    /// Downloads one track's stream to disk (no-op if already present / in flight).
    func download(_ song: NavidromeSong) async {
        guard !isDownloaded(song.id), !inFlight.contains(song.id) else { return }
        inFlight.insert(song.id)
        defer { inFlight.remove(song.id) }
        do {
            let url = try NavidromeConfig.makeClient().streamURL(songID: song.id)
            let (temp, _) = try await URLSession.shared.download(from: url)
            let name = filename(for: song)
            let destination = directory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
            manifest[song.id] = name
            meta[song.id] = DownloadMeta(
                title: song.title, artist: song.artist, album: song.album,
                duration: song.duration, coverArtID: song.coverArtID
            )
            saveManifest()
            saveMeta()
            downloadedIDs.insert(song.id)
            // Precompute + persist the waveform now, so the full-screen scrubber shows it
            // instantly later (and it survives relaunches).
            let downloadedID = song.id
            Task { _ = await WaveformExtractor.bars(forSongID: downloadedID, url: destination) }
        } catch {
            downloadLog
                .error("download \(song.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Downloads a set of tracks sequentially (album / playlist).
    func download(_ songs: [NavidromeSong]) async {
        for song in songs {
            await download(song)
        }
    }

    /// Removes a downloaded track from disk (both templated and legacy names).
    func delete(_ songID: String) {
        if let name = manifest[songID] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            manifest[songID] = nil
            saveManifest()
        }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(songID).mp3"))
        if meta[songID] != nil { meta[songID] = nil; saveMeta() }
        downloadedIDs.remove(songID)
    }

    /// Alias for `delete(_:)` — deletes a download's file and drops it from the manifest.
    /// Kept as a distinct name for the Downloads manager's call-site clarity.
    func remove(id songID: String) { delete(songID) }

    // MARK: - Enumeration (Downloads manager)

    /// Every currently-downloaded track, resolved to its on-disk URL + byte size, with a
    /// display title/artist from the sidecar metadata (falling back to the filename for
    /// legacy downloads). Only entries whose file still exists are returned; sorted by
    /// artist then title for a stable listing.
    func downloadedItems() -> [DownloadItem] {
        downloadedIDs.compactMap { id -> DownloadItem? in
            guard let url = localURL(for: id) else { return nil }
            let size = Self.fileByteSize(at: url)
            if let m = meta[id] {
                return DownloadItem(
                    id: id, url: url, byteSize: size,
                    title: m.title, artist: m.artist, album: m.album, duration: m.duration,
                    coverArtID: m.coverArtID
                )
            }
            // Legacy / externally-added file: derive a readable title from the filename.
            let (artist, title) = Self.parseFilename(url.deletingPathExtension().lastPathComponent)
            return DownloadItem(
                id: id, url: url, byteSize: size,
                title: title, artist: artist, album: nil, duration: nil,
                coverArtID: nil
            )
        }
        .sorted {
            let a = ($0.artist ?? "").localizedCaseInsensitiveCompare($1.artist ?? "")
            return a == .orderedSame ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                : a == .orderedAscending
        }
    }

    /// Total bytes of all downloaded files on disk.
    func totalBytes() -> Int64 {
        downloadedIDs.reduce(0) { sum, id in
            sum + (localURL(for: id).map { Self.fileByteSize(at: $0) } ?? 0)
        }
    }

    /// Byte size of a single file (0 if unreadable).
    nonisolated static func fileByteSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// Split a `"{artist} - {title}"` filename back into its parts (best effort; the whole
    /// string is the title when there's no ` - ` separator).
    nonisolated static func parseFilename(_ base: String) -> (artist: String?, title: String) {
        if let range = base.range(of: " - ") {
            let artist = String(base[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let title = String(base[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty, !title.isEmpty { return (artist, title) }
        }
        return (nil, base)
    }

    // MARK: - Persistence

    private var manifestURL: URL { directory.appendingPathComponent(Self.manifestName) }
    private var metaURL: URL { directory.appendingPathComponent(Self.metaName) }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { manifest = [:]; return }
        manifest = decoded
    }

    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private func loadMeta() {
        guard let data = try? Data(contentsOf: metaURL),
              let decoded = try? JSONDecoder().decode([String: DownloadMeta].self, from: data)
        else { meta = [:]; return }
        meta = decoded
    }

    private func saveMeta() {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: metaURL, options: .atomic)
    }

    private func ensureDirectoryAndRescan() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        loadManifest()
        loadMeta()

        var ids = Set<String>()
        // Templated downloads tracked by the manifest (only those whose file still exists).
        for (id, name) in manifest
            where FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        {
            ids.insert(id)
        }
        // Legacy "<id>.mp3" files not referenced by the manifest.
        let manifestFiles = Set(manifest.values)
        if let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for file in files where file.hasSuffix(".mp3") && !manifestFiles.contains(file) {
                ids.insert((file as NSString).deletingPathExtension)
            }
        }
        downloadedIDs = ids
    }
}
