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
    }

    enum Problem: Error, CustomStringConvertible {
        case notConfigured
        var description: String { "the home server is not set up in Settings" }
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
        self.clippings = clippings
        self.gateway = gateway
        self.log = log
        self.pollInterval = pollInterval
    }

    var records: [Record] { store.load() ?? [] }

    func record(forDocument documentID: String) -> Record? { records.first { $0.documentID == documentID } }
    func record(forJob jobID: String) -> Record? { records.first { $0.jobID == jobID } }

    var isConfigured: Bool { gateway() != nil }

    /// Whether the home server makes books now: configured, answering, and books switched on there.
    func available() async -> Bool {
        guard let client = gateway() else { return false }
        do {
            let listing = try await client.list()
            problem = listing.available ? nil : listing.unavailableReason
            return listing.available
        } catch {
            problem = (error as? GatewayBookError)?.listenerReason ?? error.localizedDescription
            return false
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
        summaries[summary.id] = summary
        log.notice("sent \"\(book.title, privacy: .public)\" to the home server: \(book.chapters.count) chapters")
        return summary.id
    }

    func isCollected(_ record: Record) -> Bool {
        (0..<record.chapterTitles.count).allSatisfy { clippings.item(documentID: record.documentID, chapterIndex: $0) != nil }
    }

    var hasUncollected: Bool { records.contains { !isCollected($0) } }

    /// Ask the home server about every book not yet collected, and bring each chapter that is
    /// ready into Clippings, checked against its digest. A chapter already here is not fetched
    /// again. Returns what arrived in this round, chapter by chapter.
    @discardableResult
    func collect() async -> [Arrival] {
        guard !collecting, let client = gateway() else { return [] }
        collecting = true
        defer { collecting = false }
        var arrivals: [Arrival] = []
        for record in records where !isCollected(record) {
            let summary: BookJob.Summary
            do {
                summary = try await client.status(record.jobID)
                problem = nil
            } catch {
                problem = (error as? GatewayBookError)?.listenerReason ?? error.localizedDescription
                continue
            }
            summaries[record.jobID] = summary
            for chapter in summary.chapters where chapter.state == "ready" {
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

    /// Stop making the book and forget it here. Chapters already in Clippings stay there.
    func cancel(jobID: String) async {
        do { try await gateway()?.delete(jobID) } catch {
            log.error("could not delete book \(jobID.prefix(12), privacy: .public) on the home server: \(String(describing: error), privacy: .public)")
        }
        forget(jobID: jobID)
    }

    func forget(jobID: String) {
        save(records.filter { $0.jobID != jobID })
        summaries[jobID] = nil
    }

    func markFinished(jobID: String) async {
        try? await gateway()?.markFinished(jobID)
    }

    private func save(_ records: [Record]) { _ = store.save(records) }
}

/// The voice a book gets before a suggestion exists (M4.4): the same choice a reading makes. A
/// language with its own entry in the voice map gets that voice, and everything else, English
/// included, gets the configured default. One rule for both apps.
enum DocumentVoices {
    static func languageDefault(for document: ImportedDocument) -> String {
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
