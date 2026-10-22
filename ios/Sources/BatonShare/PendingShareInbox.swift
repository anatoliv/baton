import Foundation

/// The hand-off between the Baton Share extension and the app.
///
/// A share extension cannot open its host app on iOS, so the extension leaves what was shared in
/// the App Group container and the app picks it up the next time it becomes active. Each share is
/// one folder under `PendingImports/`, named by its id, holding a small `marker.json` and, for a
/// file, the file itself under its original name:
///
///     PendingImports/<id>/marker.json   {"version":1,"id":…,"kind":"file"|"link","originalName":…,"created":…}
///     PendingImports/<id>/<originalName>
///
/// The writer builds the folder under `PendingImports/.incoming/` and renames it into place only
/// once it is complete, so the reader never sees half a share. The reader claims a share by moving
/// its whole folder out of the container before reading the payload: once moved, the marker is
/// gone from the inbox, so it is read exactly once even if the app is killed straight afterwards.
/// A folder whose marker is missing, malformed, inconsistent or older than `maximumAge` is removed
/// rather than offered.
///
/// Foundation only: this file is compiled into both the extension and the app.
struct PendingShareInbox: Sendable {
    static let appGroupID = "group.io.tonebox.baton"
    static let markerName = "marker.json"
    static let incomingName = ".incoming"
    /// A share nobody came back for in a week is dropped rather than sprung on its owner later.
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    /// An unfinished write older than this belongs to an extension that was killed mid-copy.
    static let abandonedWriteAge: TimeInterval = 60 * 60

    struct Marker: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case file, link }
        var version = 1
        let id: String
        let kind: Kind
        /// The file's name as shared, or the page's host for a link.
        let originalName: String
        let created: Date
        /// The page's address; links only.
        var link: String?
    }

    /// A share taken out of the inbox: a file now owned by the app, or a web page's address.
    struct Claimed: Equatable, Sendable {
        let marker: Marker
        let url: URL
    }

    enum WriteError: Error { case notAWebLink, unusableName, batonShareLink }

    let root: URL

    /// The real inbox in the App Group container; nil when the group is not provisioned (a build
    /// signed without it, see `WITH_ENTITLEMENTS=0` in ios/scripts/testflight.sh).
    static var shared: PendingShareInbox? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            .map { PendingShareInbox(root: $0.appendingPathComponent("PendingImports", isDirectory: true)) }
    }

    // MARK: - Writing (the extension)

    /// Copy a shared file in. The source is read once by the file system, never into memory.
    @discardableResult
    func writeFile(copying source: URL, originalName: String, now: Date = Date()) throws -> Marker {
        guard let name = Self.safeName(originalName) else { throw WriteError.unusableName }
        return try write(kind: .file, name: name, link: nil, now: now) { folder in
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
        }
    }

    /// Words shared as text rather than as a file, kept as a plain-text document.
    @discardableResult
    func writeText(_ text: String, originalName: String = "Shared text.txt", now: Date = Date()) throws -> Marker {
        guard let name = Self.safeName(originalName) else { throw WriteError.unusableName }
        return try write(kind: .file, name: name, link: nil, now: now) { folder in
            try Data(text.utf8).write(to: folder.appendingPathComponent(name))
        }
    }

    /// A page's address, kept without its fragment. A Baton share link is refused: its fragment
    /// is the song's key, and as a "page" it would be written here, used as a file name and sent
    /// to the gateway by Send to my Mac (TBX-1000000505 B-6).
    @discardableResult
    func writeLink(_ url: URL, now: Date = Date()) throws -> Marker {
        guard !Self.isBatonShareLink(url) else { throw WriteError.batonShareLink }
        guard Self.isWebLink(url), let host = url.host else { throw WriteError.notAWebLink }
        return try write(kind: .link, name: host, link: Self.withoutFragment(url).absoluteString, now: now) { _ in }
    }

    private func write(kind: Marker.Kind, name: String, link: String?, now: Date,
                       payload: (URL) throws -> Void) throws -> Marker {
        let fileManager = FileManager.default
        let id = UUID().uuidString
        let incoming = root.appendingPathComponent(Self.incomingName, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: incoming, withIntermediateDirectories: true)
        do {
            try payload(incoming)
            // Whole seconds, as the ISO 8601 marker stores them, so what the writer returns is
            // exactly what the reader will find.
            let created = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
            let marker = Marker(id: id, kind: kind, originalName: name, created: created, link: link)
            try Self.encoder.encode(marker).write(to: incoming.appendingPathComponent(Self.markerName), options: .atomic)
            try fileManager.moveItem(at: incoming, to: root.appendingPathComponent(id, isDirectory: true))
            return marker
        } catch {
            try? fileManager.removeItem(at: incoming)
            throw error
        }
    }

    // MARK: - Reading (the app)

    /// Take the oldest valid share out of the inbox, moving it under `staging`, and tidy away
    /// anything that cannot be offered. Returns nil when there is nothing to open.
    func claimOldest(into staging: URL, now: Date = Date()) -> Claimed? {
        let fileManager = FileManager.default
        removeAbandonedWrites(now: now)
        let folders = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles])) ?? []
        var valid: [(folder: URL, marker: Marker)] = []
        for folder in folders {
            if let marker = validMarker(in: folder, now: now) {
                valid.append((folder, marker))
            } else {
                try? fileManager.removeItem(at: folder)
            }
        }
        for (folder, marker) in valid.sorted(by: { ($0.marker.created, $0.marker.id) < ($1.marker.created, $1.marker.id) }) {
            let claimed = staging.appendingPathComponent(marker.id, isDirectory: true)
            do {
                try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
                try? fileManager.removeItem(at: claimed)
                try fileManager.moveItem(at: folder, to: claimed)
            } catch {
                // Could not be taken out, so it could be offered again: drop it rather than risk that.
                try? fileManager.removeItem(at: folder)
                continue
            }
            try? fileManager.removeItem(at: claimed.appendingPathComponent(Self.markerName))
            switch marker.kind {
            case .file:
                return Claimed(marker: marker, url: claimed.appendingPathComponent(marker.originalName))
            case .link:
                try? fileManager.removeItem(at: claimed)
                guard let link = marker.link.flatMap(URL.init(string:)) else { continue }
                return Claimed(marker: marker, url: link)
            }
        }
        return nil
    }

    private func validMarker(in folder: URL, now: Date) -> Marker? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.markerName)),
              let marker = try? Self.decoder.decode(Marker.self, from: data),
              marker.version == 1,
              marker.id == folder.lastPathComponent,
              UUID(uuidString: marker.id) != nil,
              now.timeIntervalSince(marker.created) <= Self.maximumAge,
              marker.created.timeIntervalSince(now) <= 24 * 60 * 60   // a clock far ahead is not a real share
        else { return nil }
        switch marker.kind {
        case .file:
            guard marker.link == nil, Self.safeName(marker.originalName) == marker.originalName,
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent(marker.originalName).path)
            else { return nil }
        case .link:
            guard let link = marker.link.flatMap(URL.init(string:)), Self.isWebLink(link),
                  !Self.isBatonShareLink(link) else { return nil }
        }
        return marker
    }

    private func removeAbandonedWrites(now: Date) {
        let fileManager = FileManager.default
        let incoming = root.appendingPathComponent(Self.incomingName, isDirectory: true)
        let writes = (try? fileManager.contentsOfDirectory(at: incoming, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for write in writes {
            let created = (try? write.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if now.timeIntervalSince(created) > Self.abandonedWriteAge { try? fileManager.removeItem(at: write) }
        }
    }

    // MARK: - Rules both sides share

    /// The extension's confirmation: a page by its title when the share carried one,
    /// "Saved “The Yellow Wallpaper” for Baton", rather than by its site; otherwise the file's name,
    /// or a link's host when nothing better came with it.
    static func confirmation(for marker: Marker, pageTitle: String?) -> String {
        if marker.kind == .link, let title = pageTitle { return "Saved “\(title)” for Baton" }
        return "Saved \(marker.originalName) for Baton"
    }

    /// The page's title among what a share carried (the item's `attributedTitle`, its
    /// `attributedContentText`, the provider's suggested name), first usable one first: one line,
    /// not the address itself, at most 200 characters. Nil when none will do.
    static func pageTitle(from candidates: [String?], link: String?) -> String? {
        let address = link?.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = link.flatMap { URL(string: $0)?.host }
        for candidate in candidates {
            guard let line = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty,
                  !line.contains(where: \.isNewline), line.count <= 200,
                  line != address, line != host, URL(string: line).map(isWebLink) != true else { continue }
            return line
        }
        return nil
    }

    static func isWebLink(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }

    /// A Baton share link (`https://batonmusic.app/s/<id>#<key>`, `/m/`, `/b/`, or `baton://`),
    /// whose fragment is a key. Foundation only, so the extension can ask without BatonShareKit;
    /// the hosts are `ShareLink.hosts`, and `ShareInboxTests` checks the two agree.
    static func isBatonShareLink(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "baton" { return ["share", "mixtape"].contains(url.host?.lowercased() ?? "") }
        guard ["http", "https"].contains(scheme), let host = url.host?.lowercased(), batonShareHosts.contains(host) else { return false }
        return ["/s/", "/m/", "/b/"].contains { url.path.hasPrefix($0) }
    }

    static let batonShareHosts: Set<String> = ["batonmusic.app", "www.batonmusic.app", "baton.tonebox.io"]

    /// The address with no fragment: a page is read without one, and a fragment can be a secret.
    static func withoutFragment(_ url: URL) -> URL {
        guard url.fragment != nil, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.fragment = nil
        return parts.url ?? url
    }

    /// A shared name as a single path component: no separators, not hidden, not the marker's.
    static func safeName(_ name: String) -> String? {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.hasPrefix("."), cleaned != markerName, cleaned.utf8.count <= 200 else { return nil }
        return cleaned
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
