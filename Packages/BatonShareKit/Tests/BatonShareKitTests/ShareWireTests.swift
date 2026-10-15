@testable import BatonShareKit
import Foundation
import XCTest

final class ShareWireTests: XCTestCase {
    func testPreservationConsentIsExplicitVersionedAndSurvivesPreparation() throws {
        let legacy = makeCreate()
        XCTAssertNil(legacy.reviewPreservationConsent)
        XCTAssertNil(try JSONDecoder().decode(CreateShareRequest.self, from: JSONEncoder().encode(legacy)).reviewPreservationConsent)
        let prepared = try PreparedShare.make(audio: Data("synthetic audio".utf8),
            metadata: ShareMetadata(title: "Synthetic", durationSeconds: 40), isPrivate: true,
            expiresInSeconds: 604800, playCap: 2, client: ShareClientInfo(platform: "ios", appVersion: "probe"),
            reviewPreservationConsent: CreateShareRequest.reviewConsentVersion)
        let decoded = try JSONDecoder().decode(CreateShareRequest.self, from: JSONEncoder().encode(prepared.request))
        XCTAssertEqual(try decoded.validated().reviewPreservationConsent, "review-v1")
        XCTAssertNil(decoded.preview)
        var unknown = legacy; unknown.reviewPreservationConsent = "review-v2"
        XCTAssertThrowsError(try unknown.validated())
    }

    func testOwnerReviewNoticeIsOptionalAndRoundTrips() throws {
        let summary = ShareSummary(id: Base64URL.encode(Data(repeating: 2, count: 16)), status: .ready,
            createdAt: ShareDate.string(Date()), expiresAt: ShareDate.string(Date().addingTimeInterval(86400)),
            playCap: 10, preview: nil, stats: ShareStats(), reactions: [])
        let oldJSON = try JSONEncoder().encode(summary)
        XCTAssertNil(try JSONDecoder().decode(ShareSummary.self, from: oldJSON).actionRequired)
        var held = summary
        held.actionRequired = "This link requires review. You can still revoke it."
        XCTAssertEqual(try JSONDecoder().decode(ShareSummary.self, from: JSONEncoder().encode(held)), held)
    }

    // MARK: - Link

    func testALinkRoundTrips() throws {
        let id = Base64URL.encode(Data(repeating: 0xAB, count: 16))
        let key = ShareCrypto.newKey()
        let link = ShareLink(id: id, key: key)
        let url = link.url()
        XCTAssertEqual(url.absoluteString, "https://batonmusic.app/s/\(id)#\(Base64URL.encode(key))")
        XCTAssertEqual(ShareLink(url: url), link)
    }

    func testALinkWithoutACompleteKeyIsNotAShare() throws {
        let id = Base64URL.encode(Data(repeating: 1, count: 16))
        let key = Base64URL.encode(Data(repeating: 2, count: 16))
        XCTAssertNil(ShareLink(url: URL(string: "https://batonmusic.app/s/\(id)")!), "no fragment")
        XCTAssertNil(ShareLink(url: URL(string: "https://batonmusic.app/s/\(id)#\(key.dropLast(2))")!), "short key")
        XCTAssertNil(ShareLink(url: URL(string: "https://example.com/s/\(id)#\(key)")!), "foreign host")
        XCTAssertNotNil(ShareLink(url: URL(string: "http://127.0.0.1:8790/s/\(id)#\(key)")!, allowedHosts: nil))
        XCTAssertNil(ShareLink(url: URL(string: "https://batonmusic.app/s/\(id)/x#\(key)")!), "extra path")
    }

    func testOnlyTheCanonicalSpellingOfAnIdIsValid() {
        let id = Base64URL.encode(Data(repeating: 0, count: 16)) // "AAAA…AA", last char carries 4 spare bits
        XCTAssertTrue(ShareLink.isValidID(id))
        XCTAssertFalse(ShareLink.isValidID(String(id.dropLast()) + "B"), "same bytes, different spelling")
        XCTAssertFalse(ShareLink.isValidID(String(id.dropLast())))
        XCTAssertFalse(ShareLink.isValidID(String(id.dropLast()) + "+"))
    }

    // MARK: - Metadata

    func testMetadataIsNormalizedAndBounded() throws {
        let meta = ShareMetadata(title: "  Cafe\u{301}  ", artist: "A", durationSeconds: 200,
                                 from: "Anatoli", note: "line one\nline two", accent: "#3a7bd5",
                                 peaks: [0, 128, 255])
        let clean = try meta.validated()
        XCTAssertEqual(clean.title, "Café")
        XCTAssertEqual(clean.title.unicodeScalars.count, 4, "NFC: one scalar for é")
        XCTAssertEqual(clean.accent, "#3A7BD5")
        XCTAssertEqual(clean.note, "line one\nline two")

        XCTAssertThrowsError(try ShareMetadata(title: " ", durationSeconds: 1).validated())
        XCTAssertThrowsError(try ShareMetadata(title: "x", durationSeconds: 0).validated())
        XCTAssertThrowsError(try ShareMetadata(title: "x", durationSeconds: 1201).validated())
        XCTAssertThrowsError(try ShareMetadata(title: "x\u{7}", durationSeconds: 1).validated())
        XCTAssertThrowsError(try ShareMetadata(title: "x", durationSeconds: 1, from: "a\nb").validated())
        XCTAssertThrowsError(try ShareMetadata(title: "x", durationSeconds: 1, accent: "blue").validated())
        XCTAssertThrowsError(try ShareMetadata(title: "x", durationSeconds: 1, peaks: [256]).validated())
        XCTAssertThrowsError(try ShareMetadata(title: "x", durationSeconds: 1,
                                               note: String(repeating: "a", count: 281)).validated())
        XCTAssertNoThrow(try ShareMetadata(title: "x", durationSeconds: 1,
                                           note: String(repeating: "é", count: 280)).validated())
    }

    func testMetadataDecodesWithOnlyTheRequiredFields() throws {
        let meta = try JSONDecoder().decode(ShareMetadata.self,
                                            from: Data(#"{"title":"T","durationSeconds":3}"#.utf8))
        XCTAssertEqual(meta, ShareMetadata(title: "T", durationSeconds: 3))
    }

    // MARK: - Create

    func makeCreate(preview: ShareMetadata? = ShareMetadata(title: "Song", durationSeconds: 241),
                    encryptedMeta: String? = nil, bucket: DurationBucket? = nil) -> CreateShareRequest {
        CreateShareRequest(expiresInSeconds: 604_800, playCap: 100, preview: preview,
                           encryptedMeta: encryptedMeta, durationBucket: bucket,
                           audioBytes: 9_000_000, audioSHA256: String(repeating: "a", count: 64),
                           client: ShareClientInfo(platform: "ios", appVersion: "1.2 (345)"))
    }

    func testAPublicCreateValidates() throws {
        let valid = try makeCreate().validated()
        XCTAssertFalse(valid.isPrivate)
        XCTAssertEqual(valid.effectiveDurationBucket, .threeToFive)
    }

    func testAPrivateCreateNeedsSealedMetadataAndABucket() throws {
        let sealed = try ShareCrypto.seal(Data(#"{"title":"x"}"#.utf8), key: ShareCrypto.newKey(), purpose: .meta)
        let ok = makeCreate(preview: nil, encryptedMeta: sealed.base64EncodedString(), bucket: .oneToThree)
        XCTAssertTrue(try ok.validated().isPrivate)

        XCTAssertThrowsError(try makeCreate(preview: nil, encryptedMeta: sealed.base64EncodedString()).validated())
        XCTAssertThrowsError(try makeCreate(preview: nil, encryptedMeta: Data("plain".utf8).base64EncodedString(),
                                            bucket: .oneToThree).validated())
        XCTAssertThrowsError(try makeCreate(encryptedMeta: sealed.base64EncodedString()).validated(), "both")
        XCTAssertThrowsError(try makeCreate(preview: nil).validated(), "neither")
    }

    func testCreateRefusesOutOfRangeChoices() {
        var request = makeCreate()
        request.expiresInSeconds = 3600
        XCTAssertThrowsError(try request.validated())
        request = makeCreate(); request.playCap = 0
        XCTAssertThrowsError(try request.validated())
        request = makeCreate(); request.audioBytes = ShareLimits.standard.maxAudioBytes + 1
        XCTAssertThrowsError(try request.validated())
        request = makeCreate(); request.audioSHA256 = String(repeating: "A", count: 64)
        XCTAssertThrowsError(try request.validated())
        request = makeCreate(); request.client.platform = "android"
        XCTAssertThrowsError(try request.validated())
        request = makeCreate(); request.recentFailures = [ShareFailureReport(reason: "made up")]
        XCTAssertThrowsError(try request.validated())
    }

    // MARK: - Events and reactions

    func testEventPropsKeepOnlyWhatTheSpecLists() throws {
        XCTAssertEqual(try PlayerEvent(type: .playStarted, ms: 1234, reason: "ignored").props(), ["ms": .int(1234)])
        XCTAssertEqual(try PlayerEvent(type: .playStarted, ms: -5).props(), ["ms": .int(0)])
        XCTAssertEqual(try PlayerEvent(type: .played30s, target: "app_store").props(), [:])
        XCTAssertEqual(try PlayerEvent(type: .decryptFailed, reason: "auth").props(), ["reason": .string("auth")])
        XCTAssertThrowsError(try PlayerEvent(type: .decryptFailed, reason: "<script>").props())
        XCTAssertThrowsError(try PlayerEvent(type: .getBatonClicked, target: "evil.example").props())
        XCTAssertEqual(try PlayerEvent(type: .foundInLibrary, found: false).props(), ["found": .bool(false)])
    }

    func testAnUnknownEventTypeDoesNotDecode() {
        XCTAssertThrowsError(try JSONDecoder().decode(PlayerEvent.self, from: Data(#"{"type":"keylogger"}"#.utf8)))
    }

    func testReactionsAreFromTheOfferedSet() throws {
        XCTAssertEqual(try ReactionRequest(emoji: "❤️", name: " Maya ").validated().name, "Maya")
        XCTAssertThrowsError(try ReactionRequest(emoji: "💩").validated())
        XCTAssertThrowsError(try ReactionRequest(emoji: "🔥", name: String(repeating: "n", count: 41)).validated())
    }

    // MARK: - Identity

    func testSharerIDIsAStablePrefixAndNotTheLookupDigest() {
        let secret = "s3cret"
        XCTAssertEqual(ShareHash.sharerID(secret: secret).count, 16)
        XCTAssertEqual(ShareHash.sharerID(secret: secret), ShareHash.sharerID(secret: secret))
        XCTAssertFalse(ShareHash.secretDigest(secret).hasPrefix(ShareHash.sharerID(secret: secret)))
    }

    func testDurationBuckets() {
        XCTAssertEqual(DurationBucket(seconds: 59), .underOne)
        XCTAssertEqual(DurationBucket(seconds: 60), .oneToThree)
        XCTAssertEqual(DurationBucket(seconds: 299), .threeToFive)
        XCTAssertEqual(DurationBucket(seconds: 599), .fiveToTen)
        XCTAssertEqual(DurationBucket(seconds: 1200), .overTen)
    }
}
