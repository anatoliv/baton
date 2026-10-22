import BatonSubsonicKit
import CryptoKit
import Foundation
import Observation
import OSLog

/// The covers of the books on this device, by document id: the same key Clippings,
/// the ledger and the home server's listing use, so a cover follows its book whatever voice it
/// is read in.
///
/// One small folder: a picture per book, named with the start of its digest so a changed cover
/// is a new file URL (no cache anywhere can show the old one), and one index file saying what
/// each book's cover is, where it came from, and how it stands with the home server. The
/// pictures are already re-encoded by the time they get here (`BookCoverImaging.sanitize`, or a
/// designed cover); this store only keeps them.
///
/// A book chapter handed to the player carries its book's cover as `artworkURL`
/// (`ClippingStore.Item.asSong`), which is what every Now Playing surface, the lock screen and
/// Control Center already read first.
@MainActor
@Observable
public final class BookCoverStore {
    /// Where a cover came from, for the menu's wording and for "keep the book's own cover".
    public enum Source: String, Codable, Sendable {
        /// The book's own file: an EPUB's cover picture.
        case book
        case openLibrary
        /// Drawn here from the title and author.
        case made
        /// A picture the listener chose.
        case file
        /// Set on another device and fetched from the home server.
        case homeServer
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var documentID: String
        /// The kept picture's digest; nil once the cover was removed (kept so the removal still
        /// reaches the home server).
        public var sha256: String?
        public var fileName: String?
        public var source: Source?
        public var changedAt: Date
        /// Changed on this device and not yet told to the home server.
        public var needsPush: Bool
        /// The home server job this entry last agreed with, and that job's cover `changedAt` then
        /// (the server's own clock, compared only with itself).
        public var syncedJobID: String?
        public var serverChangedAt: Date?
        /// That job's cover revision then, from a home server that counts them (two changes in
        /// one second share a `changedAt`, never a revision). Nil before revisions existed.
        public var serverRevision: Int? = nil

        public var hasCover: Bool { sha256 != nil && fileName != nil }
    }

    public private(set) var entries: [String: Entry] = [:]
    /// Told the document id whenever a book's cover changes here, so whoever plays its chapters
    /// can swap the artwork of what is queued.
    @ObservationIgnored public var onChange: ((String) -> Void)?

    @ObservationIgnored public let directory: URL
    @ObservationIgnored private let index: VersionedStore<[Entry]>
    @ObservationIgnored private let log = Logger(subsystem: "io.tonebox.baton", category: "documents")

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        index = VersionedStore<[Entry]>(fileURL: directory.appendingPathComponent("covers.json"), currentVersion: 1,
                                        keepBackup: true, encoder: encoder, decoder: decoder)
        entries = Dictionary((index.load() ?? []).map { ($0.documentID, $0) }, uniquingKeysWith: { _, last in last })
        publishArtwork()
    }

    // MARK: - Reading

    public func entry(_ documentID: String) -> Entry? { entries[documentID] }

    /// The picture for a book, when it has one and the file is still there.
    public func url(for documentID: String) -> URL? {
        guard let entry = entries[documentID], entry.hasCover, let name = entry.fileName else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func hasCover(_ documentID: String) -> Bool { url(for: documentID) != nil }

    public func source(of documentID: String) -> Source? { entries[documentID].flatMap { $0.hasCover ? $0.source : nil } }

    /// The kept bytes, for an upload.
    public func imageData(_ documentID: String) -> Data? { url(for: documentID).flatMap { try? Data(contentsOf: $0) } }

    // MARK: - Changing

    /// Keep `image` (a JPEG or PNG made by `BookCoverImaging`) as the book's cover. `push` says
    /// whether the home server should be told: false only for a cover that came from there.
    public func set(_ image: Data, documentID: String, source: Source, push: Bool = true,
                    syncedJobID: String? = nil, serverChangedAt: Date? = nil, serverRevision: Int? = nil,
                    now: Date = Date()) throws {
        guard Self.isSafeID(documentID) else { throw StoreError.badID }
        guard let ext = Self.fileExtension(of: image) else { throw StoreError.notAnImage }
        let sha = Self.sha256(image)
        let name = "\(documentID)-\(sha.prefix(12)).\(ext)"
        try image.write(to: directory.appendingPathComponent(name), options: .atomic)
        let previous = entries[documentID]
        if let old = previous?.fileName, old != name { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old)) }
        var entry = Entry(documentID: documentID, sha256: sha, fileName: name, source: source, changedAt: now,
                          needsPush: push, syncedJobID: previous?.syncedJobID, serverChangedAt: previous?.serverChangedAt,
                          serverRevision: previous?.serverRevision)
        if !push {
            entry.syncedJobID = syncedJobID
            entry.serverChangedAt = serverChangedAt
            entry.serverRevision = serverRevision
        }
        entries[documentID] = entry
        save()
        changed(documentID)
    }

    /// Keep the book's own cover (an EPUB's) only when it shows none: a cover the listener
    /// chose, found or made is never replaced by an import of the same book. Importing the book
    /// again after its cover was removed brings the book's own cover back, which is what
    /// importing it asks for.
    @discardableResult
    public func setIfAbsent(_ image: Data, documentID: String, source: Source) -> Bool {
        guard !hasCover(documentID) else { return false }
        do { try set(image, documentID: documentID, source: source) } catch { return false }
        return true
    }

    /// "Remove Cover": the picture goes, and the removal is kept so the home server and the
    /// other devices remove theirs too.
    public func remove(documentID: String, push: Bool = true, syncedJobID: String? = nil, serverChangedAt: Date? = nil,
                       serverRevision: Int? = nil, now: Date = Date()) {
        guard let previous = entries[documentID] else { return }
        if let old = previous.fileName { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old)) }
        var entry = Entry(documentID: documentID, sha256: nil, fileName: nil, source: nil, changedAt: now, needsPush: push,
                          syncedJobID: previous.syncedJobID, serverChangedAt: previous.serverChangedAt,
                          serverRevision: previous.serverRevision)
        if !push {
            entry.syncedJobID = syncedJobID
            entry.serverChangedAt = serverChangedAt
            entry.serverRevision = serverRevision
        }
        entries[documentID] = entry
        save()
        changed(documentID)
    }

    /// What a push sent: a cover by its digest, or a removal (nil).
    public enum Pushed: Equatable, Sendable {
        case cover(String)
        case removal
    }

    /// The home server agrees with this device about the book's cover, as of its stamp. After a
    /// push, `pushed` says what was sent: if the cover here changed while it was on its way, the
    /// home server's stamp is remembered but the new cover still needs sending (review:
    /// a cover chosen during an upload was otherwise marked sent and never went).
    public func markSynced(documentID: String, jobID: String, serverChangedAt: Date?, serverRevision: Int? = nil,
                           pushed: Pushed? = nil) {
        guard var entry = entries[documentID] else {
            // Nothing here and nothing there worth a record: remember the job, so a later
            // cover on it reads as new.
            entries[documentID] = Entry(documentID: documentID, sha256: nil, fileName: nil, source: nil,
                                        changedAt: serverChangedAt ?? Date(), needsPush: false, syncedJobID: jobID,
                                        serverChangedAt: serverChangedAt, serverRevision: serverRevision)
            save()
            return
        }
        let stillWhatWasSent: Bool
        switch pushed {
        case nil: stillWhatWasSent = true
        case let .cover(sha): stillWhatWasSent = entry.hasCover && entry.sha256 == sha
        case .removal: stillWhatWasSent = !entry.hasCover
        }
        if stillWhatWasSent { entry.needsPush = false }
        entry.syncedJobID = jobID
        entry.serverChangedAt = serverChangedAt
        entry.serverRevision = serverRevision
        entries[documentID] = entry
        save()
    }

    /// A book gone from this device for good (its Recently removed week is over): its picture and
    /// its record go, with nothing left to tell the home server, which deleted it with the book
    /// or keeps it for the other devices.
    public func forget(documentID: String) {
        guard let previous = entries[documentID] else { return }
        if let old = previous.fileName { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old)) }
        entries[documentID] = nil
        save()
        changed(documentID)
    }

    // MARK: - The home server

    /// What the home server's listing says about a book's cover.
    public struct ServerCover: Equatable, Sendable {
        public var sha256: String?
        public var changedAt: Date
        /// Counts every change on that job; nil from a home server older than revisions.
        public var revision: Int?

        public init(sha256: String?, changedAt: Date, revision: Int? = nil) {
            self.sha256 = sha256
            self.changedAt = changedAt
            self.revision = revision
        }
    }

    public enum SyncAction: Equatable, Sendable {
        case nothing
        /// Both sides agree; only remember it.
        case settled
        /// Send this device's cover.
        case push
        /// Tell the home server the cover was removed.
        case pushRemoval
        /// Fetch the home server's cover.
        case pull
        /// The cover was removed on another device: remove it here.
        case removeLocal
    }

    /// What to do about one book's cover, given this device's entry, the job the home server
    /// lists for the book now, and that job's cover (nil: never set there).
    ///
    /// A change made here wins until the home server has it. Otherwise the home server's
    /// `changedAt` decides: a stamp this device has not seen for this job is another device's
    /// change, and is taken. A job this device has not seen (the book made again in another
    /// voice) with no cover gets this device's.
    public nonisolated static func decide(local: Entry?, jobID: String, server: ServerCover?) -> SyncAction {
        let localSHA = (local?.hasCover ?? false) ? local?.sha256 : nil
        if let local, local.needsPush {
            if let localSHA {
                return server?.sha256 == localSHA ? .settled : .push
            }
            return server == nil || server?.sha256 == nil ? .settled : .pushRemoval
        }
        guard let server else { return localSHA == nil ? .nothing : .push }
        if let local, local.syncedJobID == jobID, sameStamp(local, server) { return .nothing }
        if server.sha256 == localSHA { return .settled }
        if server.sha256 != nil { return .pull }
        return localSHA == nil ? .settled : .removeLocal
    }

    /// Whether this device has already seen this change of the home server's cover: by revision
    /// when the home server counts them, else by its `changedAt`, which has whole-second precision.
    nonisolated static func sameStamp(_ local: Entry, _ server: ServerCover) -> Bool {
        if let revision = server.revision { return local.serverRevision == revision }
        return local.serverChangedAt == server.changedAt
    }

    // MARK: - Now Playing

    /// The cover each book's chapters carry to the player, readable from anywhere (the player
    /// builds songs off the main actor too). Filled by the app's store.
    private nonisolated static let artwork = ArtworkIndex()

    public nonisolated static func artworkURL(documentID: String) -> URL? { artwork.url(documentID) }

    private func publishArtwork() {
        var map: [String: URL] = [:]
        for id in entries.keys { if let url = url(for: id) { map[id] = url } }
        Self.artwork.replace(map)
    }

    // MARK: - Helpers

    public enum StoreError: Error, Equatable {
        case badID
        case notAnImage
    }

    private func changed(_ documentID: String) {
        publishArtwork()
        onChange?(documentID)
    }

    private func save() {
        if !index.save(entries.values.sorted { $0.documentID < $1.documentID }) {
            log.error("could not save the book covers index")
        }
    }

    /// Document ids become file names: hex and dashes only, which a document's digest is.
    nonisolated static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    nonisolated static func fileExtension(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(8))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "jpg" }
        if bytes == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return "png" }
        return nil
    }

    nonisolated static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// The document-id-to-cover map the player reads, behind a lock.
private final class ArtworkIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: URL] = [:]

    func url(_ id: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return map[id]
    }

    func replace(_ new: [String: URL]) {
        lock.lock(); defer { lock.unlock() }
        map = new
    }
}
