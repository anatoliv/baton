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

/// The encrypted manifest of a book link: its title and author, the sender's From and note, and
/// every chapter in order. All of it is inside the encryption, including chapter names and order.
public struct ShareBookManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = "baton-book-1"

    public struct Text: Codable, Equatable, Sendable {
        /// The text blob's own random ID (its storage name); its key comes from the chapter's ID.
        public var id: String
        public var bytes: Int
        public var sha256: String
        public init(id: String, bytes: Int, sha256: String) { self.id = id; self.bytes = bytes; self.sha256 = sha256 }
    }

    public struct Chapter: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var durationSeconds: Int
        public var audioBytes: Int
        public var audioSHA256: String
        public var text: Text?
        public init(id: String, title: String, durationSeconds: Int, audioBytes: Int, audioSHA256: String, text: Text? = nil) {
            self.id = id; self.title = title; self.durationSeconds = durationSeconds
            self.audioBytes = audioBytes; self.audioSHA256 = audioSHA256; self.text = text
        }
    }

    public var schema: String
    public var title: String
    public var author: String
    public var from: String
    public var note: String
    public var chapters: [Chapter]

    public init(title: String, author: String = "", from: String = "", note: String = "", chapters: [Chapter]) {
        self.schema = Self.schemaVersion; self.title = title; self.author = author
        self.from = from; self.note = note; self.chapters = chapters
    }

    enum CodingKeys: String, CodingKey { case schema, title, author, from, note, chapters }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(String.self, forKey: .schema)
        title = try c.decode(String.self, forKey: .title)
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        chapters = try c.decode([Chapter].self, forKey: .chapters)
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
        guard schema == Self.schemaVersion else { throw ShareValidationError("schema", "unsupported book") }
        guard (1 ... limits.maxBookChapters).contains(chapters.count) else {
            throw ShareValidationError("chapters", "must contain 1 to \(limits.maxBookChapters) chapters")
        }
        var result = self
        result.title = try ShareText.clean(title, field: "title", max: ShareLimits.maxTitleLength)
        guard !result.title.isEmpty else { throw ShareValidationError("title", "is required") }
        result.author = try ShareText.clean(author, field: "author", max: ShareLimits.maxTitleLength)
        result.from = try ShareText.clean(from, field: "from", max: ShareLimits.maxFromLength)
        result.note = try ShareText.clean(note, field: "note", max: ShareLimits.maxNoteLength, allowNewlines: true)
        var seen = Set<String>(), bytes = encryptedManifestBytes, seconds = 0
        result.chapters = try chapters.map { chapter in
            var normalized = chapter
            guard ShareBookCrypto.isCanonicalID(chapter.id), seen.insert(chapter.id).inserted else {
                throw ShareValidationError("chapters.id", "invalid or duplicate ID")
            }
            normalized.title = try ShareText.clean(chapter.title, field: "chapters.title", max: ShareLimits.maxTitleLength)
            guard !normalized.title.isEmpty else { throw ShareValidationError("chapters.title", "is required") }
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
