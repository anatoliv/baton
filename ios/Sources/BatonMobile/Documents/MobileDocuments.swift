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
/// Behind `baton.documents.enabled` (off), the same flag as the Mac.
@MainActor
enum MobileDocuments {
    static let enabledKey = "baton.documents.enabled"
    static func isEnabled(in defaults: UserDefaults = BatonStorage.defaults) -> Bool {
        defaults.bool(forKey: enabledKey)
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

    nonisolated static func importDocument(fromWeb url: URL) async throws -> ImportedDocument {
        try await DocumentImporter.importURL(url) { try await URLSession.shared.data(for: $0) }
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

    static func notifyChapterReady(_ record: HomeServerBooks.Record, chapterIndex: Int) {
        let content = UNMutableNotificationContent()
        content.title = chapterIndex == 0 ? "Chapter 1 is ready" : "Chapter \(chapterIndex + 1) is ready"
        content.body = record.title
        content.sound = .default
        let request = UNNotificationRequest(identifier: "book-\(record.jobID)-\(chapterIndex)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
