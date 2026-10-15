import AppKit
import BatonDocuments
import BatonPlaybackKit
import BatonSpeech
import BatonSubsonicKit
import Foundation
import Observation
import OSLog
import UniformTypeIdentifiers

let documentsLog = Logger(subsystem: "io.tonebox.baton", category: "documents")

/// Books narrated on this Mac (`specs/document-clippings.md`, *Rendering*, `LocalBookRenderer`).
///
/// One `BookRenderer`, the same render loop the gateway runs: chapter 1 first, a content-addressed
/// chunk cache so a quit or a host outage resumes rather than restarts, and a host failure
/// **pauses** the book with its reason. It never finishes in the built-in voice; that would be a
/// voice change at minute 12 nobody asked for, and "finish in the built-in voice" is a later,
/// explicit choice.
///
/// The library's own job is the Mac's half: importing a file, choosing the language-default
/// voice, and moving each finished chapter into `ClippingStore` as a chapter of a book, where it
/// plays through the ordinary player. Moved, not copied: one copy of 30 MB, not two.
///
/// Behind `baton.documents.enabled` (off) until M3 is complete.
@MainActor
@Observable
final class DocumentLibrary {
    static let enabledKey = "baton.documents.enabled"
    static func isEnabled(in defaults: UserDefaults = BatonStorage.defaults) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// Where a book is made: here, or on the home server (the gateway's book routes, M5.6), which
    /// renders while this Mac sleeps. Either way each chapter ends up in Clippings.
    enum Renderer: String, Codable, Sendable {
        case thisMac, homeServer
    }

    /// A render job and the book it is for. The summary is what the gateway's listing carries;
    /// the document id is what Clippings and the ledger key books by.
    struct Job: Identifiable, Equatable {
        let documentID: String
        let summary: BookJob.Summary
        var renderer: Renderer = .thisMac
        var id: String { summary.id }

        init(_ job: BookJob) {
            documentID = job.book.documentID
            summary = job.summary
        }

        init(documentID: String, summary: BookJob.Summary, renderer: Renderer) {
            self.documentID = documentID
            self.summary = summary
            self.renderer = renderer
        }
    }

    /// What this Mac remembers about a book it sent to the home server: the shared record both
    /// apps keep (`Shared/HomeServerBooks.swift`).
    typealias RemoteBook = HomeServerBooks.Record

    /// Every job this Mac knows, newest first.
    private(set) var jobs: [Job] = []
    private(set) var isStarted = false

    @ObservationIgnored let store: BookStore
    @ObservationIgnored private let renderer: BookRenderer
    @ObservationIgnored private let clippings: ClippingStore
    @ObservationIgnored private let refreshInterval: Duration
    @ObservationIgnored private var watcher: Task<Void, Never>?
    /// The home server's half (M5.6), shared with the phone: what was sent there, what is ready,
    /// and bringing each chapter down once.
    let homeServer: HomeServerBooks
    /// The latest summary of each book on the home server, by job id.
    var remoteSummaries: [String: BookJob.Summary] { homeServer.summaries }
    /// Why the last attempt to reach the home server failed, in a listener's words.
    var homeServerProblem: String? { homeServer.problem }

    init(clippings: ClippingStore,
         directory: URL = BatonStorage.supportSubdirectory("Books"),
         synthesizer: any SpeechSynthesizing = ConfiguredSpeechSynthesizer(),
         muxer: any AudioMuxing = AVAssetWriterMuxer(),
         concurrency: Int = 1,
         retry: BookRenderer.Retry = BookRenderer.Retry(),
         refreshInterval: Duration = .seconds(1),
         gateway: @escaping @MainActor () -> GatewayBookClient? = DocumentLibrary.configuredGateway) {
        self.clippings = clippings
        self.homeServer = HomeServerBooks(directory: directory, clippings: clippings, gateway: gateway, log: documentsLog)
        self.store = BookStore(directory: directory)
        // Concurrency 1: Phase 0 measured Kokoro on the LAN model host at 17.7x real time at 1, 2 and 4
        // requests alike, so more in flight only queues on the server.
        self.renderer = BookRenderer(store: store, cacheDirectory: directory.appendingPathComponent("cache"),
                                     synthesizer: synthesizer, muxer: muxer, concurrency: concurrency,
                                     retry: retry, log: { documentsLog.notice("\($0, privacy: .public)") })
        self.refreshInterval = refreshInterval
    }

    // MARK: - Lifecycle

    /// Resume whatever was left unfinished. Called at launch when the flag is on; `force` is for
    /// tests, which have no flag.
    func start(force: Bool = false) {
        guard force || Self.isEnabled(), !isStarted else { return }
        isStarted = true
        let renderer = self.renderer
        Task { await renderer.startIfNeeded() }
        refresh()
    }

    /// Read the jobs back from disk, and adopt every chapter that has become ready.
    func refresh() {
        let all = store.list()
        adoptReadyChapters(all)
        var fresh = all.map(Job.init)
        for record in remoteBooks {
            if let summary = remoteSummaries[record.jobID] {
                fresh.append(Job(documentID: record.documentID, summary: summary, renderer: .homeServer))
            }
        }
        fresh.sort { $0.summary.createdAt > $1.summary.createdAt }
        if fresh != jobs { jobs = fresh }
        homeServer.watchIfNeeded { [weak self] in self?.refresh() }
        let busy = all.contains { $0.status == .rendering || $0.status == .paused }
        if busy { watch() } else { watcher?.cancel(); watcher = nil }
    }

    /// Poll the job files while something renders. Each `job.json` carries the whole prepared
    /// book, so this stops as soon as nothing is in flight.
    private func watch() {
        guard watcher == nil else { return }
        let interval = refreshInterval
        watcher = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled else { return }
            self.watcher = nil
            self.refresh()   // arms the next one while anything is still in flight
        }
    }

    // MARK: - Import

    /// What Import Document… and a drop accept: PDF, EPUB, web pages saved as HTML, plain text
    /// and Markdown files, and links to web pages. RTF is not read yet.
    static var importableTypes: [UTType] {
        [.pdf, .epub, .html, .plainText] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
    }

    static func canImport(_ url: URL) -> Bool {
        if isWebLink(url) { return true }
        guard url.isFileURL, let kind = DocumentImporter.kind(for: url) else { return false }
        return [.pdf, .text, .markdown, .html, .epub].contains(kind)
    }

    /// An address on the web, read as a page rather than downloaded as a file (M8.1b).
    static func isWebLink(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }

    /// A web page by its address: the article, not the page furniture, or the PDF or text the
    /// address serves.
    nonisolated static func importDocument(fromWeb url: URL,
                                           fetch: @escaping DocumentImporter.Fetch = { try await URLSession.shared.data(for: $0) })
        async throws -> ImportedDocument {
        try await DocumentImporter.importURL(url, fetch: fetch)
    }

    /// Read a file into a structured document, off the main thread. The spell checker breaks
    /// hyphenation ties; `NSSpellChecker` is main-actor, so it is reached by a hop.
    nonisolated static func importDocument(at url: URL) async throws -> ImportedDocument {
        try await Task.detached(priority: .userInitiated) {
            try DocumentImporter.importFile(at: url, isWord: { word in
                DispatchQueue.main.sync {
                    NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
                }
            })
        }.value
    }

    /// The voice a book gets before the voice suggestion exists (M4.4): the same choice a
    /// reading makes. A language with its own entry in the voice map gets that voice, and
    /// everything else, English included, gets the configured default.
    static func languageDefaultVoice(for document: ImportedDocument) -> String {
        DocumentVoices.languageDefault(for: document)
    }

    /// Submit a shaped book. The same book in the same voice is the same job, so submitting twice
    /// finds the first.
    @discardableResult
    func submit(_ book: PreparedBook) async throws -> String {
        let id = BookJob.id(for: book)
        _ = try await renderer.submit(book, id: id)
        documentsLog.notice("submitted \"\(book.title, privacy: .public)\": \(book.chapters.count) chapters, \(book.segmentCount) chunks")
        refresh()
        return id
    }

    /// Stop rendering a book and remove its job, here or on the home server. Chapters already in
    /// Clippings stay there.
    func cancel(_ id: String) async {
        if homeServer.record(forJob: id) != nil {
            await homeServer.cancel(jobID: id)
        } else {
            await renderer.cancel(id)
        }
        refresh()
    }

    func job(forDocument documentID: String) -> Job? {
        jobs.first { $0.documentID == documentID }
    }

    /// The listener reached the end of the book: the job records it, which is what the storage
    /// rules and the gateway's retention run on.
    func markFinished(documentID: String) async {
        guard let job = job(forDocument: documentID) else { return }
        if job.renderer == .homeServer {
            await homeServer.markFinished(jobID: job.id)
        } else {
            _ = await renderer.markFinished(job.id)
        }
        refresh()
    }

    // MARK: - The home server (M5.6)

    typealias HomeServerError = HomeServerBooks.Problem

    /// The gateway as Settings configures it (`baton.agent.gatewayURL`, its token in the
    /// Keychain), the same pair kept readings travel through.
    static func configuredGateway() -> GatewayBookClient? {
        let raw = (BatonStorage.defaults.string(forKey: "baton.agent.gatewayURL") ?? "").trimmingCharacters(in: .whitespaces)
        let token = (NavidromeKeychain.secret(account: "baton.agent.gatewayToken") ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !token.isEmpty, let url = URL(string: raw), url.host != nil else { return nil }
        return GatewayBookClient(baseURL: url, token: token)
    }

    /// Whether the home server makes books now: configured, answering, and books switched on there.
    func homeServerAvailable() async -> Bool {
        await homeServer.available()
    }

    /// Submit a shaped book to be made here or on the home server.
    @discardableResult
    func submit(_ book: PreparedBook, on where: Renderer) async throws -> String {
        guard `where` == .homeServer else { return try await submit(book) }
        let id = try await homeServer.submit(book)
        refresh()
        return id
    }

    var remoteBooks: [RemoteBook] { homeServer.records }

    /// Ask the home server about every book not yet collected, and bring each chapter that is
    /// ready into Clippings, checked against its digest.
    func refreshHomeServer() async {
        await homeServer.collect()
        refresh()
    }

    // MARK: - Chapters into Clippings

    private func adoptReadyChapters(_ all: [BookJob]) {
        for job in all {
            for (index, state) in job.chapters.enumerated() {
                guard case let .ready(file, _, seconds, sha) = state,
                      clippings.item(documentID: job.book.documentID, chapterIndex: index) == nil,
                      let url = store.chapterURL(job.id, file: file),
                      FileManager.default.fileExists(atPath: url.path) else { continue }
                let chapter = job.book.chapters[index]
                let text = chapter.segments.map(\.text).joined(separator: " ")
                do {
                    try clippings.adopt(url, title: chapter.title, sourceName: job.book.author,
                                        durationSeconds: seconds, text: text, sha256: sha,
                                        chapter: .init(documentID: job.book.documentID, documentTitle: job.book.title,
                                                       author: job.book.author, chapterIndex: index,
                                                       chapterTitle: chapter.title))
                    documentsLog.notice("book \(job.id.prefix(12), privacy: .public): chapter \(index + 1) is in Clippings")
                } catch {
                    documentsLog.error("book \(job.id.prefix(12), privacy: .public): could not keep chapter \(index + 1): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}

/// Kokoro and Chatterbox at the hosts in Settings → Speech, read per request so a host changed
/// in Settings is used by the next chunk without a relaunch.
struct ConfiguredSpeechSynthesizer: SpeechSynthesizing {
    func synthesize(text: String, voice: String, speed: Double?) async throws -> Data {
        try await synthesize(text: text, voice: voice, speed: speed, style: nil)
    }

    /// The style goes through (M8.7): with a Chatterbox voice, `HTTPSpeechSynthesizer` sends it
    /// to the server's own `/tts` route, which is the one that honours `exaggeration` and
    /// `cfg_weight` (confirmed against the LAN Chatterbox server on 2026-10-14). Without this overload the
    /// protocol's default dropped the style and every chapter rendered flat.
    func synthesize(text: String, voice: String, speed: Double?, style: SpeechStyle?) async throws -> Data {
        try await HTTPSpeechSynthesizer(engines: Self.engines()).synthesize(text: text, voice: voice, speed: speed, style: style)
    }

    /// The engines Settings → Speech names, read per call. A blank host is left out, so a voice
    /// on that engine fails as "no host is configured" rather than as a bad URL.
    static func engines() -> [String: URL] {
        var engines: [String: URL] = [:]
        if let kokoro = URL(string: SpeechConfig.kokoroBaseURL), kokoro.host != nil { engines["kokoro"] = kokoro }
        if let chatterbox = URL(string: SpeechConfig.chatterboxBaseURL), chatterbox.host != nil { engines["chatterbox"] = chatterbox }
        return engines
    }
}
