@testable import BatonShareKit
import Foundation
import XCTest

/// The Swift half of the album and playlist format check (`baton-collection-1`,
/// specs/collection-sharing.md). The browser's half is
/// `gateway/Tests/share-player/share-collection-crypto.test.mjs`; both read the "collection"
/// section of `specs/share-crypto/vectors.json`, written by an independent Python implementation.
final class ShareCollectionVectorTests: XCTestCase {
    struct Vectors: Decodable {
        struct Positive: Decodable {
            let name, kind, rootKey, derivedKey, purpose, baseNonce, plaintext, ciphertext, ciphertextSHA256: String
            let trackID: String?
            let recordSize: Int
        }

        struct Negative: Decodable {
            let name, kind, rootKey, ciphertext, reason: String
            let trackID: String?
        }

        struct Invalid: Decodable { let name, rootKey, ciphertext, reason: String }
        struct Labels: Decodable { let manifest, track: String }
        struct Limits: Decodable {
            let maxTracks, maxTrackAudioBytes, maxCollectionBytes, maxEncryptedManifestBytes: Int
            let maxTrackSeconds, maxCollectionSeconds, maxCoverBytes, maxTrackNumber: Int
        }

        let format: String
        let kinds: [String]
        let labels: Labels
        let limits: Limits
        let positive: [Positive]
        let negative: [Negative]
        let invalidManifests: [Invalid]
    }

    struct File: Decodable { let collection: Vectors }

    static func loadCollection() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("specs/share-crypto/vectors.json")
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).collection
    }

    private func data(_ base64: String) throws -> Data { try XCTUnwrap(Data(base64Encoded: base64)) }
    private func hex(_ text: String) -> Data {
        Data(stride(from: 0, to: text.count, by: 2).map {
            UInt8(text[text.index(text.startIndex, offsetBy: $0) ..< text.index(text.startIndex, offsetBy: $0 + 2)], radix: 16)!
        })
    }

    private func key(_ kind: String, root: Data, trackID: String?) throws -> Data {
        kind == "manifest" ? try ShareBookCrypto.manifestKey(rootKey: root)
            : try ShareBookCrypto.chapterKey(rootKey: root, chapterID: XCTUnwrap(trackID))
    }

    func testLabelsKindsAndLimitsMatchTheKit() throws {
        let c = try Self.loadCollection()
        XCTAssertEqual(c.format, ShareBookManifest.collectionSchemaVersion)
        XCTAssertEqual(c.kinds, ShareCollectionKind.allCases.map(\.rawValue))
        XCTAssertEqual(c.labels.manifest, ShareBookCrypto.manifestLabel)
        XCTAssertEqual(c.labels.track, ShareBookCrypto.chapterLabel)
        let limits = ShareLimits.standard
        XCTAssertEqual(c.limits.maxTracks, limits.maxBookChapters)
        XCTAssertEqual(c.limits.maxTrackAudioBytes, limits.maxBookChapterBytes)
        XCTAssertEqual(c.limits.maxCollectionBytes, limits.maxBookBytes)
        XCTAssertEqual(c.limits.maxEncryptedManifestBytes, limits.maxBookManifestBytes)
        XCTAssertEqual(c.limits.maxTrackSeconds, limits.maxBookChapterSeconds)
        XCTAssertEqual(c.limits.maxCollectionSeconds, limits.maxBookSeconds)
        XCTAssertEqual(c.limits.maxCoverBytes, ShareBookManifest.maxCoverBytes)
        XCTAssertEqual(c.limits.maxTrackNumber, ShareBookManifest.maxTrackNumber)
        XCTAssertEqual(ShareCollectionLimits().maxCoverBytes, ShareBookManifest.maxCoverBytes)
    }

    func testEveryPositiveDerivesTheSameKeyAndSealsToTheSameBytes() throws {
        let c = try Self.loadCollection()
        XCTAssertEqual(c.positive.filter { $0.kind == "manifest" }.count, 2)
        XCTAssertEqual(c.positive.filter { $0.kind == "track" }.count, 3)
        for vector in c.positive {
            let root = try XCTUnwrap(Base64URL.decode(vector.rootKey))
            let derived = try key(vector.kind, root: root, trackID: vector.trackID)
            XCTAssertEqual(Base64URL.encode(derived), vector.derivedKey, vector.name)
            let purpose = try XCTUnwrap(ShareCrypto.Purpose(rawValue: vector.purpose))
            let sealed = try ShareCrypto.seal(data(vector.plaintext), key: derived, purpose: purpose,
                                              recordSize: vector.recordSize, baseNonce: hex(vector.baseNonce))
            XCTAssertEqual(sealed, try data(vector.ciphertext), vector.name)
            XCTAssertEqual(ShareHash.sha256Hex(sealed), vector.ciphertextSHA256, vector.name)
            XCTAssertEqual(try ShareCrypto.open(sealed, key: derived, purpose: purpose), try data(vector.plaintext), vector.name)
        }
    }

    func testTheAlbumManifestOpensWithItsCoverAndAuthenticatesItsTracks() throws {
        let c = try Self.loadCollection()
        let vector = try XCTUnwrap(c.positive.first { $0.name == "album manifest" })
        let root = try XCTUnwrap(Base64URL.decode(vector.rootKey))
        let album = try ShareBookManifest.open(data(vector.ciphertext), rootKey: root)
        XCTAssertEqual(album.schema, ShareBookManifest.collectionSchemaVersion)
        XCTAssertEqual(album.kind, .album)
        XCTAssertEqual(album.title, "A Long Album")
        XCTAssertEqual(album.author, "The Band")
        XCTAssertEqual(album.note, "Side B is the best.\nTurn it up.")
        XCTAssertEqual(album.chapters.count, 14)
        XCTAssertEqual(album.chapters.map(\.trackNumber), Array(1 ... 14))
        XCTAssertEqual(album.chapters[1].title, "Ça plane pour moi")
        XCTAssertEqual(album.chapters[2].artist, "Guest Player")
        XCTAssertNil(album.chapters[0].artist)
        XCTAssertEqual(album.cover?.type, "image/png")
        XCTAssertEqual(album.cover?.bytes.map { ShareBookManifest.Cover.type(of: $0) }, "image/png")
        XCTAssertEqual(album.blobs.count, 14)
        XCTAssertTrue(album.blobs.values.allSatisfy { $0.role == .audio })

        let tracks = c.positive.filter { $0.kind == "track" }
        XCTAssertEqual(Array(album.chapters.prefix(3).map(\.id)), tracks.map { $0.trackID! }, "order is the manifest's")
        for track in tracks {
            XCTAssertEqual(try album.openAudio(data(track.ciphertext), chapterID: XCTUnwrap(track.trackID), rootKey: root),
                           try data(track.plaintext), track.name)
        }
        XCTAssertThrowsError(try album.openAudio(data(tracks[1].ciphertext), chapterID: tracks[0].trackID!, rootKey: root))

        // A book reader's view of it: the descriptor says collection, and the manifest agrees.
        let published = PublicBook(status: .ready, preview: nil, encryptedManifest: vector.ciphertext, blobs: album.blobs,
                                   expiresAt: "2026-10-25T00:00:00Z", remainingListeners: 10, kind: .album)
        XCTAssertEqual(try published.open(rootKey: root).kind, .album)
        var mislabelled = published
        mislabelled.kind = .playlist
        XCTAssertThrowsError(try mislabelled.open(rootKey: root), "a descriptor's kind must match the manifest's")
        var asBook = published
        asBook.kind = nil
        asBook.schema = ShareBookManifest.schemaVersion
        XCTAssertThrowsError(try asBook.open(rootKey: root), "a collection never opens as a book")
    }

    func testThePlaylistManifestOpens() throws {
        let c = try Self.loadCollection()
        let vector = try XCTUnwrap(c.positive.first { $0.name == "playlist manifest" })
        let playlist = try ShareBookManifest.open(data(vector.ciphertext), rootKey: XCTUnwrap(Base64URL.decode(vector.rootKey)))
        XCTAssertEqual(playlist.kind, .playlist)
        XCTAssertEqual(playlist.title, "Road Trip")
        XCTAssertEqual(playlist.author, "")
        XCTAssertNil(playlist.cover)
        XCTAssertEqual(playlist.chapters.map { $0.artist ?? "" }, ["Ana", "Bo", "Cy"])
        XCTAssertEqual(playlist.chapters.map { $0.album ?? "" }, ["First", "Second", "Third"])
        XCTAssertEqual(playlist.chapters.map(\.trackNumber), [nil, nil, nil])
    }

    func testEveryNegativeIsRefusedAsAuthentication() throws {
        let c = try Self.loadCollection()
        XCTAssertGreaterThanOrEqual(c.negative.count, 9, "the vector file lost entries")
        for vector in c.negative {
            let root = try XCTUnwrap(Base64URL.decode(vector.rootKey))
            let derived = try key(vector.kind, root: root, trackID: vector.trackID)
            let purpose: ShareCrypto.Purpose = vector.kind == "track" ? .audio : .meta
            XCTAssertEqual(vector.reason, "auth")
            XCTAssertThrowsError(try ShareCrypto.open(data(vector.ciphertext), key: derived, purpose: purpose), vector.name) { error in
                XCTAssertEqual(error as? ShareCrypto.Failure, .authentication, vector.name)
            }
        }
    }

    func testEveryInvalidManifestDecryptsButIsRefusedByValidation() throws {
        let c = try Self.loadCollection()
        XCTAssertGreaterThanOrEqual(c.invalidManifests.count, 30, "the vector file lost entries")
        for vector in c.invalidManifests {
            let root = try XCTUnwrap(Base64URL.decode(vector.rootKey))
            let encrypted = try data(vector.ciphertext)
            XCTAssertNoThrow(try ShareCrypto.open(encrypted, key: ShareBookCrypto.manifestKey(rootKey: root), purpose: .meta), vector.name)
            XCTAssertThrowsError(try ShareBookManifest.open(encrypted, rootKey: root), vector.name) { error in
                XCTAssertNotEqual(error as? ShareCrypto.Failure, .authentication, vector.name)
            }
        }
    }

    func testAMadeCollectionSealsOpensAndItsRequestCarriesTheKind() throws {
        let root = ShareCrypto.newKey()
        let id = ShareBookCrypto.newID()
        let audio = try ShareCrypto.seal(Data(repeating: 9, count: 4000), key: ShareBookCrypto.chapterKey(rootKey: root, chapterID: id), purpose: .audio)
        let cover = ShareBookManifest.Cover(type: "image/jpeg", bytes: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]))
        let manifest = ShareBookManifest(collection: .playlist, title: "Mix", cover: cover, tracks: [
            .init(id: id, title: "One", durationSeconds: 3, audioBytes: audio.count, audioSHA256: ShareHash.sha256Hex(audio),
                  artist: "Ana", album: "First", trackNumber: 4),
        ])
        let sealed = try manifest.seal(rootKey: root)
        let opened = try ShareBookManifest.open(sealed, rootKey: root)
        XCTAssertEqual(opened, try manifest.validated())
        let request = try CreateBookRequest(encryptedManifest: sealed.base64EncodedString(), blobs: manifest.blobs, totalDurationSeconds: 3,
                                            expiresInSeconds: 604_800, listenerCap: 10, preview: nil,
                                            client: .init(platform: "ios", appVersion: "1"), kind: .playlist).validated()
        XCTAssertEqual(request.schema, ShareBookManifest.collectionSchemaVersion)
        let body = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "playlist")

        // A collection declares audio only; the schema and the kind go together.
        var withText = request
        withText.blobs[ShareBookCrypto.newID()] = .init(role: .text, bytes: 100, sha256: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try withText.validated())
        var noKind = request
        noKind.kind = nil
        XCTAssertThrowsError(try noKind.validated())
        var bookSchema = request
        bookSchema.schema = ShareBookManifest.schemaVersion
        XCTAssertThrowsError(try bookSchema.validated())

        // A book's request still encodes without a kind.
        let book = CreateBookRequest(encryptedManifest: sealed.base64EncodedString(), blobs: manifest.blobs, totalDurationSeconds: 3,
                                     expiresInSeconds: 604_800, listenerCap: 10, preview: nil, client: .init(platform: "ios", appVersion: "1"))
        let bookJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
        XCTAssertNil(bookJSON["kind"])
        XCTAssertEqual(bookJSON["schema"] as? String, ShareBookManifest.schemaVersion)
    }

    func testABookManifestRefusesACoverAndACollectionRefusesText() throws {
        let root = ShareCrypto.newKey()
        let hash = String(repeating: "a", count: 64)
        var book = ShareBookManifest(title: "B", chapters: [.init(id: ShareBookCrypto.newID(), title: "C", durationSeconds: 1, audioBytes: 100, audioSHA256: hash)])
        book.cover = .init(type: "image/jpeg", bytes: Data([0xFF, 0xD8, 0xFF]))
        XCTAssertThrowsError(try book.seal(rootKey: root))
        let collection = ShareBookManifest(collection: .album, title: "A", tracks: [
            .init(id: ShareBookCrypto.newID(), title: "T", durationSeconds: 1, audioBytes: 100, audioSHA256: hash,
                  text: .init(id: ShareBookCrypto.newID(), bytes: 100, sha256: hash)),
        ])
        XCTAssertThrowsError(try collection.seal(rootKey: root))
    }

    func testABookChapterIgnoresTrackFieldsOfAnyTypeAsTheBrowserDoes() throws {
        let root = ShareCrypto.newKey()
        let id = ShareBookCrypto.newID()
        let hash = String(repeating: "a", count: 64)
        for extra in [#""artist":5"#, #""trackNumber":"1""#, #""album":[1]"#, #""trackNumber":1.5"#] {
            let json = #"{"schema":"baton-book-1","title":"B","chapters":[{"id":""# + id
                + #"","title":"C",\#(extra),"durationSeconds":1,"audioBytes":100,"audioSHA256":""# + hash + #""}]}"#
            let sealed = try ShareCrypto.seal(Data(json.utf8), key: ShareBookCrypto.manifestKey(rootKey: root), purpose: .meta)
            let book = try ShareBookManifest.open(sealed, rootKey: root)
            XCTAssertNil(book.chapters[0].artist, extra)
            XCTAssertNil(book.chapters[0].trackNumber, extra)
            // The same field on a collection track is refused.
            let track = json.replacingOccurrences(of: #""schema":"baton-book-1""#, with: #""schema":"baton-collection-1","kind":"playlist""#)
                .replacingOccurrences(of: #""chapters""#, with: #""tracks""#)
            let sealedTrack = try ShareCrypto.seal(Data(track.utf8), key: ShareBookCrypto.manifestKey(rootKey: root), purpose: .meta)
            XCTAssertThrowsError(try ShareBookManifest.open(sealedTrack, rootKey: root), extra)
        }
    }

    func testTheMusicBitRateFallsBackForLongTracks() {
        let cap = ShareLimits.standard.maxBookChapterBytes
        XCTAssertEqual(ShareCollectionLimits.bitRate(forSeconds: 240, maxTrackBytes: cap), 128_000)
        XCTAssertEqual(ShareCollectionLimits.bitRate(forSeconds: 30 * 60, maxTrackBytes: cap), 96_000)
        XCTAssertEqual(ShareCollectionLimits.bitRate(forSeconds: 50 * 60, maxTrackBytes: cap), 64_000)
        XCTAssertEqual(ShareCollectionLimits.bitRate(forSeconds: 65 * 60, maxTrackBytes: cap), 48_000)
        XCTAssertNil(ShareCollectionLimits.bitRate(forSeconds: 75 * 60, maxTrackBytes: cap))
    }
}
