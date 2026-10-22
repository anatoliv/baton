import Foundation

/// A document the iPhone sent to the Mac through the home gateway.
///
/// The phone can read a document but not make it into a book on its own; the Mac can. When the
/// home server is there but cannot make books (no voice server, books off), the phone parks the
/// original on the gateway and the Mac opens it in its import sheet. This record is what travels
/// beside the document, as its own small JSON file, so the title, the original file name and the
/// sending device keep their exact spelling: header values are ASCII, people's names are not.
public struct PendingImport: Codable, Equatable, Sendable, Identifiable {
    /// The record's content type on the gateway. It is how a pending import is told apart from
    /// everything else in the file store, with no change to the gateway.
    public static let contentType = "application/vnd.baton.pending-import+json"
    /// A Mac's claim on a record (see `PendingImportRelay.claim(as:)`).
    public static let claimContentType = "application/vnd.baton.pending-import-claim"

    /// The record's id on the gateway: a lowercase UUID.
    public var id: String
    /// What the phone read as the document's title.
    public var title: String
    /// The original file name, or nil for a link.
    public var filename: String?
    /// The original kind: the file's extension ("pdf", "epub", "md"), or "link".
    public var kind: String
    /// The document's own content type on the gateway, or nil for a link.
    public var contentType: String?
    public var size: Int?
    /// The document's digest, checked by the Mac after download (the gateway never checks).
    public var sha256: String?
    /// Where the document is on the gateway, or nil for a link.
    public var documentID: String?
    /// The page's address, for a link import.
    public var link: String?
    /// The sending device's name, for "Sent from Anatoli's iPhone".
    public var fromDevice: String
    public var sentAt: Date

    public init(id: String, title: String, filename: String?, kind: String, contentType: String?,
                size: Int?, sha256: String?, documentID: String?, link: String?,
                fromDevice: String, sentAt: Date) {
        self.id = id
        self.title = title
        self.filename = filename
        self.kind = kind
        self.contentType = contentType
        self.size = size
        self.sha256 = sha256
        self.documentID = documentID
        self.link = link
        self.fromDevice = fromDevice
        self.sentAt = sentAt
    }

    /// The document's id on the gateway: the record's id with a fixed suffix, so the two are
    /// found and deleted together. `d0c` because ids are hex and dashes only.
    public static func documentID(for recordID: String) -> String { "\(recordID)-d0c" }
    /// One Mac's claim on a record.
    public static func claimID(for recordID: String, device: String) -> String { "\(recordID)-\(device)" }
}

/// The road for `PendingImport`: the gateway's existing file routes (`PUT`/`GET`/`DELETE
/// /v1/files`), with nothing new on the gateway.
///
/// **Kept away from the phone's clipping collector.** That collector takes every listed file
/// that carries a digest, installed phones included, so nothing here sends one: the document's
/// digest travels inside the record, and the Mac checks it after download.
///
/// **Taken exactly once, even with two Macs.** The gateway has no compare-and-set: a `DELETE`
/// answers 200 whether or not the file was there, and two Macs can both download before either
/// deletes. So a Mac first puts a small claim beside the record, waits a moment, and lists again.
/// The earliest claim wins (ties go to the smaller id), and every Mac reaches the same answer:
/// the gateway stamps each claim when it is stored, to the second, and the wait is longer than a
/// second, so any claim stamped no later than a Mac's own is already stored when that Mac lists
/// again. A Mac that loses removes its claim and leaves the record alone.
///
/// The record, the document and the claims stay on the gateway until the person imports or
/// discards it on the Mac that won (`finish`). "Not Now" leaves them, held by that Mac. If no
/// Mac collects them, the gateway's own fourteen-day limit clears them, and under its total cap
/// it may clear them sooner; a record found without its document reads as `documentMissing`.
public struct PendingImportRelay: Sendable {
    let files: GatewayFiles
    /// How long a Mac waits between claiming and checking who won. Over a second, because the
    /// gateway stamps claims to the second.
    let settle: Duration

    public init(files: GatewayFiles, settle: Duration = .milliseconds(2_100)) {
        self.files = files
        self.settle = settle
    }

    // MARK: - The phone's half

    /// Park a document for the Mac: the file first, then the record that points at it, so a Mac
    /// never finds a record whose document is still on its way.
    @discardableResult
    public func send(file: URL, title: String, contentType: String, fromDevice: String,
                     now: Date = Date()) async throws -> PendingImport {
        let id = UUID().uuidString.lowercased()
        let digest = try GatewayFiles.sha256(of: file)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        let documentID = PendingImport.documentID(for: id)
        let filename = file.lastPathComponent
        try await files.put(file, id: documentID, name: GatewayFiles.headerSafe(filename),
                            contentType: contentType, origin: GatewayFiles.headerSafe(fromDevice), sha256: nil)
        let record = PendingImport(id: id, title: title, filename: filename,
                                   kind: file.pathExtension.lowercased().isEmpty ? "file" : file.pathExtension.lowercased(),
                                   contentType: contentType, size: size, sha256: digest, documentID: documentID,
                                   link: nil, fromDevice: fromDevice, sentAt: now)
        do {
            try await putRecord(record)
        } catch {
            // A document with no record is never picked up; take it back rather than leave it
            // for the gateway's fortnight.
            try? await files.delete(id: documentID)
            throw error
        }
        return record
    }

    /// Park a link for the Mac: the record alone, since the Mac reads the page itself. Without
    /// its fragment, which the Mac does not need to read the page and which can be a secret, a
    /// Baton share link's key.
    @discardableResult
    public func send(link: URL, title: String, fromDevice: String, now: Date = Date()) async throws -> PendingImport {
        var parts = URLComponents(url: link, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        let address = parts?.url ?? link
        let record = PendingImport(id: UUID().uuidString.lowercased(), title: title, filename: nil, kind: "link",
                                   contentType: nil, size: nil, sha256: nil, documentID: nil,
                                   link: address.absoluteString, fromDevice: fromDevice, sentAt: now)
        try await putRecord(record)
        return record
    }

    private func putRecord(_ record: PendingImport) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(record)
        try await withTemporaryFile(body) { url in
            try await files.put(url, id: record.id, name: "pending-import.json",
                                contentType: PendingImport.contentType,
                                origin: GatewayFiles.headerSafe(record.fromDevice), sha256: nil)
        }
    }

    // MARK: - The Mac's half

    /// The records this Mac holds, oldest first: those it claimed before, and those nobody had
    /// claimed that it has just won. `device` is this Mac's own id (a lowercase UUID it keeps).
    public func claim(as device: String) async throws -> [String] {
        let before = try await files.list()
        let records = before.filter { $0.contentType == PendingImport.contentType }
            .sorted { $0.createdAt < $1.createdAt }
        var held: [String] = []
        var asked: [String] = []
        for record in records {
            let claims = Self.claims(on: record.id, in: before)
            if claims.isEmpty {
                try await withTemporaryFile(Data("{}".utf8)) { url in
                    try await files.put(url, id: PendingImport.claimID(for: record.id, device: device), name: "claim",
                                        contentType: PendingImport.claimContentType, origin: "Mac", sha256: nil)
                }
                asked.append(record.id)
            } else if Self.winner(claims) == PendingImport.claimID(for: record.id, device: device) {
                held.append(record.id)
            }
        }
        guard !asked.isEmpty else { return held }

        try await Task.sleep(for: settle)
        let after = try await files.list()
        var won: Set<String> = []
        for id in asked {
            let mine = PendingImport.claimID(for: id, device: device)
            if Self.winner(Self.claims(on: id, in: after)) == mine {
                won.insert(id)
            } else {
                try? await files.delete(id: mine)
            }
        }
        return records.map(\.id).filter { held.contains($0) || won.contains($0) }
    }

    /// Why a held record could not be brought down, beyond the transfer's own errors.
    public enum FetchError: LocalizedError, Equatable {
        /// The record is there but its document is not: the gateway's age limit or its cap
        /// eviction took the document first, since it was stored first. It will
        /// never arrive, so the Mac says so and finishes the record rather than asking again.
        case documentMissing(PendingImport)

        public var errorDescription: String? {
            switch self {
            case let .documentMissing(record): "\(record.title) didn't arrive. Send it again from the iPhone."
            }
        }
    }

    /// Bring a held record and its document down into `directory`, the document verified
    /// against the digest the phone recorded. Throws `TransferError.rejected(404, _)` when the
    /// record is no longer there, and `FetchError.documentMissing` when the record is there and
    /// its document is not.
    public func fetch(_ id: String, into directory: URL) async throws -> (record: PendingImport, file: URL?) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recordURL = directory.appendingPathComponent("pending-import.json")
        try await files.download(id: id, expecting: nil, to: recordURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(PendingImport.self, from: Data(contentsOf: recordURL))
        guard let documentID = record.documentID else { return (record, nil) }
        let name = Self.safeFilename(record.filename ?? "document.\(record.kind)")
        let file = directory.appendingPathComponent(name)
        do {
            try await files.download(id: documentID, expecting: record.sha256, to: file)
        } catch GatewayFiles.TransferError.rejected(404, _) {
            throw FetchError.documentMissing(record)
        }
        return (record, file)
    }

    /// Imported or discarded: remove the record first (so no Mac finds it again), then the
    /// document, then every claim on it.
    public func finish(_ id: String) async throws {
        try await files.delete(id: id)
        try await files.delete(id: PendingImport.documentID(for: id))
        let listing = (try? await files.list()) ?? []
        for claim in Self.claims(on: id, in: listing) {
            try? await files.delete(id: claim.id)
        }
    }

    // MARK: - Helpers

    static func claims(on id: String, in listing: [GatewayFiles.RemoteFile]) -> [GatewayFiles.RemoteFile] {
        listing.filter { $0.contentType == PendingImport.claimContentType && $0.id.hasPrefix("\(id)-") }
    }

    /// The earliest claim, ties to the smaller id: the same answer on every Mac that sees it.
    static func winner(_ claims: [GatewayFiles.RemoteFile]) -> String? {
        claims.min { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }?.id
    }

    /// The phone's file name, kept to a plain last path component on the Mac's disk.
    static func safeFilename(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return last.isEmpty || last.hasPrefix(".") ? "document" + last : last
    }

    private func withTemporaryFile<T>(_ data: Data, _ body: (URL) async throws -> T) async throws -> T {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("baton-relay-\(UUID().uuidString).json")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url)
    }
}
