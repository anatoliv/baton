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
/// The gateway's summary does not carry the words, and Clippings needs them to file a chapter
/// as part of a book, so each submission keeps a `Record` beside the audio. A book another
/// device sent is adopted the same way: the listing names its document, the shaped
/// book comes down once, and from then on it is a record like this device's own, under the job
/// id the home server gave it. Collection is idempotent: a chapter already in Clippings is never
/// fetched again, and a download is verified against the gateway's digest before it is adopted.
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
        /// "Chapter 1 is ready" has been said for this book, or needed no saying: its
        /// first chapter came down with the app in front, or came back by Download Again, Render
        /// Again or a corrected pronunciation. Written only where `firstChapterArrived` is set (the
        /// phone); absent on the Mac and in files written before TBX-10982.
        var firstChapterAnnounced: Bool? = nil
        /// Another device sent this book and this one adopted it from the home server's listing
        ///: the row says "Made on the home server". Nil for a book sent from here.
        var adopted: Bool? = nil

        var offloaded: Set<Int> { Set(offloadedChapters ?? []) }
    }

    enum Problem: Error, CustomStringConvertible {
        case notConfigured
        case nothingToRender
        var description: String {
            switch self {
            case .notConfigured: return "the Baton server is not set up in Settings"
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
    /// Books removed from this device only, by document id: the home server keeps
    /// them for the other devices, and this one does not adopt them again from its listing.
    @ObservationIgnored private let hidden: VersionedStore<[String]>
    /// Where each submitted book's shaped text is kept, so a book the home server has since
    /// removed can be made again ("Render Again", M6.3). Small: words and voice choices only.
    @ObservationIgnored private let preparedDirectory: URL
    @ObservationIgnored private let clippings: ClippingStore
    /// Books being made again in another voice, here or on the home server: the
    /// Mac's own renderer shares it, so one record keeps both apps' changes.
    let voiceChanges: BookVoiceChanges
    /// Read-along timing of the chapters on this device, by audio digest.
    @ObservationIgnored let readAlong: ReadAlongStore
    @ObservationIgnored private let gateway: @MainActor () -> GatewayBookClient?
    @ObservationIgnored private let log: Logger
    @ObservationIgnored private let pollInterval: Duration
    /// Whether this device makes the book from `documentID` itself (the Mac's own renderer), so
    /// it is not adopted from the home server in a second copy. The phone makes none.
    @ObservationIgnored var isMadeHere: @MainActor (String) -> Bool = { _ in false }
    @ObservationIgnored private var collecting = false
    @ObservationIgnored private var watcher: Task<Void, Never>?
    /// What the running watch tells after each round, kept so it can restart at another pace.
    @ObservationIgnored private var watching: (@MainActor () -> Void)?
    /// How often the watch asks while the app is in the background (the phone, TBX-10982).
    @ObservationIgnored private let backgroundPollInterval: Duration
    /// The app is not in front: the watch asks every `backgroundPollInterval` instead.
    @ObservationIgnored private var inBackground = false

    /// Says "Chapter 1 is ready" (the phone, M5.4). Called once per book, by whichever collection
    /// brings its first chapter down: the watch, an activation or the background refresh. The
    /// record remembers it before the call, so no later round, relaunch or Download Again says it
    /// twice; whether to say it at all (never with the app in front) is the phone's to decide.
    /// Nil on the Mac, which announces nothing and keeps its records as before.
    @ObservationIgnored var firstChapterArrived: (@MainActor (Record) -> Void)?

    init(directory: URL, clippings: ClippingStore,
         gateway: @escaping @MainActor () -> GatewayBookClient?,
         log: Logger = Logger(subsystem: "io.tonebox.baton", category: "documents"),
         pollInterval: Duration = .seconds(5), backgroundPollInterval: Duration = .seconds(60)) {
        self.store = VersionedStore<[Record]>(fileURL: directory.appendingPathComponent("home-server-books.json"),
                                              currentVersion: 1, keepBackup: true, log: log)
        self.pendingDeletes = VersionedStore<[String]>(
            fileURL: directory.appendingPathComponent("home-server-books-pending-deletes.json"),
            currentVersion: 1, log: log)
        self.hidden = VersionedStore<[String]>(
            fileURL: directory.appendingPathComponent("home-server-books-hidden.json"),
            currentVersion: 1, log: log)
        self.preparedDirectory = directory.appendingPathComponent("home-server-books", isDirectory: true)
        self.readAlong = ReadAlongStore.inBooks(directory)
        self.voiceChanges = BookVoiceChanges(directory: directory, clippings: clippings, log: log)
        self.clippings = clippings
        self.gateway = gateway
        self.log = log
        self.pollInterval = pollInterval
        self.backgroundPollInterval = backgroundPollInterval
    }

    var records: [Record] { store.load() ?? [] }

    /// Job ids of books stopped here that the home server has still to delete.
    var pendingDeleteIDs: [String] { pendingDeletes.load() ?? [] }

    /// Document ids of books removed from this device only, which it does not adopt again.
    var hiddenDocumentIDs: [String] { hidden.load() ?? [] }

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
                if status == 404 { problem = "the Baton server does not make books" }
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
        // Sent again from here: a book removed from this device earlier is wanted again.
        unhide(documentID: book.documentID)
        var kept = records.filter { $0.jobID != summary.id }
        kept.append(Self.record(of: book, jobID: summary.id, createdAt: Date()))
        save(kept)
        savePreparedBook(book, jobID: summary.id)
        summaries[summary.id] = summary
        log.notice("sent \"\(book.title, privacy: .public)\" to the home server: \(book.chapters.count) chapters")
        return summary.id
    }

    private static func record(of book: PreparedBook, jobID: String, createdAt: Date, adopted: Bool? = nil) -> Record {
        Record(jobID: jobID, documentID: book.documentID, title: book.title, author: book.author,
               chapterTitles: book.chapters.map(\.title),
               chapterTexts: book.chapters.map { $0.segments.map(\.text).joined(separator: " ") },
               createdAt: createdAt, adopted: adopted)
    }

    // MARK: - Books another device sent

    /// Adopt the home server's books that this device did not send, so a book made from the Mac
    /// is on the iPhone too, and the reverse. Each comes down as its shaped book, once, and is
    /// then remembered like this device's own: same job id (nothing is submitted), same
    /// document id, so the shared ledger carries its place and "finished" between devices.
    ///
    /// Left alone: a book this device already has under its document (its own, perhaps in
    /// another voice), one removed from this device only, one whose delete is waiting here, a
    /// book that failed, and every book from a gateway that does not name its document yet.
    @discardableResult
    func adoptOthers() async -> [Record] {
        guard let client = gateway() else { return [] }
        let listing: GatewayBookClient.Listing
        do {
            listing = try await client.list()
        } catch {
            log.error("could not list the home server's books: \(String(describing: error), privacy: .public)")
            return []
        }
        let skipped = Set(hiddenDocumentIDs)
        let pending = Set(pendingDeleteIDs)
        await follow(listing, pending: pending)
        var knownJobs = Set(records.map(\.jobID))
        var knownDocuments = Set(records.map(\.documentID))
        var adopted: [Record] = []
        // Newest first, as the home server lists them: of two books from one document, the
        // newer is the one adopted.
        for summary in listing.books where !knownJobs.contains(summary.id) && !pending.contains(summary.id) {
            guard summary.status != .failed, let documentID = summary.documentID,
                  !knownDocuments.contains(documentID), !skipped.contains(documentID),
                  !isMadeHere(documentID) else { continue }
            let book: PreparedBook
            do {
                book = try await client.preparedBook(summary.id)
            } catch {
                log.error("book \(summary.id.prefix(12), privacy: .public): could not adopt it from the home server: \(String(describing: error), privacy: .public)")
                continue
            }
            guard book.documentID == documentID else { continue }
            var record = Self.record(of: book, jobID: summary.id, createdAt: summary.createdAt, adopted: true)
            // Another device made it, so this one does not say "Chapter 1 is ready" for it.
            if firstChapterArrived != nil { record.firstChapterAnnounced = true }
            save(records.filter { $0.jobID != summary.id } + [record])
            savePreparedBook(book, jobID: summary.id)
            summaries[summary.id] = summary
            knownJobs.insert(summary.id)
            knownDocuments.insert(documentID)
            adopted.append(record)
            log.notice("book \(summary.id.prefix(12), privacy: .public): adopted from the home server, \(book.chapters.count) chapters")
        }
        return adopted
    }

    /// A book this device has whose job the home server no longer lists, while it lists another
    /// job for the same document: another device made it again, in another voice or
    /// with a corrected pronunciation, and deleted the job this device knew. The record follows
    /// the newest such job, and each chapter here is replaced in its row as the new audio comes
    /// down, so the book here changes voice too rather than keeping the old one for ever.
    private func follow(_ listing: GatewayBookClient.Listing, pending: Set<String>) async {
        guard let client = gateway() else { return }
        let listed = Set(listing.books.map(\.id))
        for record in records where !listed.contains(record.jobID) && record.serverRemoved != true {
            // Newest first, as the home server lists them.
            guard let summary = listing.books.first(where: {
                $0.documentID == record.documentID && $0.status != .failed && !pending.contains($0.id)
            }) else { continue }
            let book: PreparedBook
            do {
                book = try await client.preparedBook(summary.id)
            } catch {
                log.error("book \(summary.id.prefix(12), privacy: .public): could not follow it on the home server: \(String(describing: error), privacy: .public)")
                continue
            }
            guard book.documentID == record.documentID else { continue }
            let before = preparedBook(forJob: record.jobID)
            let present = (0..<record.chapterTitles.count).filter {
                !record.offloaded.contains($0) && clippings.item(documentID: record.documentID, chapterIndex: $0) != nil
            }
            move(record.jobID, to: summary, book: book)
            if !present.isEmpty {
                voiceChanges.begin(documentID: record.documentID, voice: book.voices.narrator,
                                   previousVoices: before?.voices ?? book.voices, jobID: summary.id,
                                   pending: present, startedHere: false)
            }
            log.notice("book \(record.jobID.prefix(12), privacy: .public): made again on another device, now \(summary.id.prefix(12), privacy: .public)")
        }
    }

    /// Remove a book from this device only: forget it here and leave the home
    /// server's copy for the other devices, without adopting it again from the next listing.
    /// Delete Everywhere is `cancel(jobID:)`, which deletes it there too.
    func hide(documentID: String) {
        var all = hiddenDocumentIDs
        if !all.contains(documentID) {
            all.append(documentID)
            _ = hidden.save(all)
        }
        for record in records where record.documentID == documentID { forget(jobID: record.jobID) }
    }

    /// A book removed from this device only is wanted here again: sent again, or restored.
    func unhide(documentID: String) {
        let all = hiddenDocumentIDs
        guard all.contains(documentID) else { return }
        _ = hidden.save(all.filter { $0 != documentID })
    }

    /// Every chapter is here, apart from those removed on purpose.
    func isCollected(_ record: Record) -> Bool {
        let offloaded = record.offloaded
        // A chapter here in the old voice is still to come while the book is made again.
        if let change = voiceChanges.change(forDocument: record.documentID), change.jobID == record.jobID,
           change.pending.contains(where: { !offloaded.contains($0) }) { return false }
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

    /// Whether this device kept the shaped book, without reading it: for a menu drawn often.
    func hasPreparedBook(forJob jobID: String) -> Bool {
        preparedURL(jobID).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
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
        // A chapter removed while the book is made again is no longer waiting for its new voice.
        if let documentID = record(forJob: jobID)?.documentID {
            for index in chapters { voiceChanges.settle(documentID, chapterIndex: index) }
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
        settleFirstChapter(jobID)
        await collect()
    }

    /// Send the saved book to the home server again, to be made afresh: for a book the server
    /// has removed. Its chapters come down as they are ready, as the first time.
    func renderAgain(jobID: String) async throws {
        guard let client = gateway() else { throw Problem.notConfigured }
        guard let book = preparedBook(forJob: jobID) else { throw Problem.nothingToRender }
        let summary = try await client.submit(book)
        // A pronunciation saved in place (one the book never says) changed the saved book's id
        // without sending it; the book comes back under the id the home server now gives it.
        move(jobID, to: summary, book: book)
        update(summary.id) { record in
            record.offloadedChapters = nil
            record.serverRemoved = nil
        }
        settleFirstChapter(summary.id)
        log.notice("book \(jobID.prefix(12), privacy: .public): sent to the home server to be made again")
    }

    /// Send a changed version of a book to the home server under its own id (a corrected
    /// pronunciation, TBX-10964). The home server makes the whole book again, every chunk
    /// whose words did not change straight from its chunk cache, and this device collects
    /// only the chapters the caller takes out of Clippings: the others are already here. The
    /// record keeps its document, its date and the chapters removed here on purpose; the old
    /// job is deleted on the home server once the new one is there. Returns the new job id.
    @discardableResult
    func resubmit(jobID: String, as book: PreparedBook) async throws -> String {
        guard let client = gateway() else { throw Problem.notConfigured }
        guard record(forJob: jobID) != nil else { throw Problem.nothingToRender }
        let summary = try await client.submit(book)
        move(jobID, to: summary, book: book)
        update(summary.id) { $0.serverRemoved = nil }
        settleFirstChapter(summary.id)
        log.notice("book \(jobID.prefix(12), privacy: .public): sent to the home server again as \(summary.id.prefix(12), privacy: .public)")
        if summary.id != jobID { await cancelRemote(jobID: jobID) }
        return summary.id
    }

    /// Make the whole book again in another narrator's voice (Change Voice, TBX-10989), through
    /// `resubmit`: the home server makes it under the job id the new voice gives it, every chunk
    /// a new one, and the record follows that id, keeping its document (so the place in the book
    /// and "finished" stay), its pronunciations and its cast. The chapters here keep playing in
    /// the old voice until each new one comes down and takes its place (`collect`). Returns the
    /// new job id; the same voice changes nothing.
    @discardableResult
    func changeVoice(jobID: String, to narrator: String) async throws -> String {
        guard let record = record(forJob: jobID), let book = preparedBook(forJob: jobID) else { throw Problem.nothingToRender }
        let updated = book.inVoice(narrator)
        guard BookJob.id(for: updated) != jobID else { return jobID }
        let present = (0..<record.chapterTitles.count).filter {
            !record.offloaded.contains($0) && clippings.item(documentID: record.documentID, chapterIndex: $0) != nil
        }
        // Sent first: a home server that is away leaves the book as it was.
        let newID = try await resubmit(jobID: jobID, as: updated)
        // With nothing here yet, every chapter simply comes down in the new voice.
        if !present.isEmpty {
            voiceChanges.begin(documentID: record.documentID, voice: narrator, previousVoices: book.voices,
                               jobID: newID, pending: present, startedHere: true)
        }
        return newID
    }

    /// Stop making a book again in another voice: the home server goes back to the voices the
    /// book had (its chunks are cached there, so that is quick) and each chapter already
    /// replaced here gets its old audio back. A home server that is away leaves the change
    /// running, to be stopped again.
    func cancelVoiceChange(documentID: String) async throws {
        guard let change = voiceChanges.change(forDocument: documentID) else { return }
        guard let record = record(forDocument: documentID), let book = preparedBook(forJob: record.jobID) else {
            voiceChanges.abandon(documentID)
            return
        }
        var back = book
        back.voices = change.previousVoices
        if BookJob.id(for: back) != record.jobID {
            _ = try await resubmit(jobID: record.jobID, as: back)
        }
        voiceChanges.abandon(documentID)
    }

    /// The voices the home server offers (`GET /v1/voices`, TBX-10962), or nil when it cannot
    /// be asked or is older than that route.
    func voices() async -> [String]? {
        guard let client = gateway(), let list = try? await client.voices() else { return nil }
        return list.specs
    }

    /// Keep a changed version of a book that does not have to be made again (a pronunciation
    /// for a word it never says), under the job it has.
    func replacePreparedBook(_ book: PreparedBook, jobID: String) {
        guard record(forJob: jobID) != nil else { return }
        savePreparedBook(book, jobID: jobID)
    }

    /// The record and the saved book now belong to the job the home server answered with.
    private func move(_ jobID: String, to summary: BookJob.Summary, book: PreparedBook) {
        if summary.id != jobID {
            var all = records.filter { $0.jobID != summary.id }
            if let index = all.firstIndex(where: { $0.jobID == jobID }) { all[index].jobID = summary.id }
            save(all)
            summaries[jobID] = nil
            if let url = preparedURL(jobID) { try? FileManager.default.removeItem(at: url) }
        }
        savePreparedBook(book, jobID: summary.id)
        summaries[summary.id] = summary
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

    /// No "Chapter 1 is ready" for this book from now on. Only where announcing is wired (the
    /// phone), so the Mac's records stay as they were.
    private func settleFirstChapter(_ jobID: String) {
        guard firstChapterArrived != nil else { return }
        update(jobID) { $0.firstChapterAnnounced = true }
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
        // "Already here?" is asked of Clippings below, so Clippings must have read its folder
        // first. Right after a launch it may not have, and the first ready chapter then came
        // down a second time and was kept twice.
        clippings.loadIfNeeded()
        await retryPendingDeletes()
        await adoptOthers()
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
            // The voice its chapters are in, for the clipping; read once per book.
            var narrator: String??
            for chapter in summary.chapters where chapter.state == "ready" && !record.offloaded.contains(chapter.index) {
                let existing = clippings.item(documentID: record.documentID, chapterIndex: chapter.index)
                // A chapter here in the old voice is replaced by the new one in its row.
                let replacing = existing != nil
                    && voiceChanges.isPending(record.documentID, chapterIndex: chapter.index, jobID: record.jobID)
                guard existing == nil || replacing else { continue }
                if replacing, let sha = chapter.sha256, existing?.clipping.sha256 == sha {
                    voiceChanges.settle(record.documentID, chapterIndex: chapter.index)
                    continue
                }
                if narrator == nil { narrator = .some(preparedBook(forJob: record.jobID)?.voices.narrator) }
                let temporary = FileManager.default.temporaryDirectory
                    .appendingPathComponent("baton-chapter-\(UUID().uuidString).m4a")
                do {
                    let file = try await client.downloadChapter(record.jobID, number: chapter.index + 1, to: temporary)
                    let title = record.chapterTitles.indices.contains(chapter.index) ? record.chapterTitles[chapter.index] : chapter.title
                    if replacing {
                        try voiceChanges.replace(documentID: record.documentID, chapterIndex: chapter.index, with: file.url,
                                                 seconds: file.seconds ?? chapter.seconds, sha256: file.sha256)
                    } else {
                        try clippings.adopt(file.url, title: title, sourceName: record.author,
                                            durationSeconds: file.seconds ?? chapter.seconds,
                                            text: record.chapterTexts.indices.contains(chapter.index) ? record.chapterTexts[chapter.index] : nil,
                                            sha256: file.sha256,
                                            chapter: .init(documentID: record.documentID, documentTitle: record.title,
                                                           author: record.author, chapterIndex: chapter.index, chapterTitle: title),
                                            voice: narrator ?? nil)
                        // Gone from here while the book was made again: it came down new.
                        voiceChanges.settle(record.documentID, chapterIndex: chapter.index)
                    }
                    // Read-along timing comes down with the chapter when the home server kept
                    // it; a gateway older than it has none, and the text shows without a highlight.
                    if let timing = try? await client.chapterTiming(record.jobID, number: chapter.index + 1) {
                        try? readAlong.save(timing, forAudio: file.sha256)
                    }
                    if replacing {
                        log.notice("book \(record.jobID.prefix(12), privacy: .public): chapter \(chapter.index + 1) replaced in its new voice")
                        continue
                    }
                    arrivals.append(Arrival(record: record, chapterIndex: chapter.index))
                    if chapter.index == 0, record.firstChapterAnnounced != true, let announce = firstChapterArrived {
                        settleFirstChapter(record.jobID)
                        announce(record)
                    }
                    log.notice("book \(record.jobID.prefix(12), privacy: .public): chapter \(chapter.index + 1) collected from the home server")
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    log.error("book \(record.jobID.prefix(12), privacy: .public): could not collect chapter \(chapter.index + 1): \(String(describing: error), privacy: .public)")
                }
            }
        }
        return arrivals
    }

    /// A chapter's read-along timing: the copy on this device, else, for a chapter
    /// of a book made on the home server, asked of it once and kept. Nil when there is none,
    /// and the read-along view then shows the text without a highlight.
    func readAlongTiming(for item: ClippingStore.Item) async -> ReadAlongTiming? {
        if let local = readAlong.load(forAudio: item.clipping.sha256) { return local }
        guard let sha = item.clipping.sha256, let documentID = item.clipping.documentID,
              let index = item.clipping.chapterIndex, let record = record(forDocument: documentID),
              let client = gateway(),
              let timing = try? await client.chapterTiming(record.jobID, number: index + 1) else { return nil }
        // Only when it is this audio's: a chapter made again in another voice has other times.
        guard summaries[record.jobID]?.chapters.first(where: { $0.index == index })?.sha256.map({ $0 == sha }) ?? true
        else { return nil }
        try? readAlong.save(timing, forAudio: sha)
        return timing
    }

    /// Poll the home server every few seconds while a book there is not fully collected, calling
    /// `changed` after each round so the owner can refresh what it shows.
    func watchIfNeeded(changed: @escaping @MainActor () -> Void) {
        guard watcher == nil, hasUncollected else { return }
        watching = changed
        let interval = inBackground ? backgroundPollInterval : pollInterval
        watcher = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled else { return }
            await self.collect()
            // Stopped while collecting: a newer watcher may own the slot by now. Leave it.
            guard !Task.isCancelled else { return }
            self.watcher = nil
            changed()
            if self.hasUncollected { self.watchIfNeeded(changed: changed) } else { self.watching = nil }
        }
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
        watching = nil
    }

    /// The app left the foreground (the phone, TBX-10982): the watch keeps going, once a minute
    /// instead of every few seconds. It only runs while something keeps the process alive in the
    /// background, such as music playing; otherwise iOS suspends the app and the background
    /// refresh takes over. Alive, a status request a minute is a small cost in battery and radio
    /// time (the 5-second pace would wake the radio twelve times as often), and it brings chapter 1
    /// down, announced by `firstChapterArrived`, within a minute of it being ready rather than
    /// whenever iOS next grants a refresh.
    func enterBackground() {
        guard !inBackground else { return }
        inBackground = true
        restartWatchAtCurrentPace()
    }

    /// Back in front: the watch returns to `pollInterval` and asks again straight after it.
    func enterForeground() {
        guard inBackground else { return }
        inBackground = false
        restartWatchAtCurrentPace()
    }

    /// A watch waiting out its interval starts again at the current one. One in the middle of a
    /// round is left alone, so a download is never cut off: its next round takes the new pace.
    private func restartWatchAtCurrentPace() {
        guard watcher != nil, !collecting, let changed = watching else { return }
        watcher?.cancel()
        watcher = nil
        watchIfNeeded(changed: changed)
    }

    /// Stop making the book and forget it here. Chapters already in Clippings stay there. The
    /// delete is remembered before it is sent, so a home server that is away (or fails) is asked
    /// again on the next refresh rather than keeping the book for ever.
    func cancel(jobID: String) async {
        forget(jobID: jobID)
        await cancelRemote(jobID: jobID)
    }

    /// Delete a job on the home server, remembered first so an absent home server is asked
    /// again on the next refresh.
    private func cancelRemote(jobID: String) async {
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
        if let record = record(forJob: jobID) { voiceChanges.drop(record.documentID) }
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
/// The phone passes the home server's list (`GET /v1/voices`, TBX-10962); without a list (a
/// gateway from before that route) the configured default stands, so a book is never sent to a
/// voice nobody checked is there.
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
        // Removed from this device only and restored: the home server's copy is this device's
        // again, so the next listing adopts it and Download Again works.
        homeServer.unhide(documentID: entry.documentID)
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

// MARK: - Change Voice
//
// Here rather than in a file of its own for the reason above: both apps compile this file.

/// A book being made again in another voice, the same on both apps. Whoever makes
/// it (this Mac's renderer or the home server) makes the whole book in the new voice under a new
/// job, and each chapter on this device is **replaced in place** as its new audio lands: one row
/// throughout, the old voice playable until the new one is here, and the place in the book
/// untouched, since the shared ledger keeps it by document, chapter and time.
///
/// The old audio of each replaced chapter is set aside until the whole book is in the new voice,
/// so Stop puts the book back as it was. Small and on this device only: it never travels.
@MainActor
@Observable
final class BookVoiceChanges {
    /// A replaced chapter's old audio, waiting in the hold folder.
    struct Held: Codable, Equatable, Sendable {
        var chapterIndex: Int
        var audio: ClippingStore.PreviousAudio
    }

    struct Change: Codable, Equatable, Sendable {
        var documentID: String
        /// The narrator it is being made again in, as an `"engine:voice"` spec.
        var voice: String
        /// The voices the book had, which Stop goes back to.
        var previousVoices: VoicePlan
        /// The job making it in the new voice.
        var jobID: String
        /// The job it was made by before, kept until the change ends so Stop can go back to it
        /// without making anything (this Mac's renderer). Nil on the home server, which deletes
        /// it at once and makes the old voice again from its chunk cache on Stop.
        var previousJobID: String? = nil
        /// Chapters on this device still in the old voice, waiting for their new audio.
        var pending: [Int]
        var held: [Held] = []
        var startedAt: Date
        /// Started on this device. A change another device started is followed here (its
        /// chapters replaced as they land), and stopped from there.
        var startedHere: Bool
    }

    private(set) var all: [Change]
    @ObservationIgnored private let store: VersionedStore<[Change]>
    @ObservationIgnored private let holdDirectory: URL
    @ObservationIgnored private let clippings: ClippingStore
    @ObservationIgnored private let log: Logger

    init(directory: URL, clippings: ClippingStore, log: Logger) {
        self.store = VersionedStore<[Change]>(fileURL: directory.appendingPathComponent("voice-changes.json"),
                                              currentVersion: 1, keepBackup: true, log: log)
        self.holdDirectory = directory.appendingPathComponent("voice-change-hold", isDirectory: true)
        self.clippings = clippings
        self.log = log
        self.all = store.load() ?? []
    }

    func change(forDocument documentID: String) -> Change? { all.first { $0.documentID == documentID } }

    /// Start, or restart in a third voice: a book changed again before the first change ended
    /// keeps the audio it had before either, so Stop still goes back to the voice it started in.
    func begin(documentID: String, voice: String, previousVoices: VoicePlan, jobID: String, previousJobID: String? = nil,
               pending: [Int], startedHere: Bool, now: Date = Date()) {
        let earlier = change(forDocument: documentID)
        let change = Change(documentID: documentID, voice: voice,
                            previousVoices: earlier?.previousVoices ?? previousVoices, jobID: jobID,
                            previousJobID: earlier == nil ? previousJobID : earlier?.previousJobID,
                            pending: pending.sorted(), held: earlier?.held ?? [], startedAt: now,
                            startedHere: startedHere || earlier?.startedHere == true)
        save(all.filter { $0.documentID != documentID } + [change])
        log.notice("book \(jobID.prefix(12), privacy: .public): making it again in \(voice, privacy: .public), \(pending.count) chapters to replace")
    }

    /// Whether `chapterIndex` of `documentID` is on this device in the old voice and waits for
    /// the new audio from `jobID`.
    func isPending(_ documentID: String, chapterIndex: Int, jobID: String) -> Bool {
        guard let change = change(forDocument: documentID), change.jobID == jobID else { return false }
        return change.pending.contains(chapterIndex)
    }

    /// The new audio for a chapter has landed: it takes the old one's place in the same row, the
    /// old one set aside (the first time only: a chapter replaced twice keeps its first voice
    /// for Stop). The change ends when no chapter is left in the old voice.
    func replace(documentID: String, chapterIndex: Int, with file: URL, seconds: Double?, sha256: String?) throws {
        guard var change = change(forDocument: documentID) else { return }
        guard let item = clippings.item(documentID: documentID, chapterIndex: chapterIndex) else {
            settle(documentID, chapterIndex: chapterIndex)
            return
        }
        let alreadyHeld = change.held.contains { $0.chapterIndex == chapterIndex }
        let (_, previous) = try clippings.replaceAudio(id: item.id, with: file, durationSeconds: seconds, sha256: sha256,
                                                       voice: change.voice,
                                                       holdingPreviousIn: alreadyHeld ? nil : hold(documentID))
        if let previous { change.held.append(Held(chapterIndex: chapterIndex, audio: previous)) }
        change.pending.removeAll { $0 == chapterIndex }
        save(all.map { $0.documentID == documentID ? change : $0 })
        log.notice("book \(change.jobID.prefix(12), privacy: .public): chapter \(chapterIndex + 1) is now in \(change.voice, privacy: .public)")
        if change.pending.isEmpty { finish(documentID) }
    }

    /// A chapter that needs no new audio here after all: it left this device, or its audio
    /// is already the new one.
    func settle(_ documentID: String, chapterIndex: Int) {
        guard var change = change(forDocument: documentID), change.pending.contains(chapterIndex) else { return }
        change.pending.removeAll { $0 == chapterIndex }
        save(all.map { $0.documentID == documentID ? change : $0 })
        if change.pending.isEmpty { finish(documentID) }
    }

    /// Every chapter is in the new voice: the old audio goes.
    func finish(_ documentID: String) {
        guard let change = change(forDocument: documentID) else { return }
        try? FileManager.default.removeItem(at: hold(documentID))
        save(all.filter { $0.documentID != documentID })
        log.notice("book \(change.jobID.prefix(12), privacy: .public): every chapter is in \(change.voice, privacy: .public)")
    }

    /// Stop: each chapter already replaced gets its old audio back, in its row. Returns the
    /// change that was stopped.
    @discardableResult
    func abandon(_ documentID: String) -> Change? {
        guard let change = change(forDocument: documentID) else { return nil }
        let folder = hold(documentID)
        for held in change.held {
            guard let item = clippings.item(documentID: documentID, chapterIndex: held.chapterIndex) else { continue }
            let file = folder.appendingPathComponent(held.audio.file)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                try clippings.replaceAudio(id: item.id, with: file, durationSeconds: held.audio.durationSeconds,
                                           sha256: held.audio.sha256, voice: held.audio.voice)
            } catch {
                log.error("book: could not put chapter \(held.chapterIndex + 1) back in its old voice: \(String(describing: error), privacy: .public)")
            }
        }
        try? FileManager.default.removeItem(at: folder)
        save(all.filter { $0.documentID != documentID })
        log.notice("book \(change.jobID.prefix(12), privacy: .public): voice change stopped, \(change.held.count) chapters back in their old voice")
        return change
    }

    /// The book is gone from this device: nothing to go back to.
    func drop(_ documentID: String) {
        guard change(forDocument: documentID) != nil else { return }
        try? FileManager.default.removeItem(at: hold(documentID))
        save(all.filter { $0.documentID != documentID })
    }

    private func hold(_ documentID: String) -> URL {
        holdDirectory.appendingPathComponent(BookStore.sanitize(documentID) ?? "book", isDirectory: true)
    }

    private func save(_ changes: [Change]) {
        all = changes
        _ = store.save(changes)
    }

    // MARK: Words, the same on both apps

    /// "af_sky on Kokoro", as the import sheet names a voice.
    nonisolated static func voiceLabel(_ spec: String) -> String {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return spec }
        return "\(parts[1]) on \(parts[0].prefix(1).uppercased() + parts[0].dropFirst())"
    }

    /// The row's line while a book is made again: "Making again in af_sky on
    /// Kokoro… chapter 1 of 2, 40%", from the new job's account of the first chapter still in
    /// the old voice. No dashes in user copy.
    nonisolated static func statusLine(_ change: Change, chapters: [BookJob.ChapterSummary]?, total: Int) -> String {
        let head = "Making again in \(voiceLabel(change.voice))…"
        guard let next = change.pending.min() else { return head }
        let of = "chapter \(next + 1) of \(total)"
        guard let chapter = chapters?.first(where: { $0.index == next }) else { return "\(head) waiting to make \(of)" }
        switch chapter.state {
        case "rendering": return "\(head) \(of), \(Int((chapter.progress * 100).rounded()))%"
        case "encoding", "ready": return "\(head) finishing \(of)"
        case "failed": return "\(head) \(of) failed"
        default: return "\(head) waiting to make \(of)"
        }
    }

    /// The voices the picker offers, in order: the one the book has now, then the voices that
    /// suit narrating a book in its language, best first (`VoiceCatalogue.candidates`), or every
    /// voice offered when none of them is described.
    nonisolated static func choices(current: String?, language: String?, available: [String]) -> [String] {
        let code = language.map { String($0.prefix(2)).lowercased() } ?? "en"
        var ordered = VoiceCatalogue.candidates(language: code, available: available).map(\.spec)
        if ordered.isEmpty { ordered = available }
        if let current { ordered.removeAll { $0 == current }; ordered.insert(current, at: 0) }
        return ordered
    }

    /// "American, female. Good for narration." from what the catalogue knows of a voice.
    nonisolated static func description(_ spec: String) -> String? {
        let voice = VoiceCatalogue.describe(spec)
        let kind = [voice.accent, voice.gender].compactMap { $0 }.joined(separator: ", ")
        var parts: [String] = []
        if !kind.isEmpty { parts.append(kind.prefix(1).uppercased() + kind.dropFirst() + ".") }
        if let tag = voice.tags.first(where: { $0.hasPrefix("good for") }) { parts.append(tag.prefix(1).uppercased() + tag.dropFirst() + ".") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// What the voice picker says about a book whose dialogue is voiced (G4).
    nonisolated static let castNote = "This book voices the dialogue with a cast. Only the narrator changes; each character keeps its voice."
}
