import BatonDocuments
import BatonPlaybackKit
import BatonSpeech
import BatonSubsonicKit
import Foundation
import Observation
import OSLog

/// Books made on the home server, as one device remembers them (`specs/document-clippings.md`,
/// *Rendering*, `GatewayBookRenderer`): the Mac's "Made on: Home server" (M5.6) and every
/// iPhone import (M5.3) share this file verbatim, so the two apps cannot drift on what a
/// remembered book is or how a chapter comes down.
///
/// The gateway's summary does not carry the document id, the author or the words, and Clippings
/// needs all three to file a chapter as part of a book, so each submission keeps a `Record`
/// beside the audio. Collection is idempotent: a chapter already in Clippings is never fetched
/// again, and a download is verified against the gateway's digest before it is adopted.
@MainActor
@Observable
final class HomeServerBooks {
    /// What this device remembers about a book it sent to the home server. The JSON is the Mac's
    /// `home-server-books.json` from M5.6, unchanged, so an existing file reads as before.
    struct Record: Codable, Equatable, Sendable {
        var jobID: String
        var documentID: String
        var title: String
        var author: String?
        var chapterTitles: [String]
        var chapterTexts: [String]
        var createdAt: Date
        /// Chapters whose audio this device removed on purpose (M6.3, "Remove Download"). They
        /// are not collected again until "Download Again". Absent in files written before M6.3.
        var offloadedChapters: [Int]? = nil
        /// The home server no longer has this book (finished, and past its keep date) while
        /// some of its chapters are offloaded here: they come back with "Render Again", from
        /// the shaped book saved beside the record.
        var serverRemoved: Bool? = nil

        var offloaded: Set<Int> { Set(offloadedChapters ?? []) }
    }

    enum Problem: Error, CustomStringConvertible {
        case notConfigured
        case nothingToRender
        var description: String {
            switch self {
            case .notConfigured: return "the home server is not set up in Settings"
            case .nothingToRender: return "this device has no copy of the book's text to make it again"
            }
        }
    }

    /// The latest summary of each remembered book, by job id.
    private(set) var summaries: [String: BookJob.Summary] = [:]
    /// Why the last attempt to reach the home server failed, in a listener's words.
    private(set) var problem: String?

    /// A chapter that just came down, for whoever wants to say so (the phone's "Chapter 1 is
    /// ready", M5.4). Returned by `collect`, never accumulated: a list nobody drained would
    /// grow for the life of the process and announce old chapters twice.
    struct Arrival: Equatable {
        let record: Record
        let chapterIndex: Int
    }

    @ObservationIgnored private let store: VersionedStore<[Record]>
    /// Books stopped here whose delete the home server has not confirmed yet (it was away, or
    /// answered with an error). Asked again on every refresh until it answers 2xx or 404.
    @ObservationIgnored private let pendingDeletes: VersionedStore<[String]>
    /// Where each submitted book's shaped text is kept, so a book the home server has since
    /// removed can be made again ("Render Again", M6.3). Small: words and voice choices only.
    @ObservationIgnored private let preparedDirectory: URL
    @ObservationIgnored private let clippings: ClippingStore
    @ObservationIgnored private let gateway: @MainActor () -> GatewayBookClient?
    @ObservationIgnored private let log: Logger
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var collecting = false
    @ObservationIgnored private var watcher: Task<Void, Never>?

    init(directory: URL, clippings: ClippingStore,
         gateway: @escaping @MainActor () -> GatewayBookClient?,
         log: Logger = Logger(subsystem: "io.tonebox.baton", category: "documents"),
         pollInterval: Duration = .seconds(5)) {
        self.store = VersionedStore<[Record]>(fileURL: directory.appendingPathComponent("home-server-books.json"),
                                              currentVersion: 1, keepBackup: true, log: log)
        self.pendingDeletes = VersionedStore<[String]>(
            fileURL: directory.appendingPathComponent("home-server-books-pending-deletes.json"),
            currentVersion: 1, log: log)
        self.preparedDirectory = directory.appendingPathComponent("home-server-books", isDirectory: true)
        self.clippings = clippings
        self.gateway = gateway
        self.log = log
        self.pollInterval = pollInterval
    }

    var records: [Record] { store.load() ?? [] }

    /// Job ids of books stopped here that the home server has still to delete.
    var pendingDeleteIDs: [String] { pendingDeletes.load() ?? [] }

    func record(forDocument documentID: String) -> Record? { records.first { $0.documentID == documentID } }
    func record(forJob jobID: String) -> Record? { records.first { $0.jobID == jobID } }

    var isConfigured: Bool { gateway() != nil }

    /// Whether the home server makes books now: configured, answering, and books switched on there.
    func available() async -> Bool {
        await availability() == .available
    }

    /// What the home server said about making books, finer than yes or no: the phone offers
    /// "Send to my Mac" only when the home server answered but cannot make books.
    enum Availability: Equatable {
        /// No home server set up on this device.
        case notConfigured
        /// It answered with books on.
        case available
        /// It answered, and cannot make books: no voice server, books off, or a gateway from
        /// before books (404). Its file store still carries documents.
        case cannotMakeBooks
        /// It did not answer, or refused this device's token.
        case unreachable
    }

    func availability() async -> Availability {
        guard let client = gateway() else { return .notConfigured }
        do {
            let listing = try await client.list()
            problem = listing.available ? nil : listing.unavailableReason
            return listing.available ? .available : .cannotMakeBooks
        } catch {
            problem = (error as? GatewayBookError)?.listenerReason ?? error.localizedDescription
            if case let .http(status, _)? = error as? GatewayBookError, status == 404 || status == 503 {
                if status == 404 { problem = "the home server does not make books" }
                return .cannotMakeBooks
            }
            return .unreachable
        }
    }

    /// Submit a shaped book and remember it. Submitting the same book in the same voice again
    /// finds the job already there.
    @discardableResult
    func submit(_ book: PreparedBook) async throws -> String {
        guard let client = gateway() else { throw Problem.notConfigured }
        let summary = try await client.submit(book)
        var kept = records.filter { $0.jobID != summary.id }
        kept.append(Record(jobID: summary.id, documentID: book.documentID, title: book.title, author: book.author,
                           chapterTitles: book.chapters.map(\.title),
                           chapterTexts: book.chapters.map { $0.segments.map(\.text).joined(separator: " ") },
                           createdAt: Date()))
        save(kept)
        savePreparedBook(book, jobID: summary.id)
        summaries[summary.id] = summary
        log.notice("sent \"\(book.title, privacy: .public)\" to the home server: \(book.chapters.count) chapters")
        return summary.id
    }

    /// Every chapter is here, apart from those removed on purpose.
    func isCollected(_ record: Record) -> Bool {
        let offloaded = record.offloaded
        return (0..<record.chapterTitles.count).allSatisfy {
            offloaded.contains($0) || clippings.item(documentID: record.documentID, chapterIndex: $0) != nil
        }
    }

    var hasUncollected: Bool { records.contains { $0.serverRemoved != true && !isCollected($0) } }

    // MARK: - Offload, download again, render again (M6.3)

    /// The shaped book this device sent, when it kept one (every submission since M6.3).
    func preparedBook(forJob jobID: String) -> PreparedBook? {
        guard let url = preparedURL(jobID), let data = try? Data(contentsOf: url) else { return nil }
        return try? PreparedBook.decode(data)
    }

    /// Whether audio removed from this device can come back: from the home server while it
    /// still has the book, or made again from the shaped book saved here.
    func canGetBack(_ record: Record) -> Bool {
        (record.serverRemoved != true && summaries[record.jobID] != nil) || preparedBook(forJob: record.jobID) != nil
    }

    /// Note that these chapters' audio was removed from this device on purpose, so collecting
    /// does not bring them straight back. The caller removes the clippings.
    func offload(jobID: String, chapters: [Int]) {
        update(jobID) { record in
            record.offloadedChapters = Array(record.offloaded.union(chapters)).sorted()
        }
    }

    /// Bring removed chapters back (all of them, or `chapters`): from the home server while it
    /// has the book, else by sending the saved book to be made again.
    func downloadAgain(jobID: String, chapters: [Int]? = nil) async throws {
        guard let record = record(forJob: jobID) else { return }
        if record.serverRemoved == true {
            try await renderAgain(jobID: jobID)
            return
        }
        update(jobID) { record in
            let back = chapters.map(Set.init) ?? record.offloaded
            let left = record.offloaded.subtracting(back)
            record.offloadedChapters = left.isEmpty ? nil : left.sorted()
        }
        await collect()
    }

    /// Send the saved book to the home server again, to be made afresh: for a book the server
    /// has removed. Its chapters come down as they are ready, as the first time.
    func renderAgain(jobID: String) async throws {
        guard let client = gateway() else { throw Problem.notConfigured }
        guard let book = preparedBook(forJob: jobID) else { throw Problem.nothingToRender }
        let summary = try await client.submit(book)
        update(jobID) { record in
            record.offloadedChapters = nil
            record.serverRemoved = nil
        }
        summaries[summary.id] = summary
        log.notice("book \(jobID.prefix(12), privacy: .public): sent to the home server to be made again")
    }

    /// The home server's own account of its books, for the Storage screen: sizes, the quota and
    /// how long finished books are kept there. Nil when it cannot be asked.
    func listing() async -> GatewayBookClient.Listing? {
        guard let client = gateway() else { return nil }
        await retryPendingDeletes()
        do {
            var listing = try await client.list()
            problem = nil
            // A book stopped here stays gone while its delete waits to be confirmed.
            let pending = Set(pendingDeleteIDs)
            listing.books.removeAll { pending.contains($0.id) }
            return listing
        } catch {
            problem = (error as? GatewayBookError)?.listenerReason ?? error.localizedDescription
            return nil
        }
    }

    /// The summary of a book the home server no longer has, from the saved book: every chapter
    /// "ready", so the ones removed here show as removed and can be made again.
    private func localSummary(_ record: Record) -> BookJob.Summary? {
        guard let book = preparedBook(forJob: record.jobID) else { return nil }
        var job = BookJob(id: record.jobID, book: book, now: record.createdAt)
        job.status = .ready
        job.chapters = book.chapters.map { _ in .ready(file: "", bytes: 0, seconds: 0, sha256: "") }
        return job.summary
    }

    private func update(_ jobID: String, _ change: (inout Record) -> Void) {
        var all = records
        guard let index = all.firstIndex(where: { $0.jobID == jobID }) else { return }
        change(&all[index])
        save(all)
    }

    private func preparedURL(_ jobID: String) -> URL? {
        guard let id = BookStore.sanitize(jobID) else { return nil }
        return preparedDirectory.appendingPathComponent("\(id).json")
    }

    private func savePreparedBook(_ book: PreparedBook, jobID: String) {
        guard let url = preparedURL(jobID), let data = try? book.encoded() else { return }
        do {
            try FileManager.default.createDirectory(at: preparedDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("could not keep the shaped book \(jobID.prefix(12), privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Ask the home server about every book not yet collected, and bring each chapter that is
    /// ready into Clippings, checked against its digest. A chapter already here is not fetched
    /// again. Returns what arrived in this round, chapter by chapter.
    @discardableResult
    func collect() async -> [Arrival] {
        guard !collecting, let client = gateway() else { return [] }
        collecting = true
        defer { collecting = false }
        await retryPendingDeletes()
        var arrivals: [Arrival] = []
        // A collected book is asked about once per process too, so a finished book shows "kept
        // until" after a relaunch (M6.6); a book the home server has since removed is forgotten,
        // its chapters staying in Clippings.
        for record in records where !isCollected(record) || summaries[record.jobID] == nil {
            if record.serverRemoved == true {
                if summaries[record.jobID] == nil { summaries[record.jobID] = localSummary(record) }
                continue
            }
            let summary: BookJob.Summary
            do {
                summary = try await client.status(record.jobID)
                problem = nil
            } catch {
                if case GatewayBookError.http(404, _) = error, isCollected(record) {
                    // Chapters removed here on purpose can still be made again from the saved
                    // book; without one there is nothing to keep the record for.
                    if !record.offloaded.isEmpty, let local = localSummary(record) {
                        update(record.jobID) { $0.serverRemoved = true }
                        summaries[record.jobID] = local
                    } else {
                        forget(jobID: record.jobID)
                    }
                    continue
                }
                problem = (error as? GatewayBookError)?.listenerReason ?? error.localizedDescription
                continue
            }
            summaries[record.jobID] = summary
            for chapter in summary.chapters where chapter.state == "ready" && !record.offloaded.contains(chapter.index) {
                guard clippings.item(documentID: record.documentID, chapterIndex: chapter.index) == nil else { continue }
                let temporary = FileManager.default.temporaryDirectory
                    .appendingPathComponent("baton-chapter-\(UUID().uuidString).m4a")
                do {
                    let file = try await client.downloadChapter(record.jobID, number: chapter.index + 1, to: temporary)
                    let title = record.chapterTitles.indices.contains(chapter.index) ? record.chapterTitles[chapter.index] : chapter.title
                    try clippings.adopt(file.url, title: title, sourceName: record.author,
                                        durationSeconds: file.seconds ?? chapter.seconds,
                                        text: record.chapterTexts.indices.contains(chapter.index) ? record.chapterTexts[chapter.index] : nil,
                                        sha256: file.sha256,
                                        chapter: .init(documentID: record.documentID, documentTitle: record.title,
                                                       author: record.author, chapterIndex: chapter.index, chapterTitle: title))
                    arrivals.append(Arrival(record: record, chapterIndex: chapter.index))
                    log.notice("book \(record.jobID.prefix(12), privacy: .public): chapter \(chapter.index + 1) collected from the home server")
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    log.error("book \(record.jobID.prefix(12), privacy: .public): could not collect chapter \(chapter.index + 1): \(String(describing: error), privacy: .public)")
                }
            }
        }
        return arrivals
    }

    /// Poll the home server every few seconds while a book there is not fully collected, calling
    /// `changed` after each round so the owner can refresh what it shows.
    func watchIfNeeded(changed: @escaping @MainActor () -> Void) {
        guard watcher == nil, hasUncollected else { return }
        let interval = pollInterval
        watcher = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled else { return }
            await self.collect()
            // Stopped while collecting: a newer watcher may own the slot by now. Leave it.
            guard !Task.isCancelled else { return }
            self.watcher = nil
            changed()
            if self.hasUncollected { self.watchIfNeeded(changed: changed) }
        }
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    /// Stop making the book and forget it here. Chapters already in Clippings stay there. The
    /// delete is remembered before it is sent, so a home server that is away (or fails) is asked
    /// again on the next refresh rather than keeping the book for ever.
    func cancel(jobID: String) async {
        forget(jobID: jobID)
        var pending = pendingDeleteIDs
        if !pending.contains(jobID) {
            pending.append(jobID)
            _ = pendingDeletes.save(pending)
        }
        await retryPendingDeletes()
    }

    /// Ask the home server to delete every book stopped here that it has not yet confirmed. A
    /// book leaves the list when the server answers 2xx, or 404 (it no longer has it).
    func retryPendingDeletes() async {
        guard let client = gateway() else { return }
        for jobID in pendingDeleteIDs {
            do {
                try await client.delete(jobID)
            } catch GatewayBookError.http(status: 404, message: _) {
                // Already gone there: nothing left to ask.
            } catch {
                log.error("could not delete book \(jobID.prefix(12), privacy: .public) on the home server, will ask again: \(String(describing: error), privacy: .public)")
                continue
            }
            _ = pendingDeletes.save(pendingDeleteIDs.filter { $0 != jobID })
        }
    }

    func forget(jobID: String) {
        save(records.filter { $0.jobID != jobID })
        summaries[jobID] = nil
        if let url = preparedURL(jobID) { try? FileManager.default.removeItem(at: url) }
    }

    /// Tell the home server the listener reached the end, and read the summary back: it now
    /// carries `removesAt`, the date the row shows as "kept until" (M6.6).
    func markFinished(jobID: String) async {
        guard let client = gateway() else { return }
        try? await client.markFinished(jobID)
        if let summary = try? await client.status(jobID) { summaries[jobID] = summary }
    }

    private func save(_ records: [Record]) { _ = store.save(records) }
}

/// The voice a book gets before a suggestion exists (M4.4): the same choice a reading makes. A
/// language with its own entry in the voice map gets that voice, and everything else, English
/// included, gets the configured default. One rule for both apps.
///
/// When the caller knows the voices the engine that will render offers (`available`: the Kokoro
/// host's list, or the built-in voices), an English book gets Heart, or Emma when it declared
/// British English, if that voice is among them (`VoiceCatalogue.narratorDefault`, TBX-10916).
/// Without the list (the phone, whose home server does not list its voices) the configured
/// default stands, so a book is never sent to a voice nobody checked is there.
enum DocumentVoices {
    static func languageDefault(for document: ImportedDocument, available: [String]? = nil) -> String {
        if let available, let voice = VoiceCatalogue.narratorDefault(for: document, available: available) { return voice }
        let code = document.language.map { String($0.prefix(2)).lowercased() }
        let category = code.flatMap { $0 != "en" && SpeechConfig.voiceMap()[$0] != nil ? $0 : nil }
        let voice = SpeechConfig.resolve(category: category, explicitVoice: nil, engineOverride: nil)
        return "\(voice.engine.rawValue):\(voice.voice)"
    }
}

extension ImportWarning {
    /// A warning in plain words, the same on both apps. No dashes in user copy.
    var listenerText: String {
        let pages = Self.pageList(pages)
        switch kind {
        case .pagesWithoutText:
            return "\(pages.isEmpty ? "Some pages" : pages) have no text Baton could read, so they are left out."
        case .pagesRecognized:
            return "\(pages.isEmpty ? "Some pages" : pages) were read by text recognition, which can misread words."
        case .noChapters:
            return "No chapters were found, so the book is one long chapter."
        case .metadataTitleIgnored:
            return "The file's own title (\(detail ?? "unknown")) looked like a file name, so the title comes from the first page."
        case .protectedContent:
            return "This file is protected, so Baton cannot read it."
        case .empty:
            return "Nothing to read aloud was found in this file."
        case .contentSkipped:
            return "Left out of the reading: \(detail ?? "some content")."
        }
    }

    /// "Page 4", "Pages 4, 5 and 9".
    static func pageList(_ pages: [Int]) -> String {
        guard let last = pages.last else { return "" }
        if pages.count == 1 { return "Page \(last)" }
        return "Pages " + pages.dropLast().map(String.init).joined(separator: ", ") + " and \(last)"
    }
}

// MARK: - Book storage on this device (M6.3 to M6.5)
//
// In this file rather than one of its own because it is the one both apps compile for books:
// a new file under Shared/ would need a line in each app's project.yml.

/// A book as storage sees it, the same on both apps: what is on this device, how big it is,
/// where the listener is with it, and whether its audio can come back once removed.
struct StoredBook: Equatable, Identifiable {
    var documentID: String
    var title: String
    var author: String?
    /// Chapters whose audio is on this device.
    var present: [ClippingStore.Item]
    /// Chapters made once whose audio is not on this device now.
    var missing: [Int]
    var createdAt: Date
    var finishedAt: Date?
    var lastPlayedAt: Date?
    var inProgress: Bool
    /// Made on the home server: its job there, for Remove Download and Download Again.
    var homeServerJobID: String?
    /// Whether removed audio can come back: made on this Mac with its job kept, or on the home
    /// server while it has the book or the shaped book is saved here. Without this a book is
    /// never offloaded, by hand or by a rule, because removing it would lose it.
    var canGetBack: Bool

    var id: String { documentID }

    var bytes: Int {
        present.reduce(0) { total, item in
            total + ((try? FileManager.default.attributesOfItem(atPath: item.url.path)[.size] as? Int) ?? 0)
        }
    }

    /// Every chapter's audio is gone from this device (offloaded).
    var isOffloaded: Bool { present.isEmpty && !missing.isEmpty }

    /// The book's dates from the shared ledger: finished, last played, and whether it is the
    /// one being listened to (started and not finished), which nothing ever removes.
    static func listening(_ documentID: String, ledger: ClippingLedger,
                          present: [ClippingStore.Item]) -> (finishedAt: Date?, lastPlayedAt: Date?, inProgress: Bool) {
        let record = ledger.document(documentID)
        let finishedAt = record?.finished == true ? (record?.finishedAt ?? record?.positionAt) : nil
        let played = ([record?.positionAt] + present.map(\.clipping.lastPlayedAt)).compactMap { $0 }.max()
        let inProgress = record?.finished != true && record?.chapterIndex != nil
        return (finishedAt, played, inProgress)
    }
}

/// This device's book storage (M6.3 to M6.5): the person's rules and Keeps, removing a book's
/// download and bringing it back, the week-long "Recently removed" list, and the weekly
/// suggestion in Clippings. Decisions are `StoragePolicy`'s and the record is `BookStorage`'s,
/// both in `BatonDocuments`; this is where they meet the files.
///
/// A deleted book's audio is **held** here for a week rather than deleted at once, so Restore
/// brings it back as it was; after the week it is purged. A removed download is not held: the
/// point of removing it is the space, and it comes back with Download Again.
@MainActor
@Observable
final class BookCleanup {
    private(set) var settings: BookStorage.Settings
    private(set) var removed: [BookStorage.Removed] = []

    /// Called with the player ids of chapters whose audio just left, so the player drops them
    /// rather than playing on into a file that is gone.
    @ObservationIgnored var dropFromQueue: ([String]) -> Void = { _ in }

    @ObservationIgnored private let clippings: ClippingStore
    @ObservationIgnored private let homeServer: HomeServerBooks
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let removedStore: VersionedStore<[BookStorage.Removed]>
    @ObservationIgnored private let holdDirectory: URL
    @ObservationIgnored private let log: Logger

    init(directory: URL, clippings: ClippingStore, homeServer: HomeServerBooks,
         defaults: UserDefaults = BatonStorage.defaults,
         log: Logger = Logger(subsystem: "io.tonebox.baton", category: "documents")) {
        self.clippings = clippings
        self.homeServer = homeServer
        self.defaults = defaults
        self.log = log
        self.removedStore = VersionedStore<[BookStorage.Removed]>(
            fileURL: directory.appendingPathComponent("recently-removed.json"), currentVersion: 1, keepBackup: true, log: log)
        self.holdDirectory = directory.appendingPathComponent("recently-removed", isDirectory: true)
        self.settings = BookStorage.loadSettings(from: defaults)
        self.removed = removedStore.load() ?? []
    }

    // MARK: Rules and Keep

    var rules: StoragePolicy.Rules { settings.rules }

    func setRules(_ rules: StoragePolicy.Rules) {
        change { $0.rules = rules }
    }

    func isKept(_ documentID: String) -> Bool { settings.keep.contains(documentID) }

    func setKeep(_ keep: Bool, documentID: String) {
        change { settings in
            if keep { settings.keep.insert(documentID) } else { settings.keep.remove(documentID) }
        }
    }

    /// The book as `StoragePolicy` reads it. A book whose audio could not come back is treated
    /// as kept, so no rule and no suggestion ever removes it.
    func policyItem(_ book: StoredBook) -> StoragePolicy.Item {
        StoragePolicy.Item(id: book.documentID, title: book.title, bytes: book.bytes, isBook: true,
                           addedAt: book.createdAt, lastPlayedAt: book.lastPlayedAt, finishedAt: book.finishedAt,
                           inProgress: book.inProgress, keep: isKept(book.documentID) || !book.canGetBack,
                           downloaded: !book.present.isEmpty)
    }

    /// Remove what the rules say is due, as removals the person can see in Recently removed.
    /// Returns the books whose download went.
    @discardableResult
    func applyRules(_ books: [StoredBook], now: Date = Date()) -> [String] {
        purge(now: now)
        guard !settings.rules.isEmpty else { return [] }
        let due = StoragePolicy.removals(books.map(policyItem), rules: settings.rules, now: now)
        for removal in due {
            guard let book = books.first(where: { $0.documentID == removal.id }) else { continue }
            offload(book, automatic: true, now: now)
        }
        if !due.isEmpty { log.notice("storage rules removed \(due.count) book downloads") }
        return due.map(\.id)
    }

    // MARK: Remove Download (offload)

    /// Remove this book's audio from this device (all of it, or `chapters`), keeping the book:
    /// its row, its text, its voice and where the listener is. It comes back with Download
    /// Again. Returns the bytes freed.
    @discardableResult
    func offload(_ book: StoredBook, chapters: [Int]? = nil, automatic: Bool = false, now: Date = Date()) -> Int {
        guard book.canGetBack else { return 0 }
        let wanted = chapters.map(Set.init)
        let items = book.present.filter { wanted?.contains($0.clipping.chapterIndex ?? -1) ?? true }
        guard !items.isEmpty else { return 0 }
        let bytes = items.reduce(0) { $0 + Self.size($1.url) }
        let indices = items.compactMap(\.clipping.chapterIndex)
        // Noted before the files go, so a collection running meanwhile cannot fetch them back.
        if let jobID = book.homeServerJobID { homeServer.offload(jobID: jobID, chapters: indices) }
        dropFromQueue(items.map(\.asSong.id))
        for item in items { clippings.remove(id: item.id, dismissing: false) }
        record(BookStorage.Removed(id: UUID().uuidString.lowercased(), documentID: book.documentID, title: book.title,
                                   author: book.author, bytes: bytes, removedAt: now, kind: .offloaded,
                                   automatic: automatic, chapters: indices.sorted()))
        log.notice("removed the download of \(indices.count) chapters of a book, \(bytes) bytes\(automatic ? " (rule)" : "", privacy: .public)")
        return bytes
    }

    /// The book's audio is back: its "download removed" entries have done their job.
    func cameBack(_ documentID: String) {
        saveRemoved(removed.filter { !($0.documentID == documentID && $0.kind == .offloaded) })
    }

    // MARK: Delete, Restore, purge

    /// What a held chapter was, to adopt it back as it was.
    private struct HeldChapter: Codable {
        var file: String
        var title: String
        var source: String?
        var durationSeconds: Double?
        var text: String?
        var sha256: String?
        var documentTitle: String
        var author: String?
        var chapterIndex: Int
        var chapterTitle: String
    }

    private struct Held: Codable {
        var chapters: [HeldChapter]
        /// The app's own record of the book (the Mac's render job), handed back on Restore.
        var payload: Data?
    }

    /// Delete a book from this device, or everywhere: its chapters leave Clippings now, and
    /// their audio is held for a week so Restore can bring the book back. `payload` is whatever
    /// the app wants back on Restore (the Mac keeps the render job).
    func delete(_ book: StoredBook, everywhere: Bool, payload: Data? = nil, now: Date = Date()) {
        let id = UUID().uuidString.lowercased()
        let folder = holdDirectory.appendingPathComponent(id, isDirectory: true)
        var held: [HeldChapter] = []
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for item in book.present where item.isPresent {
                let index = item.clipping.chapterIndex ?? held.count
                let file = "chapter-\(index + 1).\(item.url.pathExtension.isEmpty ? "m4a" : item.url.pathExtension)"
                try FileManager.default.moveItem(at: item.url, to: folder.appendingPathComponent(file))
                held.append(HeldChapter(file: file, title: item.clipping.title, source: item.clipping.source,
                                        durationSeconds: item.clipping.durationSeconds, text: item.clipping.text,
                                        sha256: item.clipping.sha256,
                                        documentTitle: item.clipping.documentTitle ?? book.title,
                                        author: item.clipping.author ?? book.author, chapterIndex: index,
                                        chapterTitle: item.clipping.chapterTitle ?? item.clipping.title))
            }
            try JSONEncoder().encode(Held(chapters: held, payload: payload))
                .write(to: folder.appendingPathComponent("held.json"), options: .atomic)
        } catch {
            log.error("could not hold a deleted book's audio: \(String(describing: error), privacy: .public)")
        }
        let bytes = held.reduce(0) { $0 + Self.size(folder.appendingPathComponent($1.file)) }
        dropFromQueue(book.present.map(\.asSong.id))
        for item in book.present { clippings.remove(id: item.id, everywhere: everywhere) }
        record(BookStorage.Removed(id: id, documentID: book.documentID, title: book.title, author: book.author,
                                   bytes: bytes, removedAt: now, kind: .deleted, everywhere: everywhere,
                                   chapters: held.map(\.chapterIndex)))
    }

    /// Bring a deleted book back into Clippings as it was, and hand back the app's payload.
    /// Restoring a book deleted everywhere keeps it again here, which the shared ledger then
    /// carries like any clipping kept again.
    @discardableResult
    func restore(_ entry: BookStorage.Removed) throws -> Data? {
        let folder = holdDirectory.appendingPathComponent(entry.id, isDirectory: true)
        let held = try JSONDecoder().decode(Held.self, from: Data(contentsOf: folder.appendingPathComponent("held.json")))
        for chapter in held.chapters {
            let url = folder.appendingPathComponent(chapter.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try clippings.adopt(url, title: chapter.title, sourceName: chapter.source,
                                durationSeconds: chapter.durationSeconds, text: chapter.text, sha256: chapter.sha256,
                                chapter: .init(documentID: entry.documentID, documentTitle: chapter.documentTitle,
                                               author: chapter.author, chapterIndex: chapter.chapterIndex,
                                               chapterTitle: chapter.chapterTitle))
        }
        try? FileManager.default.removeItem(at: folder)
        saveRemoved(removed.filter { $0.id != entry.id })
        log.notice("restored a deleted book, \(held.chapters.count) chapters")
        return held.payload
    }

    /// Delete now what would otherwise wait out its week.
    func purgeNow(_ entry: BookStorage.Removed) {
        try? FileManager.default.removeItem(at: holdDirectory.appendingPathComponent(entry.id, isDirectory: true))
        saveRemoved(removed.filter { $0.id != entry.id })
    }

    /// Entries a week old go, and a deleted book's held audio with them.
    func purge(now: Date = Date()) {
        let expired = BookStorage.expired(removed, now: now)
        guard !expired.isEmpty else { return }
        for entry in expired {
            try? FileManager.default.removeItem(at: holdDirectory.appendingPathComponent(entry.id, isDirectory: true))
        }
        let gone = Set(expired.map(\.id))
        saveRemoved(removed.filter { !gone.contains($0.id) })
        log.notice("purged \(expired.count) recently removed entries")
    }

    // MARK: Suggestions (M6.5)

    /// The suggestion Clippings shows now, if any: at most one a week, kept until answered.
    func suggestion(for books: [StoredBook], freeBytes: Int?, now: Date = Date()) -> BookStorage.Suggestion? {
        let (suggestion, updated) = BookStorage.offer(books.map(policyItem), settings: settings, now: now, freeBytes: freeBytes)
        if updated != settings { change { $0 = updated } }
        return suggestion
    }

    /// Answer the suggestion: remove now, remove and set the rule, or keep. Returns the bytes
    /// freed.
    @discardableResult
    func answer(_ answer: BookStorage.Answer, to suggestion: BookStorage.Suggestion, books: [StoredBook],
                now: Date = Date()) -> Int {
        let (ids, updated) = BookStorage.answer(answer, to: suggestion, settings: settings)
        change { $0 = updated }
        return books.filter { ids.contains($0.documentID) }.reduce(0) { $0 + offload($1, now: now) }
    }

    /// Free space on the volume that holds `url`, as iOS and macOS count it for things the
    /// person asked for.
    nonisolated static func freeBytes(at url: URL) -> Int? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { Int($0) }
    }

    // MARK: Plumbing

    private func change(_ update: (inout BookStorage.Settings) -> Void) {
        var copy = settings
        update(&copy)
        guard copy != settings else { return }
        settings = copy
        BookStorage.save(copy, to: defaults)
    }

    private func record(_ entry: BookStorage.Removed) {
        saveRemoved(removed + [entry])
    }

    private func saveRemoved(_ entries: [BookStorage.Removed]) {
        removed = entries.sorted { $0.removedAt > $1.removedAt }
        _ = removedStore.save(removed)
    }

    private static func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}
