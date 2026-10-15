import Foundation

/// A book the gateway is rendering, or has rendered (`specs/document-clippings.md`, *Rendering*).
///
/// The device that imported the document shapes it into a `PreparedBook` and submits it; the
/// gateway synthesizes each chapter, encodes it, and keeps it for the phone and the Mac to
/// collect. The job carries the per-chapter state a client shows ("Chapter 2, 41%", "paused:
/// Kokoro unreachable") and the timestamps retention runs on.
public struct BookJob: Codable, Sendable, Equatable {
    public enum ChapterState: Codable, Sendable, Equatable {
        case queued
        case rendering(done: Int, of: Int)
        case ready(file: String, bytes: Int, seconds: Double, sha256: String)
        case failed(reason: String)
    }

    public enum Status: String, Codable, Sendable {
        /// Waiting for, or in, the render loop.
        case rendering
        /// The TTS host stopped answering. Retried with backoff, never finished in another voice.
        case paused
        /// Every chapter is ready.
        case ready
        /// Something no retry can fix (ffmpeg missing, a chunk the engine refuses).
        case failed
    }

    public var id: String
    public var book: PreparedBook
    public var chapters: [ChapterState]
    public var status: Status
    /// Why it is paused, in a listener's words (`SynthesisError.listenerReason`).
    public var pauseReason: String?
    /// The engine's own message, for the log and for a person debugging. Optional in the
    /// stored JSON, so jobs written before it existed still load.
    public var pauseDetail: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// Set by a client when the listener reaches the end (synced "finished"). Retention runs
    /// on this: an unfinished book is never evicted.
    public var finishedAt: Date?

    public init(id: String, book: PreparedBook, now: Date = Date()) {
        self.id = id
        self.book = book
        self.chapters = Array(repeating: .queued, count: book.chapters.count)
        self.status = .rendering
        self.createdAt = now
        self.updatedAt = now
    }

    public var bytesOnDisk: Int {
        chapters.reduce(0) { total, state in
            if case let .ready(_, bytes, _, _) = state { return total + bytes }
            return total
        }
    }

    public var readyChapters: Int {
        chapters.filter { if case .ready = $0 { return true } else { return false } }.count
    }

    /// The job id a client should use for a book: the same document in the same voices is the
    /// same job, so submitting twice (a retry, a second device) finds the first one.
    public static func id(for book: PreparedBook) -> String {
        let voices = (try? BookJSON.sortedKeys.encode(book.voices)) ?? Data()
        // A corrected pronunciation is a different reading, so it is a different job; a book
        // with no lexicon keeps the id it had before lexicons existed.
        let lexicon = book.lexicon.flatMap { $0.isEmpty ? nil : try? BookJSON.sortedKeys.encode($0) } ?? Data()
        return SHA256Digest.hex(of: Data("book-v1|\(book.documentID)|".utf8) + voices + lexicon)
    }

    /// What a listing shows: everything but the text.
    public struct Summary: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var author: String?
        public var status: Status
        public var pauseReason: String?
        public var pauseDetail: String?
        public var chapters: [ChapterSummary]
        public var bytes: Int
        public var createdAt: Date
        public var finishedAt: Date?
        /// When the home server will remove this finished book (M6.6), so both apps can say
        /// "kept until 2 November" instead of a rule the listener has to work out. Set by
        /// `BookStore.summary(of:)`, which knows the retention; nil until the book is finished.
        public var removesAt: Date? = nil
    }

    public struct ChapterSummary: Codable, Sendable, Equatable {
        public var index: Int
        public var title: String
        /// "queued", "rendering", "encoding", "ready", "failed".
        public var state: String
        /// 0...1 while rendering, 1 when ready.
        public var progress: Double
        public var seconds: Double?
        public var bytes: Int?
        public var sha256: String?
        public var reason: String?
    }

    public var summary: Summary {
        Summary(id: id, title: book.title, author: book.author, status: status, pauseReason: pauseReason, pauseDetail: pauseDetail,
                chapters: zip(book.chapters, chapters).map { chapter, state in
                    switch state {
                    case .queued:
                        return ChapterSummary(index: chapter.index, title: chapter.title, state: "queued", progress: 0)
                    case let .rendering(done, of):
                        // Every chunk synthesized and the chapter not yet ready means ffmpeg is
                        // encoding it, which takes a while for a long chapter. Saying so beats
                        // a progress bar parked at 100%.
                        return ChapterSummary(index: chapter.index, title: chapter.title,
                                              state: of > 0 && done == of ? "encoding" : "rendering",
                                              progress: of > 0 ? Double(done) / Double(of) : 0)
                    case let .ready(_, bytes, seconds, sha):
                        return ChapterSummary(index: chapter.index, title: chapter.title, state: "ready", progress: 1,
                                              seconds: seconds, bytes: bytes, sha256: sha)
                    case let .failed(reason):
                        return ChapterSummary(index: chapter.index, title: chapter.title, state: "failed",
                                              progress: 0, reason: reason)
                    }
                },
                bytes: bytesOnDisk, createdAt: createdAt, finishedAt: finishedAt)
    }
}

/// Jobs on disk: one directory per job, `job.json` beside its chapter files. The gateway keeps
/// it beside its state file; the Mac in Application Support. The same layout either way.
///
/// On the gateway it is separate from `FileStore` on purpose. That store's rules (512 MB total, oldest first, two
/// weeks) are right for readings in transit and wrong for books: evicting the oldest file would
/// take chapter 1 of the book someone is halfway through. Books get their own quota, and an
/// unfinished book is never evicted (`specs/document-clippings.md`, *Storage*).
public struct BookStore: Sendable {
    public static let defaultMaximumBytes = 4 * 1024 * 1024 * 1024
    public static let defaultKeepFinished: TimeInterval = 30 * 24 * 60 * 60

    public let directory: URL
    public let maximumBytes: Int
    public let keepFinished: TimeInterval

    public init(directory: URL, maximumBytes: Int = BookStore.defaultMaximumBytes,
                keepFinished: TimeInterval = BookStore.defaultKeepFinished) {
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.keepFinished = keepFinished
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Ids come off the wire (the gateway) and become directory names, so they are whitelisted
    /// rather than escaped: hex and dashes, which covers the SHA-256 a job id is.
    public static func sanitize(_ id: String) -> String? {
        guard !id.isEmpty, id.count <= 128 else { return nil }
        let allowed = Set("0123456789abcdefABCDEF-")
        guard id.allSatisfy({ allowed.contains($0) }) else { return nil }
        return id.lowercased()
    }

    public func jobDirectory(_ id: String) -> URL? {
        guard let id = BookStore.sanitize(id) else { return nil }
        return directory.appendingPathComponent(id, isDirectory: true)
    }

    public func load(_ id: String) -> BookJob? {
        guard let dir = jobDirectory(id),
              let data = try? Data(contentsOf: dir.appendingPathComponent("job.json")) else { return nil }
        return try? BookJSON.decoder.decode(BookJob.self, from: data)
    }

    public func save(_ job: BookJob) throws {
        guard let dir = jobDirectory(job.id) else { throw BookStoreError.badID }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try BookJSON.encoder.encode(job).write(to: dir.appendingPathComponent("job.json"), options: .atomic)
    }

    public func list() -> [BookJob] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { load($0) }.sorted { $0.createdAt > $1.createdAt }
    }

    /// A job's summary with what only the store knows: when a finished book will be removed.
    public func summary(of job: BookJob) -> BookJob.Summary {
        var summary = job.summary
        summary.removesAt = job.finishedAt.map { $0.addingTimeInterval(keepFinished) }
        return summary
    }

    public func chapterURL(_ id: String, file: String) -> URL? {
        guard let dir = jobDirectory(id), file.range(of: #"^chapter-\d{1,4}\.m4a$"#, options: .regularExpression) != nil
        else { return nil }
        let url = dir.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func remove(_ id: String) {
        guard let dir = jobDirectory(id) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    public var usedBytes: Int { list().reduce(0) { $0 + $1.bytesOnDisk } }

    /// Retention, then the quota. Finished books past `keepFinished` go first; then, while over
    /// the quota, finished books by when they were finished, oldest first. Unfinished books are
    /// never touched. Returns the ids removed, so the log can say what went and why.
    @discardableResult
    public func prune(now: Date = Date()) -> [String] {
        var removed: [String] = []
        var jobs = list()
        for job in jobs {
            if let finished = job.finishedAt, now.timeIntervalSince(finished) > keepFinished {
                remove(job.id)
                removed.append(job.id)
            }
        }
        jobs = list()
        var total = jobs.reduce(0) { $0 + $1.bytesOnDisk }
        let finished = jobs.filter { $0.finishedAt != nil }.sorted { $0.finishedAt! < $1.finishedAt! }
        for job in finished where total > maximumBytes {
            remove(job.id)
            removed.append(job.id)
            total -= job.bytesOnDisk
        }
        return removed
    }

    /// Whether a new book of about `estimatedBytes` fits once retention has run. Unfinished
    /// books are what is left when this says no, and the answer then names them.
    public func hasRoom(for estimatedBytes: Int, now: Date = Date()) -> Bool {
        prune(now: now)
        return usedBytes + estimatedBytes <= maximumBytes
    }
}

public enum BookStoreError: Error, Equatable {
    case badID
}

/// The JSON a book job is stored and served as: ISO-8601 dates (readable in a log, safe for a
/// client that is not Foundation) and sorted keys (stable on disk and in tests).
public enum BookJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static var sortedKeys: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
