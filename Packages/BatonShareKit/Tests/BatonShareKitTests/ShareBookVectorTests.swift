@testable import BatonShareKit
import Foundation
import XCTest

/// The Swift half of the book format check (`baton-book-1`, specs/book-sharing.md). The browser's
/// half is `gateway/Tests/share-player/share-book-crypto.test.mjs`; both read the "book" section
/// of `specs/share-crypto/vectors.json`, written by an independent Python implementation.
final class ShareBookVectorTests: XCTestCase {
    struct Book: Decodable {
        struct Positive: Decodable {
            let name, kind, rootKey, derivedKey, purpose, baseNonce, plaintext, ciphertext, ciphertextSHA256: String
            let chapterID, textID: String?
            let recordSize: Int
        }

        struct Negative: Decodable {
            let name, kind, rootKey, ciphertext, reason: String
            let chapterID: String?
        }

        struct Invalid: Decodable { let name, rootKey, ciphertext, reason: String }
        struct Labels: Decodable { let manifest, chapter, text: String }
        struct Limits: Decodable {
            let maxChapters, maxChapterAudioBytes, maxChapterTextBytes, maxBookBytes, maxEncryptedManifestBytes: Int
            let maxChapterSeconds, maxBookSeconds: Int
        }

        let format: String
        let labels: Labels
        let limits: Limits
        let positive: [Positive]
        let negative: [Negative]
        let invalidManifests: [Invalid]
    }

    struct File: Decodable { let book: Book }

    static func loadBook() throws -> Book {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("specs/share-crypto/vectors.json")
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).book
    }

    private func data(_ base64: String) throws -> Data { try XCTUnwrap(Data(base64Encoded: base64)) }
    private func hex(_ text: String) -> Data {
        Data(stride(from: 0, to: text.count, by: 2).map {
            UInt8(text[text.index(text.startIndex, offsetBy: $0) ..< text.index(text.startIndex, offsetBy: $0 + 2)], radix: 16)!
        })
    }

    private func key(_ kind: String, root: Data, chapterID: String?) throws -> Data {
        switch kind {
        case "manifest": return try ShareBookCrypto.manifestKey(rootKey: root)
        case "chapter": return try ShareBookCrypto.chapterKey(rootKey: root, chapterID: XCTUnwrap(chapterID))
        default: return try ShareBookCrypto.textKey(rootKey: root, chapterID: XCTUnwrap(chapterID))
        }
    }

    func testLabelsAndLimitsMatchTheKit() throws {
        let book = try Self.loadBook()
        XCTAssertEqual(book.format, ShareBookManifest.schemaVersion)
        XCTAssertEqual(book.labels.manifest, ShareBookCrypto.manifestLabel)
        XCTAssertEqual(book.labels.chapter, ShareBookCrypto.chapterLabel)
        XCTAssertEqual(book.labels.text, ShareBookCrypto.textLabel)
        let limits = ShareLimits.standard
        XCTAssertEqual(book.limits.maxChapters, limits.maxBookChapters)
        XCTAssertEqual(book.limits.maxChapterAudioBytes, limits.maxBookChapterBytes)
        XCTAssertEqual(book.limits.maxChapterTextBytes, limits.maxBookTextBytes)
        XCTAssertEqual(book.limits.maxBookBytes, limits.maxBookBytes)
        XCTAssertEqual(book.limits.maxEncryptedManifestBytes, limits.maxBookManifestBytes)
        XCTAssertEqual(book.limits.maxChapterSeconds, limits.maxBookChapterSeconds)
        XCTAssertEqual(book.limits.maxBookSeconds, limits.maxBookSeconds)
    }

    func testEveryPositiveDerivesTheSameKeyAndSealsToTheSameBytes() throws {
        let book = try Self.loadBook()
        XCTAssertEqual(book.positive.filter { $0.kind == "chapter" }.count, 12)
        XCTAssertEqual(book.positive.filter { $0.kind == "text" }.count, 1)
        for vector in book.positive {
            let root = try XCTUnwrap(Base64URL.decode(vector.rootKey))
            let derived = try key(vector.kind, root: root, chapterID: vector.chapterID)
            XCTAssertEqual(Base64URL.encode(derived), vector.derivedKey, vector.name)
            let purpose = try XCTUnwrap(ShareCrypto.Purpose(rawValue: vector.purpose))
            let sealed = try ShareCrypto.seal(data(vector.plaintext), key: derived, purpose: purpose,
                                              recordSize: vector.recordSize, baseNonce: hex(vector.baseNonce))
            XCTAssertEqual(sealed, try data(vector.ciphertext), vector.name)
            XCTAssertEqual(ShareHash.sha256Hex(sealed), vector.ciphertextSHA256, vector.name)
            XCTAssertEqual(try ShareCrypto.open(sealed, key: derived, purpose: purpose), try data(vector.plaintext), vector.name)
        }
    }

    func testTheManifestOpensAndAuthenticatesEveryChapterAndText() throws {
        let book = try Self.loadBook()
        let manifestVector = try XCTUnwrap(book.positive.first { $0.kind == "manifest" })
        let root = try XCTUnwrap(Base64URL.decode(manifestVector.rootKey))
        let manifest = try ShareBookManifest.open(data(manifestVector.ciphertext), rootKey: root)
        XCTAssertEqual(manifest.title, "A Short Book")
        XCTAssertEqual(manifest.author, "A. Writer")
        XCTAssertEqual(manifest.note, "For the train.\nEnjoy.")
        XCTAssertEqual(manifest.chapters.count, 12)
        XCTAssertEqual(manifest.chapters.last?.title, "Épilogue")
        XCTAssertEqual(manifest.blobs.count, 13)

        let chapters = book.positive.filter { $0.kind == "chapter" }
        XCTAssertEqual(manifest.chapters.map(\.id), chapters.map { $0.chapterID! }, "order is the manifest's")
        for vector in chapters {
            let audio = try manifest.openAudio(data(vector.ciphertext), chapterID: XCTUnwrap(vector.chapterID), rootKey: root)
            XCTAssertEqual(audio, try data(vector.plaintext), vector.name)
        }
        // Substitution: another chapter's ciphertext under this chapter's ID fails the manifest's
        // length/hash check before any decryption.
        XCTAssertThrowsError(try manifest.openAudio(data(chapters[1].ciphertext), chapterID: chapters[0].chapterID!, rootKey: root))

        let textVector = try XCTUnwrap(book.positive.first { $0.kind == "text" })
        let text = try manifest.openText(data(textVector.ciphertext), chapterID: XCTUnwrap(textVector.chapterID), rootKey: root)
        XCTAssertEqual(text.segments.map(\.text), ["Chapter Two: The Road", "The road went on."])
        XCTAssertEqual(manifest.chapters[1].text?.id, textVector.textID)
        XCTAssertThrowsError(try manifest.openText(data(textVector.ciphertext), chapterID: chapters[0].chapterID!, rootKey: root),
                             "chapter 1 has no text")
    }

    func testEveryNegativeIsRefusedAsAuthentication() throws {
        let book = try Self.loadBook()
        XCTAssertGreaterThanOrEqual(book.negative.count, 13, "the vector file lost entries")
        for vector in book.negative {
            let root = try XCTUnwrap(Base64URL.decode(vector.rootKey))
            let derived = try key(vector.kind, root: root, chapterID: vector.chapterID)
            let purpose: ShareCrypto.Purpose = vector.kind == "chapter" ? .audio : .meta
            XCTAssertEqual(vector.reason, "auth")
            XCTAssertThrowsError(try ShareCrypto.open(data(vector.ciphertext), key: derived, purpose: purpose), vector.name) { error in
                XCTAssertEqual(error as? ShareCrypto.Failure, .authentication, vector.name)
            }
        }
    }

    func testEveryInvalidManifestDecryptsButIsRefusedByValidation() throws {
        let book = try Self.loadBook()
        XCTAssertGreaterThanOrEqual(book.invalidManifests.count, 15, "the vector file lost entries")
        for vector in book.invalidManifests {
            let root = try XCTUnwrap(Base64URL.decode(vector.rootKey))
            let encrypted = try data(vector.ciphertext)
            XCTAssertNoThrow(try ShareCrypto.open(encrypted, key: ShareBookCrypto.manifestKey(rootKey: root), purpose: .meta), vector.name)
            XCTAssertThrowsError(try ShareBookManifest.open(encrypted, rootKey: root), vector.name) { error in
                XCTAssertNotEqual(error as? ShareCrypto.Failure, .authentication, vector.name)
            }
        }
    }

    func testAMadeManifestSealsOpensAndMatchesItsDescriptors() throws {
        let root = ShareCrypto.newKey()
        let chapterID = ShareBookCrypto.newID(), textID = ShareBookCrypto.newID()
        let audio = try ShareCrypto.seal(Data(repeating: 7, count: 5000), key: ShareBookCrypto.chapterKey(rootKey: root, chapterID: chapterID), purpose: .audio)
        let text = try ShareCrypto.seal(ShareBookText(segments: [.init(text: "Hi.", paragraph: 0, start: 0, end: 1)]).encoded(),
                                        key: ShareBookCrypto.textKey(rootKey: root, chapterID: chapterID), purpose: .meta)
        let manifest = ShareBookManifest(title: "Book", author: "Me", chapters: [
            .init(id: chapterID, title: "One", durationSeconds: 3, audioBytes: audio.count, audioSHA256: ShareHash.sha256Hex(audio),
                  text: .init(id: textID, bytes: text.count, sha256: ShareHash.sha256Hex(text))),
        ])
        let sealed = try manifest.seal(rootKey: root)
        let request = try CreateBookRequest(encryptedManifest: sealed.base64EncodedString(), blobs: manifest.blobs, totalDurationSeconds: 3,
                                            expiresInSeconds: 604_800, listenerCap: 10, preview: nil,
                                            client: .init(platform: "macos", appVersion: "1")).validated()
        XCTAssertEqual(request.chapterCount, 1)
        XCTAssertEqual(request.totalBytes, audio.count + text.count + sealed.count)
        let published = PublicBook(status: .ready, preview: nil, encryptedManifest: request.encryptedManifest, blobs: request.blobs,
                                   expiresAt: "2026-10-25T00:00:00Z", remainingListeners: 10)
        let opened = try published.open(rootKey: root)
        XCTAssertEqual(try opened.openText(text, chapterID: chapterID, rootKey: root).segments.first?.text, "Hi.")
        var tampered = published
        tampered.blobs[textID]?.bytes += 1
        XCTAssertThrowsError(try tampered.open(rootKey: root))
    }

    func testRequestValidationEnforcesTheBookCaps() throws {
        let manifest = try ShareCrypto.seal(Data("{}".utf8), key: ShareCrypto.newKey(), purpose: .meta).base64EncodedString()
        func request(_ blobs: [String: BookBlobDescriptor], listeners: Int = 10) -> CreateBookRequest {
            CreateBookRequest(encryptedManifest: manifest, blobs: blobs, totalDurationSeconds: 60, expiresInSeconds: 604_800,
                              listenerCap: listeners, preview: nil, client: .init(platform: "ios", appVersion: "1"))
        }
        let hash = String(repeating: "a", count: 64)
        let chapter = BookBlobDescriptor(role: .audio, bytes: 26_214_400, sha256: hash)
        XCTAssertNoThrow(try request([ShareBookCrypto.newID(): chapter]).validated())
        XCTAssertThrowsError(try request([ShareBookCrypto.newID(): .init(role: .audio, bytes: 26_214_401, sha256: hash)]).validated())
        XCTAssertThrowsError(try request([ShareBookCrypto.newID(): .init(role: .text, bytes: 100, sha256: hash)]).validated(), "no chapter")
        XCTAssertThrowsError(try request([ShareBookCrypto.newID(): chapter,
                                          ShareBookCrypto.newID(): .init(role: .text, bytes: 1_048_577, sha256: hash)]).validated())
        XCTAssertThrowsError(try request([ShareBookCrypto.newID(): chapter], listeners: 51).validated())
        var eleven = [String: BookBlobDescriptor]()
        for _ in 0 ..< 11 { eleven[ShareBookCrypto.newID()] = chapter }
        XCTAssertThrowsError(try request(eleven).validated(), "11 × 25 MiB is over 256 MiB")
        var many = [String: BookBlobDescriptor]()
        for _ in 0 ..< 201 { many[ShareBookCrypto.newID()] = .init(role: .audio, bytes: 100, sha256: hash) }
        XCTAssertThrowsError(try request(many).validated(), "201 chapters")
        XCTAssertEqual(ShareLimits.bookSessionAllowance(bookBytes: 1000), 1500)
    }
}
