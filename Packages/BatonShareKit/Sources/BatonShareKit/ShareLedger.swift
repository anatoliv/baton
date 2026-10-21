import Foundation

/// What one install remembers about the shares it sent (spec §1, plan §5).
///
/// The server never holds a share's key, so only this device can show its link again. The
/// ledger is that memory: one record per share with the key, plus the last stats the server
/// reported, and the failures waiting to be reported with the next create (`recentFailures`).
/// It is a plain value saved as one JSON file, so the Mac, the iPhone and the tests all use the
/// same code, and a corrupt file costs the list rather than a crash.
public struct ShareLedger: Codable, Equatable, Sendable {
    public struct Record: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        /// The link with its key: `https://batonmusic.app/s/<id>#<key>`.
        public var link: String
        public var songID: String
        public var title: String
        public var artist: String
        public var isPrivate: Bool
        public var createdAt: Date
        public var expiresAt: Date
        /// The server's last word on this share, from `GET /v1/share/shares`. `nil` until the
        /// list is first refreshed after sending.
        public var summary: ShareSummary?
        public var kind: ShareInvitation.Kind?
        public var songIDs: [String]?
        public var mixtapeSummary: MixtapeSummary?
        /// A whole-book link's last summary from `GET /v1/share/books` (kind `.book`).
        public var bookSummary: BookSummary?
        public var containerKind: ShareInvitation.Kind { kind ?? .song }
        public var identity: String { "\(containerKind.rawValue):\(id)" }

        public init(id: String, link: String, songID: String, title: String, artist: String,
                    isPrivate: Bool, createdAt: Date, expiresAt: Date, summary: ShareSummary? = nil, kind: ShareInvitation.Kind? = nil, songIDs: [String]? = nil, mixtapeSummary: MixtapeSummary? = nil,
                    bookSummary: BookSummary? = nil) {
            self.id = id
            self.link = link
            self.songID = songID
            self.title = title
            self.artist = artist
            self.isPrivate = isPrivate
            self.createdAt = createdAt
            self.expiresAt = expiresAt
            self.summary = summary
            self.kind = kind
            self.songIDs = songIDs
            self.mixtapeSummary = mixtapeSummary
            self.bookSummary = bookSummary
        }

        public var status: ShareStatus { summary?.status ?? (expiresAt <= Date() ? .expired : .ready) }

        /// An owned held copy remains revocable even after its old public calendar expiry.
        public var isHeldForReview: Bool {
            summary?.actionRequired != nil && (status == .ready || status == .pending)
        }

        /// Whether the link can still be played, so "Copy link again" and "Extend" make sense.
        public func isLive(now: Date = Date()) -> Bool {
            let status = summary?.status ?? .ready
            return !isHeldForReview && (status == .ready || status == .pending) && expiresAt > now
        }
    }

    public private(set) var records: [Record] = []
    public private(set) var pendingFailures: [ShareFailureReport] = []

    public init() {}

    // Whole-book records never go into the ledger file itself. A released app decodes that file
    // with a `Kind` that knows only songs and mixtapes, and one record it cannot read costs the
    // whole list; so book records live in their own file beside it (`booksURL`), which only apps
    // that know books read, and the two are joined in memory.
    enum CodingKeys: String, CodingKey { case records, pendingFailures }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = try container.decode([Record].self, forKey: .records)
        pendingFailures = try container.decode([ShareFailureReport].self, forKey: .pendingFailures)
    }

    /// Songs and mixtapes only, exactly what a released app's decoder reads.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(records.filter { $0.containerKind != .book }, forKey: .records)
        try container.encode(pendingFailures, forKey: .pendingFailures)
    }

    /// Newest first.
    public mutating func add(_ record: Record) {
        records.removeAll { $0.identity == record.identity }
        records.insert(record, at: 0)
    }

    public mutating func remove(id: String, kind: ShareInvitation.Kind = .song) {
        records.removeAll { $0.id == id && $0.containerKind == kind }
    }

    /// Folds the server's list into the ledger. Stats, status, expiry and reactions come from
    /// the server; the link and the song come from here, because only here has them. A share the
    /// server no longer lists (purged after its retention) is dropped once it has ended; a live
    /// one is kept, since a missing row then means a server problem, not a finished share.
    public mutating func merge(_ summaries: [ShareSummary], now: Date = Date()) {
        let byID = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        records = records.compactMap { record in
            var record = record
            guard record.containerKind == .song else { return record }
            if let summary = byID[record.id] {
                record.summary = summary
                if let expiry = ShareDate.date(summary.expiresAt) { record.expiresAt = expiry }
                return record
            }
            return record.isLive(now: now) ? record : nil
        }
    }

    /// Updates one record from a single summary (after extend or a play-cap change).
    public mutating func update(_ summary: ShareSummary) {
        guard let index = records.firstIndex(where: { $0.id == summary.id && $0.containerKind == .song }) else { return }
        records[index].summary = summary
        if let expiry = ShareDate.date(summary.expiresAt) { records[index].expiresAt = expiry }
    }

    public mutating func mergeMixtapes(_ summaries: [MixtapeSummary], now: Date = Date()) {
        let byID = Dictionary(summaries.map { ($0.share.id, $0) }, uniquingKeysWith: { first, _ in first })
        records = records.compactMap { original in
            guard original.containerKind == .mixtape else { return original }
            var record = original
            if let value = byID[record.id] {
                record.summary = value.share; record.mixtapeSummary = value
                record.expiresAt = ShareDate.date(value.share.expiresAt) ?? record.expiresAt
                return record
            }
            return record.isLive(now: now) || record.isHeldForReview ? record : nil
        }
    }
    public mutating func updateMixtape(_ summary: MixtapeSummary) {
        guard let index = records.firstIndex(where: { $0.id == summary.share.id && $0.containerKind == .mixtape }) else { return }
        records[index].summary = summary.share; records[index].mixtapeSummary = summary
        records[index].expiresAt = ShareDate.date(summary.share.expiresAt) ?? records[index].expiresAt
    }

    /// Folds the service's book list into the ledger, as `mergeMixtapes` does for mixtapes: the
    /// link and the key come from here, status, expiry and listeners from the service. A book the
    /// service no longer lists is kept while it is live or held, and dropped once it has ended.
    public mutating func mergeBooks(_ summaries: [BookSummary], now: Date = Date()) {
        let byID = Dictionary(summaries.map { ($0.share.id, $0) }, uniquingKeysWith: { first, _ in first })
        records = records.compactMap { original in
            guard original.containerKind == .book else { return original }
            var record = original
            if let value = byID[record.id] {
                record.summary = value.share; record.bookSummary = value
                record.expiresAt = ShareDate.date(value.share.expiresAt) ?? record.expiresAt
                return record
            }
            return record.isLive(now: now) || record.isHeldForReview ? record : nil
        }
    }

    public mutating func updateBook(_ summary: BookSummary) {
        guard let index = records.firstIndex(where: { $0.id == summary.share.id && $0.containerKind == .book }) else { return }
        records[index].summary = summary.share; records[index].bookSummary = summary
        records[index].expiresAt = ShareDate.date(summary.share.expiresAt) ?? records[index].expiresAt
    }

    // MARK: - Failures waiting to be reported

    /// Queues a failure that never reached the server, to be reported with the next create.
    public mutating func noteFailure(_ reason: String) {
        let reason = ShareFailureReport.reasons.contains(reason) ? reason : "other"
        pendingFailures.append(ShareFailureReport(reason: reason))
        if pendingFailures.count > ShareLimits.maxRecentFailures {
            pendingFailures.removeFirst(pendingFailures.count - ShareLimits.maxRecentFailures)
        }
    }

    /// The queued failures, cleared: call when a create has carried them.
    public mutating func takeFailures() -> [ShareFailureReport] {
        defer { pendingFailures = [] }
        return pendingFailures
    }

    // MARK: - Persistence

    /// The ledger and, joined to it, the book links kept beside it (`booksURL`).
    public static func load(from url: URL) -> ShareLedger {
        var ledger = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(ShareLedger.self, from: $0) } ?? ShareLedger()
        ledger.join(books: loadBooks(beside: url))
        return ledger
    }

    /// Written atomically and readable only by this user: the file holds every link's key. Book
    /// links go to their own file beside it.
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try saveBooks(beside: url)
    }

    /// `SongShares.json` → `SongShares.books.json`: the book links, which released apps never open.
    public static func booksURL(beside url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".books.json")
    }

    private struct BookFile: Codable {
        var version = 1
        var records: [Record]
    }

    static func loadBooks(beside url: URL) -> [Record] {
        guard let data = try? Data(contentsOf: booksURL(beside: url)),
              let file = try? decoder.decode(BookFile.self, from: data), file.version == 1 else { return [] }
        return file.records.filter { $0.containerKind == .book }
    }

    /// Writes this ledger's book links beside `url`, protected like the ledger. Call it wherever
    /// the ledger file is written by other means (`ShareUploadStore.saveLedger`), so book changes
    /// are kept too. Nothing is written for a ledger that never had a book.
    public func saveBooks(beside url: URL) throws {
        let books = records.filter { $0.containerKind == .book }
        let target = Self.booksURL(beside: url)
        guard !books.isEmpty || FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ShareUploadStore.writeProtected(Self.encoder.encode(BookFile(records: books)), to: target)
    }

    /// Both lists are newest first; the ledger's own order is kept exactly, and each book goes in
    /// before the first record that is not newer than it.
    mutating func join(books stored: [Record]) {
        guard !stored.isEmpty else { return }
        let main = records.filter { $0.containerKind != .book }
        // A book record found in the ledger file itself (never written there by this code) is
        // kept unless the books file has it too, and moves there on the next save.
        let known = Set(stored.map(\.identity))
        let books = (stored + records.filter { $0.containerKind == .book && !known.contains($0.identity) })
            .sorted { $0.createdAt > $1.createdAt }
        var merged = [Record](), i = 0, j = 0
        merged.reserveCapacity(main.count + books.count)
        while i < main.count || j < books.count {
            if j < books.count, i == main.count || books[j].createdAt > main[i].createdAt {
                merged.append(books[j]); j += 1
            } else {
                merged.append(main[i]); i += 1
            }
        }
        records = merged
    }

    static var encoder: JSONEncoder {
        // Dates as Foundation's own reference-date seconds: lossless, so a save and a load give
        // back exactly what was saved (ISO 8601 drops the fraction of a second).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        JSONDecoder()
    }
}

/// The small pieces of the composer and the Shared Links list that are the same on both apps.
public enum SharePresentation {
    /// The message the share sheet is pre-filled with (plan §1): the note, then on its own line
    /// `"<title> by <artist> <link>"`, dropping whatever is empty.
    public static func message(title: String, artist: String, note: String, link: URL) -> String {
        let song = artist.isEmpty ? title : "\(title) by \(artist)"
        let lead = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return lead.isEmpty ? "\(song) \(link.absoluteString)" : "\(lead)\n\n\(song) \(link.absoluteString)"
    }

    /// Downsamples a waveform (any number of non-negative amplitudes) to the 0–255 peaks the
    /// player draws, normalized so the loudest bucket is 255. `count` buckets, each the maximum
    /// of its slice, so a transient is not averaged away.
    public static func peaks(_ samples: [Float], count: Int = 200) -> [Int] {
        guard !samples.isEmpty, count > 0 else { return [] }
        let buckets = min(count, samples.count)
        var maxima = [Float](repeating: 0, count: buckets)
        for (index, sample) in samples.enumerated() {
            let bucket = min(buckets - 1, index * buckets / samples.count)
            maxima[bucket] = max(maxima[bucket], abs(sample.isFinite ? sample : 0))
        }
        let loudest = maxima.max() ?? 0
        guard loudest > 0 else { return [Int](repeating: 0, count: buckets) }
        return maxima.map { Int(($0 / loudest * 255).rounded()) }
    }

    /// "Expires in 6 days", "Expires in 3 hours", "Expired".
    public static func expiry(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "Expired" }
        let days = Int(seconds / 86400)
        if days >= 1 { return "Expires in \(days) day\(days == 1 ? "" : "s")" }
        let hours = max(1, Int(seconds / 3600))
        return "Expires in \(hours) hour\(hours == 1 ? "" : "s")"
    }

    /// "Opened 3 · Played 2", the row's stats line, from what the server counted.
    public static func stats(_ stats: ShareStats) -> String {
        var parts = ["Opened \(stats.opens)", "Played \(stats.plays)"]
        if stats.completed > 0 { parts.append("Finished \(stats.completed)") }
        return parts.joined(separator: " · ")
    }
}
