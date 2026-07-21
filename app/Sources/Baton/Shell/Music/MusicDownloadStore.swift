import Foundation
import Observation
import OSLog

private let downloadLog = Logger(subsystem: "io.tonebox.baton", category: "MusicDownloads")

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
    /// Songs whose most recent download attempt failed, keyed by id — retained (not just the id) so
    /// the Downloads screen can offer a working Retry without re-resolving the track. Surfaced so a
    /// partly-failed batch is visible (not just logged) instead of the spinner vanishing with the
    /// user none the wiser. Cleared per id on a successful (re)download.
    private(set) var failedDownloads: [String: NavidromeSong] = [:]
    /// Ids of failed downloads (compat shim over `failedDownloads`).
    var failedIDs: Set<String> { Set(failedDownloads.keys) }
    /// Live download progress per in-flight song id (0…1), so the Downloads screen can show a real
    /// progress bar instead of an opaque spinner. Absent once a download finishes.
    private(set) var downloadProgress: [String: Double] = [:]
    /// albumID → count of that album's downloaded tracks. Observable, so an album row's
    /// download badge (full vs partial) updates as tracks are cached/removed. Albums have a
    /// natural per-song key (`albumID`) and a track total (`songCount`), so this alone gives
    /// accurate full/partial even for ad-hoc single-track downloads.
    private(set) var downloadedAlbumCounts: [String: Int] = [:]
    /// collection key (`artist:<id>` / `playlist:<id>`) → the member track ids captured when
    /// that collection was downloaded as a unit. Artists and playlists have no cheap per-song
    /// key or track total, so their badge is computed from this recorded membership intersected
    /// with `downloadedIDs` — accurate complete/partial, no name-matching. Observable.
    private(set) var downloadedCollections: [String: Set<String>] = [:]

    @ObservationIgnored static let folderKey = "tonebox.music.downloadFolder"
    @ObservationIgnored static let templateKey = "tonebox.music.downloadFilenameTemplate"
    /// Default filename template. Tokens: `{artist} {album} {title} {id}`.
    static let defaultTemplate = "{artist} - {title}"
    static let manifestName = ".tonebox-downloads.json"
    /// Sidecar manifest of lightweight track metadata, so the Downloads screen can show
    /// real titles/artists and re-play a track offline without touching the server.
    static let metaName = ".tonebox-downloads-meta.json"
    /// Sidecar recording each downloaded collection's member track ids (artist / playlist),
    /// so their download badge reports accurate complete/partial state.
    static let collectionsName = ".tonebox-downloads-collections.json"

    /// Where downloads are written + read. Observable so Settings reflects a change.
    private(set) var directory: URL
    /// songID → filename (relative to `directory`). Persisted alongside the files.
    @ObservationIgnored private var manifest: [String: String] = [:]
    /// songID → cached track metadata (title / artist / album / duration), written on
    /// download. Legacy downloads with no entry fall back to the parsed filename.
    @ObservationIgnored private var meta: [String: DownloadMeta] = [:]
    /// URLSession used for downloads. Injectable so tests can stub HTTP responses
    ///. Defaults to `.shared`.
    @ObservationIgnored var urlSession: URLSession = .shared
    /// Supplies each song id's last-played time for LRU storage-cap eviction. Wired by MusicModel
    /// from play history; nil ⇒ never-played ordering (cap still enforced by size).
    @ObservationIgnored var lastPlayedProvider: (() -> [String: Date])?

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
        /// Direct artwork URL — set for downloaded podcast episodes (which have no coverArtID).
        let artworkURL: URL?

        /// A `NavidromeSong` good enough to hand to the player — the controller resolves
        /// the local file for playback, so no server round-trip is needed. Falls back to the
        /// song id for cover art (Navidrome's getCoverArt accepts it) so the now-playing bar
        /// shows artwork even for downloads saved before the cover id was persisted. A podcast
        /// download carries its direct `artworkURL`, which every now-playing surface prefers.
        var song: NavidromeSong {
            var song = NavidromeSong(
                id: id, title: title, artist: artist, album: album,
                duration: duration, coverArtID: coverArtID ?? (artworkURL == nil ? id : nil)
            )
            song.artworkURL = artworkURL
            return song
        }
    }

    /// Persisted metadata sidecar entry.
    private struct DownloadMeta: Codable {
        var title: String
        var artist: String?
        var album: String?
        var albumID: String?
        var duration: Int?
        var coverArtID: String?
        var artworkURL: URL?
    }

    // MARK: - Collection download state

    /// How many of an album's tracks are downloaded (for the full/partial badge).
    func downloadedCount(albumID: String) -> Int { downloadedAlbumCounts[albumID] ?? 0 }

    static func collectionKey(kind: String, id: String) -> String { "\(kind):\(id)" }

    /// Records a downloaded collection's full member set — called when an artist/playlist is
    /// downloaded as a unit — so its badge reports accurate complete/partial state.
    func registerCollection(kind: String, id: String, trackIDs: [String]) {
        guard !id.isEmpty, !trackIDs.isEmpty else { return }
        downloadedCollections[Self.collectionKey(kind: kind, id: id)] = Set(trackIDs)
        saveCollections()
    }

    /// `(downloaded, total)` member counts for a recorded collection, or nil if it was never
    /// downloaded as a unit (so its badge stays hidden).
    func collectionMemberCount(kind: String, id: String) -> (downloaded: Int, total: Int)? {
        guard let members = downloadedCollections[Self.collectionKey(kind: kind, id: id)], !members.isEmpty else { return nil }
        let downloaded = members.reduce(0) { $0 + (downloadedIDs.contains($1) ? 1 : 0) }
        return (downloaded, members.count)
    }

    /// Adds `delta` (±1) to the per-album downloaded-track count for one track's metadata,
    /// dropping keys that reach zero so `downloadedCount(albumID:)` stays honest.
    private func adjustAggregates(_ meta: DownloadMeta?, delta: Int) {
        guard let meta, let albumID = meta.albumID, !albumID.isEmpty else { return }
        let next = (downloadedAlbumCounts[albumID] ?? 0) + delta
        if next > 0 { downloadedAlbumCounts[albumID] = next } else { downloadedAlbumCounts[albumID] = nil }
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

    /// Render the template for a song into a safe, de-duplicated `<name>.<ext>`.
    func filename(for song: NavidromeSong, ext: String = "mp3") -> String {
        Self.renderFilename(
            template: filenameTemplate,
            artist: song.artist, album: song.album, title: song.title, id: song.id,
            taken: manifest, ext: ext
        )
    }

    /// Map a response Content-Type to a file extension so a downloaded original is named
    /// honestly (a FLAC as .flac, an AAC podcast as .m4a — not a lying .mp3).
    static func fileExtension(forContentType type: String?) -> String {
        switch (type ?? "").lowercased() {
        case let t where t.contains("flac"): return "flac"
        case let t where t.contains("mp4") || t.contains("m4a") || t.contains("aac"): return "m4a"
        case let t where t.contains("ogg") || t.contains("opus"): return "ogg"
        case let t where t.contains("wav"): return "wav"
        default: return "mp3"
        }
    }

    /// Pure filename renderer (unit-tested). Substitutes the tokens, sanitizes the
    /// result, and disambiguates with a short id suffix if a **different** song already
    /// owns the same name.
    nonisolated static func renderFilename(
        template: String,
        artist: String?, album: String?, title: String, id: String,
        taken: [String: String], ext: String = "mp3"
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

        var candidate = "\(base).\(ext)"
        let owner = taken.first { $0.value.caseInsensitiveCompare(candidate) == .orderedSame }?.key
        if let owner, owner != id {
            candidate = "\(base) [\(id.prefix(6))].\(ext)"
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

    /// Directory holding persisted resume data for interrupted downloads, so a blip at 95 % of a
    /// long episode resumes from the partial rather than restarting.
    private var resumeDirectory: URL { directory.appendingPathComponent(".resume", isDirectory: true) }

    /// Resume-data file for a song id (id sanitized to a filesystem-safe name).
    private func resumeFileURL(for songID: String) -> URL {
        let safe = songID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        return resumeDirectory.appendingPathComponent(String(safe) + ".resume")
    }

    private func persistedResumeData(for songID: String) -> Data? {
        try? Data(contentsOf: resumeFileURL(for: songID))
    }

    private func saveResumeData(_ data: Data, for songID: String) {
        try? FileManager.default.createDirectory(at: resumeDirectory, withIntermediateDirectories: true)
        try? data.write(to: resumeFileURL(for: songID))
    }

    private func clearResumeData(for songID: String) {
        try? FileManager.default.removeItem(at: resumeFileURL(for: songID))
    }

    /// Downloads one track's stream to disk (no-op if already present / in flight). Reports live
    /// progress via `downloadProgress` and resumes from persisted partial data when present.
    @discardableResult
    func download(_ song: NavidromeSong) async -> Bool {
        guard !isDownloaded(song.id), !inFlight.contains(song.id) else { return isDownloaded(song.id) }
        inFlight.insert(song.id)
        downloadProgress[song.id] = 0
        defer {
            inFlight.remove(song.id)
            downloadProgress[song.id] = nil
        }
        do {
            // resolveStreamURL handles both library tracks (Subsonic stream id) and client-side
            // podcast episodes (id is the enclosure URL, streamed directly) — so this one path
            // downloads both. Playback then prefers the local file via `localURL(for:)`.
            // Download the ORIGINAL file (download.view for library tracks), not a transcoded
            // stream, so a FLAC library isn't stored as lossy MP3.
            let url = try StreamingPlaybackController.resolveDownloadURL(songID: song.id)
            // Report byte-level progress to the UI.
            let observer = DownloadProgressObserver(songID: song.id) { [weak self] id, fraction in
                Task { @MainActor in if self?.downloadProgress[id] != nil { self?.downloadProgress[id] = fraction } }
            }
            let temp: URL
            let response: URLResponse
            // Resume from persisted partial data if a prior attempt was interrupted.
            if let resume = persistedResumeData(for: song.id) {
                (temp, response) = try await urlSession.download(resumeFrom: resume, delegate: observer)
            } else {
                (temp, response) = try await urlSession.download(from: url, delegate: observer)
            }
            clearResumeData(for: song.id) // completed → the partial is no longer needed
            // : URLSession.download does NOT throw on 4xx/5xx. Without this check a
            // 404, a 500, or a reverse-proxy HTML login page would be saved as a
            // completed `.mp3`, marked downloaded, and then preferred over streaming
            // forever (re-download blocked by the isDownloaded guard).
            do {
                try Self.validateDownloadResponse(response, fileURL: temp)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw error
            }
            let ext = Self.fileExtension(forContentType: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"))
            let name = filename(for: song, ext: ext)
            let destination = directory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
            manifest[song.id] = name
            let entry = DownloadMeta(
                title: song.title, artist: song.artist, album: song.album, albumID: song.albumID,
                duration: song.duration, coverArtID: song.coverArtID, artworkURL: song.artworkURL
            )
            meta[song.id] = entry
            saveManifest()
            saveMeta()
            downloadedIDs.insert(song.id)
            adjustAggregates(entry, delta: 1)
            // Precompute + persist the waveform now, so the full-screen scrubber shows it
            // instantly later (and it survives relaunches).
            let downloadedID = song.id
            Task { _ = await WaveformExtractor.bars(forSongID: downloadedID, url: destination) }
            failedDownloads[song.id] = nil // a retry that succeeds clears the prior failure
            // Keep the download folder under any configured size cap, evicting least-recently-played
            // first. Mark the just-downloaded track as most-recent so a freshly-fetched-but-unplayed
            // file isn't the first thing evicted.
            var lastPlayed = lastPlayedProvider?() ?? [:]
            lastPlayed[song.id] = Date()
            enforceStorageCap(lastPlayed: lastPlayed)
            return true
        } catch {
            downloadLog
                .error("download \(song.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            // Persist any partial so a retry resumes instead of restarting from zero.
            if let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                saveResumeData(resume, for: song.id)
            }
            failedDownloads[song.id] = song
            return false
        }
    }

    /// Downloads a set of tracks sequentially (album / playlist). Cooperatively cancellable: a
    /// cancelled enclosing `Task` (e.g. the Downloads screen's Cancel) stops the batch between
    /// items rather than plowing through the whole album. Returns the count actually downloaded.
    ///
    @discardableResult
    func download(_ songs: [NavidromeSong]) async -> Int {
        var completed = 0
        for song in songs {
            if Task.isCancelled { break }
            if await download(song) { completed += 1 }
        }
        return completed
    }

    /// Re-attempt every track whose last download failed (the Downloads screen's "Retry failed").
    /// Self-sufficient — it re-downloads the retained failed songs (resuming from partials where
    /// available), so the caller needs no track lookup.
    func retryFailed() async {
        for song in failedDownloads.values.sorted(by: { $0.id < $1.id }) {
            if Task.isCancelled { break }
            await download(song)
        }
    }

    /// A download that must not be adopted as a valid file.
    enum DownloadError: Error, LocalizedError {
        case badStatus(Int)
        case notAudio(String)
        case tooSmall(Int)
        var errorDescription: String? {
            switch self {
            case .badStatus(let c): return "server returned HTTP \(c)"
            case .notAudio(let t): return "response was \(t), not audio"
            case .tooSmall(let n): return "response too small (\(n) bytes)"
            }
        }
    }

    /// Reject an HTTP error page, a login/redirect stub, or an empty body being saved
    /// as audio: require a 2xx status, a non-text Content-Type, and a plausible size.
    /// Pure/static so it's unit-testable without a session.
    static func validateDownloadResponse(_ response: URLResponse, fileURL: URL) throws {
        if let http = response as? HTTPURLResponse {
            guard (200 ..< 300).contains(http.statusCode) else {
                throw DownloadError.badStatus(http.statusCode)
            }
            if let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
               type.contains("text/html") || type.contains("application/json") || type.contains("text/plain") {
                throw DownloadError.notAudio(type)
            }
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size >= 1024 else { throw DownloadError.tooSmall(size) }
    }

    /// Removes a downloaded track from disk (both templated and legacy names).
    func delete(_ songID: String) {
        if let name = manifest[songID] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            manifest[songID] = nil
            saveManifest()
        }
        // Legacy "<id>.mp3": only unlink it if we have provenance (a metadata entry we
        // wrote). Never delete a bare file we can't attribute to Baton.
        if meta[songID] != nil {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(songID).mp3"))
        }
        if let entry = meta[songID] { adjustAggregates(entry, delta: -1); meta[songID] = nil; saveMeta() }
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
                    coverArtID: m.coverArtID, artworkURL: m.artworkURL
                )
            }
            // Legacy / externally-added file: derive a readable title from the filename.
            let (artist, title) = Self.parseFilename(url.deletingPathExtension().lastPathComponent)
            return DownloadItem(
                id: id, url: url, byteSize: size,
                title: title, artist: artist, album: nil, duration: nil,
                coverArtID: nil, artworkURL: nil
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

    /// Optional download size cap in bytes (0 = unlimited). When set, the store evicts the
    /// least-recently-played downloads until the total fits.
    static let storageCapKey = "baton.downloads.storageCapBytes"
    var storageCapBytes: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: Self.storageCapKey)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: Self.storageCapKey) }
    }

    /// Pure LRU planner: which ids to evict so `items` fits under `capBytes`, dropping the
    /// least-recently-played first (a never-played download counts as oldest). Returns [] when
    /// the cap is unlimited (≤0) or the total already fits. Unit-tested in isolation.
    static func evictionPlan(items: [(id: String, bytes: Int64)], lastPlayed: [String: Date], capBytes: Int64) -> [String] {
        let total = items.reduce(Int64(0)) { $0 + $1.bytes }
        guard capBytes > 0, total > capBytes else { return [] }
        let ordered = items.sorted { (lastPlayed[$0.id] ?? .distantPast) < (lastPlayed[$1.id] ?? .distantPast) }
        var evict: [String] = []
        var running = total
        for item in ordered where running > capBytes {
            evict.append(item.id)
            running -= item.bytes
        }
        return evict
    }

    /// Enforce `storageCapBytes` by deleting the least-recently-played downloads. `lastPlayed`
    /// maps a download id to its last listen time (supplied by the caller from play history, so
    /// this stays decoupled). No-op when the cap is unlimited or everything fits.
    @discardableResult
    func enforceStorageCap(lastPlayed: [String: Date]) -> [String] {
        let items = downloadedItems().map { (id: $0.id, bytes: $0.byteSize) }
        let evict = Self.evictionPlan(items: items, lastPlayed: lastPlayed, capBytes: storageCapBytes)
        for id in evict { delete(id) }
        return evict
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
    private var collectionsURL: URL { directory.appendingPathComponent(Self.collectionsName) }

    // Versioned, corruption-safe sidecars: a corrupt file is preserved aside, not
    // silently wiped over on the next save; a write failure is logged, never swallowed.
    private var collectionsStore: VersionedStore<[String: Set<String>]> { VersionedStore(fileURL: collectionsURL) }
    private var manifestStore: VersionedStore<[String: String]> { VersionedStore(fileURL: manifestURL) }
    private var metaStore: VersionedStore<[String: DownloadMeta]> { VersionedStore(fileURL: metaURL) }

    private func loadCollections() { downloadedCollections = collectionsStore.load() ?? [:] }
    private func saveCollections() { collectionsStore.save(downloadedCollections) }
    private func loadManifest() { manifest = manifestStore.load() ?? [:] }
    private func saveManifest() { manifestStore.save(manifest) }
    private func loadMeta() { meta = metaStore.load() ?? [:] }
    private func saveMeta() { metaStore.save(meta) }

    private func ensureDirectoryAndRescan() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        loadManifest()
        loadMeta()
        loadCollections()

        var ids = Set<String>()
        // Templated downloads tracked by the manifest (only those whose file still exists).
        for (id, name) in manifest
            where FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        {
            ids.insert(id)
        }
        // Legacy "<id>.mp3" files not referenced by the manifest. Only adopt files we
        // can attribute to Baton — a metadata sidecar entry, or a basename shaped like a
        // Subsonic id — so pointing the download folder at an existing music library
        // never adopts (and later lets the user delete via Remove) their own files.
        let manifestFiles = Set(manifest.values)
        if let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for file in files where file.hasSuffix(".mp3") && !manifestFiles.contains(file) {
                let id = (file as NSString).deletingPathExtension
                if meta[id] != nil || Self.isPlausibleSubsonicID(id) {
                    ids.insert(id)
                }
            }
        }
        downloadedIDs = ids
        rebuildAggregates()
    }

    /// A bare "<id>.mp3" is adopted as a legacy download only if its basename looks like
    /// a Subsonic/Navidrome id (id-like charset, no spaces, reasonably long) — this
    /// rejects a user's own music files such as "01 - Song.mp3".
    static func isPlausibleSubsonicID(_ s: String) -> Bool {
        guard s.count >= 16, s.count <= 64 else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Recomputes the per-album downloaded-track counts from scratch (called after a rescan).
    private func rebuildAggregates() {
        var albums: [String: Int] = [:]
        for id in downloadedIDs {
            guard let entry = meta[id], let albumID = entry.albumID, !albumID.isEmpty else { continue }
            albums[albumID, default: 0] += 1
        }
        downloadedAlbumCounts = albums
    }
}

/// Observes a single download task's byte-progress and forwards the completed fraction (0…1) to a
/// callback keyed by song id, so the store can publish a live progress bar instead of an opaque
/// spinner. Passed as the per-task delegate to `URLSession.download(from:delegate:)`.
private final class DownloadProgressObserver: NSObject, URLSessionTaskDelegate {
    private let songID: String
    private let onProgress: @Sendable (String, Double) -> Void
    private var observation: NSKeyValueObservation?

    init(songID: String, onProgress: @escaping @Sendable (String, Double) -> Void) {
        self.songID = songID
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [songID, onProgress] progress, _ in
            onProgress(songID, progress.fractionCompleted)
        }
    }
}
