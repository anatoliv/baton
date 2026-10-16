import BatonMCPProtocol
import BatonShareKit
@testable import BatonShareServer
import Foundation
import XCTest

extension ShareAppAttestServiceTests {
    func testMixtapeCreateProofIsRouteBoundAndReplaysSameContainerAfterRestart() throws {
        config.mixtapesEnabled = true
        let currentClock = clock!
        service = try ShareService(config: config, clock: { currentClock.now })
        let rootKey = Data(repeating: 4, count: 16)
        let tracks = try (1...2).map { i -> ShareMixtapeManifest.Track in
            let id = Base64URL.encode(Data(repeating: UInt8(i), count: 16))
            let audio = try ShareCrypto.seal(Data(repeating: UInt8(i), count: 100), key: ShareMixtapeCrypto.trackKey(rootKey: rootKey, trackID: id), purpose: .audio)
            return .init(id: id, metadata: .init(title: "Synthetic \(i)", durationSeconds: 10), audioBytes: audio.count, audioSHA256: ShareHash.sha256Hex(audio))
        }
        let manifest = try ShareMixtapeManifest(title: "Synthetic", tracks: tracks).seal(rootKey: rootKey)
        let object = CreateMixtapeRequest(encryptedManifest: manifest.base64EncodedString(), tracks: Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, .init(audioBytes: $0.audioBytes, audioSHA256: $0.audioSHA256)) }), totalDurationSeconds: 20, expiresInSeconds: 86400, playCap: 2, preview: nil, client: .init(platform: "ios", appVersion: "fixture"))
        let body = try JSONEncoder().encode(object)
        let response = request("/v1/share/attestation/challenge", try JSONEncoder().encode(ShareAttestationChallengeRequest(purpose: "create", keyID: keyID)))
        let challenge = try JSONDecoder().decode(ShareAttestationChallenge.self, from: response.body)
        let id = UUID().uuidString
        let envelope = ShareAttestationEnvelope.data(challenge: challenge, policy: config.appAttest!.policy, secret: secret, requestID: id, body: body, path: "/v1/share/mixtapes")
        let signed = ShareAttestationProof(keyID: keyID, challengeID: challenge.id, requestID: id,
            assertion: try AppAttestTestFixture.assertion(key: key, envelope: envelope).base64EncodedString())
        let header = try signed.headerValue()
        let first = request("/v1/share/mixtapes", body, header: header)
        XCTAssertEqual(first.status, 201)
        service = try ShareService(config: config, clock: { currentClock.now })
        let replay = request("/v1/share/mixtapes", body, header: header)
        XCTAssertEqual(replay.status, 201); XCTAssertEqual(replay.body, first.body)
        XCTAssertEqual(request("/v1/share/mixtapes", body + Data(" ".utf8), header: header).status, 401)
        XCTAssertEqual(request("/v1/share/shares", try prepared(), header: header).status, 401)
        let legacyBody = try prepared(), legacyProof = try proof(legacyBody, counter: 2)
        XCTAssertEqual(request("/v1/share/shares", legacyBody, header: try legacyProof.headerValue()).status, 201)
        XCTAssertEqual(request("/v1/share/mixtapes", body, header: try legacyProof.headerValue()).status, 401)
        let list = service.handle(HTTPRequestMessage(method: "GET", path: "/v1/share/mixtapes", query: [:], headers: ["authorization": "Bearer " + secret], body: Data()))
        XCTAssertEqual(try JSONDecoder().decode(MixtapeList.self, from: list.body).mixtapes.count, 1)
    }
}

extension AppAttestTests {
    func testLegacyEnvelopeRetainsIndependentlyFrozenBytesWhenMixtapePathIsAdded() throws {
        let challenge = ShareAttestationChallenge(id: "id", nonce: "nonce", expiresAt: "unused")
        let policy = ShareAttestationPolicy(appID: "ABCDEFGHIJ.io.fixture.baton", environment: "development", audience: "https://batonmusic.app")
        let expectedHex = "000000196261746f6e2d73686172652d6170702d6174746573742d763100000004504f5354000000102f76312f73686172652f7368617265730000001b4142434445464748494a2e696f2e666978747572652e6261746f6e0000000b646576656c6f706d656e740000001668747470733a2f2f6261746f6e6d757369632e617070000000026964000000056e6f6e6365000000403966313337393135346236613132343931626334363931643432313437333963666534373533383339663538333365346565366136336432643563356337663600000007726571756573740000004034343133366661333535623336373861313134366164313666376538363439653934666234666332316665373765383331306330363066363163616166663861"
        let bytes = ShareAttestationEnvelope.data(challenge: challenge, policy: policy, secret: "secret", requestID: "request", body: Data("{}".utf8))
        XCTAssertEqual(bytes.map { String(format: "%02x", $0) }.joined(), expectedHex)
        XCTAssertNotEqual(bytes, ShareAttestationEnvelope.data(challenge: challenge, policy: policy, secret: "secret", requestID: "request", body: Data("{}".utf8), path: "/v1/share/mixtapes"))
    }
}
