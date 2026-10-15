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
/// On for everyone since TBX-10801 (owner decision, 2026-10-15): `baton.documents.enabled` reads
/// an absent key as on, and the **Documents** toggle in Settings → Speech turns it off. The flag
/// stays on this Mac (it is not a synced preference), so each device decides for itself.
@MainActor
@Observable
final class DocumentLibrary {
    static let enabledKey = "baton.documents.enabled"
    static func isEnabled(in defaults: UserDefaults = BatonStorage.defaults) -> Bool {
        // `bool(forKey:)` reads a missing key as false, which would make "on by default" a lie
        // on a fresh install. Only a stored `false` turns documents off.
        defaults.object(forKey: enabledKey) as? Bool ?? true
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
    @ObservationIgnored private var rendererControl: Task<Void, Never>?
    /// The home server's half (M5.6), shared with the phone: what was sent there, what is ready,
    /// and bringing each chapter down once.
    let homeServer: HomeServerBooks
    /// This Mac's book storage: rules, Keep, Remove Download, Recently removed and the weekly
    /// suggestion (M6.3 to M6.5), shared with the phone.
    let cleanup: BookCleanup
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
         storageDefaults: UserDefaults = BatonStorage.defaults,
         gateway: @escaping @MainActor () -> GatewayBookClient? = DocumentLibrary.configuredGateway) {
        self.clippings = clippings
        self.homeServer = HomeServerBooks(directory: directory, clippings: clippings, gateway: gateway, log: documentsLog)
        self.cleanup = BookCleanup(directory: directory, clippings: clippings, homeServer: homeServer,
                                   defaults: storageDefaults, log: documentsLog)
        self.store = BookStore(directory: directory)
        // Concurrency 1: Phase 0 measured Kokoro on the LAN model host at 17.7x real time at 1, 2 and 4
        // requests alike, so more in flight only queues on the server.
        self.renderer = BookRenderer(store: store, cacheDirectory: directory.appendingPathComponent("cache"),
                                     synthesizer: synthesizer, muxer: muxer, concurrency: concurrency,
                                     retry: retry, log: { documentsLog.notice("\($0, privacy: .public)") })
        self.refreshInterval = refreshInterval
    }

    // MARK: - Lifecycle

    /// Resume whatever was left unfinished. Called at launch when the flag is on, and when the
    /// **Documents** switch is turned on while Baton runs (`follow`); `force` skips reading the
    /// flag, for tests and for a caller that already holds the live switch.
    func start(force: Bool = false) {
        guard force || Self.isEnabled(), !isStarted else { return }
        isStarted = true
        controlRenderer { await $0.startIfNeeded() }
        refresh()
        // The storage rules the person chose run at launch (and when Clippings opens), never
        // before they chose one.
        applyStorageRules()
        // Books on the home server are asked about once at launch, so a finished one shows its
        // "kept until" date without a chapter still to collect (M6.6), and a book stopped while
        // the home server was away is deleted there now.
        if homeServer.isConfigured, !homeServer.records.isEmpty || !homeServer.pendingDeleteIDs.isEmpty {
            Task { await refreshHomeServer() }
        }
    }

    /// Documents turned off in Settings while Baton runs: stop making books and stop asking the
    /// home server. Nothing is removed, and turning documents on again resumes where it stopped.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        watcher?.cancel()
        watcher = nil
        homeServer.stopWatching()
        controlRenderer { await $0.stop() }
        documentsLog.notice("documents turned off: rendering and home server polling stopped")
    }

    /// Start and stop reach the renderer in the order they were asked for, so off and on again
    /// in quick succession cannot leave it stopped.
    private func controlRenderer(_ work: @escaping @Sendable (BookRenderer) async -> Void) {
        let previous = rendererControl
        let renderer = self.renderer
        rendererControl = Task {
            await previous?.value
            await work(renderer)
        }
    }

    /// Start and stop with the **Documents** switch, live: the switch in Settings
    /// takes effect at once rather than at the next launch.
    func follow(_ documentsSwitch: DefaultsSwitch) {
        documentsSwitch.onChange { [weak self] on in
            guard let self else { return }
            if on { self.start(force: true) } else { self.stop() }
        }
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

    // MARK: - Storage (M6.3 to M6.5)

    /// Every book on this Mac as Clippings shows it.
    var shelf: [BookShelf.Book] {
        BookShelf.entries(items: clippings.items, jobs: jobs, ledger: clippings.ledger)
            .compactMap { if case let .book(book) = $0 { book } else { nil } }
    }

    /// A book as storage sees it.
    func stored(_ book: BookShelf.Book) -> StoredBook {
        let job = job(forDocument: book.documentID)
        let present = book.chapters.compactMap(\.item).filter(\.isPresent)
        let listening = StoredBook.listening(book.documentID, ledger: clippings.ledger, present: present)
        let canGetBack: Bool
        switch job?.renderer {
        case .thisMac?: canGetBack = store.load(job!.id) != nil
        case .homeServer?: canGetBack = homeServer.record(forJob: job!.id).map(homeServer.canGetBack) ?? false
        case nil: canGetBack = false
        }
        return StoredBook(documentID: book.documentID, title: book.title, author: book.author, present: present,
                          missing: book.chapters.filter { $0.state == .removed }.map(\.index),
                          createdAt: book.createdAt, finishedAt: listening.finishedAt, lastPlayedAt: listening.lastPlayedAt,
                          inProgress: listening.inProgress,
                          homeServerJobID: job?.renderer == .homeServer ? job?.id : nil, canGetBack: canGetBack)
    }

    var storedBooks: [StoredBook] { shelf.map(stored) }

    /// Run the person's storage rules now. Returns the books whose download went.
    @discardableResult
    func applyStorageRules(now: Date = Date()) -> [String] {
        let removed = cleanup.applyRules(storedBooks, now: now)
        if !removed.isEmpty { refresh() }
        return removed
    }

    /// What brings a book's removed audio back, in the menu's words: "Download Again" from the
    /// home server, "Render Again" when it is made afresh (on this Mac, or on a home server
    /// that has since removed it). Nil when nothing is missing or it cannot come back.
    func getBackTitle(_ book: BookShelf.Book) -> String? {
        let stored = stored(book)
        guard stored.canGetBack, !stored.missing.isEmpty, let job = job(forDocument: book.documentID) else { return nil }
        if job.renderer == .homeServer, homeServer.record(forJob: job.id)?.serverRemoved != true { return "Download Again" }
        return "Render Again"
    }

    /// Bring a book's removed audio back (all of it, or `chapters`): from the home server, or
    /// made again here from the chunk cache, which makes a chapter made before quick.
    func getBack(_ book: BookShelf.Book, chapters: [Int]? = nil) async throws {
        guard let job = job(forDocument: book.documentID) else { return }
        let missing = chapters ?? book.chapters.filter { $0.state == .removed }.map(\.index)
        switch job.renderer {
        case .thisMac:
            _ = await renderer.requeue(job.id, chapters: missing)
        case .homeServer:
            try await homeServer.downloadAgain(jobID: job.id, chapters: chapters)
        }
        cleanup.cameBack(book.documentID)
        refresh()
    }

    /// Remove a book's download from this Mac (all of it, or `chapters`), keeping the book.
    @discardableResult
    func offload(_ book: BookShelf.Book, chapters: [Int]? = nil) -> Int {
        let bytes = cleanup.offload(stored(book), chapters: chapters)
        refresh()
        return bytes
    }

    /// Delete a book, from this Mac or everywhere: it stops being made, leaves Clippings, and
    /// waits in Recently removed for a week. A book made here keeps its render job there too,
    /// so Restore brings back the book with its pronunciations and Render Again.
    func deleteBook(_ book: BookShelf.Book, everywhere: Bool) async {
        let job = job(forDocument: book.documentID)
        let payload = job.flatMap { $0.renderer == .thisMac ? store.load($0.id) : nil }
            .flatMap { try? BookJSON.encoder.encode($0) }
        cleanup.delete(stored(book), everywhere: everywhere, payload: payload)
        if let job { await cancel(job.id) }
        refresh()
    }

    /// Bring a deleted book back from Recently removed.
    func restore(_ entry: BookStorage.Removed) throws {
        if let payload = try cleanup.restore(entry), let job = try? BookJSON.decoder.decode(BookJob.self, from: payload) {
            try? store.save(job)
        }
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
/// in Settings is used by the next chunk without a relaunch, and the built-in "This Mac" engine
/// in Baton's own process. Which of them reads a voice is Settings → Speech → Voice
/// engine for books (TBX-10909, `BookVoiceSettings.route`), also read per request.
struct ConfiguredSpeechSynthesizer: SpeechSynthesizing {
    /// The built-in engine when its model is present, read per call so a download or a removal
    /// takes effect on the next chunk. Tests replace it.
    nonisolated(unsafe) static var builtIn: @Sendable () -> (any BuiltInSpeechEngine)? = { BuiltInVoices.shared.ifAvailable }
    /// The Voice engine for books setting, read per call. Tests replace it.
    nonisolated(unsafe) static var choice: @Sendable () -> BookVoiceSettings.Engine = { BookVoiceSettings.engine }

    /// Per instance, so a test can route one synthesizer without touching the statics other
    /// suites read in parallel. Production uses the statics.
    var localEngine: @Sendable () -> (any BuiltInSpeechEngine)? = { ConfiguredSpeechSynthesizer.builtIn() }
    var engineSetting: @Sendable () -> BookVoiceSettings.Engine = { ConfiguredSpeechSynthesizer.choice() }

    /// Where a voice goes, in the order engines are offered it.
    enum Engine: Equatable {
        /// The built-in "This Mac" voices, in Baton's own process.
        case thisMac
        /// A server from Settings → Speech, by engine name.
        case server(String)
    }

    func synthesize(text: String, voice: String, speed: Double?) async throws -> Data {
        try await synthesize(text: text, voice: voice, speed: speed, style: nil)
    }

    /// The style goes through (M8.7): with a Chatterbox voice, `HTTPSpeechSynthesizer` sends it
    /// to the server's own `/tts` route, which is the one that honours `exaggeration` and
    /// `cfg_weight` (confirmed against the LAN Chatterbox server on 2026-10-14). Without this overload the
    /// protocol's default dropped the style and every chapter rendered flat.
    func synthesize(text: String, voice: String, speed: Double?, style: SpeechStyle?) async throws -> Data {
        let builtIn = localEngine()
        switch BookVoiceSettings.route(voice: voice, engine: engineSetting(), builtIn: builtIn) {
        case .builtIn:
            guard let builtIn else { throw SynthesisError.transient(BookVoiceSettings.notReadyReason) }
            return try await builtIn.synthesizeWAV(text: text, voice: voice, speed: speed)
        case .server:
            return try await HTTPSpeechSynthesizer(engines: Self.engines()).synthesize(text: text, voice: voice, speed: speed, style: style)
        case let .refused(why):
            // Transient, so the book pauses with this line and carries on by itself once the
            // voices are downloaded or the setting changes, rather than failing for good.
            throw SynthesisError.transient(why)
        }
    }

    /// The engines in the order a voice is offered to them under the setting: the built-in one
    /// first when its model is present (not under Voice server), then Kokoro's and Chatterbox's
    /// servers when they have a host (not under Built-in voices on this Mac).
    static func registeredEngines() -> [Engine] {
        let choice = choice()
        let servers = engines()
        let local: [Engine] = (choice == .server || builtIn() == nil) ? [] : [.thisMac]
        let remote: [Engine] = choice == .builtIn ? [] : ["kokoro", "chatterbox"].filter { servers[$0] != nil }.map(Engine.server)
        return local + remote
    }

    /// The engine that reads `voice` under the setting, or its server's name when it goes to
    /// one (so the failure names the missing host). Nil when the setting refuses it.
    static func engine(for voice: String) -> Engine? {
        switch BookVoiceSettings.route(voice: voice, engine: choice(), builtIn: builtIn()) {
        case .builtIn: .thisMac
        case let .server(name): .server(name)
        case .refused: nil
        }
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
