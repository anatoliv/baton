import Foundation
import OSLog
import BatonSubsonicKit
import BatonSubsonicModels

private let bgLog = Logger(subsystem: "io.tonebox.baton", category: "BackgroundDownloads")

/// Downloads over a background `URLSession`, so an album keeps arriving after the
/// app is suspended — and finished tasks are recovered on the next launch
/// (`restoreOutstandingTasks`, the part Shelv proved most clients get wrong).
///
/// Each task carries its song as JSON in `taskDescription`, so a task that
/// completes in a *later process* than the one that enqueued it can still be
/// validated and committed through `MusicDownloadStore.finalizeDownload` — the
/// same integrity path as foreground downloads.
public final class BackgroundDownloadEngine: NSObject, @unchecked Sendable {
    public static let sessionIdentifier = "io.tonebox.baton.downloads"

    /// Minimal persisted shape for `taskDescription` — enough to finalize.
    struct TaskTicket: Codable {
        var id: String
        var title: String
        var artist: String?
        var album: String?
        var albumID: String?
        var duration: Int?
        var coverArtID: String?
        var artworkURL: URL?

        init(song: NavidromeSong) {
            id = song.id
            title = song.title
            artist = song.artist
            album = song.album
            albumID = song.albumID
            duration = song.duration
            coverArtID = song.coverArtID
            artworkURL = song.artworkURL
        }

        var song: NavidromeSong {
            var song = NavidromeSong(
                id: id, title: title, artist: artist, album: album,
                duration: duration, coverArtID: coverArtID
            )
            song.albumID = albumID
            song.artworkURL = artworkURL
            return song
        }
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Called on the main actor when the system relaunch-completion handler should
    /// fire (set by the app delegate on iOS).
    public var backgroundCompletionHandler: (@Sendable () -> Void)?

    /// Last progress fraction forwarded per task, so the main actor isn't flooded
    /// at wire speed (the DownloadProgressCoalescer lesson, cheaply).
    private var lastForwardedProgress: [Int: Double] = [:]
    private let progressLock = NSLock()

    override public init() {
        super.init()
    }

    /// Enqueues a background download for the song. Fire-and-forget: completion
    /// lands in the delegate, possibly in a later app launch.
    @MainActor
    public func enqueue(_ song: NavidromeSong) {
        do {
            let url = try StreamingPlaybackController.resolveDownloadURL(songID: song.id)
            var request = URLRequest(url: url)
            for (name, value) in NavidromeConfig.customHeaders() {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let task = session.downloadTask(with: request)
            task.taskDescription = String(data: try JSONEncoder().encode(TaskTicket(song: song)), encoding: .utf8)
            task.resume()
        } catch {
            bgLog.error("enqueue \(song.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            Task { @MainActor in
                MusicDownloadStore.shared.noteBackgroundFailure(song)
            }
        }
    }

    /// Re-attaches to tasks that survived a relaunch — running tasks get their
    /// in-flight state back so the Downloads screen shows them, and the session's
    /// pending delegate events (completions while we were gone) replay after this.
    @MainActor
    public func restoreOutstandingTasks() {
        session.getAllTasks { tasks in
            let tickets = tasks.compactMap { task -> TaskTicket? in
                guard task.state == .running || task.state == .suspended else { return nil }
                return Self.ticket(from: task)
            }
            Task { @MainActor in
                for ticket in tickets {
                    MusicDownloadStore.shared.noteBackgroundRestored(ticket.song)
                }
                if !tickets.isEmpty {
                    bgLog.info("restored \(tickets.count) outstanding background download(s)")
                }
            }
        }
    }

    private static func ticket(from task: URLSessionTask) -> TaskTicket? {
        guard let raw = task.taskDescription, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskTicket.self, from: data)
    }
}

extension BackgroundDownloadEngine: URLSessionDownloadDelegate {
    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let ticket = Self.ticket(from: downloadTask) else {
            try? FileManager.default.removeItem(at: location)
            return
        }
        // The temp file dies when this method returns — stage it synchronously first.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("bg-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            bgLog.error("staging failed for \(ticket.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        let response = downloadTask.response
        Task { @MainActor in
            MusicDownloadStore.shared.completeBackgroundDownload(
                song: ticket.song, temp: staging,
                response: response ?? URLResponse()
            )
        }
    }

    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0, let ticket = Self.ticket(from: downloadTask) else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        // Forward at most every 1% per task — raw didWriteData at wire speed becomes a
        // main-actor hop per callback and drowns the UI (Shelv's coalescer lesson).
        progressLock.lock()
        let last = lastForwardedProgress[downloadTask.taskIdentifier] ?? -1
        let shouldForward = fraction - last >= 0.01 || fraction >= 1
        if shouldForward { lastForwardedProgress[downloadTask.taskIdentifier] = fraction }
        progressLock.unlock()
        guard shouldForward else { return }
        let id = ticket.id
        Task { @MainActor in
            MusicDownloadStore.shared.noteBackgroundProgress(id: id, fraction: fraction)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        progressLock.lock()
        lastForwardedProgress[task.taskIdentifier] = nil
        progressLock.unlock()
        guard let error, let ticket = Self.ticket(from: task) else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        bgLog.error("background download \(ticket.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor in
            MusicDownloadStore.shared.noteBackgroundFailure(ticket.song, resumeData: resume)
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // iOS relaunched us for these events; tell the system we're done so it can
        // snapshot and re-suspend. The handler is set by the app delegate.
        let handler = backgroundCompletionHandler
        Task { @MainActor in handler?() }
    }
}
