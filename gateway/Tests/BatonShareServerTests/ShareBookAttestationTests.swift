import BatonMCPProtocol
import BatonShareKit
@testable import BatonShareServer
import Foundation
import XCTest

extension ShareAppAttestServiceTests {
    func testBookCreateProofIsRouteBoundAndReplaysSameBookAfterRestart() throws {
        config.booksEnabled = true
        config.mixtapesEnabled = true
        let currentClock = clock!
        service = try ShareService(config: config, clock: { currentClock.now })
        let rootKey = Data(repeating: 9, count: 16)
        let chapters = try (1 ... 2).map { index -> ShareBookManifest.Chapter in
            let id = Base64URL.encode(Data(repeating: UInt8(index + 40), count: 16))
            let audio = try ShareCrypto.seal(Data(repeating: UInt8(index), count: 100), key: ShareBookCrypto.chapterKey(rootKey: rootKey, chapterID: id), purpose: .audio)
            return .init(id: id, title: "Synthetic \(index)", durationSeconds: 30, audioBytes: audio.count, audioSHA256: ShareHash.sha256Hex(audio))
        }
        let manifest = ShareBookManifest(title: "Synthetic", chapters: chapters)
        let object = CreateBookRequest(encryptedManifest: try manifest.seal(rootKey: rootKey).base64EncodedString(), blobs: manifest.blobs,
            totalDurationSeconds: 60, expiresInSeconds: 86400, listenerCap: 10, preview: nil, client: .init(platform: "ios", appVersion: "fixture"))
        let body = try JSONEncoder().encode(object)
        func signed(_ body: Data, path: String, counter: UInt32) throws -> String {
            let response = request("/v1/share/attestation/challenge", try JSONEncoder().encode(ShareAttestationChallengeRequest(purpose: "create", keyID: keyID)))
            let challenge = try JSONDecoder().decode(ShareAttestationChallenge.self, from: response.body)
            let id = UUID().uuidString
            let envelope = ShareAttestationEnvelope.data(challenge: challenge, policy: config.appAttest!.policy, secret: secret, requestID: id, body: body, path: path)
            return try ShareAttestationProof(keyID: keyID, challengeID: challenge.id, requestID: id,
                assertion: try AppAttestTestFixture.assertion(key: key, counter: counter, envelope: envelope).base64EncodedString()).headerValue()
        }
        let header = try signed(body, path: "/v1/share/books", counter: 1)
        let first = request("/v1/share/books", body, header: header)
        XCTAssertEqual(first.status, 201, String(decoding: first.body, as: UTF8.self))
        XCTAssertNoThrow(try JSONDecoder().decode(CreateBookResponse.self, from: first.body))
        service = try ShareService(config: config, clock: { currentClock.now })
        let replay = request("/v1/share/books", body, header: header)
        XCTAssertEqual(replay.status, 201); XCTAssertEqual(replay.body, first.body)
        XCTAssertEqual(request("/v1/share/books", body + Data(" ".utf8), header: header).status, 401)
        // The same proof cannot create on another route, and another route's proof cannot create a book.
        XCTAssertEqual(request("/v1/share/mixtapes", body, header: header).status, 400, "not a mixtape body, refused before any proof is spent")
        XCTAssertEqual(request("/v1/share/shares", try prepared(), header: header).status, 401)
        let mixtapeSigned = try signed(body, path: "/v1/share/mixtapes", counter: 2)
        XCTAssertEqual(request("/v1/share/books", body, header: mixtapeSigned).status, 401)
        let legacyBody = try prepared(), legacyProof = try proof(legacyBody, counter: 3)
        XCTAssertEqual(request("/v1/share/shares", legacyBody, header: try legacyProof.headerValue()).status, 201)
        XCTAssertEqual(request("/v1/share/books", body, header: try legacyProof.headerValue()).status, 401)
        let list = service.handle(HTTPRequestMessage(method: "GET", path: "/v1/share/books", query: [:], headers: ["authorization": "Bearer " + secret], body: Data()))
        XCTAssertEqual(try JSONDecoder().decode(BookList.self, from: list.body).books.count, 1)
        let integrity = try service.store.database.query("SELECT props FROM events WHERE type='share_created'").compactMap { $0["props"]?.text }
        XCTAssertEqual(integrity.filter { $0.contains("\"kind\":\"book\"") && $0.contains("\"integrity\":\"app_attest\"") }.count, 1)
    }
}
