@testable import BatonShareKit
import Foundation
import XCTest

/// The Swift half of the cross-implementation check (spec §2). The browser's half is
/// `gateway/Tests/share-player/share-crypto.test.mjs`, over the same file.
final class ShareCryptoVectorTests: XCTestCase {
    struct Vectors: Decodable {
        struct Positive: Decodable {
            let name, purpose, key, baseNonce, plaintext, plaintextSHA256, ciphertext, ciphertextSHA256: String
            let recordSize: Int
        }

        struct Negative: Decodable {
            let name, purpose, key, ciphertext, reason: String
        }

        let positive: [Positive]
        let negative: [Negative]
    }

    static func loadVectors() throws -> Vectors {
        // Tests/BatonShareKitTests/<file> → repo root is five levels up.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("specs/share-crypto/vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testEveryPositiveVectorSealsToTheSameBytesAndOpensBack() throws {
        let vectors = try Self.loadVectors()
        XCTAssertGreaterThanOrEqual(vectors.positive.count, 9, "the vector file lost entries")
        for vector in vectors.positive {
            let key = try XCTUnwrap(Base64URL.decode(vector.key))
            let purpose = try XCTUnwrap(ShareCrypto.Purpose(rawValue: vector.purpose))
            let plaintext = try XCTUnwrap(Data(base64Encoded: vector.plaintext))
            let expected = try XCTUnwrap(Data(base64Encoded: vector.ciphertext))
            let nonce = try XCTUnwrap(hexData(vector.baseNonce))

            let sealed = try ShareCrypto.seal(plaintext, key: key, purpose: purpose,
                                              recordSize: vector.recordSize, baseNonce: nonce)
            XCTAssertEqual(sealed, expected, vector.name)
            XCTAssertEqual(ShareHash.sha256Hex(sealed), vector.ciphertextSHA256, vector.name)
            XCTAssertEqual(sealed.count, ShareCrypto.sealedLength(plaintextLength: plaintext.count,
                                                                  recordSize: vector.recordSize), vector.name)

            let opened = try ShareCrypto.open(expected, key: key, purpose: purpose)
            XCTAssertEqual(opened, plaintext, vector.name)
            XCTAssertEqual(ShareHash.sha256Hex(opened), vector.plaintextSHA256, vector.name)
        }
    }

    func testEveryNegativeVectorIsRefusedForTheStatedReason() throws {
        let vectors = try Self.loadVectors()
        XCTAssertGreaterThanOrEqual(vectors.negative.count, 14, "the vector file lost entries")
        for vector in vectors.negative {
            let key = try XCTUnwrap(Base64URL.decode(vector.key))
            let purpose = try XCTUnwrap(ShareCrypto.Purpose(rawValue: vector.purpose))
            let ciphertext = try XCTUnwrap(Data(base64Encoded: vector.ciphertext))
            do {
                let opened = try ShareCrypto.open(ciphertext, key: key, purpose: purpose)
                XCTFail("\(vector.name): opened \(opened.count) bytes that should have been refused")
            } catch let failure as ShareCrypto.Failure {
                switch (failure, vector.reason) {
                case (.authentication, "auth"), (.format, "format"):
                    break
                default:
                    XCTFail("\(vector.name): refused as \(failure), expected \(vector.reason)")
                }
            }
        }
    }

    func testARandomRoundTripAtTheDefaultRecordSize() throws {
        let key = ShareCrypto.newKey()
        let song = Data((0 ..< 300_001).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 7) })
        let sealed = try ShareCrypto.seal(song, key: key, purpose: .audio)
        XCTAssertEqual(try ShareCrypto.open(sealed, key: key, purpose: .audio), song)
        let layout = try ShareCrypto.layout(headerBytes: Array(sealed.prefix(20)), totalLength: sealed.count)
        XCTAssertEqual(layout.records, 5)
        XCTAssertEqual(layout.plaintextLength, song.count)
    }

    func testTwoSealsOfTheSameSongDiffer() throws {
        let key = ShareCrypto.newKey()
        let song = Data(repeating: 7, count: 5000)
        XCTAssertNotEqual(try ShareCrypto.seal(song, key: key, purpose: .audio),
                          try ShareCrypto.seal(song, key: key, purpose: .audio),
                          "the base nonce must be fresh per seal")
    }

    func testAShortKeyIsRefused() {
        XCTAssertThrowsError(try ShareCrypto.seal(Data(), key: Data(count: 15), purpose: .audio)) {
            XCTAssertEqual($0 as? ShareCrypto.Failure, .badKey)
        }
    }

    private func hexData(_ hex: String) -> Data? {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
