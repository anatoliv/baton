@testable import BatonGatewayCore
import BatonMCPProtocol
import BatonShareKit
@testable import BatonShareServer
import Foundation
import XCTest

/// A clock a test can move.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) { value = start }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value += seconds
        lock.unlock()
    }
}

/// Drives `ShareService` the way the transport does, minus the socket. Every route, every
/// refusal, and the events each one leaves behind.
final class ShareServiceTests: XCTestCase {
    var directory: URL!
    var clock: TestClock!
    var service: ShareService!

    let secret = Base64URL.encode(Data(repeating: 7, count: 32))
    let otherSecret = Base64URL.encode(Data(repeating: 9, count: 32))
    let browser = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("share-tests-\(UUID().uuidString)")
        clock = TestClock()
        service = try makeService()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeService(enabled: Bool = true, limits: ShareLimits = .standard, admin: String? = nil) throws -> ShareService {
        let clock = self.clock!
        return try ShareService(
            config: ShareConfiguration(dataDirectory: directory, publicBase: URL(string: "https://batonmusic.app")!,
                                       enabled: enabled, adminToken: admin, blobDelivery: .direct, limits: limits),
            salt: DailySalt(random: { Data(repeating: 1, count: 32) }),
            clock: { clock.now })
    }

    func testMutablePlayerAssetsAndRetiredQueryMarkersAlwaysRequireRevalidation() throws {
        for name in SharePage.assetTypes.keys.sorted() {
            let path = "/s/_/" + name
            let plain = request("GET", path)
            XCTAssertEqual(plain.status, 200)
            XCTAssertFalse(plain.body.isEmpty)
            for query in [[:], ["v": service.page.version], ["v": "retired-deployment-hash"]] {
                let response = request("GET", path, query: query)
                XCTAssertEqual(response.status, 200)
                XCTAssertEqual(response.headers["Cache-Control"], "public, no-cache")
                XCTAssertEqual(response.contentType, SharePage.assetTypes[name])
                XCTAssertEqual(response.body, plain.body, "Old query URLs serve current bytes, so cannot be immutable")
            }
        }
        let missing = request("GET", "/s/_/retired-missing.mjs", query: ["v": "retired-deployment-hash"])
        XCTAssertEqual(missing.status, 404)
        XCTAssertEqual(missing.headers["Cache-Control"], "no-store")
        XCTAssertEqual(request("GET", "/s/" + Base64URL.encode(Data(repeating: 1, count: 16))).headers["Cache-Control"], "no-store")
        XCTAssertEqual(request("GET", "/v1/share/config").headers["Cache-Control"], "no-store")
    }

    // MARK: - Helpers

    func request(_ method: String, _ path: String, json: Any? = nil, body: Data? = nil, secret: String? = nil,
                 query: [String: String] = [:], headers: [String: String] = [:], ip: String = "203.0.113.7",
                 userAgent: String? = nil) -> ShareResponse {
        var all = headers
        if let secret { all["authorization"] = "Bearer \(secret)" }
        all["x-real-ip"] = ip
        all["user-agent"] = userAgent ?? browser
        let payload = body ?? json.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
        return service.handle(HTTPRequestMessage(method: method, path: path, query: query, headers: all, body: payload))
    }

    func upload(_ id: String, _ kind: String, _ bytes: Data, secret: String? = nil, declared: Int? = nil) throws -> ShareResponse {
        let file = directory.appendingPathComponent("staged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: file)
        let head = StreamingUpload.Request(method: "PUT", path: "/v1/share/shares/\(id)/\(kind)",
                                           headers: ["authorization": "Bearer \(secret ?? self.secret)"],
                                           contentLength: declared ?? bytes.count)
        return service.handleUpload(head, file: file)
    }

    func decode<T: Decodable>(_ type: T.Type, _ response: ShareResponse, file: StaticString = #filePath,
                              line: UInt = #line) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: response.body)
        } catch {
            XCTFail("\(response.status): \(String(decoding: response.body, as: UTF8.self))", file: file, line: line)
            throw error
        }
    }

    func code(_ response: ShareResponse) -> String? {
        (try? JSONDecoder().decode(ShareErrorBody.self, from: response.body))?.code
    }

    struct Made {
        let id: String
        let key: Data
        let song: Data
        let sealed: Data
    }

    func createBody(_ sealed: Data, preview: [String: Any]? = nil, expires: Int = 604_800, cap: Int = 100,
                    privateMeta: Data? = nil, failures: [String] = []) -> [String: Any] {
        var body: [String: Any] = [
            "expiresInSeconds": expires, "playCap": cap, "audioBytes": sealed.count,
            "audioSHA256": ShareHash.sha256Hex(sealed),
            "client": ["platform": "ios", "appVersion": "1.2 (345)"],
        ]
        if let privateMeta {
            body["encryptedMeta"] = privateMeta.base64EncodedString()
            body["durationBucket"] = "3-5m"
        } else {
            body["preview"] = preview ?? ["title": "Song <One>", "artist": "Artist", "album": "Album",
                                          "durationSeconds": 241, "from": "Anatoli", "note": "Listen to this",
                                          "accent": "#3a7bd5", "peaks": [10, 200, 90]]
        }
        if !failures.isEmpty { body["recentFailures"] = failures.map { ["reason": $0] } }
        return body
    }

    /// Creates, uploads and finalizes a share, asserting every step.
    @discardableResult
    func makeReadyShare(cap: Int = 100, expires: Int = 604_800, secret: String? = nil, art: Bool = false) throws -> Made {
        let key = ShareCrypto.newKey()
        let song = Data((0 ..< 150_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let sealed = try ShareCrypto.seal(song, key: key, purpose: .audio)
        let created = request("POST", "/v1/share/shares", json: createBody(sealed, expires: expires, cap: cap),
                              secret: secret ?? self.secret)
        XCTAssertEqual(created.status, 201, String(decoding: created.body, as: UTF8.self))
        let response = try decode(CreateShareResponse.self, created)
        XCTAssertTrue(ShareLink.isValidID(response.id))
        XCTAssertEqual(response.url, "https://batonmusic.app/s/\(response.id)")
        XCTAssertEqual(try upload(response.id, "audio", sealed, secret: secret).status, 200)
        if art {
            XCTAssertEqual(try upload(response.id, "art", Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(count: 100),
                                      secret: secret).status, 200)
        }
        let finalized = request("POST", "/v1/share/shares/\(response.id)/finalize", secret: secret ?? self.secret)
        XCTAssertEqual(finalized.status, 200)
        XCTAssertEqual(try decode(ShareSummary.self, finalized).status, .ready)
        return Made(id: response.id, key: key, song: song, sealed: sealed)
    }

    func events(_ type: String? = nil) throws -> [[String: SQLValue]] {
        let rows = try service.store.database.query("SELECT * FROM events ORDER BY id")
        return type.map { t in rows.filter { $0["type"]?.text == t } } ?? rows
    }

    func testPendingAudioReservationsSurviveRestartAndPreventOverAdmission() throws {
        let sealed = try ShareCrypto.seal(Data(repeating: 3, count: 1000), key: Data(repeating: 4, count: 16), purpose: .audio)
        var limits = ShareLimits.standard
        limits.quotaBytes = Int64(sealed.count * 2 - 1)
        service = try makeService(limits: limits)
        let first = request("POST", "/v1/share/shares", json: createBody(sealed), secret: secret)
        XCTAssertEqual(first.status, 201)
        let id = try decode(CreateShareResponse.self, first).id
        service = try makeService(limits: limits)
        XCTAssertEqual(request("POST", "/v1/share/shares", json: createBody(sealed), secret: otherSecret).status, 503)
        XCTAssertEqual(try upload(id, "audio", sealed).status, 200, "Uploading reserved audio must not charge it twice")
        XCTAssertEqual(request("POST", "/v1/share/shares/\(id)/finalize", secret: secret).status, 200)
        let owned = try decode(ShareList.self, request("GET", "/v1/share/shares", secret: secret))
        XCTAssertEqual(owned.shares.map(\.status), [.ready])
    }

    // MARK: - The whole flow

    func testAShareGoesFromCreateToAFriendPlayingIt() throws {
        let made = try makeReadyShare(art: true)

        // The friend opens the page.
        let page = request("GET", "/s/\(made.id)")
        XCTAssertEqual(page.status, 200)
        let html = String(decoding: page.body, as: UTF8.self)
        XCTAssertTrue(html.contains(#"<meta property="og:title" content="Anatoli sent you Song &lt;One&gt; by Artist">"#), html)
        XCTAssertTrue(html.contains("og:image"), "artwork becomes the preview image when there is no card")
        XCTAssertFalse(html.contains("Song <One>"), "every interpolated value is escaped")
        XCTAssertEqual(page.headers["X-Robots-Tag"], "noindex, nofollow, noarchive")
        XCTAssertEqual(page.headers["Referrer-Policy"], "no-referrer")
        XCTAssertNotNil(page.headers["Content-Security-Policy"])

        // The player reads the share and fetches the ciphertext, which opens with the link's key.
        let info = try decode(PublicShare.self, request("GET", "/v1/share/p/\(made.id)"))
        XCTAssertEqual(info.status, .ready)
        XCTAssertEqual(info.preview?.title, "Song <One>")
        XCTAssertTrue(info.hasArt)
        let audio = request("GET", "/v1/share/p/\(made.id)/audio")
        XCTAssertEqual(audio.status, 200)
        XCTAssertEqual(audio.headers["Cache-Control"], "private, no-store")
        XCTAssertEqual(try ShareCrypto.open(audio.body, key: made.key, purpose: .audio), made.song)

        // Beacons, then a reaction.
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/events", json: ["type": "play_started", "ms": 1800]).status, 204)
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/events", json: ["type": "play_30s"]).status, 204)
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/events", json: ["type": "play_completed"]).status, 204)
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/reactions",
                               json: ["emoji": "❤️", "name": "Maya", "reply": "On repeat"]).status, 204)

        // The sharer sees it all.
        let list = try decode(ShareList.self, request("GET", "/v1/share/shares", secret: secret))
        XCTAssertEqual(list.shares.count, 1)
        let stats = list.shares[0].stats
        XCTAssertEqual(stats.opens, 1)
        XCTAssertEqual(stats.fetches, 1)
        XCTAssertEqual(stats.plays, 1)
        XCTAssertEqual(stats.listeners, 1)
        XCTAssertEqual(stats.listened30s, 1)
        XCTAssertEqual(stats.completed, 1)
        XCTAssertEqual(list.shares[0].reactions.map(\.name), ["Maya"])
        XCTAssertEqual(list.shares[0].reactions.first?.reply, "On repeat")

        XCTAssertEqual(try events().compactMap { $0["type"]?.text }, [
            "share_created", "share_finalized", "page_opened", "audio_fetched",
            "play_started", "play_30s", "play_completed", "reaction_sent",
        ])
    }

    func testAPrivateShareKeepsItsDetailsOutOfThePage() throws {
        let key = ShareCrypto.newKey()
        let sealed = try ShareCrypto.seal(Data(count: 5000), key: key, purpose: .audio)
        let meta = try ShareCrypto.seal(Data(#"{"title":"Secret Song","durationSeconds":200,"from":"Anatoli"}"#.utf8),
                                        key: key, purpose: .meta)
        let created = try decode(CreateShareResponse.self,
                                 request("POST", "/v1/share/shares", json: createBody(sealed, privateMeta: meta), secret: secret))
        XCTAssertEqual(try upload(created.id, "card", Data([0xFF, 0xD8, 0xFF]) + Data(count: 10)).status, 400,
                       "a private share has no preview card")
        XCTAssertEqual(try upload(created.id, "art", Data([0xFF, 0xD8, 0xFF]) + Data(count: 10)).status, 400,
                       "a private share's artwork must be sealed")
        XCTAssertEqual(try upload(created.id, "art", try ShareCrypto.seal(Data(count: 900), key: key, purpose: .art)).status, 200)
        XCTAssertEqual(try upload(created.id, "audio", sealed).status, 200)
        XCTAssertEqual(request("POST", "/v1/share/shares/\(created.id)/finalize", secret: secret).status, 200)

        let html = String(decoding: request("GET", "/s/\(created.id)").body, as: UTF8.self)
        XCTAssertFalse(html.contains("Secret Song"))
        XCTAssertFalse(html.contains("Anatoli"))
        XCTAssertTrue(html.contains("Someone sent you a song"))
        XCTAssertFalse(html.contains("og:image"), "sealed artwork is no use to a crawler")

        let info = try decode(PublicShare.self, request("GET", "/v1/share/p/\(created.id)"))
        XCTAssertNil(info.preview)
        let opened = try ShareCrypto.open(try XCTUnwrap(Data(base64Encoded: info.encryptedMeta ?? "")), key: key, purpose: .meta)
        XCTAssertTrue(String(decoding: opened, as: UTF8.self).contains("Secret Song"))
        XCTAssertEqual(try events("share_created").first?["props"]?.text?.contains(#""mode":"private""#), true)
    }

    // MARK: - Sharer routes: auth, ownership, validation

    func testSharerRoutesNeedAWellFormedSecret() throws {
        XCTAssertEqual(request("GET", "/v1/share/shares").status, 401)
        XCTAssertEqual(request("GET", "/v1/share/shares", secret: "short").status, 401)
        XCTAssertEqual(request("GET", "/v1/share/shares", secret: String(repeating: "!", count: 40)).status, 401)
        XCTAssertEqual(request("GET", "/v1/share/shares", secret: secret).status, 200)
    }

    func testSomeoneElsesShareIsNotFoundRatherThanForbidden() throws {
        let made = try makeReadyShare()
        for (method, path) in [("DELETE", "/v1/share/shares/\(made.id)"), ("PATCH", "/v1/share/shares/\(made.id)"),
                               ("POST", "/v1/share/shares/\(made.id)/finalize")] {
            let response = request(method, path, json: ["playCap": 5], secret: otherSecret)
            XCTAssertEqual(response.status, 404, "\(method) \(path)")
        }
        XCTAssertEqual(try upload(made.id, "art", Data([0xFF, 0xD8, 0xFF]), secret: otherSecret).status, 404)
        XCTAssertEqual(try decode(ShareList.self, request("GET", "/v1/share/shares", secret: otherSecret)).shares, [])
    }

    func testCreateRefusesABadBodyWithTheFieldNamed() throws {
        let sealed = try ShareCrypto.seal(Data(count: 10), key: ShareCrypto.newKey(), purpose: .audio)
        var body = createBody(sealed)
        body["playCap"] = 0
        let response = request("POST", "/v1/share/shares", json: body, secret: secret)
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(code(response), "invalid")
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("playCap"))
        XCTAssertEqual(request("POST", "/v1/share/shares", body: Data("nope".utf8), secret: secret).status, 400)
        XCTAssertEqual(try events("share_created").count, 0)
    }

    func testUploadsAreCheckedForSizeShapeAndChecksum() throws {
        let key = ShareCrypto.newKey()
        let sealed = try ShareCrypto.seal(Data(count: 3000), key: key, purpose: .audio)
        let id = try decode(CreateShareResponse.self,
                            request("POST", "/v1/share/shares", json: createBody(sealed), secret: secret)).id

        XCTAssertEqual(request("POST", "/v1/share/shares/\(id)/finalize", secret: secret).status, 409, "no audio yet")
        XCTAssertEqual(try upload(id, "audio", sealed.dropLast()).status, 400, "length differs from the declaration")
        var tampered = sealed
        tampered[100] ^= 1
        let mismatch = try upload(id, "audio", tampered)
        XCTAssertEqual(mismatch.status, 422)
        XCTAssertEqual(code(mismatch), "checksum")
        var notBSH1 = sealed
        notBSH1[0] = 0x58
        XCTAssertEqual(try upload(id, "audio", notBSH1).status, 400, "only BSH1-shaped bytes are stored")
        XCTAssertEqual(try upload(id, "art", Data("GIF89a".utf8)).status, 400, "JPEG or PNG only")
        XCTAssertEqual(try upload(id, "art", Data([0xFF, 0xD8, 0xFF]) + Data(count: 600_000)).status, 413)
        XCTAssertEqual(try upload(id, "audio", sealed).status, 200)
        XCTAssertEqual(try upload(id, "audio", sealed).status, 409, "once only")
        XCTAssertEqual(request("POST", "/v1/share/shares/\(id)/finalize", secret: secret).status, 200)
        XCTAssertEqual(try upload(id, "art", Data([0xFF, 0xD8, 0xFF])).status, 409, "finalized shares are closed")
        let staged = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("staged-") }
        XCTAssertEqual(staged, [], "every upload's staging file is gone, accepted or not")
    }

    // MARK: - Public routes and states

    func testAPendingShareIsNotPlayable() throws {
        let sealed = try ShareCrypto.seal(Data(count: 10), key: ShareCrypto.newKey(), purpose: .audio)
        let id = try decode(CreateShareResponse.self,
                            request("POST", "/v1/share/shares", json: createBody(sealed), secret: secret)).id
        let page = request("GET", "/s/\(id)")
        XCTAssertEqual(page.status, 200)
        XCTAssertTrue(String(decoding: page.body, as: UTF8.self).contains(#"data-state="pending""#))
        XCTAssertEqual(request("GET", "/v1/share/p/\(id)/audio").status, 404)
        XCTAssertEqual(try decode(PublicShare.self, request("GET", "/v1/share/p/\(id)")).status, .pending)
    }

    func testUnknownAndMalformedIdsAre404() throws {
        XCTAssertEqual(request("GET", "/s/AAAAAAAAAAAAAAAAAAAAAA").status, 404)
        XCTAssertEqual(request("GET", "/s/not-an-id").status, 404)
        XCTAssertEqual(request("GET", "/v1/share/p/../../etc/passwd/audio").status, 404)
        XCTAssertEqual(request("GET", "/v1/share/nothing").status, 404)
        XCTAssertEqual(request("DELETE", "/v1/share/config").status, 405)
    }

    func testTheLinkStopsAtItsStatedTimeEvenBeforeTheSweeper() throws {
        let made = try makeReadyShare(expires: 86400)
        clock.advance(86399)
        XCTAssertEqual(request("GET", "/v1/share/p/\(made.id)/audio").status, 200)
        clock.advance(1)
        let gone = request("GET", "/v1/share/p/\(made.id)/audio")
        XCTAssertEqual(gone.status, 410)
        XCTAssertEqual(code(gone), "expired")
        let page = request("GET", "/s/\(made.id)")
        XCTAssertEqual(page.status, 410)
        XCTAssertTrue(String(decoding: page.body, as: UTF8.self).contains("This song’s link has expired"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.store.blobURL(id: made.id, kind: .audio).path),
                       "the audio is deleted, not just hidden")
        let summary = try decode(ShareList.self, request("GET", "/v1/share/shares", secret: secret)).shares[0]
        XCTAssertEqual(summary.status, .expired)
        XCTAssertNil(summary.preview, "a tombstone keeps counters, not content")
        XCTAssertEqual(summary.stats.fetches, 1)
        XCTAssertEqual(try events("page_opened").last?["props"]?.text?.contains(#""state":"expired""#), true,
                       "opens after the end are recorded, so the default expiry can be judged")
    }

    func testThePlayCapCountsWholeFetchesNotRanges() throws {
        let made = try makeReadyShare(cap: 2)
        XCTAssertEqual(request("GET", "/v1/share/p/\(made.id)/audio").status, 200)
        XCTAssertEqual(request("GET", "/v1/share/p/\(made.id)/audio", headers: ["range": "bytes=5000-"]).status, 200)
        XCTAssertEqual(request("GET", "/v1/share/p/\(made.id)/audio", headers: ["range": "bytes=0-"]).status, 200)
        let capped = request("GET", "/v1/share/p/\(made.id)/audio")
        XCTAssertEqual(capped.status, 410)
        XCTAssertEqual(code(capped), "play_cap")
        XCTAssertEqual(try events("share_capped").count, 1)
        let page = request("GET", "/s/\(made.id)")
        XCTAssertEqual(page.status, 410)
        XCTAssertTrue(String(decoding: page.body, as: UTF8.self).contains("played a lot"))

        // The sharer can raise it.
        XCTAssertEqual(request("PATCH", "/v1/share/shares/\(made.id)", json: ["playCap": 10], secret: secret).status, 200)
        XCTAssertEqual(request("GET", "/v1/share/p/\(made.id)/audio").status, 200)
    }

    func testRevokeDeletesAtOnceAndReadsAsExpiredToTheFriend() throws {
        let made = try makeReadyShare()
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/reactions", json: ["emoji": "🔥"]).status, 204)
        XCTAssertEqual(request("DELETE", "/v1/share/shares/\(made.id)", secret: secret).status, 204)
        XCTAssertEqual(request("DELETE", "/v1/share/shares/\(made.id)", secret: secret).status, 204, "idempotent")
        let audio = request("GET", "/v1/share/p/\(made.id)/audio")
        XCTAssertEqual(audio.status, 410)
        XCTAssertEqual(code(audio), "expired", "the public API does not say revoked either")
        XCTAssertEqual(code(request("GET", "/v1/share/p/\(made.id)")), "expired")
        let html = String(decoding: request("GET", "/s/\(made.id)").body, as: UTF8.self)
        XCTAssertTrue(html.contains("This song’s link has expired"), "revoked says expired: it does not leak intent")
        XCTAssertFalse(html.contains("revoked"), "not in the page's data either: \(html)")
        XCTAssertEqual(try decode(ShareList.self, request("GET", "/v1/share/shares", secret: secret)).shares[0].status,
                       .revoked, "the sharer still sees what they did")
        XCTAssertEqual(try service.store.reactions(shareID: made.id), [])
        XCTAssertEqual(request("PATCH", "/v1/share/shares/\(made.id)", json: ["extendBySeconds": 60], secret: secret).status, 409)
    }

    func testExtendIsCappedAtThirtyDaysFromNow() throws {
        let made = try makeReadyShare(expires: 2_592_000)
        let summary = try decode(ShareSummary.self, request("PATCH", "/v1/share/shares/\(made.id)",
                                                            json: ["extendBySeconds": 2_592_000], secret: secret))
        XCTAssertEqual(ShareDate.date(summary.expiresAt), clock.now + 2_592_000)
    }

    // MARK: - Beacons and reactions

    func testBeaconsTakeOnlyKnownEventsAndPlainTextBodies() throws {
        let made = try makeReadyShare()
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/events",
                               body: Data(#"{"type":"get_baton_clicked","target":"app_store"}"#.utf8),
                               headers: ["content-type": "text/plain;charset=UTF-8"]).status, 204)
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/events", json: ["type": "keylogger"]).status, 400)
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/events",
                               json: ["type": "get_baton_clicked", "target": "https://evil.example"]).status, 400)
        XCTAssertEqual(request("POST", "/v1/share/p/AAAAAAAAAAAAAAAAAAAAAA/events", json: ["type": "play_30s"]).status, 204,
                       "a beacon for nothing is dropped quietly")
        XCTAssertEqual(try events("get_baton_clicked").count, 1)
    }

    func testBeaconsAreRateLimitedPerVisitor() throws {
        let made = try makeReadyShare()
        for _ in 0 ..< 30 {
            XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/events", json: ["type": "play_30s"]).status, 204)
        }
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/events", json: ["type": "play_30s"]).status, 429)
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/events", json: ["type": "play_30s"], ip: "198.51.100.1").status,
                       204, "another visitor is unaffected")
        clock.advance(60)
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/events", json: ["type": "play_30s"]).status, 204)
    }

    func testReactionsAreLimitedAndValidated() throws {
        let made = try makeReadyShare()
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/reactions", json: ["emoji": "💩"]).status, 400)
        for _ in 0 ..< 5 {
            XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/reactions", json: ["emoji": "🙏"]).status, 204)
        }
        XCTAssertEqual(request("POST", "/v1/share/p/\(made.id)/reactions", json: ["emoji": "🙏"]).status, 429)
    }

    // MARK: - Crawlers and devices

    func testACrawlerIsAnUnfurlNotAnOpen() throws {
        let made = try makeReadyShare()
        let iMessage = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_1) AppleWebKit/601.2.4 (KHTML, like Gecko) "
            + "Version/9.0.1 Safari/601.2.4 facebookexternalhit/1.1 Facebot Twitterbot/1.0"
        XCTAssertEqual(request("GET", "/s/\(made.id)", userAgent: iMessage).status, 200)
        XCTAssertEqual(request("GET", "/s/\(made.id)", userAgent: "WhatsApp/2.23.20.0").status, 200)
        XCTAssertEqual(try events("link_unfurled").compactMap { $0["props"]?.text }, [#"{"app":"imessage"}"#, #"{"app":"whatsapp"}"#])
        XCTAssertEqual(try events("page_opened").count, 0)
        XCTAssertEqual(try decode(ShareList.self, request("GET", "/v1/share/shares", secret: secret)).shares[0].stats.opens, 0)
    }

    func testDeviceClasses() {
        XCTAssertEqual(ClientClass.device(userAgent: browser), "ios")
        XCTAssertEqual(ClientClass.device(userAgent: "Mozilla/5.0 (Linux; Android 14; Pixel 8)"), "android")
        XCTAssertEqual(ClientClass.device(userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0)"), "mac")
        XCTAssertEqual(ClientClass.device(userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"), "windows")
        XCTAssertNil(ClientClass.crawler(userAgent: browser))
        XCTAssertEqual(ClientClass.crawler(userAgent: "Slackbot-LinkExpanding 1.0"), "slack")
        XCTAssertEqual(ClientClass.crawler(userAgent: ""), "other_bot")
    }

    // MARK: - Limits

    func testDailyAndLiveLimitsPerSharer() throws {
        var limits = ShareLimits()
        limits.createsPerSharerPerDay = 2
        service = try makeService(limits: limits)
        try makeReadyShare()
        try makeReadyShare()
        let sealed = try ShareCrypto.seal(Data(count: 10), key: ShareCrypto.newKey(), purpose: .audio)
        let refused = request("POST", "/v1/share/shares", json: createBody(sealed), secret: secret)
        XCTAssertEqual(refused.status, 429)
        XCTAssertNotNil(refused.headers["Retry-After"])
        XCTAssertEqual(request("POST", "/v1/share/shares", json: createBody(sealed), secret: otherSecret).status, 201)
        clock.advance(86400)
        XCTAssertEqual(request("POST", "/v1/share/shares", json: createBody(sealed), secret: secret).status, 201)
        XCTAssertEqual(try events("rate_limited").first?["props"]?.text, #"{"scope":"sharer_daily"}"#)
    }

    func testNewSharersPerNetworkAreLimited() throws {
        var limits = ShareLimits()
        limits.newSharersPerNetworkPerDay = 1
        service = try makeService(limits: limits)
        let sealed = try ShareCrypto.seal(Data(count: 10), key: ShareCrypto.newKey(), purpose: .audio)
        XCTAssertEqual(request("POST", "/v1/share/shares", json: createBody(sealed), secret: secret).status, 201)
        XCTAssertEqual(request("POST", "/v1/share/shares", json: createBody(sealed), secret: otherSecret).status, 429)
        XCTAssertEqual(request("POST", "/v1/share/shares", json: createBody(sealed), secret: secret).status, 201,
                       "an existing sharer is not a new one")
        XCTAssertEqual(request("POST", "/v1/share/shares", json: createBody(sealed), secret: otherSecret,
                               ip: "198.51.100.2").status, 201)
    }

    func testQuotaAndKillSwitch() throws {
        var limits = ShareLimits()
        limits.quotaBytes = 200_000
        service = try makeService(limits: limits)
        try makeReadyShare()
        let sealed = try ShareCrypto.seal(Data(count: 100_000), key: ShareCrypto.newKey(), purpose: .audio)
        let busy = request("POST", "/v1/share/shares", json: createBody(sealed), secret: secret)
        XCTAssertEqual(busy.status, 503)
        XCTAssertEqual(code(busy), "busy")

        service = try makeService(enabled: false)
        let paused = request("POST", "/v1/share/shares", json: createBody(sealed), secret: secret)
        XCTAssertEqual(code(paused), "share_disabled")
        XCTAssertEqual(try decode(ShareConfig.self, request("GET", "/v1/share/config")).enabled, false)
    }

    // MARK: - Sweeper

    func testTheSweeperExpiresAbandonsAndPurges() throws {
        let ready = try makeReadyShare(expires: 86400)
        let sealed = try ShareCrypto.seal(Data(count: 10), key: ShareCrypto.newKey(), purpose: .audio)
        let pending = try decode(CreateShareResponse.self,
                                 request("POST", "/v1/share/shares", json: createBody(sealed), secret: secret)).id
        try FileManager.default.createDirectory(at: service.store.blobsDirectory.appendingPathComponent("orphan"),
                                                withIntermediateDirectories: true)

        clock.advance(3600)
        var result = try service.sweep()
        XCTAssertEqual(result.abandoned, 1)
        XCTAssertNil(try service.store.share(id: pending), "an upload never finished is deleted outright")
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.store.blobsDirectory.appendingPathComponent("orphan").path))

        clock.advance(86400)
        result = try service.sweep()
        XCTAssertEqual(result.expired, 1)
        XCTAssertEqual(try service.store.share(id: ready.id)?.status, .expired)

        clock.advance(400 * 86400)
        result = try service.sweep()
        XCTAssertEqual(result.purged, 1)
        XCTAssertGreaterThan(result.eventsPurged, 0)
        XCTAssertNil(try service.store.share(id: ready.id))
    }

    // MARK: - Privacy

    func testNoRawAddressIsEverWrittenDown() throws {
        let address = "203.0.113.77"
        let made = try makeReadyShare()
        _ = request("GET", "/s/\(made.id)", ip: address)
        _ = request("GET", "/v1/share/p/\(made.id)/audio", ip: address)
        _ = request("POST", "/v1/share/p/\(made.id)/events", json: ["type": "play_started", "ms": 900], ip: address)
        _ = request("POST", "/v1/share/p/\(made.id)/reactions", json: ["emoji": "❤️"], ip: address)
        try service.store.database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        for name in try FileManager.default.subpathsOfDirectory(atPath: directory.path) {
            let url = directory.appendingPathComponent(name)
            guard let bytes = try? Data(contentsOf: url) else { continue }
            XCTAssertNil(bytes.range(of: Data(address.utf8)), "\(name) contains the client address")
        }
    }

    func testBlobsAreReadableByNginxAndTheDatabaseIsNot() throws {
        let made = try makeReadyShare(art: true)
        func mode(_ path: String) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        XCTAssertEqual(try mode(service.store.blobURL(id: made.id, kind: .audio).path), 0o644)
        XCTAssertEqual(try mode(service.store.blobURL(id: made.id, kind: .art).path), 0o644)
        XCTAssertEqual(try mode(service.store.blobURL(id: made.id, kind: .audio).deletingLastPathComponent().path), 0o755)
        XCTAssertEqual(try mode(service.store.blobsDirectory.path), 0o755)
        XCTAssertEqual(try mode(directory.appendingPathComponent("share.sqlite").path), 0o600)
        XCTAssertEqual(try mode(directory.appendingPathComponent("share.sqlite-wal").path), 0o600)
    }

    func testVisitorHashesChangeWithTheDay() throws {
        let salt = DailySalt()
        let today = salt.hash(["visitor", "1.2.3.4", "ua", "share"], now: 1_790_000_000)
        XCTAssertEqual(today, salt.hash(["visitor", "1.2.3.4", "ua", "share"], now: 1_790_000_100))
        XCTAssertNotEqual(today, salt.hash(["visitor", "1.2.3.4", "ua", "share"], now: 1_790_000_000 + 86400))
        XCTAssertNotEqual(today, salt.hash(["visitor", "1.2.3.4", "ua", "other share"], now: 1_790_000_000))
    }

    // MARK: - Admin

    func testAdminStatsAnswerOnlyInsideTheHostAndCountWhatHappened() throws {
        let token = String(repeating: "a", count: 40)
        service = try makeService(admin: token)
        let made = try makeReadyShare()
        try makeReadyShare(secret: otherSecret)
        _ = request("GET", "/s/\(made.id)")
        _ = request("GET", "/v1/share/p/\(made.id)/audio")
        _ = request("POST", "/v1/share/p/\(made.id)/events", json: ["type": "play_started", "ms": 1200])
        _ = request("POST", "/v1/share/p/\(made.id)/events", json: ["type": "play_30s"])
        _ = request("POST", "/v1/share/p/\(made.id)/reactions", json: ["emoji": "❤️", "reply": "yes"])
        let sealed = try ShareCrypto.seal(Data(count: 10), key: ShareCrypto.newKey(), purpose: .audio)
        _ = request("POST", "/v1/share/shares", json: createBody(sealed, failures: ["transcode", "network"]), secret: secret)

        func admin(_ headers: [String: String]) -> ShareResponse {
            service.handle(HTTPRequestMessage(method: "GET", path: "/v1/share/admin/stats", query: ["days": "7"],
                                              headers: headers, body: Data()))
        }
        XCTAssertEqual(admin(["authorization": "Bearer \(token)", "x-forwarded-for": "1.1.1.1"]).status, 404,
                       "through the proxy, the route does not exist")
        XCTAssertEqual(admin(["authorization": "Bearer wrong"]).status, 404)
        let report = try decode(ShareReport.self, admin(["authorization": "Bearer \(token)"]))
        XCTAssertEqual(report.sharers.active, 2)
        XCTAssertEqual(report.sharers.new, 2)
        XCTAssertEqual(report.sharers.repeating, 1)
        XCTAssertEqual(report.sharers.byPlatform, ["ios": 2])
        XCTAssertEqual(report.shares.created, 3)
        XCTAssertEqual(report.shares.finalized, 2)
        XCTAssertEqual(report.shares.liveNow, 2)
        XCTAssertEqual(report.recipients.pageOpens, 1)
        XCTAssertEqual(report.recipients.uniqueOpeners, 1)
        XCTAssertEqual(report.listening.playsStarted, 1)
        XCTAssertEqual(report.listening.timeToFirstSoundMsP50, 1200)
        XCTAssertEqual(report.engagement.reactions, 1)
        XCTAssertEqual(report.engagement.reactionsWithReply, 1)
        XCTAssertEqual(report.health.failuresByReason, ["transcode": 1, "network": 1])
        XCTAssertEqual(report.rates.openRate, 0.5)
        XCTAssertEqual(report.rates.playRate, 1)
        XCTAssertNil(report.rates.getBatonRate.flatMap { $0 > 0 ? $0 : nil })
    }

    func testAdminIsOffWithoutAToken() {
        XCTAssertEqual(request("GET", "/v1/share/admin/stats", headers: ["authorization": "Bearer "]).status, 404)
    }
}
