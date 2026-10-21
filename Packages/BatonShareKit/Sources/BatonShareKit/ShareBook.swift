#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The whole-book link format, `baton-book-1` (specs/book-sharing.md, "The format").
///
/// A book is an encrypted manifest and, per chapter, one audio blob and an optional read-along
/// text blob. Each is an ordinary BSH1 stream under its own key, derived from the link's root key
/// with HKDF-SHA256 (empty salt, 16 bytes). Chapter and text keys are bound to the chapter ID's
/// 16 decoded bytes, so a blob moved to another chapter, or a text blob read as audio, does not
/// open. Checked against `specs/share-crypto/vectors.json` ("book"), which neither this file nor
/// the browser's `share-book-crypto.mjs` wrote.
public enum ShareBookCrypto {
    public static let manifestLabel = "baton-share book v1 manifest"
    public static let chapterLabel = "baton-share book v1 chapter"
    public static let textLabel = "baton-share book v1 text"

    public static func manifestKey(rootKey: Data) throws -> Data {
        try derive(rootKey, info: Data(manifestLabel.utf8))
    }

    public static func chapterKey(rootKey: Data, chapterID: String) throws -> Data {
        try derive(rootKey, info: Data((chapterLabel + "\0").utf8) + id(chapterID))
    }

    public static func textKey(rootKey: Data, chapterID: String) throws -> Data {
        try derive(rootKey, info: Data((textLabel + "\0").utf8) + id(chapterID))
    }

    /// A canonical blob ID: 16 random bytes as 22 characters of unpadded base64url.
    public static func isCanonicalID(_ text: String) -> Bool { ShareMixtapeCrypto.canonicalID(text) != nil }

    public static func newID() -> String { Base64URL.encode(ShareCrypto.newKey()) }

    private static func id(_ text: String) throws -> Data {
        guard let bytes = ShareMixtapeCrypto.canonicalID(text) else {
            throw ShareValidationError("chapterID", "must be a canonical 16-byte ID")
        }
        return bytes
    }

    private static func derive(_ root: Data, info: Data) throws -> Data {
        guard root.count == ShareCrypto.keyLength else { throw ShareCrypto.Failure.badKey }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: root),
                                         salt: Data(), info: info, outputByteCount: ShareCrypto.keyLength)
        return key.withUnsafeBytes { Data($0) }
    }
}

/// What a `/b/` link holds besides a book: an album or a playlist (specs/collection-sharing.md).
public enum ShareCollectionKind: String, Codable, Equatable, Sendable, CaseIterable {
    case album, playlist
}

/// The encrypted manifest of a `/b/` link. A book (`baton-book-1`) holds its title and author, the
/// sender's From and note, and every chapter in order. An album or a playlist
/// (`baton-collection-1`, specs/collection-sharing.md) is the same shape under its own schema: the
/// kind, the title, the artist (kept in `author`), an optional cover image, and its tracks (kept in
/// `chapters`, each with an optional artist, album and track number, and never read-along text).
/// Both use the book's keys; the schema inside the authenticated manifest tells them apart. All of
/// it is inside the encryption, including track names, order and the cover.
public struct ShareBookManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = "baton-book-1"
    public static let collectionSchemaVersion = "baton-collection-1"
    /// A cover's decoded bytes, at most (the whole manifest stays within 256 KiB sealed).
    public static let maxCoverBytes = 131_072
    public static let maxTrackNumber = 9999

    public struct Text: Codable, Equatable, Sendable {
        /// The text blob's own random ID (its storage name); its key comes from the chapter's ID.
        public var id: String
        public var bytes: Int
        public var sha256: String
        public init(id: String, bytes: Int, sha256: String) { self.id = id; self.bytes = bytes; self.sha256 = sha256 }
    }

    /// A collection's cover: a JPEG or PNG inside the manifest, so a listener sees it before
    /// spending a listener and the service never sees it.
    public struct Cover: Codable, Equatable, Sendable {
        public static let types = ["image/jpeg", "image/png"]
        public var type: String
        /// Canonical, padded standard base64 of the image bytes.
        public var data: String
        public init(type: String, data: String) { self.type = type; self.data = data }
        public init(type: String, bytes: Data) { self.type = type; self.data = bytes.base64EncodedString() }

        public var bytes: Data? { Data(base64Encoded: data) }

        /// The image's type from its signature, or nil for anything but JPEG or PNG.
        public static func type(of bytes: Data) -> String? {
            if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
            if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
            return nil
        }

        public func validated() throws -> Self {
            guard Self.types.contains(type), let bytes = Data(base64Encoded: data), bytes.base64EncodedString() == data,
                  (1 ... ShareBookManifest.maxCoverBytes).contains(bytes.count), Self.type(of: bytes) == type else {
                throw ShareValidationError("cover", "must be a JPEG or PNG of at most \(ShareBookManifest.maxCoverBytes) bytes")
            }
            return self
        }
    }

    /// A book's chapter, or a collection's track.
    public struct Chapter: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        /// A track's own artist, when it has one. Never set on a book chapter.
        public var artist: String?
        /// A track's album, when it has one. Never set on a book chapter.
        public var album: String?
        /// A track's number on its album, 1 to 9999. Never set on a book chapter.
        public var trackNumber: Int?
        public var durationSeconds: Int
        public var audioBytes: Int
        public var audioSHA256: String
        public var text: Text?
        public init(id: String, title: String, durationSeconds: Int, audioBytes: Int, audioSHA256: String, text: Text? = nil,
                    artist: String? = nil, album: String? = nil, trackNumber: Int? = nil) {
            self.id = id; self.title = title; self.durationSeconds = durationSeconds
            self.audioBytes = audioBytes; self.audioSHA256 = audioSHA256; self.text = text
            self.artist = artist; self.album = album; self.trackNumber = trackNumber
        }

        enum CodingKeys: String, CodingKey { case id, title, artist, album, trackNumber, durationSeconds, audioBytes, audioSHA256, text }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            // Read leniently here, so a book chapter ignores these keys whatever they hold, as the
            // browser does; a collection's tracks are decoded strictly too (`TrackFields`).
            artist = (try? c.decodeIfPresent(String.self, forKey: .artist)) ?? nil
            album = (try? c.decodeIfPresent(String.self, forKey: .album)) ?? nil
            trackNumber = (try? c.decodeIfPresent(Int.self, forKey: .trackNumber)) ?? nil
            durationSeconds = try c.decode(Int.self, forKey: .durationSeconds)
            audioBytes = try c.decode(Int.self, forKey: .audioBytes)
            audioSHA256 = try c.decode(String.self, forKey: .audioSHA256)
            // A collection track carrying text is refused by `validated`, not dropped here.
            text = try c.decodeIfPresent(Text.self, forKey: .text)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(title, forKey: .title)
            try c.encodeIfPresent(artist, forKey: .artist)
            try c.encodeIfPresent(album, forKey: .album)
            try c.encodeIfPresent(trackNumber, forKey: .trackNumber)
            try c.encode(durationSeconds, forKey: .durationSeconds)
            try c.encode(audioBytes, forKey: .audioBytes)
            try c.encode(audioSHA256, forKey: .audioSHA256)
            try c.encodeIfPresent(text, forKey: .text)
        }
    }

    public var schema: String
    /// nil for a book; the album or playlist for a collection.
    public var kind: ShareCollectionKind?
    public var title: String
    /// A book's author, or a collection's (album) artist.
    public var author: String
    public var from: String
    public var note: String
    /// A collection's cover. Never set on a book.
    public var cover: Cover?
    /// A book's chapters, or a collection's tracks.
    public var chapters: [Chapter]

    public var isCollection: Bool { kind != nil }

    public init(title: String, author: String = "", from: String = "", note: String = "", chapters: [Chapter]) {
        self.schema = Self.schemaVersion; self.title = title; self.author = author
        self.from = from; self.note = note; self.chapters = chapters
    }

    /// An album or playlist manifest. `artist` is the album artist, and may be empty for a playlist.
    public init(collection kind: ShareCollectionKind, title: String, artist: String = "", from: String = "", note: String = "",
                cover: Cover? = nil, tracks: [Chapter]) {
        self.schema = Self.collectionSchemaVersion; self.kind = kind; self.title = title; self.author = artist
        self.from = from; self.note = note; self.cover = cover; self.chapters = tracks
    }

    enum CodingKeys: String, CodingKey { case schema, kind, title, author, artist, from, note, cover, chapters, tracks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(String.self, forKey: .schema)
        title = try c.decode(String.self, forKey: .title)
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        if schema == Self.collectionSchemaVersion {
            // A missing or unknown kind is refused here; a book kind is not a kind.
            kind = try c.decode(ShareCollectionKind.self, forKey: .kind)
            author = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
            cover = try c.decodeIfPresent(Cover.self, forKey: .cover)
            chapters = try c.decode([Chapter].self, forKey: .tracks)
            // A track's artist, album and number must have their types: a number written as text
            // is refused, not dropped.
            _ = try c.decode([TrackFields].self, forKey: .tracks)
        } else {
            author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
            chapters = try c.decode([Chapter].self, forKey: .chapters)
        }
    }

    /// A collection track's optional fields, decoded strictly.
    private struct TrackFields: Decodable {
        enum CodingKeys: String, CodingKey { case artist, album, trackNumber }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            _ = try c.decodeIfPresent(String.self, forKey: .artist)
            _ = try c.decodeIfPresent(String.self, forKey: .album)
            _ = try c.decodeIfPresent(Int.self, forKey: .trackNumber)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        if let kind {
            try c.encode(kind, forKey: .kind)
            try c.encode(title, forKey: .title)
            try c.encode(author, forKey: .artist)
            try c.encode(from, forKey: .from)
            try c.encode(note, forKey: .note)
            try c.encodeIfPresent(cover, forKey: .cover)
            try c.encode(chapters, forKey: .tracks)
        } else {
            try c.encode(title, forKey: .title)
            try c.encode(author, forKey: .author)
            try c.encode(from, forKey: .from)
            try c.encode(note, forKey: .note)
            try c.encode(chapters, forKey: .chapters)
        }
    }

    /// Every sealed blob byte the manifest declares: audio and text, not the manifest itself.
    public var blobBytes: Int { chapters.reduce(0) { $0 + $1.audioBytes + ($1.text?.bytes ?? 0) } }
    public var durationSeconds: Int { chapters.reduce(0) { $0 + $1.durationSeconds } }

    /// The storage descriptors the service is told about, keyed by blob ID.
    public var blobs: [String: BookBlobDescriptor] {
        var out = [String: BookBlobDescriptor]()
        for chapter in chapters {
            out[chapter.id] = .init(role: .audio, bytes: chapter.audioBytes, sha256: chapter.audioSHA256)
            if let text = chapter.text { out[text.id] = .init(role: .text, bytes: text.bytes, sha256: text.sha256) }
        }
        return out
    }

    /// Checks the whole manifest before any chapter is requested. `encryptedManifestBytes` counts
    /// against the book's total when known.
    public func validated(limits: ShareLimits = .standard, encryptedManifestBytes: Int = 0) throws -> Self {
        if kind != nil {
            guard schema == Self.collectionSchemaVersion else { throw ShareValidationError("schema", "unsupported collection") }
        } else {
            guard schema == Self.schemaVersion, cover == nil else { throw ShareValidationError("schema", "unsupported book") }
        }
        guard (1 ... limits.maxBookChapters).contains(chapters.count) else {
            throw ShareValidationError("chapters", "must contain 1 to \(limits.maxBookChapters) chapters")
        }
        var result = self
        result.title = try ShareText.clean(title, field: "title", max: ShareLimits.maxTitleLength)
        guard !result.title.isEmpty else { throw ShareValidationError("title", "is required") }
        result.author = try ShareText.clean(author, field: "author", max: ShareLimits.maxTitleLength)
        result.from = try ShareText.clean(from, field: "from", max: ShareLimits.maxFromLength)
        result.note = try ShareText.clean(note, field: "note", max: ShareLimits.maxNoteLength, allowNewlines: true)
        result.cover = try cover?.validated()
        var seen = Set<String>(), bytes = encryptedManifestBytes, seconds = 0
        result.chapters = try chapters.map { chapter in
            var normalized = chapter
            guard ShareBookCrypto.isCanonicalID(chapter.id), seen.insert(chapter.id).inserted else {
                throw ShareValidationError("chapters.id", "invalid or duplicate ID")
            }
            normalized.title = try ShareText.clean(chapter.title, field: "chapters.title", max: ShareLimits.maxTitleLength)
            guard !normalized.title.isEmpty else { throw ShareValidationError("chapters.title", "is required") }
            if isCollection {
                guard chapter.text == nil else { throw ShareValidationError("tracks.text", "a track has no read-along text") }
                normalized.artist = try chapter.artist.map { try ShareText.clean($0, field: "tracks.artist", max: ShareLimits.maxTitleLength) }
                normalized.album = try chapter.album.map { try ShareText.clean($0, field: "tracks.album", max: ShareLimits.maxTitleLength) }
                if let number = chapter.trackNumber, !(1 ... Self.maxTrackNumber).contains(number) {
                    throw ShareValidationError("tracks.trackNumber", "must be from 1 to \(Self.maxTrackNumber)")
                }
            } else {
                // A book chapter has none of these; like any unknown key, they are not read.
                normalized.artist = nil; normalized.album = nil; normalized.trackNumber = nil
            }
            guard (1 ... limits.maxBookChapterSeconds).contains(chapter.durationSeconds),
                  chapter.durationSeconds <= limits.maxBookSeconds - seconds else {
                throw ShareValidationError("chapters.durationSeconds", "out of range")
            }
            guard Self.validBlob(chapter.audioBytes, chapter.audioSHA256, max: limits.maxBookChapterBytes),
                  chapter.audioBytes <= limits.maxBookBytes - bytes else {
                throw ShareValidationError("chapters.audioBytes", "invalid size, hash or book total")
            }
            bytes += chapter.audioBytes; seconds += chapter.durationSeconds
            if let text = chapter.text {
                guard ShareBookCrypto.isCanonicalID(text.id), seen.insert(text.id).inserted else {
                    throw ShareValidationError("chapters.text.id", "invalid or duplicate ID")
                }
                guard Self.validBlob(text.bytes, text.sha256, max: limits.maxBookTextBytes),
                      text.bytes <= limits.maxBookBytes - bytes else {
                    throw ShareValidationError("chapters.text.bytes", "invalid size, hash or book total")
                }
                bytes += text.bytes
            }
            return normalized
        }
        return result
    }

    static func validBlob(_ bytes: Int, _ hash: String, max: Int) -> Bool {
        bytes >= ShareCrypto.headerLength + ShareCrypto.tagLength && bytes <= max && isLowerHex(hash)
    }

    static func isLowerHex(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    public func seal(rootKey: Data, limits: ShareLimits = .standard) throws -> Data {
        let encoded = try JSONEncoder().encode(validated(limits: limits))
        let sealedLength = ShareCrypto.sealedLength(plaintextLength: encoded.count)
        guard sealedLength <= limits.maxBookManifestBytes else {
            throw ShareValidationError("manifest", "exceeds encrypted manifest limit")
        }
        _ = try validated(limits: limits, encryptedManifestBytes: sealedLength)
        return try ShareCrypto.seal(encoded, key: ShareBookCrypto.manifestKey(rootKey: rootKey), purpose: .meta)
    }

    public static func open(_ encrypted: Data, rootKey: Data, limits: ShareLimits = .standard) throws -> Self {
        guard encrypted.count <= limits.maxBookManifestBytes else {
            throw ShareValidationError("manifest", "exceeds encrypted manifest limit")
        }
        let plain = try ShareCrypto.open(encrypted, key: ShareBookCrypto.manifestKey(rootKey: rootKey), purpose: .meta)
        return try JSONDecoder().decode(Self.self, from: plain)
            .validated(limits: limits, encryptedManifestBytes: encrypted.count)
    }

    /// Checks the authenticated length and hash before decrypting, then opens under the chapter key.
    public func openAudio(_ ciphertext: Data, chapterID: String, rootKey: Data) throws -> Data {
        guard let chapter = chapters.first(where: { $0.id == chapterID }),
              ciphertext.count == chapter.audioBytes, ShareHash.sha256Hex(ciphertext) == chapter.audioSHA256 else {
            throw ShareValidationError("audio", "does not match the authenticated manifest")
        }
        return try ShareCrypto.open(ciphertext, key: ShareBookCrypto.chapterKey(rootKey: rootKey, chapterID: chapterID),
                                    purpose: .audio)
    }

    public func openText(_ ciphertext: Data, chapterID: String, rootKey: Data) throws -> ShareBookText {
        guard let text = chapters.first(where: { $0.id == chapterID })?.text,
              ciphertext.count == text.bytes, ShareHash.sha256Hex(ciphertext) == text.sha256 else {
            throw ShareValidationError("text", "does not match the authenticated manifest")
        }
        let plain = try ShareCrypto.open(ciphertext, key: ShareBookCrypto.textKey(rootKey: rootKey, chapterID: chapterID),
                                         purpose: .meta)
        return try JSONDecoder().decode(ShareBookText.self, from: plain).validated()
    }
}

/// A chapter's read-along text: its sentences and where each sits in the chapter's audio. The same
/// shape as the app's `ReadAlongTiming`, under its own schema. Sealed only when the sharer turns
/// on "Include the text for read-along"; a book without it plays the same.
public struct ShareBookText: Codable, Equatable, Sendable {
    public static let schemaVersion = "baton-book-text-1"
    public static let maxSegments = 20_000
    public static let maxSegmentLength = 4000

    public struct Segment: Codable, Equatable, Sendable {
        public var text: String
        public var paragraph: Int
        public var start: Double
        public var end: Double
        public init(text: String, paragraph: Int, start: Double, end: Double) {
            self.text = text; self.paragraph = paragraph; self.start = start; self.end = end
        }
    }

    public var schema: String
    public var segments: [Segment]

    public init(segments: [Segment]) { self.schema = Self.schemaVersion; self.segments = segments }

    public func validated() throws -> Self {
        guard schema == Self.schemaVersion, segments.count <= Self.maxSegments else {
            throw ShareValidationError("text", "unsupported read-along text")
        }
        for segment in segments {
            guard segment.text.unicodeScalars.count <= Self.maxSegmentLength, segment.paragraph >= -1,
                  segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end >= segment.start else {
                throw ShareValidationError("text.segments", "invalid segment")
            }
        }
        return self
    }

    /// Compact JSON, as sealed.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(validated())
    }
}
