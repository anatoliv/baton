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
        /// Made on the home server from another device and adopted from its listing.
        var adopted = false
        var id: String { summary.id }

        init(_ job: BookJob) {
            documentID = job.book.documentID
            summary = job.summary
        }

        init(documentID: String, summary: BookJob.Summary, renderer: Renderer, adopted: Bool = false) {
            self.documentID = documentID
            self.summary = summary
            self.renderer = renderer
            self.adopted = adopted
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
    /// The books the storage rules last saw as able to come back.
    @ObservationIgnored private var rulesSawGettable: Set<String>?
    /// Asks the home server again whenever Baton comes to the front.
    @ObservationIgnored private var activation: NSObjectProtocol?
    /// The home server's half (M5.6), shared with the phone: what was sent there, what is ready,
    /// and bringing each chapter down once.
    let homeServer: HomeServerBooks
    /// This Mac's book storage: rules, Keep, Remove Download, Recently removed and the weekly
    /// suggestion (M6.3 to M6.5), shared with the phone.
    let cleanup: BookCleanup
    /// Books made here, sent to the Baton server for the iPhone as they are made.
    let uploads: MacBookUploads
    /// Each book's cover, kept here and settled with the Baton server.
    let covers: BookCovers
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
         uploadRetry: MacBookUploads.Retry = MacBookUploads.Retry(),
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
        self.covers = BookCovers(directory: directory.appendingPathComponent("covers", isDirectory: true), gateway: gateway)
        self.uploads = MacBookUploads(directory: directory, books: store, clippings: clippings, homeServer: homeServer,
                                      gateway: gateway, log: documentsLog, retry: uploadRetry)
        // A book this Mac makes itself is not adopted again from the home server in a second
        // copy when the iPhone sends the same document there.
        homeServer.isMadeHere = { [weak self] documentID in
            self?.jobs.contains { $0.documentID == documentID && $0.renderer == .thisMac } ?? false
        }
        covers.attach(to: homeServer, clippings: clippings, cleanup: cleanup)
        // A book made here reaches the Baton server: its cover goes too, without waiting for
        // the next time Baton comes to the front.
        uploads.onAccepted = { [weak covers] _ in covers?.syncSoon() }
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
        // before they chose one; again once the home server answers about a book made there.
        applyStorageRules()
        // Books on the home server are asked about once at launch, so a finished one shows its
        // "kept until" date without a chapter still to collect (M6.6), and a book stopped while
        // the home server was away is deleted there now.
        if homeServer.isConfigured, !homeServer.records.isEmpty || !homeServer.pendingDeleteIDs.isEmpty {
            Task { await refreshHomeServer() }
        }
        // Each time Baton comes to the front, and when Clippings opens, the home server is asked
        // again: a book another device sent there is adopted then.
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isStarted, self.homeServer.isConfigured else { return }
                Task { await self.refreshHomeServer() }
            }
        }
    }

    /// Documents turned off in Settings while Baton runs: stop making books and stop asking the
    /// home server. Nothing is removed, and turning documents on again resumes where it stopped.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        watcher?.cancel()
        watcher = nil
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
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
                fresh.append(Job(documentID: record.documentID, summary: summary, renderer: .homeServer,
                                 adopted: record.adopted == true))
            }
        }
        // Newest first. A job kept only so a voice change can be stopped goes after
        // the one making the new voice, also when the two were made within the same second
        // (job dates are kept to the second).
        let kept = Set(voiceChanges.all.compactMap(\.previousJobID))
        fresh.sort { a, b in
            if a.summary.createdAt != b.summary.createdAt { return a.summary.createdAt > b.summary.createdAt }
            return kept.contains(b.id) && !kept.contains(a.id)
        }
        if fresh != jobs { jobs = fresh }
        // A chapter finished or a book was made here: it goes to the Baton server.
        if isStarted { uploads.jobsChanged(all) }
        homeServer.watchIfNeeded { [weak self] in self?.refresh(); self?.applyStorageRulesToNewlyGettable() }
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

    /// Where files handed over from outside go: Finder's Open With and the "Make an Audiobook
    /// with Baton" service (spec §9, TBX-10950). Pure, so every outcome is testable without a
    /// window. Several files at once open the first one Baton can read; there is no queue of
    /// imports to put the rest in, so the others are counted and the person is told.
    enum OpenRoute: Equatable {
        /// The import sheet opens for `url`; `others` is how many of the files handed over wait.
        case importSheet(URL, others: Int)
        /// Documents is turned off in Settings: nothing is imported.
        case documentsOff
        /// None of the files is one Baton reads.
        case unsupported(URL)
        /// Nothing that is a file (a `baton://` link takes its own path).
        case none
    }

    static func route(opening urls: [URL], documentsEnabled: Bool) -> OpenRoute {
        let files = urls.filter(\.isFileURL)
        guard let firstFile = files.first else { return .none }
        guard documentsEnabled else { return .documentsOff }
        guard let readable = files.first(where: canImport) else { return .unsupported(firstFile) }
        return .importSheet(readable, others: files.count - 1)
    }

    /// The alert for a route that does not end in the import sheet, or nil when it does.
    static func openAlert(for route: OpenRoute) -> (title: String, message: String)? {
        switch route {
        case .documentsOff:
            return ("Documents is turned off",
                    "To make an audiobook from a document, turn on Documents in Settings, under Speech, then open the file again.")
        case let .unsupported(url):
            return ("Baton can't read \(url.lastPathComponent)",
                    "Baton makes audiobooks from PDF, EPUB, web pages saved as HTML, plain text and Markdown files.")
        case .importSheet, .none:
            return nil
        }
    }

    /// What a hand-over of several files says, once the first is in the import sheet.
    static func othersNotice(opened url: URL, others: Int) -> String? {
        guard others > 0 else { return nil }
        let rest = others == 1 ? "the other file" : "the other \(others) files"
        return "Opened \(url.lastPathComponent). Baton imports one document at a time, so open \(rest) after this one."
    }

    /// An address on the web, read as a page rather than downloaded as a file (M8.1b).
    static func isWebLink(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }

    /// A web page by its address: the article, not the page furniture, or the PDF or text the
    /// address serves.
    nonisolated static func importDocument(fromWeb url: URL,
                                           fetch: @escaping DocumentImporter.Fetch = DocumentImporter.pageFetch)
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
        // Made here again after it was removed from this Mac: it is this Mac's again, and the
        // copy sent before is replaced by this one.
        homeServer.unhide(documentID: book.documentID)
        documentsLog.notice("submitted \"\(book.title, privacy: .private)\": \(book.chapters.count) chapters, \(book.segmentCount) chunks")
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
            await uploads.markFinished(jobID: job.id)
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
        // A book made here that the Baton server missed while it was away goes up now.
        if isStarted { uploads.kick(force: true) }
        refresh()
        applyStorageRulesToNewlyGettable()
    }

    // MARK: - Storage (M6.3 to M6.5)

    /// Every book on this Mac as Clippings shows it.
    var shelf: [BookShelf.Book] {
        BookShelf.entries(items: clippings.items, jobs: jobs, ledger: clippings.ledger, changes: voiceChanges.all)
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

    /// The books whose download storage could remove: on this Mac and able to come back. A book
    /// made on the home server joins only once the home server has answered about it after
    /// launch, so Clippings asks for the weekly suggestion again when this changes, not only when
    /// it appears.
    var removableBookIDs: [String] {
        storedBooks.filter { $0.canGetBack && !$0.present.isEmpty }.map(\.documentID)
    }

    /// Run the person's storage rules now. Returns the books whose download went.
    @discardableResult
    func applyStorageRules(now: Date = Date()) -> [String] {
        let removed = cleanup.applyRules(storedBooks, now: now)
        if !removed.isEmpty { refresh() }
        rulesSawGettable = Set(storedBooks.filter(\.canGetBack).map(\.documentID))
        return removed
    }

    /// Run the rules again when a book has become able to come back since they last ran. At
    /// launch they run before the home server has answered, when a book made there has no job
    /// and so cannot come back; its answer makes it one. Only a newly gettable book
    /// counts, so Download Again bringing a book's chapters back does not remove them again.
    private func applyStorageRulesToNewlyGettable() {
        guard isStarted, let saw = rulesSawGettable,
              storedBooks.contains(where: { $0.canGetBack && !saw.contains($0.documentID) }) else { return }
        applyStorageRules()
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

    /// Delete a book, from this Mac or everywhere: it leaves Clippings and waits in Recently
    /// removed for a week. A book made here stops being made, and keeps its render job in the
    /// hold, so Restore brings back the book with its pronunciations and Render Again. A book
    /// made on the home server is deleted there only by Delete Everywhere; removed from this
    /// Mac, it stays there for the other devices and is not adopted here again. A
    /// book made here and sent to the Baton server follows the same rules for that copy.
    func deleteBook(_ book: BookShelf.Book, everywhere: Bool) async {
        let job = job(forDocument: book.documentID)
        let payload = job.flatMap { $0.renderer == .thisMac ? store.load($0.id) : nil }
            .flatMap { try? BookJSON.encoder.encode($0) }
        cleanup.delete(stored(book), everywhere: everywhere, payload: payload)
        // A book deleted while it was made again: the job kept for Stop goes with it.
        if let previous = voiceChanges.change(forDocument: book.documentID)?.previousJobID {
            await renderer.cancel(previous)
        }
        voiceChanges.drop(book.documentID)
        if job?.renderer == .thisMac {
            if everywhere {
                await uploads.deleteEverywhere(documentID: book.documentID)
            } else {
                uploads.keepOnServerOnly(documentID: book.documentID)
            }
        }
        if let job, everywhere || job.renderer == .thisMac {
            await cancel(job.id)
        } else if !everywhere {
            homeServer.hide(documentID: book.documentID)
        }
        refresh()
    }

    /// Bring a deleted book back from Recently removed.
    func restore(_ entry: BookStorage.Removed) throws {
        if let payload = try cleanup.restore(entry), let job = try? BookJSON.decoder.decode(BookJob.self, from: payload) {
            try? store.save(job)
            // Back as if it had never gone, on the Baton server too: what it still has is found
            // there, and only what it lacks is sent.
            uploads.forget(jobID: job.id)
        }
        refresh()
    }

    // MARK: - Change Voice

    /// Books being made again in another voice, here or on the home server.
    var voiceChanges: BookVoiceChanges { homeServer.voiceChanges }

    func voiceChange(for book: BookShelf.Book) -> BookVoiceChanges.Change? {
        voiceChanges.change(forDocument: book.documentID)
    }

    /// Whether Change Voice… is offered: the book's words are on this Mac (its render job, or the
    /// shaped book saved beside a home-server record).
    func canChangeVoice(_ book: BookShelf.Book) -> Bool { canEditPronunciations(book) }

    /// The voices the book is read in now: its narrator, and its cast when the dialogue is voiced.
    func voices(of book: BookShelf.Book) -> (plan: VoicePlan, hasCast: Bool, renderer: Renderer)? {
        pronunciationSource(documentID: book.documentID).map { ($0.book.voices, $0.book.hasCast, $0.renderer) }
    }

    /// The first words of the book, to hear a voice in the picker.
    func previewText(of book: BookShelf.Book, limit: Int = 220) -> String {
        let words = pronunciationSource(documentID: book.documentID)?.book.chapters
            .lazy.flatMap(\.segments).filter { $0.kind != .heading }.prefix(3).map(\.text).joined(separator: " ") ?? book.title
        let redacted = SecretRedactor.redact(words)
        guard redacted.count > limit else { return redacted }
        let cut = redacted.prefix(limit)
        if let end = cut.lastIndex(where: { ".!?".contains($0) }) { return String(cut[...end]) }
        return String(cut) + "…"
    }

    /// Make the whole book again in another narrator's voice, wherever it was made: the home
    /// server through `resubmit` (`HomeServerBooks.changeVoice`), or this Mac's renderer under a
    /// new job. Either way the cast, the pronunciations and the place in the book are kept, and
    /// each chapter here plays in the old voice until its new audio takes its place.
    func changeVoice(_ book: BookShelf.Book, to narrator: String) async throws {
        guard let source = pronunciationSource(documentID: book.documentID) else { throw PronunciationError.noPreparedBook }
        try await changeVoice(book, to: source.book.inVoice(narrator))
    }

    /// The same with the whole book as Change Voice… left it: a new narrator, and a
    /// cast given, edited or taken away. Stop goes back to the book it was, cast and all.
    func changeVoice(_ book: BookShelf.Book, to updated: PreparedBook) async throws {
        guard let source = pronunciationSource(documentID: book.documentID) else { throw PronunciationError.noPreparedBook }
        let narrator = updated.voices.narrator
        switch source.renderer {
        case .homeServer:
            let newID = try await homeServer.changeVoice(jobID: source.jobID, to: updated)
            if newID != source.jobID, clippings.ledger.document(book.documentID)?.finished == true {
                await homeServer.markFinished(jobID: newID)
            }
        case .thisMac:
            guard let stored = store.load(source.jobID) else { throw PronunciationError.noPreparedBook }
            let newID = BookJob.id(for: updated)
            guard newID != source.jobID else { return }
            let present = book.chapters.filter { $0.item?.isPresent == true }.map(\.index)
            let earlier = voiceChanges.change(forDocument: book.documentID)
            // A finished job is kept until the change ends, so Stop goes back to it without making
            // anything; one still being made stops here, so the two do not render side by side.
            let keepPrevious = earlier == nil && stored.status == .ready && !present.isEmpty
            if !present.isEmpty {
                voiceChanges.begin(documentID: book.documentID, voice: narrator, previousVoices: stored.book.voices,
                                   previousBook: updated.chapters == stored.book.chapters ? nil : stored.book,
                                   jobID: newID, previousJobID: keepPrevious ? source.jobID : nil,
                                   pending: present, startedHere: true)
            }
            // The job in between, when the voice is changed again before the first change ended.
            if !keepPrevious, source.jobID != earlier?.previousJobID {
                await renderer.cancel(source.jobID)
            }
            do {
                try await submit(updated)
            } catch {
                voiceChanges.abandon(book.documentID)
                throw error
            }
            if let finishedAt = stored.finishedAt { _ = await renderer.markFinished(newID, at: finishedAt) }
        }
        refresh()
        documentsLog.notice("book \"\(book.title, privacy: .private)\": making it again in \(narrator, privacy: .public)")
    }

    /// Stop making a book again: the chapters already replaced get their old audio back, and the
    /// book is made in the voices it had (from the job kept for it, or the chunk cache).
    func cancelVoiceChange(_ book: BookShelf.Book) async throws {
        guard let change = voiceChange(for: book) else { return }
        guard let job = job(forDocument: book.documentID) else { voiceChanges.abandon(book.documentID); return }
        switch job.renderer {
        case .homeServer:
            try await homeServer.cancelVoiceChange(documentID: book.documentID)
        case .thisMac:
            let stored = store.load(job.id)
            await renderer.cancel(job.id)
            voiceChanges.abandon(book.documentID)
            if let previous = change.previousJobID, store.load(previous) != nil {
                // Every chapter of it is already here: nothing to make.
            } else if let now = stored?.book {
                try await submit(change.bookBefore(now))
            }
        }
        refresh()
    }

    // MARK: - Chapters into Clippings

    private func adoptReadyChapters(_ all: [BookJob]) {
        for job in all {
            for (index, state) in job.chapters.enumerated() {
                guard case let .ready(file, _, seconds, sha) = state,
                      let url = store.chapterURL(job.id, file: file),
                      FileManager.default.fileExists(atPath: url.path) else { continue }
                let existing = clippings.item(documentID: job.book.documentID, chapterIndex: index)
                if existing != nil {
                    // In the old voice while the book is made again: the new audio takes its place.
                    guard voiceChanges.isPending(job.book.documentID, chapterIndex: index, jobID: job.id) else { continue }
                    replaceChapter(job, index: index, url: url, file: file, seconds: seconds, sha: sha)
                    continue
                }
                let chapter = job.book.chapters[index]
                let text = chapter.segments.map(\.text).joined(separator: " ")
                do {
                    try clippings.adopt(url, title: chapter.title, sourceName: job.book.author,
                                        durationSeconds: seconds, text: text, sha256: sha,
                                        chapter: .init(documentID: job.book.documentID, documentTitle: job.book.title,
                                                       author: job.book.author, chapterIndex: index,
                                                       chapterTitle: chapter.title),
                                        voice: job.book.voices.narrator)
                    voiceChanges.settle(job.book.documentID, chapterIndex: index)
                    // Its read-along timing goes with it, by the audio's digest.
                    if let timing = store.chapterTiming(job.id, file: file) {
                        try? homeServer.readAlong.save(timing, forAudio: sha)
                    }
                    documentsLog.notice("book \(job.id.prefix(12), privacy: .public): chapter \(index + 1) is in Clippings")
                } catch {
                    documentsLog.error("book \(job.id.prefix(12), privacy: .public): could not keep chapter \(index + 1): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// A chapter made again in the new voice replaces the old one in its row. When it was the
    /// last, the job kept for Stop has done its work and goes.
    private func replaceChapter(_ job: BookJob, index: Int, url: URL, file: String, seconds: Double, sha: String) {
        let documentID = job.book.documentID
        let previousJobID = voiceChanges.change(forDocument: documentID)?.previousJobID
        do {
            try voiceChanges.replace(documentID: documentID, chapterIndex: index, with: url, seconds: seconds, sha256: sha)
            if let timing = store.chapterTiming(job.id, file: file) {
                try? homeServer.readAlong.save(timing, forAudio: sha)
            }
            documentsLog.notice("book \(job.id.prefix(12), privacy: .public): chapter \(index + 1) replaced in its new voice")
        } catch {
            documentsLog.error("book \(job.id.prefix(12), privacy: .public): could not replace chapter \(index + 1): \(String(describing: error), privacy: .public)")
            return
        }
        if voiceChanges.change(forDocument: documentID) == nil, let previousJobID, previousJobID != job.id {
            let renderer = self.renderer
            Task { await renderer.cancel(previousJobID) }
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
        try await synthesize(text: text, voice: voice, speed: speed, style: style, instruction: nil)
    }

    /// The delivery instruction goes through too, to an expressive server.
    func synthesize(text: String, voice: String, speed: Double?, style: SpeechStyle?, instruction: String?) async throws -> Data {
        let builtIn = localEngine()
        switch BookVoiceSettings.route(voice: voice, engine: engineSetting(), builtIn: builtIn) {
        case .builtIn:
            guard let builtIn else { throw SynthesisError.transient(BookVoiceSettings.notReadyReason) }
            return try await builtIn.synthesizeWAV(text: text, voice: voice, speed: speed)
        case let .server(name):
            // The Keychain is read only for the server that needs the key.
            return try await HTTPSpeechSynthesizer(endpoints: Self.endpoints(withKey: name == SpeechEngines.openAI))
                .synthesize(text: text, voice: voice, speed: speed, style: style, instruction: instruction)
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
        let remote: [Engine] = choice == .builtIn ? [] : ["kokoro", "chatterbox", SpeechEngines.openAI].filter { servers[$0] != nil }.map(Engine.server)
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
        Dictionary(endpoints().map { ($0.engine, $0.baseURL) }, uniquingKeysWith: { first, _ in first })
    }

    /// The same with what an expressive server also needs: its model, and its key when
    /// `withKey`, which reads the Keychain.
    static func endpoints(withKey: Bool = false) -> [SpeechEngineEndpoint] {
        var endpoints: [SpeechEngineEndpoint] = []
        if let kokoro = URL(string: SpeechConfig.kokoroBaseURL), kokoro.host != nil {
            endpoints.append(SpeechEngineEndpoint(engine: SpeechEngines.kokoro, baseURL: kokoro))
        }
        if let chatterbox = URL(string: SpeechConfig.chatterboxBaseURL), chatterbox.host != nil {
            endpoints.append(SpeechEngineEndpoint(engine: SpeechEngines.chatterbox, baseURL: chatterbox))
        }
        if var expressive = BookVoiceSettings.expressiveEndpoint(key: nil) {
            if withKey { expressive = BookVoiceSettings.expressiveEndpoint(key: BookVoiceSettings.readExpressiveKey()) ?? expressive }
            endpoints.append(expressive)
        }
        return endpoints
    }
}
