import BackgroundTasks
import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation
import OSLog
import UIKit
import UniformTypeIdentifiers
import UserNotifications

let documentsLog = Logger(subsystem: "io.tonebox.baton", category: "documents")

/// Document clippings on the phone (`specs/document-clippings.md`, *iPhone import*, M5.2 to
/// M5.4): a file from Files "Open in" or a pasted link is read by the shared `DocumentImporter`,
/// shown on the import screen, and made into a book **on the home server**, the only renderer
/// the phone has. Chapters come down into Clippings through `HomeServerBooks`, the same code the
/// Mac uses for "Made on: Home server".
///
/// `baton.documents.enabled` is the same key as the Mac's and, since TBX-10801, on unless this
/// phone stored `false` from the **Documents** toggle in Settings. It stays on this device: it is
/// not a synced preference, and `SessionPurge` resetting it means "on again".
@MainActor
enum MobileDocuments {
    static let enabledKey = "baton.documents.enabled"

    /// Settings → Documents → Where books are made: read-only, because the phone
    /// has no voice engine to choose. The Mac's Voice engine for books setting is the Mac's.
    static let whereBooksAreMade = "Your Baton server makes every book from this iPhone, with its own voice server: the Kokoro or Chatterbox address set in the Baton server's own setup. The phone has no voices of its own. It needs the Baton server's address and token under Music Friend, and the Baton server's voice server answering. When the Baton server cannot make a book, Send to my Mac lets Baton on your Mac make it instead."
    static func isEnabled(in defaults: UserDefaults = BatonStorage.defaults) -> Bool {
        // `bool(forKey:)` reads a missing key as false; only a stored `false` turns documents off.
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// What Files can hand over: PDF, EPUB, web pages saved as HTML, plain text and Markdown.
    static var importableTypes: [UTType] {
        [.pdf, .epub, .html, .plainText] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
    }

    static func canImport(_ url: URL) -> Bool {
        if isWebLink(url) { return true }
        guard url.isFileURL, let kind = DocumentImporter.kind(for: url) else { return false }
        return [.pdf, .text, .markdown, .html, .epub].contains(kind)
    }

    #if DEBUG
    /// DEBUG only: the file the system picker would hand back, for a UI test of Clippings' "Import
    /// a File…" (M5.2). The picker runs out of process and its Files locations are not something
    /// a test can seed, so the test passes the file's words in `uitestPickedFileText` and the menu
    /// item takes this file instead of showing the picker; everything after the pick is the real
    /// path. Environment, never launch arguments.
    static let pickedFileTextKey = "uitestPickedFileText"
    static func uitestPickedFile(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let text = environment[pickedFileTextKey], !text.isEmpty else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Picked Notes.md")
        return (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil ? file : nil
    }
    #endif

    /// An address on the web, read as a page rather than downloaded as a file (M8.1b).
    static func isWebLink(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }

    /// A file handed over by another app or by Files is only readable while its security scope
    /// is open, and iOS may take an Inbox copy away at any time, so the import works from a copy
    /// of its own, under the app's temporary directory.
    static func stage(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("imports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: url, to: copy)
        // An "Open in" file lands in Documents/Inbox, which is ours to tidy: nothing else will.
        if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
        return copy
    }

    /// The oldest document left by the Baton share extension, taken out of the App Group inbox
    /// so it is offered exactly once. A file comes back as the app's own copy under
    /// the temporary `imports` folder, like `stage(_:)`; a link as the page's address.
    static func claimSharedImport(from inbox: PendingShareInbox? = .shared) -> URL? {
        guard let inbox else { return nil }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("imports", isDirectory: true)
        guard let claimed = inbox.claimOldest(into: staging) else { return nil }
        documentsLog.info("opened a shared \(claimed.marker.kind.rawValue, privacy: .public) from the share extension")
        return claimed.url
    }

    /// Read a file into a structured document, off the main thread. The spell checker breaks
    /// hyphenation ties; `UITextChecker` is main-thread, so it is reached by a hop.
    nonisolated static func importDocument(at url: URL) async throws -> ImportedDocument {
        try await Task.detached(priority: .userInitiated) {
            try DocumentImporter.importFile(at: url, isWord: { word in
                DispatchQueue.main.sync {
                    let checker = UITextChecker()
                    let range = checker.rangeOfMisspelledWord(in: word, range: NSRange(location: 0, length: (word as NSString).length),
                                                              startingAt: 0, wrap: false, language: "en")
                    return range.location == NSNotFound
                }
            })
        }.value
    }

    /// The import screen's narrator choice: the voices the home server lists
    /// (`GET /v1/voices`), ordered and defaulted as the Mac's import sheet does when no model
    /// suggests one, by the same `VoiceCaster` and `VoiceCatalogue`: Heart for American or
    /// unspecified English, Emma for a book declaring en-GB, narration voices next, never Aoede
    /// or Lewis. Nil when the home server does not list its voices (a gateway from before the
    /// route answers 404) or lists none: the screen then shows the configured default as before.
    static func narratorChoice(for document: ImportedDocument, client: GatewayBookClient?) async -> VoiceSuggestion? {
        guard let client, let list = try? await client.voices() else { return nil }
        return await narratorChoice(for: document, available: list.specs)
    }

    static func narratorChoice(for document: ImportedDocument, available: [String]) async -> VoiceSuggestion? {
        guard !available.isEmpty else { return nil }
        return await VoiceCaster.suggest(for: document, available: available,
                                         languageDefault: DocumentVoices.languageDefault(for: document, available: available),
                                         complete: nil)
    }

    nonisolated static func importDocument(fromWeb url: URL) async throws -> ImportedDocument {
        try await DocumentImporter.importURL(url)
    }

    // MARK: - "Chapter 1 is ready" (M5.4)

    /// The refresh iOS grants a few times a day when the app is not open. Registered at launch,
    /// scheduled after a submission, rescheduled while a book is still being made.
    static let refreshTaskIdentifier = "io.tonebox.baton.books.refresh"

    static func registerRefresh(collect: @escaping @MainActor () async -> Void, moreToCome: @escaping @MainActor () -> Bool) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskIdentifier, using: nil) { task in
            let work = Task { @MainActor in
                await collect()
                if moreToCome() { scheduleRefresh() }
                // Expired mid-collection: say so, so iOS does not count a cut-off run as a success.
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        do { try BGTaskScheduler.shared.submit(request) } catch {
            documentsLog.error("could not schedule the books refresh: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Asked once, when the first book is sent: a book is made while the phone is in a pocket,
    /// and the notification is how its owner learns chapter 1 is there.
    static func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// What `HomeServerBooks.firstChapterArrived` does on the phone. The book's record
    /// already remembers the announcement, so every path that collects (the import screen's and
    /// Clippings' watch, an activation, the background refresh) says "Chapter 1 is ready" at most
    /// once per book. Never with the app in front: the row in Clippings says it there, and the
    /// book counts as told. Chapter 1 that came down while Baton stayed alive in the background,
    /// playing music, used to arrive silently through the watch and was never announced.
    static func chapterReadyAnnouncer(
        isInForeground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
        post: @escaping @MainActor (HomeServerBooks.Record) -> Void = { notifyChapterReady($0, chapterIndex: 0) }
    ) -> @MainActor (HomeServerBooks.Record) -> Void {
        { record in
            guard !isInForeground() else {
                documentsLog.info("book \(record.jobID.prefix(12), privacy: .public): chapter 1 came down with Baton in front, no notification")
                return
            }
            documentsLog.notice("book \(record.jobID.prefix(12), privacy: .public): chapter 1 is ready, announced")
            post(record)
        }
    }

    static func notifyChapterReady(_ record: HomeServerBooks.Record, chapterIndex: Int) {
        let content = UNMutableNotificationContent()
        content.title = chapterIndex == 0 ? "Chapter 1 is ready" : "Chapter \(chapterIndex + 1) is ready"
        content.body = record.title
        content.sound = .default
        let request = UNNotificationRequest(identifier: "book-\(record.jobID)-\(chapterIndex)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
