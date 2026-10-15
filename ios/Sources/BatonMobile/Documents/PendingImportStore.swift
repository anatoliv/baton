import BatonSubsonicKit
import Foundation

/// The document waiting for its import screen, kept on disk until that screen closes
///. A file shared from another app is taken out of the share inbox once, so before
/// this a force-quit between the hand-over and the import screen closing lost it for good.
///
/// One folder in Application Support: the app's own copy of the file (moved in from the
/// temporary `imports` folder) and `pending.json`, a small marker saying what it is and when it
/// came. Restored at launch; dropped once handled, or when older than `maximumAge`.
struct PendingImportStore {
    static let shared = PendingImportStore(directory: BatonStorage.supportDirectory()
        .appendingPathComponent("PendingImport", isDirectory: true))
    /// A document nobody opened for a week is not one anyone is waiting for.
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    struct Marker: Codable, Equatable {
        /// The kept file's name inside the folder, for a file.
        var fileName: String?
        /// The page's address, for a link.
        var link: String?
        var savedAt: Date
    }

    let directory: URL
    private var markerURL: URL { directory.appendingPathComponent("pending.json") }

    /// Keep `url` until `clear()`, replacing anything kept before. A file is moved into the folder
    /// and the returned URL is the kept copy, which the import screen should read; a link is
    /// returned as it is. If keeping fails the document is still offered, just not across a quit.
    @discardableResult
    func keep(_ url: URL, now: Date = Date()) -> URL {
        // Already the kept copy (offered again): nothing to move.
        if url.isFileURL, url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL { return url }
        clear()
        let fm = FileManager.default
        var offered = url
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var marker = Marker(savedAt: now)
            if url.isFileURL {
                let kept = directory.appendingPathComponent(url.lastPathComponent)
                try fm.moveItem(at: url, to: kept)
                offered = kept
                marker.fileName = kept.lastPathComponent
            } else {
                marker.link = url.absoluteString
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(marker).write(to: markerURL, options: .atomic)
        } catch {
            documentsLog.error("could not keep the pending import: \(String(describing: error), privacy: .public)")
        }
        return offered
    }

    /// The document kept by an earlier launch, or nil (and nothing kept) when there is none, its
    /// file has gone, or it is older than `maximumAge`.
    func restore(now: Date = Date()) -> URL? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let marker = try? decoder.decode(Marker.self, from: data),
              now.timeIntervalSince(marker.savedAt) < Self.maximumAge else {
            clear()
            return nil
        }
        if let name = marker.fileName {
            let file = directory.appendingPathComponent((name as NSString).lastPathComponent)
            guard FileManager.default.fileExists(atPath: file.path) else { clear(); return nil }
            return file
        }
        if let link = marker.link, let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           url.host != nil { return url }
        clear()
        return nil
    }

    /// Forget the kept document: its import screen closed, or the session was reset.
    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
