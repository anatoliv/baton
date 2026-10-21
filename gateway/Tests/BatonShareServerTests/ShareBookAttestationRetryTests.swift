@testable import BatonShareKit
import BatonMCPProtocol
@testable import BatonShareServer
import Crypto
import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A whole-book create retried after its App Attest challenge has lapsed (TBX-1000000132 review):
/// the kit client against the real service with App Attest on, through the same bridge as
/// ShareBookClientServiceTests. A challenge lasts 300 s; a Retry Upload an hour later must still
/// make the same book, with the same body and its `requestID`, under a fresh proof.
final class ShareBookAttestationRetryTests: XCTestCase {
    var root: URL!
    var service: ShareService!
    var config: ShareConfiguration!
    private var bridge: BookHTTPBridge!
    var client: ShareClient!
    var session: URLSession!
    let clock = TestClock()
    let secret = ShareClient.newSecret()
    let base = URL(string: "https://batonmusic.app")!
    var key: P256.Signing.PrivateKey!
    var keyID: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("book-attest-retry-" + UUID().uuidString)
        config = ShareConfiguration(dataDirectory: root.appendingPathComponent("service"), blobDelivery: .direct)
        config.booksEnabled = true
        config.mixtapesEnabled = true
        config.appAttest = AppAttestTestFixture.policy
        service = try ShareService(config: config, clock: { [clock] in clock.now })
        key = P256.Signing.PrivateKey()
        keyID = Data(SHA256.hash(data: key.publicKey.x963Representation)).base64EncodedString()
        let now = Int64(clock.now.timeIntervalSince1970)
        try service.store.database.run("INSERT INTO app_attest_keys VALUES(?,?,?,?,?,0,?,?)", [
            .text(keyID), .text(ShareHash.secretDigest(secret)), .text("development"),
            .text(key.publicKey.x963Representation.base64EncodedString()), .text("synthetic-receipt"), .int(now), .int(now)])
        bridge = BookHTTPBridge(service: service, root: root)
        BookBridgeProtocol.bridge = bridge
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BookBridgeProtocol.self]
        session = URLSession(configuration: configuration)
        client = ShareClient(base: base, secret: secret, session: session)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        BookBridgeProtocol.bridge = nil; bridge = nil; service = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// What the iPhone's `SongShareAppAttest` does, with the fixture key: a create challenge from
    /// the service, then an assertion over the envelope for this body and proof identity.
    private final class Attester: @unchecked Sendable {
        let test: ShareBookAttestationRetryTests
        private let lock = NSLock()
        private var counter: UInt32 = 0
        private(set) var proofIDs: [String] = []
        init(_ test: ShareBookAttestationRetryTests) { self.test = test }
        func proof(_ body: Data, _ requestID: String) throws -> ShareAttestationProof {
            lock.lock(); counter += 1; let count = counter; proofIDs.append(requestID); lock.unlock()
            let response = test.service.handle(.init(method: "POST", path: "/v1/share/attestation/challenge", query: [:],
                headers: ["authorization": "Bearer " + test.secret, "x-real-ip": "203.0.113.42"],
                body: try JSONEncoder().encode(ShareAttestationChallengeRequest(purpose: "create", keyID: test.keyID))))
            let challenge = try JSONDecoder().decode(ShareAttestationChallenge.self, from: response.body)
            let envelope = ShareAttestationEnvelope.data(challenge: challenge, policy: test.config.appAttest!.policy, secret: test.secret,
                                                         requestID: requestID, body: body, path: "/v1/share/books")
            return .init(keyID: test.keyID, challengeID: challenge.id, requestID: requestID,
                         assertion: try AppAttestTestFixture.assertion(key: test.key, counter: count, envelope: envelope).base64EncodedString())
        }
    }

    private func prepared(_ name: String) async throws -> PreparedBookShare {
        let config = try await client.bookConfiguration()
        let limits = try XCTUnwrap(config.book)
        var chapters = [PreparedBookShare.Chapter]()
        for index in 0 ..< 2 {
            let audio = root.appendingPathComponent("\(name)-\(index).m4a")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(repeating: UInt8(index + 1), count: 3_000).write(to: audio)
            chapters.append(.init(audio: audio, title: "Chapter \(index + 1)", durationSeconds: 60))
        }
        return try PreparedBookShare.make(chapters: chapters, title: "Synthetic", preview: nil, expiresInSeconds: 86400,
                                          listenerCap: 2, client: .init(platform: "ios", appVersion: "synthetic"), limits: limits,
                                          directory: root.appendingPathComponent("staged-\(name)"))
    }

    private func creates() -> Int { bridge.requests().filter { $0 == "POST /v1/share/books" }.count }

    func testARetryAfterTheChallengeLapsedMakesAFreshProofForTheSameBody() async throws {
        let book = try await prepared("lapsed")
        let attester = Attester(self)
        let attest: ShareClient.BookAttestation = { body, id in try attester.proof(body, id) }
        // The first create never reaches the service (the phone was offline).
        bridge.failNext = "/v1/share/books"
        do { _ = try await client.shareBook(book, attest: attest); XCTFail("the first create should not have arrived") } catch {}
        let staged = try PreparedBookShare.load(from: book.directory)
        XCTAssertNotNil(staged.proof, "the first proof is kept with the staged book")
        XCTAssertNil(staged.created)
        // Retry Upload an hour later: the kept proof's challenge has lapsed.
        clock.advance(3600)
        let (link, summary) = try await client.shareBook(staged, attest: attest)
        XCTAssertEqual(summary.share.status, .ready)
        XCTAssertEqual(ShareInvitation(url: link)?.key, book.key)
        XCTAssertEqual(attester.proofIDs.count, 2, "one fresh proof after the refusal")
        XCTAssertNotEqual(attester.proofIDs[0], attester.proofIDs[1], "a fresh proof identity")
        XCTAssertFalse(attester.proofIDs.contains(book.request.requestID), "the body's requestID is not a proof identity")
        let reloaded = try PreparedBookShare.load(from: book.directory)
        XCTAssertEqual(reloaded.requestBody, book.requestBody, "identical body bytes")
        XCTAssertEqual(reloaded.proof?.requestID, attester.proofIDs[1])
        // Asked again later still, the same book.
        clock.advance(3600)
        let again = try await client.shareBook(reloaded, attest: attest)
        XCTAssertEqual(again.link, link)
        let books = try await client.listBooks()
        XCTAssertEqual(books.map(\.share.id), [summary.share.id])
        let integrity = try service.store.database.query("SELECT props FROM events WHERE type='share_created'").compactMap { $0["props"]?.text }
        XCTAssertEqual(integrity.filter { $0.contains("\"integrity\":\"app_attest\"") }.count, 1)
    }

    func testALostCreateAnswerRetriedAfterTheChallengeLapsedAnswersTheSameBook() async throws {
        let book = try await prepared("lost")
        let attester = Attester(self)
        let attest: ShareClient.BookAttestation = { body, id in try attester.proof(body, id) }
        // The service made the book, but its answer never arrived.
        bridge.loseNext = "/v1/share/books"
        do { _ = try await client.shareBook(book, attest: attest); XCTFail("the create answer should have been lost") } catch {}
        let made = try await client.listBooks()
        XCTAssertEqual(made.count, 1)
        clock.advance(3600)
        let staged = try PreparedBookShare.load(from: book.directory)
        let (link, summary) = try await client.shareBook(staged, attest: attest)
        XCTAssertEqual(summary.share.id, made[0].share.id, "the same book, from the service's replay of the kept proof")
        XCTAssertEqual(link.path, "/b/\(made[0].share.id)")
        XCTAssertEqual(attester.proofIDs.count, 1, "the kept proof replays; no fresh one is needed")
        XCTAssertEqual(creates(), 2)
        let books = try await client.listBooks()
        XCTAssertEqual(books.count, 1)
    }

    func testAFreshProofForABookTheServiceAlreadyMadeAnswersThatBook() async throws {
        let book = try await prepared("fresh")
        let attester = Attester(self)
        let attest: ShareClient.BookAttestation = { body, id in try attester.proof(body, id) }
        bridge.loseNext = "/v1/share/books"
        do { _ = try await client.shareBook(book, attest: attest); XCTFail("the create answer should have been lost") } catch {}
        let made = try await client.listBooks()
        // The kept proof no longer matches the replay (the service rotated its replay window, or the
        // ticket's proof was lost): the create is refused, a fresh proof goes with the same body,
        // and the body's requestID answers the book already made.
        var staged = try PreparedBookShare.load(from: book.directory)
        staged.proof = try attester.proof(Data("another body".utf8), UUID().uuidString)
        try staged.save()
        clock.advance(3600)
        let (_, summary) = try await client.shareBook(staged, attest: attest)
        XCTAssertEqual(summary.share.id, made[0].share.id)
        XCTAssertEqual(attester.proofIDs.count, 3)
        let books = try await client.listBooks()
        XCTAssertEqual(books.count, 1)
    }
}
