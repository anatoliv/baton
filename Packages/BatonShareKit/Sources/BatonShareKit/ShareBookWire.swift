import Foundation

/// The book caps the service advertises in `GET /v1/share/config` beside `books: 1`.
public struct ShareBookLimits: Codable, Equatable, Sendable {
    public var maxBookBytes: Int
    public var maxChapters: Int
    public var maxChapterBytes: Int
    public var maxTextBytes: Int
    public var maxManifestBytes: Int
    public var maxChapterSeconds: Int
    public var maxBookSeconds: Int
    public var defaultListeners: Int
    public var maxListeners: Int
    public var liveBooksPerSharer: Int

    public init(limits: ShareLimits) {
        maxBookBytes = limits.maxBookBytes
        maxChapters = limits.maxBookChapters
        maxChapterBytes = limits.maxBookChapterBytes
        maxTextBytes = limits.maxBookTextBytes
        maxManifestBytes = limits.maxBookManifestBytes
        maxChapterSeconds = limits.maxBookChapterSeconds
        maxBookSeconds = limits.maxBookSeconds
        defaultListeners = limits.defaultBookListeners
        maxListeners = limits.maxBookListeners
        liveBooksPerSharer = limits.liveBooksPerSharer
    }

    /// These caps applied to a copy of `base`, for validating against what a service advertised.
    public func applied(to base: ShareLimits = .standard) -> ShareLimits {
        var limits = base
        limits.maxBookBytes = maxBookBytes
        limits.maxBookChapters = maxChapters
        limits.maxBookChapterBytes = maxChapterBytes
        limits.maxBookTextBytes = maxTextBytes
        limits.maxBookManifestBytes = maxManifestBytes
        limits.maxBookChapterSeconds = maxChapterSeconds
        limits.maxBookSeconds = maxBookSeconds
        limits.defaultBookListeners = defaultListeners
        limits.maxBookListeners = maxListeners
        limits.liveBooksPerSharer = liveBooksPerSharer
        return limits
    }
}

/// What the service advertises beside `collections: 1` (specs/collection-sharing.md): the kinds
/// it takes and the cover cap. Every other cap is the book's (`ShareBookLimits`), shared.
public struct ShareCollectionLimits: Codable, Equatable, Sendable {
    public var kinds: [ShareCollectionKind]
    public var maxCoverBytes: Int
    public init(kinds: [ShareCollectionKind] = ShareCollectionKind.allCases, maxCoverBytes: Int = ShareBookManifest.maxCoverBytes) {
        self.kinds = kinds; self.maxCoverBytes = maxCoverBytes
    }

    /// Music in a collection is AAC at this bit rate (books stay at their 48 kbps).
    public static let musicBitRate = 128_000
    /// Lower rates, highest first, for a track whose 128 kbps file would pass the per-track cap.
    public static let fallbackBitRates = [96_000, 64_000, 48_000]

    /// The highest bit rate at which a track of `seconds` seals within `maxTrackBytes`, allowing
    /// for the container and BSH1 overhead, or nil when even the lowest would not fit.
    public static func bitRate(forSeconds seconds: Int, maxTrackBytes: Int) -> Int? {
        let budget = Double(maxTrackBytes) * 0.94 // MP4 boxes, the rate allowance and BSH1 tags
        return ([musicBitRate] + fallbackBitRates).first { Double($0) / 8 * Double(max(1, seconds)) <= budget }
    }

    /// How far over its nominal rate a track may come out: the up-front estimate allows for it,
    /// and a server's AAC is copied as it is only within it (otherwise it is encoded again), so the
    /// caps checked before the first fetch hold as each track lands.
    public static let rateAllowance = 1.05

    /// The size a track will roughly have at `bitRate`, for the composer's estimate.
    public static func estimatedBytes(seconds: Int, bitRate: Int = musicBitRate) -> Int {
        Int(Double(bitRate) / 8 * Double(max(1, seconds)) * rateAllowance) + 4096
    }

    /// The encoder's sample rate for `bitRate`: AAC-LC stereo at 44.1 kHz cannot go below 64 kbps,
    /// so the lower fallback rates encode at 32 kHz.
    public static func sampleRate(forBitRate bitRate: Int) -> Int { bitRate < 64_000 ? 32_000 : 44_100 }
}

/// What the service knows about one stored blob of a book: whether it is chapter audio or
/// read-along text (so it can apply that blob's cap), its sealed length and its SHA-256.
public struct BookBlobDescriptor: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case audio, text }
    public var role: Role
    public var bytes: Int
    public var sha256: String
    public init(role: Role, bytes: Int, sha256: String) { self.role = role; self.bytes = bytes; self.sha256 = sha256 }
}

/// What a public-mode book link shows before it is opened. Private mode sends none.
public struct BookPreview: Codable, Equatable, Sendable {
    public var title: String
    public var author: String
    public var from: String
    public var note: String
    public init(title: String, author: String = "", from: String = "", note: String = "") {
        self.title = title; self.author = author; self.from = from; self.note = note
    }

    public func validated() throws -> Self {
        let result = Self(title: try ShareText.clean(title, field: "preview.title", max: ShareLimits.maxTitleLength),
                          author: try ShareText.clean(author, field: "preview.author", max: ShareLimits.maxTitleLength),
                          from: try ShareText.clean(from, field: "preview.from", max: ShareLimits.maxFromLength),
                          note: try ShareText.clean(note, field: "preview.note", max: ShareLimits.maxNoteLength, allowNewlines: true))
        guard !result.title.isEmpty else { throw ShareValidationError("preview.title", "is required") }
        return result
    }
}

/// `POST /v1/share/books`. Retried with the same `requestID` and identical bytes, it answers the
/// same live book; an altered body under that ID is a 409.
public struct CreateBookRequest: Codable, Equatable, Sendable {
    /// `baton-book-1` for a book, `baton-collection-1` for an album or a playlist.
    public var schema = ShareBookManifest.schemaVersion
    /// The collection's kind, in the clear so the service can count and present it; absent for a book.
    public var kind: ShareCollectionKind?
    public var requestID: String
    public var encryptedManifest: String
    public var blobs: [String: BookBlobDescriptor]
    public var totalDurationSeconds: Int
    public var expiresInSeconds: Int
    /// How many listeners the link admits (one listening session each).
    public var listenerCap: Int
    public var preview: BookPreview?
    public var client: ShareClientInfo
    public var reviewPreservationConsent: String?

    public init(requestID: String = UUID().uuidString, encryptedManifest: String, blobs: [String: BookBlobDescriptor],
                totalDurationSeconds: Int, expiresInSeconds: Int, listenerCap: Int, preview: BookPreview?,
                client: ShareClientInfo, reviewPreservationConsent: String? = nil, kind: ShareCollectionKind? = nil) {
        self.schema = kind == nil ? ShareBookManifest.schemaVersion : ShareBookManifest.collectionSchemaVersion
        self.kind = kind
        self.requestID = requestID; self.encryptedManifest = encryptedManifest; self.blobs = blobs
        self.totalDurationSeconds = totalDurationSeconds; self.expiresInSeconds = expiresInSeconds
        self.listenerCap = listenerCap; self.preview = preview; self.client = client
        self.reviewPreservationConsent = reviewPreservationConsent
    }

    public var manifestBytes: Int { Data(base64Encoded: encryptedManifest)?.count ?? 0 }
    public var blobBytes: Int { blobs.values.reduce(0) { $0 + $1.bytes } }
    /// Everything the book holds on the service: blobs and manifest.
    public var totalBytes: Int { blobBytes + manifestBytes }
    public var chapterCount: Int { blobs.values.filter { $0.role == .audio }.count }

    public func validated(limits: ShareLimits = .standard) throws -> Self {
        let collection = kind != nil
        guard schema == (collection ? ShareBookManifest.collectionSchemaVersion : ShareBookManifest.schemaVersion),
              UUID(uuidString: requestID) != nil,
              (1 ... limits.maxBookSeconds).contains(totalDurationSeconds),
              limits.expiryChoices.contains(expiresInSeconds),
              (1 ... limits.maxBookListeners).contains(listenerCap),
              reviewPreservationConsent == nil || reviewPreservationConsent == CreateShareRequest.reviewConsentVersion,
              ShareClientInfo.platforms.contains(client.platform),
              let manifest = Data(base64Encoded: encryptedManifest), manifest.count <= limits.maxBookManifestBytes,
              (try? ShareCrypto.layout(headerBytes: Array(manifest.prefix(ShareCrypto.headerLength)), totalLength: manifest.count)) != nil
        else { throw ShareValidationError("book", "invalid book request") }
        let audio = blobs.values.filter { $0.role == .audio }.count
        guard (1 ... limits.maxBookChapters).contains(audio), blobs.count - audio <= audio, !collection || blobs.count == audio else {
            throw ShareValidationError("blobs", "must hold 1 to \(limits.maxBookChapters) chapters and at most one text each")
        }
        var total = manifest.count
        for (id, blob) in blobs {
            let cap = blob.role == .audio ? limits.maxBookChapterBytes : limits.maxBookTextBytes
            guard ShareBookCrypto.isCanonicalID(id), ShareBookManifest.validBlob(blob.bytes, blob.sha256, max: cap),
                  blob.bytes <= limits.maxBookBytes - total else {
                throw ShareValidationError("blobs", "invalid blob descriptor or book total")
            }
            total += blob.bytes
        }
        var result = self
        result.preview = try preview?.validated()
        result.client.appVersion = try ShareText.clean(client.appVersion, field: "client.appVersion", max: 40)
        return result
    }
}

public struct CreateBookResponse: Codable, Equatable, Sendable {
    public var id: String
    /// The keyless `…/b/<id>` link; the app adds `#<key>`.
    public var url: String
    public var expiresAt: String
    /// Blob ID → the owner path its sealed bytes are PUT to.
    public var uploads: [String: String]
    public init(id: String, url: String, expiresAt: String, uploads: [String: String]) {
        self.id = id; self.url = url; self.expiresAt = expiresAt; self.uploads = uploads
    }
}

/// `GET /v1/share/b/<id>`: what a listener's page or app needs before admission. Spends nothing.
public struct PublicBook: Codable, Equatable, Sendable {
    public var schema: String = ShareBookManifest.schemaVersion
    /// The collection's kind; absent for a book.
    public var kind: ShareCollectionKind?
    public var status: ShareStatus
    public var preview: BookPreview?
    public var encryptedManifest: String
    public var blobs: [String: BookBlobDescriptor]
    public var expiresAt: String
    public var remainingListeners: Int
    public init(status: ShareStatus, preview: BookPreview?, encryptedManifest: String, blobs: [String: BookBlobDescriptor],
                expiresAt: String, remainingListeners: Int, kind: ShareCollectionKind? = nil) {
        self.schema = kind == nil ? ShareBookManifest.schemaVersion : ShareBookManifest.collectionSchemaVersion
        self.kind = kind
        self.status = status; self.preview = preview; self.encryptedManifest = encryptedManifest; self.blobs = blobs
        self.expiresAt = expiresAt; self.remainingListeners = remainingListeners
    }

    /// Opens the manifest and checks every descriptor the service sent against it.
    public func open(rootKey: Data, limits: ShareLimits = .standard) throws -> ShareBookManifest {
        guard schema == (kind == nil ? ShareBookManifest.schemaVersion : ShareBookManifest.collectionSchemaVersion),
              let bytes = Data(base64Encoded: encryptedManifest) else {
            throw ShareValidationError("book", "unsupported or malformed manifest")
        }
        let manifest = try ShareBookManifest.open(bytes, rootKey: rootKey, limits: limits)
        guard manifest.schema == schema, manifest.kind == kind, manifest.blobs == blobs else {
            throw ShareValidationError("book", "descriptors do not match the authenticated manifest")
        }
        return manifest
    }
}

/// `POST /v1/share/b/<id>/sessions`: one listener admitted. The token authorizes blob reads,
/// events and reactions for this book until the link ends, within `remainingBytes`.
public struct BookSession: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "BookSession(credential withheld)" }
    public var debugDescription: String { description }
    public var token: String
    public var expiresAt: String
    public var remainingBytes: Int
    public var remainingListeners: Int
    public init(token: String, expiresAt: String, remainingBytes: Int, remainingListeners: Int) {
        self.token = token; self.expiresAt = expiresAt; self.remainingBytes = remainingBytes
        self.remainingListeners = remainingListeners
    }
}

/// The sharer's view of a book link. `share.playCap` is the listener cap and `share.stats.fetches`
/// the listeners admitted so far.
public struct BookSummary: Codable, Equatable, Sendable {
    public var share: ShareSummary
    public var chapterCount: Int
    public var hasText: Bool
    public var reviewDeadline: String?
    public var pausedLifetimeSeconds: Int64?
    /// An album or playlist link's kind; absent for a book. `chapterCount` is then its tracks.
    public var kind: ShareCollectionKind?
    public init(share: ShareSummary, chapterCount: Int, hasText: Bool, reviewDeadline: String? = nil,
                pausedLifetimeSeconds: Int64? = nil, kind: ShareCollectionKind? = nil) {
        self.kind = kind
        self.share = share; self.chapterCount = chapterCount; self.hasText = hasText
        self.reviewDeadline = reviewDeadline; self.pausedLifetimeSeconds = pausedLifetimeSeconds
    }
}

public struct BookList: Codable, Equatable, Sendable {
    public var books: [BookSummary]
    public init(books: [BookSummary]) { self.books = books }
}
