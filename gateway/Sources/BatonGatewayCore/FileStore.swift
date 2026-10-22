import Foundation

/// Files parked on the gateway so they can cross between a Mac and a phone.
///
/// The first thing to carry is an exported reading, but nothing here knows what a reading is:
/// it stores bytes under an id the client chooses, with metadata beside them. Podcast episode
/// audio and downloaded tracks would want the same road, and inventing a second one per file
/// type is how a household ends up with three half-working transports.
///
/// **The gateway does not verify content, deliberately.** The obvious design has it hash each
/// upload and reject a mismatch. That needs a SHA-256 implementation, and `CryptoKit` is
/// Apple-only while this runs on Linux, so it would mean a new dependency in a package whose
/// transport was written specifically to keep that list empty. The better answer costs nothing:
/// the sending device computes the digest, stores it in the metadata, and the *receiving* device
/// checks it after download. End-to-end beats hop-by-hop — it catches corruption in this store's
/// own files, not only in transit, and it means a gateway nobody fully trusts still cannot hand
/// over bad bytes without being caught. What is enforced here is framing: a body whose length
/// disagrees with its `Content-Length` never lands.
///
/// **Everything is bounded**, because a household gateway that fills its own disk is worse than
/// one that refuses a file. A per-file cap, a total cap with oldest-first eviction, and an age
/// limit — all three, since any one alone has an obvious way to be defeated by ordinary use.
public struct FileStore: Sendable {

    /// One stored file. Written as a sidecar next to the blob rather than into a central index:
    /// an index is one file whose corruption loses everything, and a directory of pairs can be
    /// rebuilt by listing it.
    public struct Metadata: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var contentType: String
        public var size: Int
        /// The sender's digest, for the receiver to check. Opaque here.
        public var sha256: String?
        public var createdAt: Date
        /// Which device put it there, for the listing. Not a permission — anything holding the
        /// bearer token can read everything, and pretending otherwise would be security theatre.
        public var origin: String?
    }

    /// Refused rather than truncated. A 7 MB article is the case in hand; the ceiling is set for
    /// a podcast episode, which is the next thing that will want this road.
    public static let defaultMaximumFileBytes = 64 * 1024 * 1024
    /// Everything held, together. Past this the oldest goes.
    public static let defaultMaximumTotalBytes = 512 * 1024 * 1024
    /// `name` comes straight from the caller's `X-Baton-Name` header, whose only bound is the
    /// transport's 32 KB header cap (TBX-5325, TBX-5308 S-F26). Truncated rather than refused —
    /// a display name is not something an upload should fail over — so every sidecar file and
    /// every `list()` response stays a display name's size, not a header's.
    public static let maximumNameLength = 255
    /// A file nobody collected in a fortnight is not going to be collected.
    public static let defaultMaximumAge: TimeInterval = 14 * 24 * 60 * 60

    /// The record type of the phone's "Send to my Mac" relay (`PendingImport.contentType` in
    /// BatonPlaybackKit). The one content type this store treats specially; see `prune`.
    public static let pendingImportContentType = "application/vnd.baton.pending-import+json"

    public let directory: URL
    /// The limits, as values rather than constants.
    ///
    /// Injectable because otherwise the only way to test them is to write a 64 MB file and then a
    /// 512 MB one — slow, disk-hungry, and enough friction that the eviction path would have gone
    /// untested, which is exactly the path that quietly deletes someone's file.
    public let maximumFileBytes: Int
    public let maximumTotalBytes: Int
    public let maximumAge: TimeInterval

    public init(directory: URL,
                maximumFileBytes: Int = FileStore.defaultMaximumFileBytes,
                maximumTotalBytes: Int = FileStore.defaultMaximumTotalBytes,
                maximumAge: TimeInterval = FileStore.defaultMaximumAge) {
        self.directory = directory
        self.maximumFileBytes = maximumFileBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumAge = maximumAge
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Reading

    public func metadata(id: String) -> Metadata? {
        guard let id = Self.sanitize(id),
              let data = try? Data(contentsOf: sidecarURL(id)),
              let meta = try? JSONDecoder().decode(Metadata.self, from: data)
        else { return nil }
        return meta
    }

    public func blobURL(id: String) -> URL? {
        guard let id = Self.sanitize(id) else { return nil }
        let url = blobURLUnchecked(id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Newest first, which is the order a "what is waiting for me" list wants.
    public func list() -> [Metadata] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { metadata(id: String($0.dropLast(5))) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Writing

    public enum StoreError: Error, Equatable {
        case badID
        case tooLarge(limit: Int)
    }

    /// Take a staged upload and publish it under `id`.
    ///
    /// `staged` is a file the transport has already streamed to disk, so a large upload never
    /// exists in memory as one `Data`. It is *moved* into place, not copied: a rename within one
    /// filesystem is atomic, so a reader either sees the whole file or no file, and a gateway
    /// killed mid-publish cannot leave a half-written blob that a later GET happily serves.
    @discardableResult
    public func commit(staged: URL, id: String, name: String, contentType: String,
                sha256: String?, origin: String?, now: Date = Date()) throws -> Metadata {
        guard let id = Self.sanitize(id) else {
            try? FileManager.default.removeItem(at: staged)
            throw StoreError.badID
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: staged.path)
        let size = (attributes?[.size] as? Int) ?? 0
        guard size <= maximumFileBytes else {
            try? FileManager.default.removeItem(at: staged)
            throw StoreError.tooLarge(limit: maximumFileBytes)
        }

        let blob = blobURLUnchecked(id)
        try? FileManager.default.removeItem(at: blob)   // replacing an id is a re-upload, not an error
        try FileManager.default.moveItem(at: staged, to: blob)

        let name = name.count <= Self.maximumNameLength ? name : String(name.prefix(Self.maximumNameLength))
        let meta = Metadata(id: id, name: name, contentType: contentType, size: size,
                            sha256: sha256, createdAt: now, origin: origin)
        try JSONEncoder().encode(meta).write(to: sidecarURL(id), options: .atomic)
        prune(now: now, keepingLast: id)
        return meta
    }

    public func remove(id: String) {
        guard let id = Self.sanitize(id) else { return }
        try? FileManager.default.removeItem(at: blobURLUnchecked(id))
        try? FileManager.default.removeItem(at: sidecarURL(id))
    }

    /// Drop what is too old, then what is over the total, oldest first.
    ///
    /// **A "Send to my Mac" import goes whole, and last**. The phone's relay
    /// stores a document (`<record>-d0c`), then its record (`<record>`, `pendingImportContentType`),
    /// then each Mac's claim (`<record>-<mac>`). Taken one file at a time, the document was always
    /// the oldest of the three, so the age limit and the cap removed it first and left a record
    /// the Mac claimed every minute, for a document that would never arrive. So the three are one
    /// group here: the age limit takes the group when its oldest file is too old, and under the
    /// cap every other file goes before any such group, and then whole groups go oldest first.
    /// They are not exempt from either bound; the Mac tells the person when one did not arrive.
    ///
    /// `keepingLast` is the file a commit has just written. Its group goes after every other, so
    /// an upload that was answered 201 is not evicted by its own commit (TBX-1000000493 review).
    public func prune(now: Date = Date(), keepingLast justCommitted: String? = nil) {
        for group in groups(list()) where group.files.contains(where: { now.timeIntervalSince($0.createdAt) > maximumAge }) {
            for meta in group.files { remove(id: meta.id) }
        }
        let files = list()
        var total = files.reduce(0) { $0 + $1.size }
        guard total > maximumTotalBytes else { return }
        let kept = justCommitted.flatMap(Self.sanitize)
        let order = groups(files).sorted {
            let last0 = $0.files.contains { $0.id == kept }, last1 = $1.files.contains { $0.id == kept }
            return (last0 ? 1 : 0, $0.isPendingImport ? 1 : 0, $0.oldest) < (last1 ? 1 : 0, $1.isPendingImport ? 1 : 0, $1.oldest)
        }
        for group in order {
            guard total > maximumTotalBytes else { break }
            for meta in group.files {
                remove(id: meta.id)
                total -= meta.size
            }
        }
    }

    /// The files that are evicted together: a pending import's record, document and claims, and
    /// every other file on its own.
    private struct EvictionGroup {
        var files: [Metadata]
        var isPendingImport: Bool
        var oldest: Date { files.map(\.createdAt).min() ?? .distantPast }
    }

    private func groups(_ files: [Metadata]) -> [EvictionGroup] {
        let records = Set(files.filter { $0.contentType == Self.pendingImportContentType }.map(\.id))
        var grouped: [String: EvictionGroup] = [:]
        var order: [String] = []
        for meta in files {
            // A document whose record has not landed yet (the phone sends it first) is still one.
            let documentOf = meta.id.hasSuffix("-d0c") ? String(meta.id.dropLast(4)) : nil
            let key = records.contains(meta.id) ? meta.id
                : (documentOf ?? records.first(where: { meta.id.hasPrefix("\($0)-") }) ?? meta.id)
            let pending = records.contains(key) || documentOf != nil
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: EvictionGroup(files: [], isPendingImport: pending)].files.append(meta)
        }
        return order.compactMap { grouped[$0] }
    }

    // MARK: - Ids

    /// Ids come off the wire and become file names, so they are whitelisted rather than escaped.
    ///
    /// A path separator or a `..` here would let a caller write outside the store, and this
    /// service is reachable from every device on the network. Hex and dashes cover a SHA-256
    /// digest and a UUID, which are the two things that will ever be used.
    public static func sanitize(_ id: String) -> String? {
        guard !id.isEmpty, id.count <= 128 else { return nil }
        let allowed = Set("0123456789abcdefABCDEF-")
        guard id.allSatisfy({ allowed.contains($0) }) else { return nil }
        return id.lowercased()
    }

    private func blobURLUnchecked(_ id: String) -> URL { directory.appendingPathComponent("\(id).blob") }
    private func sidecarURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }
}
