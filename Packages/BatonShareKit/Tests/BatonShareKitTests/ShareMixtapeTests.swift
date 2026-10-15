import Foundation
import XCTest
@testable import BatonShareKit

final class ShareMixtapeTests: XCTestCase {
    struct Vectors: Decodable {
        struct Positive: Decodable {
            let name, rootKey, derivedKey, purpose, baseNonce, plaintext, ciphertext, ciphertextSHA256: String
            let trackID: String?
            let recordSize: Int
        }
        struct Negative: Decodable { let name, rootKey, trackID, ciphertext: String }
        let positive: [Positive]
        let negative: [Negative]
    }
    private func vectors() throws -> Vectors {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: root.appendingPathComponent("specs/share-crypto/mixtape-vectors.json")))
    }
    func testIndependentVectorsDeriveAndSealExactly() throws {
        let vectors = try vectors()
        XCTAssertEqual(vectors.positive.count, 3)
        for vector in vectors.positive {
            let root = try XCTUnwrap(Base64URL.decode(vector.rootKey))
            let key = try vector.trackID.map { try ShareMixtapeCrypto.trackKey(rootKey: root, trackID: $0) }
                ?? ShareMixtapeCrypto.manifestKey(rootKey: root)
            XCTAssertEqual(Base64URL.encode(key), vector.derivedKey, vector.name)
            let plain = try XCTUnwrap(Data(base64Encoded: vector.plaintext))
            let cipher = try XCTUnwrap(Data(base64Encoded: vector.ciphertext))
            let nonce = Data(stride(from: 0, to: vector.baseNonce.count, by: 2).map { offset in
                let start = vector.baseNonce.index(vector.baseNonce.startIndex, offsetBy: offset)
                return UInt8(vector.baseNonce[start..<vector.baseNonce.index(start, offsetBy: 2)], radix: 16)!
            })
            let purpose = try XCTUnwrap(ShareCrypto.Purpose(rawValue: vector.purpose))
            XCTAssertEqual(try ShareCrypto.seal(plain, key: key, purpose: purpose,
                recordSize: vector.recordSize, baseNonce: nonce), cipher, vector.name)
            XCTAssertEqual(try ShareCrypto.open(cipher, key: key, purpose: purpose), plain, vector.name)
            XCTAssertEqual(ShareHash.sha256Hex(cipher), vector.ciphertextSHA256)
        }
        XCTAssertNotEqual(vectors.positive[0].derivedKey, vectors.positive[1].derivedKey)
        XCTAssertNotEqual(vectors.positive[0].ciphertext, vectors.positive[1].ciphertext)
    }
    func testNegativeVectorsNeverExposePlaintext() throws {
        let vectors = try vectors()
        XCTAssertEqual(vectors.negative.count, 4)
        for vector in vectors.negative {
            let key = try ShareMixtapeCrypto.trackKey(rootKey: XCTUnwrap(Base64URL.decode(vector.rootKey)), trackID: vector.trackID)
            let ciphertext = try XCTUnwrap(Data(base64Encoded: vector.ciphertext))
            XCTAssertThrowsError(try ShareCrypto.open(ciphertext, key: key, purpose: .audio), vector.name)
        }
    }
    private func track(_ index: Int, bytes: Int = 36, duration: Int = 1) -> ShareMixtapeManifest.Track {
        .init(id: Base64URL.encode(Data(repeating: UInt8(index), count: 16)),
              metadata: ShareMetadata(title: "Song \(index)", durationSeconds: duration),
              audioBytes: bytes, audioSHA256: String(repeating: "a", count: 64))
    }
    func testManifestLimitsRefuseDuplicatesOverflowAndUnsupportedSchema() throws {
        XCTAssertNoThrow(try ShareMixtapeManifest(title: "Two", tracks: [track(1), track(2)]).validated())
        XCTAssertNoThrow(try ShareMixtapeManifest(title: "Twelve", tracks: (1...12).map { track($0) }).validated())
        for tracks in [[track(1)], (1...13).map { track($0) }, [track(1), track(1)],
                       [track(1, bytes: Int.max), track(2)], [track(1), track(2, bytes: 35)],
                       [track(1, duration: 1200), track(2)], [track(1, duration: -1), track(2)]] {
            XCTAssertThrowsError(try ShareMixtapeManifest(title: "Bad", tracks: tracks).validated())
        }
        var unknown = ShareMixtapeManifest(title: "Bad", tracks: [track(1), track(2)])
        unknown.schema = "baton-mixtape-2"
        XCTAssertThrowsError(try unknown.validated())
        var nonCanonical = track(1)
        nonCanonical.id = String(nonCanonical.id.dropLast()) + "R"
        XCTAssertThrowsError(try ShareMixtapeManifest(title: "Bad", tracks: [nonCanonical, track(2)]).validated())
    }
    func testAuthenticatedManifestAndAudioRefuseSubstitution() throws {
        let vectors = try vectors().positive
        let root = try XCTUnwrap(Base64URL.decode(vectors[0].rootKey))
        let tracks = try vectors.prefix(2).enumerated().map { index, vector in
            ShareMixtapeManifest.Track(id: try XCTUnwrap(vector.trackID),
                metadata: .init(title: "Synthetic \(index)", durationSeconds: 10),
                audioBytes: try XCTUnwrap(Data(base64Encoded: vector.ciphertext)).count,
                audioSHA256: vector.ciphertextSHA256)
        }
        let manifest = ShareMixtapeManifest(title: "Synthetic", tracks: tracks)
        let encrypted = try manifest.seal(rootKey: root)
        let opened = try ShareMixtapeManifest.open(encrypted, rootKey: root)
        XCTAssertEqual(opened, manifest)
        let first = try XCTUnwrap(Data(base64Encoded: vectors[0].ciphertext))
        XCTAssertEqual(try opened.openAudio(first, trackID: tracks[0].id, rootKey: root), Data(base64Encoded: vectors[0].plaintext))
        XCTAssertThrowsError(try opened.openAudio(first, trackID: tracks[1].id, rootKey: root))
        XCTAssertThrowsError(try opened.openAudio(first.dropLast(), trackID: tracks[0].id, rootKey: root))
        var corrupt = encrypted; corrupt[corrupt.count - 1] ^= 1
        XCTAssertThrowsError(try ShareMixtapeManifest.open(corrupt, rootKey: root))
        XCTAssertThrowsError(try ShareMixtapeManifest.open(Data(count: 65_537), rootKey: root))
    }
}
