@testable import BatonGatewayCore
import BatonMCPProtocol
import BatonShareKit
@testable import BatonShareServer
import Foundation
import XCTest

final class ShareMixtapeServiceTests: XCTestCase {
    var root: URL!
    var service: ShareService!
    let clock = TestClock()
    let owner = Base64URL.encode(Data(repeating: 5, count: 32))
    let other = Base64URL.encode(Data(repeating: 6, count: 32))
    let operatorToken = String(repeating: "X", count: 40)
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mixtape-" + UUID().uuidString)
        service = try reopen()
    }
    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("blobs").path)
        service = nil
        try? FileManager.default.removeItem(at: root)
    }
    func reopen(quota: Int64 = ShareLimits.standard.quotaBytes, enabled: Bool = true) throws -> ShareService {
        var config = ShareConfiguration(dataDirectory: root, blobDelivery: .direct)
        config.mixtapesEnabled = enabled
        config.limits.quotaBytes = quota
        config.enforcement = try .init(token: operatorToken, retentionSeconds: 90 * 86400, auditRetentionSeconds: 90 * 86400, reasonCodes: ["review"])
        return try ShareService(config: config, clock: { [clock] in clock.now })
    }
    func send(_ method: String, _ path: String, body: Data = Data(), token: String? = nil, range: String? = nil, peer: ConnectionPeer = .unknown) -> ShareResponse {
        var headers = ["user-agent": "Synthetic browser"]
        if peer != .loopback { headers["x-real-ip"] = "203.0.113.8" }
        if let token { headers["authorization"] = "Bearer " + token }
        if let range { headers["range"] = range }
        return service.handle(.init(method: method, path: path, query: [:], headers: headers, body: body), peer: peer)
    }
    func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    func decode<T: Decodable>(_ type: T.Type, _ response: ShareResponse) throws -> T { try JSONDecoder().decode(type, from: response.body) }
    func code(_ response: ShareResponse) -> String? { (try? JSONDecoder().decode(ShareErrorBody.self, from: response.body))?.code }
    struct Fixture {
        let key: Data
        let manifest: ShareMixtapeManifest
        let audio: [String: Data]
        var body: CreateMixtapeRequest
    }
    func fixture(cap: Int = 2, count: Int = 2, consent: Bool = false) throws -> Fixture {
        // Independent Python vectors supply the actual BSH1 track bytes and hashes.
        struct Vector: Decodable { let trackID: String?; let ciphertext: String; let ciphertextSHA256: String; let rootKey: String }
        struct Vectors: Decodable { let positive: [Vector] }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: repo.appendingPathComponent("specs/share-crypto/mixtape-vectors.json"))).positive
        let key = try XCTUnwrap(Base64URL.decode(vectors[0].rootKey))
        var tracks = [ShareMixtapeManifest.Track](), audio = [String: Data]()
        for i in 0..<count {
            let id = i < 2 ? vectors[i].trackID! : Base64URL.encode(Data(repeating: UInt8(i + 2), count: 16))
            let bytes = i < 2 ? Data(base64Encoded: vectors[i].ciphertext)! : try ShareCrypto.seal(Data(repeating: 3, count: 50), key: ShareMixtapeCrypto.trackKey(rootKey: key, trackID: id), purpose: .audio)
            audio[id] = bytes
            tracks.append(.init(id: id, metadata: .init(title: "Track \(i + 1)", durationSeconds: 10), audioBytes: bytes.count, audioSHA256: i < 2 ? vectors[i].ciphertextSHA256 : ShareHash.sha256Hex(bytes)))
        }
        let manifest = ShareMixtapeManifest(title: "Ordered synthetic", tracks: tracks.reversed())
        let sealed: Data = count <= 12 ? try manifest.seal(rootKey: key) : try ShareCrypto.seal(Data("{}".utf8), key: ShareMixtapeCrypto.manifestKey(rootKey: key), purpose: .meta)
        let body = CreateMixtapeRequest(encryptedManifest: sealed.base64EncodedString(), tracks: Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, .init(audioBytes: $0.audioBytes, audioSHA256: $0.audioSHA256)) }), totalDurationSeconds: count * 10,
            expiresInSeconds: 86400, playCap: cap, preview: nil, client: .init(platform: "macos", appVersion: "synthetic"), reviewPreservationConsent: consent ? "review-v1" : nil)
        return .init(key: key, manifest: manifest, audio: audio, body: body)
    }
    func create(_ fixture: Fixture, token: String? = nil) throws -> CreateMixtapeResponse {
        let response = send("POST", "/v1/share/mixtapes", body: try encode(fixture.body), token: token ?? owner)
        XCTAssertEqual(response.status, 201)
        return try decode(CreateMixtapeResponse.self, response)
    }
    func upload(_ created: CreateMixtapeResponse, track: String, bytes: Data, token: String? = nil) throws -> ShareResponse {
        let file = root.appendingPathComponent("synthetic-upload-" + UUID().uuidString)
        try bytes.write(to: file)
        return service.handleUpload(.init(method: "PUT", path: created.uploads[track]!, headers: ["authorization": "Bearer " + (token ?? owner)], contentLength: bytes.count), file: file)
    }
    func ready(_ fixture: Fixture) throws -> CreateMixtapeResponse {
        let created = try create(fixture)
        for (id, bytes) in fixture.audio { XCTAssertEqual(try upload(created, track: id, bytes: bytes).status, 200) }
        XCTAssertEqual(send("POST", "/v1/share/mixtapes/\(created.id)/finalize", token: owner).status, 200)
        return created
    }
    func session(_ id: String) throws -> MixtapeSession {
        let response = send("POST", "/v1/share/m/\(id)/sessions")
        XCTAssertEqual(response.status, 201)
        return try decode(MixtapeSession.self, response)
    }

    func testCapabilityOffRetainsOwnerReadbackAndRevocation() throws {
        let created = try ready(try fixture())
        service = try reopen(enabled: false)
        XCTAssertEqual(send("GET", "/v1/share/mixtapes/\(created.id)", token: owner).status, 200)
        XCTAssertEqual(send("GET", "/v1/share/mixtapes", token: owner).status, 200)
        XCTAssertEqual(send("GET", "/v1/share/mixtapes/\(created.id)", token: other).status, 403, "another installation's: not_owner (C-6)")
        XCTAssertEqual(send("GET", "/v1/share/m/\(created.id)").status, 409)
        XCTAssertEqual(send("POST", "/v1/share/m/\(created.id)/sessions").status, 409)
        XCTAssertEqual(send("POST", "/v1/share/mixtapes", body: try encode(try fixture().body), token: owner).status, 409)
        XCTAssertEqual(send("DELETE", "/v1/share/mixtapes/\(created.id)", token: owner).status, 204)
        service = try reopen()
        XCTAssertEqual(try decode(MixtapeSummary.self, send("GET", "/v1/share/mixtapes/\(created.id)", token: owner)).share.status, .revoked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("blobs/\(created.id)").path))
    }
    /// A mixtape's reactions and revocation leave the same usage rows a song's do, labelled as a mixtape.
    func testReactionAndRevocationAreCountedAsMixtapeEvents() throws {
        let created = try ready(try fixture()), admitted = try session(created.id)
        let reaction = try JSONSerialization.data(withJSONObject: ["emoji": "❤️", "reply": "Lovely"])
        XCTAssertEqual(send("POST", "/v1/share/m/\(created.id)/reactions", body: reaction, token: admitted.token).status, 204)
        XCTAssertEqual(send("DELETE", "/v1/share/mixtapes/\(created.id)", token: owner).status, 204)
        XCTAssertEqual(send("DELETE", "/v1/share/mixtapes/\(created.id)", token: owner).status, 204)
        let rows = try service.store.database.query("SELECT type, props FROM events WHERE share_id=? AND type IN ('reaction_sent','share_revoked') ORDER BY id", [.text(created.id)])
        XCTAssertEqual(rows.compactMap { $0["type"]?.text }, ["reaction_sent", "share_revoked"], "a repeated revoke records nothing more")
        XCTAssertEqual(rows.compactMap { $0["props"]?.text }, [#"{"emoji":"❤️","hasName":false,"hasReply":true,"kind":"mixtape"}"#, #"{"kind":"mixtape"}"#])
    }
    /// A reaction and its event are written together: if the event cannot be recorded, the reaction
    /// is not kept either, so the sender's list and the usage report never disagree.
    func testAReactionWhoseEventCannotBeRecordedIsNotKept() throws {
        let created = try ready(try fixture()), admitted = try session(created.id)
        try service.store.database.execute("ALTER TABLE events RENAME TO events_unavailable")
        let reaction = try JSONSerialization.data(withJSONObject: ["emoji": "❤️"])
        XCTAssertEqual(send("POST", "/v1/share/m/\(created.id)/reactions", body: reaction, token: admitted.token).status, 500)
        try service.store.database.execute("ALTER TABLE events_unavailable RENAME TO events")
        XCTAssertEqual(try service.store.reactions(shareID: created.id), [], "no reaction without its event")
        XCTAssertEqual(send("POST", "/v1/share/m/\(created.id)/reactions", body: reaction, token: admitted.token).status, 204)
        XCTAssertEqual(try service.store.reactions(shareID: created.id).count, 1)
    }
    /// BATON_SHARE_ENABLED=0 refuses new shares; links already sent keep playing, page included.
    func testSharingPausedKeepsASentMixtapePagePlaying() throws {
        let created = try ready(try fixture())
        var config = ShareConfiguration(dataDirectory: root, enabled: false, blobDelivery: .direct)
        config.mixtapesEnabled = true
        service = try ShareService(config: config, clock: { [clock] in clock.now })
        XCTAssertEqual(send("GET", "/v1/share/m/\(created.id)").status, 200)
        let page = send("GET", "/m/\(created.id)")
        XCTAssertEqual(page.status, 200)
        XCTAssertTrue(String(decoding: page.body, as: UTF8.self).contains(#"data-state="ready""#))
    }
    func largeFixture() throws -> Fixture {
        let key = Data(repeating: 8, count: 16)
        var tracks = [ShareMixtapeManifest.Track](), audio = [String: Data]()
        for i in 0..<2 {
            let id = Base64URL.encode(Data(repeating: UInt8(i + 8), count: 16))
            let bytes = try ShareCrypto.seal(Data(repeating: UInt8(i), count: 8_000_000), key: ShareMixtapeCrypto.trackKey(rootKey: key, trackID: id), purpose: .audio)
            audio[id] = bytes
            tracks.append(.init(id: id, metadata: .init(title: "Large \(i)", durationSeconds: 10), audioBytes: bytes.count, audioSHA256: ShareHash.sha256Hex(bytes)))
        }
        let manifest = ShareMixtapeManifest(title: "Race fixture", tracks: tracks)
        let body = CreateMixtapeRequest(encryptedManifest: try manifest.seal(rootKey: key).base64EncodedString(), tracks: Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, .init(audioBytes: $0.audioBytes, audioSHA256: $0.audioSHA256)) }), totalDurationSeconds: 20, expiresInSeconds: 86400, playCap: 2, preview: nil, client: .init(platform: "macos", appVersion: "synthetic"))
        return .init(key: key, manifest: manifest, audio: audio, body: body)
    }
    final class ConcurrentResults: @unchecked Sendable {
        let lock = NSLock(); var statuses: [Int] = []
        func append(_ status: Int) { lock.lock(); statuses.append(status); lock.unlock() }
    }
    func testConcurrentIdenticalUploadsCannotDoubleChargeOrBreakFinalize() throws {
        let fixture = try largeFixture(), created = try create(fixture)
        let services = try (0..<4).map { _ in try reopen() }
        let track = fixture.manifest.tracks[0], bytes = fixture.audio[track.id]!
        let files = try (0..<4).map { index -> URL in
            let file = root.appendingPathComponent("race-upload-\(index)"); try bytes.write(to: file); return file
        }
        let results = ConcurrentResults()
        let request = StreamingUpload.Request(method: "PUT", path: created.uploads[track.id]!, headers: ["authorization": "Bearer " + owner], contentLength: bytes.count)
        DispatchQueue.concurrentPerform(iterations: services.count) { index in results.append(services[index].handleUpload(request, file: files[index]).status) }
        XCTAssertEqual(results.statuses.sorted(), [200,200,200,200])
        let next = fixture.manifest.tracks[1]
        XCTAssertEqual(try upload(created, track: next.id, bytes: fixture.audio[next.id]!).status, 200)
        service = try reopen()
        XCTAssertEqual(send("POST", "/v1/share/mixtapes/\(created.id)/finalize", token: owner).status, 200)
        XCTAssertEqual(try decode(PublicMixtape.self, send("GET", "/v1/share/m/\(created.id)")).status, .ready)
    }
    func testUploadCannotRecreateMaterialAfterConcurrentRevocation() throws {
        let fixture = try largeFixture(), created = try create(fixture)
        let uploader = try reopen(), revoker = try reopen()
        let track = fixture.manifest.tracks[0], bytes = fixture.audio[track.id]!
        let file = root.appendingPathComponent("racing-revoked-upload"); try bytes.write(to: file)
        let request = StreamingUpload.Request(method: "PUT", path: created.uploads[track.id]!, headers: ["authorization": "Bearer " + owner], contentLength: bytes.count)
        let group = DispatchGroup(); group.enter()
        DispatchQueue.global().async { _ = uploader.handleUpload(request, file: file); group.leave() }
        Thread.sleep(forTimeInterval: 0.002)
        XCTAssertEqual(revoker.handle(.init(method: "DELETE", path: "/v1/share/mixtapes/\(created.id)", query: [:], headers: ["authorization": "Bearer " + owner], body: Data())).status, 204)
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        service = try reopen()
        XCTAssertEqual(try decode(MixtapeSummary.self, send("GET", "/v1/share/mixtapes/\(created.id)", token: owner)).share.status, .revoked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("blobs/\(created.id)").path))
    }

    func testFinalizeCannotResurrectConcurrentRevocation() throws {
        let fixture = try largeFixture(), created = try create(fixture)
        for (id, bytes) in fixture.audio { XCTAssertEqual(try upload(created, track: id, bytes: bytes).status, 200) }
        let finalizer = try reopen(), revoker = try reopen()
        let owner = self.owner
        let group = DispatchGroup(); group.enter()
        DispatchQueue.global().async {
            _ = finalizer.handle(.init(method: "POST", path: "/v1/share/mixtapes/\(created.id)/finalize", query: [:], headers: ["authorization": "Bearer " + owner], body: Data()))
            group.leave()
        }
        // The real file verification gives the competing connection time to revoke.
        Thread.sleep(forTimeInterval: 0.002)
        XCTAssertEqual(revoker.handle(.init(method: "DELETE", path: "/v1/share/mixtapes/\(created.id)", query: [:], headers: ["authorization": "Bearer " + owner], body: Data())).status, 204)
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        service = try reopen()
        XCTAssertEqual(try decode(MixtapeSummary.self, send("GET", "/v1/share/mixtapes/\(created.id)", token: owner)).share.status, .revoked)
        XCTAssertEqual(send("GET", "/v1/share/m/\(created.id)").status, 410)
        XCTAssertEqual(send("POST", "/v1/share/m/\(created.id)/sessions").status, 410)
    }

    func testOrderedAuthenticatedTracksAndReadyStateSurviveRestart() throws {
        let fixture = try fixture(), created = try ready(fixture)
        XCTAssertTrue(created.url.contains("/m/"))
        service = try reopen()
        let info = try decode(PublicMixtape.self, send("GET", "/v1/share/m/\(created.id)"))
        XCTAssertNil(info.preview)
        XCTAssertEqual(try info.open(rootKey: fixture.key), fixture.manifest)
        let session = try session(created.id)
        for track in fixture.manifest.tracks {
            let bytes = send("GET", "/v1/share/m/\(created.id)/tracks/\(track.id)", token: session.token)
            XCTAssertEqual(bytes.status, 200)
            XCTAssertEqual(bytes.body, fixture.audio[track.id])
            XCTAssertNoThrow(try fixture.manifest.openAudio(bytes.body, trackID: track.id, rootKey: fixture.key))
            XCTAssertEqual(bytes.headers["Cache-Control"], "private, no-store")
            XCTAssertNil(bytes.headers["X-Accel-Redirect"])
        }
        XCTAssertEqual(send("GET", "/v1/share/p/\(created.id)").status, 404, "Old single-song route must not interpret a container")
        XCTAssertEqual(try decode(ShareList.self, send("GET", "/v1/share/shares", token: owner)).shares.count, 0)
        XCTAssertEqual(try decode(MixtapeList.self, send("GET", "/v1/share/mixtapes", token: owner)).mixtapes.first?.share.stats.fetches, 1)
    }
    func testPartialFinalizeAndWrongBytesNeverPublishAndRetryKeepsIdentity() throws {
        let fixture = try fixture(), created = try create(fixture)
        XCTAssertEqual(try create(fixture).id, created.id)
        let tracks = fixture.manifest.tracks
        XCTAssertEqual(try upload(created, track: tracks[0].id, bytes: fixture.audio[tracks[1].id]!).status, 422)
        XCTAssertEqual(try upload(created, track: tracks[0].id, bytes: fixture.audio[tracks[0].id]!, token: other).status, 403, "not_owner (C-6)")
        XCTAssertEqual(try upload(created, track: tracks[0].id, bytes: fixture.audio[tracks[0].id]!).status, 200)
        XCTAssertEqual(send("POST", "/v1/share/mixtapes/\(created.id)/finalize", token: owner).status, 409)
        XCTAssertEqual(try decode(PublicMixtape.self, send("GET", "/v1/share/m/\(created.id)")).status, .pending)
        service = try reopen()
        XCTAssertEqual(try create(fixture).id, created.id)
        XCTAssertEqual(try upload(created, track: tracks[1].id, bytes: fixture.audio[tracks[1].id]!).status, 200)
        XCTAssertEqual(send("POST", "/v1/share/mixtapes/\(created.id)/finalize", token: owner).status, 200)
        XCTAssertEqual(send("POST", "/v1/share/mixtapes/\(created.id)/finalize", token: owner).status, 200)
        var changed = fixture; changed.body.playCap = 3
        XCTAssertEqual(send("POST", "/v1/share/mixtapes", body: try encode(changed.body), token: owner).status, 409)
    }
    func testLastCapAdmissionContinuesButNoImplicitNewSessionIsSpent() throws {
        let fixture = try fixture(cap: 1), created = try ready(fixture), admitted = try session(created.id)
        XCTAssertEqual(admitted.remainingPlays, 0)
        XCTAssertEqual(send("POST", "/v1/share/m/\(created.id)/sessions").status, 410)
        let track = fixture.manifest.tracks[0]
        XCTAssertEqual(send("GET", "/v1/share/m/\(created.id)/tracks/\(track.id)", token: admitted.token).status, 200)
        service = try reopen()
        let next = fixture.manifest.tracks[1]
        XCTAssertEqual(send("GET", "/v1/share/m/\(created.id)/tracks/\(next.id)", token: admitted.token).status, 200)
        XCTAssertEqual(send("GET", "/v1/share/m/\(created.id)/tracks/\(next.id)", token: admitted.token).status, 409)
        XCTAssertEqual(try decode(MixtapeList.self, send("GET", "/v1/share/mixtapes", token: owner)).mixtapes.first?.share.stats.fetches, 1)
    }
    func testRangeHeadAndRejectedRequestsPreserveExactDurableByteBudget() throws {
        let fixture = try fixture(), created = try ready(fixture), admitted = try session(created.id)
        let track = fixture.manifest.tracks[0], path = "/v1/share/m/\(created.id)/tracks/\(track.id)"
        XCTAssertEqual(send("GET", path).status, 401)
        for range in ["bytes=0-1,4-5", "bytes=999999-", "bytes=5-2", "bytes=-0"] { XCTAssertEqual(send("GET", path, token: admitted.token, range: range).status, 416) }
        XCTAssertEqual(send("HEAD", path, token: admitted.token).status, 200)
        let first = send("GET", path, token: admitted.token, range: "bytes=0-9")
        XCTAssertEqual(first.status, 206); XCTAssertEqual(first.body, fixture.audio[track.id]!.prefix(10))
        XCTAssertEqual(first.headers["Content-Length"], "10")
        service = try reopen()
        let rest = send("GET", path, token: admitted.token, range: "bytes=10-")
        XCTAssertEqual(rest.status, 206); XCTAssertEqual(rest.body, fixture.audio[track.id]!.dropFirst(10))
        let next = fixture.manifest.tracks[1]
        XCTAssertEqual(send("GET", "/v1/share/m/\(created.id)/tracks/\(next.id)", token: admitted.token).status, 200)
        XCTAssertEqual(send("GET", path, token: admitted.token, range: "bytes=0-0").status, 409)
        XCTAssertEqual(send("HEAD", path, token: admitted.token).status, 200)
    }
    func testSharedPendingQuotaReservesBothKindsWithoutDoubleCharge() throws {
        let fixture = try fixture()
        let reserve = fixture.body.audioBytes + Data(base64Encoded: fixture.body.encryptedManifest)!.count
        let single = fixture.audio.values.first!
        let body = CreateShareRequest(expiresInSeconds: 86400, playCap: 1, preview: .init(title: "Single", durationSeconds: 10), encryptedMeta: nil, durationBucket: nil, audioBytes: single.count, audioSHA256: ShareHash.sha256Hex(single), client: .init(platform: "macos", appVersion: "test"))
        service = try reopen(quota: Int64(reserve + single.count - 1))
        let created = try create(fixture)
        XCTAssertEqual(send("POST", "/v1/share/shares", body: try encode(body), token: other).status, 503)
        for (id, bytes) in fixture.audio { XCTAssertEqual(try upload(created, track: id, bytes: bytes).status, 200) }
        XCTAssertEqual(send("DELETE", "/v1/share/mixtapes/\(created.id)", token: owner).status, 204)
        XCTAssertEqual(send("POST", "/v1/share/shares", body: try encode(body), token: other).status, 201)
        service = try reopen(quota: Int64(reserve + single.count - 1))
        XCTAssertEqual(send("POST", "/v1/share/mixtapes", body: try encode(try self.fixture().body), token: owner).status, 503)
    }
    func testCountBoundsAndDefaultOffAreExplicitUnsupported() throws {
        for count in [2,12] { XCTAssertEqual(send("POST", "/v1/share/mixtapes", body: try encode(try fixture(count: count).body), token: owner).status, 201) }
        XCTAssertEqual(send("POST", "/v1/share/mixtapes", body: try encode(try fixture(count: 13).body), token: owner).status, 400)
        service = try reopen(enabled: false)
        XCTAssertEqual(send("POST", "/v1/share/mixtapes", body: Data("{}".utf8), token: owner).status, 409)
        XCTAssertNil(try decode(ShareConfig.self, send("GET", "/v1/share/config")).mixtapes)
    }
    func testRevokeExpiryAndFixedSessionDeadlineFenceEveryRead() throws {
        let fixture = try fixture(), created = try ready(fixture), admitted = try session(created.id)
        let path = "/v1/share/m/\(created.id)/tracks/\(fixture.manifest.tracks[0].id)"
        clock.advance(1800)
        XCTAssertEqual(send("GET", path, token: admitted.token).status, 401)
        let second = try session(created.id)
        XCTAssertEqual(send("DELETE", "/v1/share/mixtapes/\(created.id)", token: other).status, 403, "another installation cannot revoke it")
        XCTAssertEqual(send("DELETE", "/v1/share/mixtapes/\(created.id)", token: owner).status, 204)
        XCTAssertEqual(send("GET", path, token: second.token).status, 410)
        let another = try ready(try self.fixture())
        clock.advance(86400)
        XCTAssertEqual(send("POST", "/v1/share/m/\(another.id)/sessions").status, 410)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("blobs/\(another.id)").path))
    }
    func testReviewRetentionRestoreKeepsOriginalCeilingAndInvalidatesSession() throws {
        let fixture = try fixture(cap: 3, consent: true), created = try ready(fixture), admitted = try session(created.id)
        let start = Int64(clock.now.timeIntervalSince1970)
        func apply(_ request: [String: Any]) throws {
            let body = try JSONSerialization.data(withJSONObject: request)
            let plan = send("POST", "/v1/share/admin/enforcement/plan", body: body, token: operatorToken, peer: .loopback)
            XCTAssertEqual(plan.status, 200)
            XCTAssertEqual(send("POST", "/v1/share/admin/enforcement/apply", body: plan.body, token: operatorToken, peer: .loopback).status, 200)
        }
        try apply(["operationID": UUID().uuidString, "action": "disable-share", "shareID": created.id, "caseReference": "case_1", "reasonCode": "review", "reviewUntil": start + 20 * 86400, "preservationDeadline": start + 22 * 86400])
        XCTAssertEqual(send("GET", "/v1/share/m/\(created.id)").status, 410)
        let held = try decode(MixtapeList.self, send("GET", "/v1/share/mixtapes", token: owner)).mixtapes[0]
        XCTAssertNotNil(held.reviewDeadline); XCTAssertEqual(held.pausedLifetimeSeconds, 86400)
        clock.advance(3 * 86400); try service.sweep(); service = try reopen()
        try apply(["operationID": UUID().uuidString, "action": "restore-share", "shareID": created.id, "caseReference": "case_1", "reasonCode": "review"])
        let restored = try decode(PublicMixtape.self, send("GET", "/v1/share/m/\(created.id)"))
        XCTAssertEqual(restored.remainingPlays, 2)
        XCTAssertEqual(send("GET", "/v1/share/m/\(created.id)/tracks/\(fixture.manifest.tracks[0].id)", token: admitted.token).status, 401)
        XCTAssertEqual(restored.expiresAt, ShareDate.string(Date(timeIntervalSince1970: TimeInterval(start + 4 * 86400))))
        func disablePlan(deadline: Int64) throws -> ShareResponse {
            send("POST", "/v1/share/admin/enforcement/plan", body: try JSONSerialization.data(withJSONObject: ["operationID": UUID().uuidString, "action": "disable-share", "shareID": created.id, "caseReference": "case_1", "reasonCode": "review", "reviewUntil": start + 28 * 86400, "preservationDeadline": deadline]), token: operatorToken, peer: .loopback)
        }
        XCTAssertEqual(try disablePlan(deadline: start + 91 * 86400).status, 409)
        let repeated = try disablePlan(deadline: start + 30 * 86400)
        XCTAssertEqual(repeated.status, 200)
        let plan = try decode(EnforcementPlan.self, repeated)
        XCTAssertEqual(plan.affected[0].preservationStartedAt, start)
        XCTAssertEqual(plan.affected[0].preservationCeiling, start + 90 * 86400)
        XCTAssertEqual(send("POST", "/v1/share/admin/enforcement/apply", body: repeated.body, token: operatorToken, peer: .loopback).status, 200)
        service = try reopen()
        XCTAssertEqual(try decode(MixtapeSummary.self, send("GET", "/v1/share/mixtapes/\(created.id)", token: owner)).reviewDeadline, ShareDate.string(Date(timeIntervalSince1970: TimeInterval(start + 30 * 86400))))
    }
    /// A mixtape that exists but belongs to another installation secret is not one that ended: the
    /// app deletes a ticket's key only on not_found, so a changed secret must not read as gone
    /// 403, so even an older app that ends on any 404 keeps it.
    func testAnotherInstallationsMixtapeIsNotOwnedRatherThanNotFound() throws {
        let created = try ready(try fixture())
        let foreign = send("GET", "/v1/share/mixtapes/\(created.id)", token: other)
        XCTAssertEqual(foreign.status, 403)
        XCTAssertEqual(code(foreign), "not_owner")
        for (method, path) in [("PATCH", "/v1/share/mixtapes/\(created.id)"), ("DELETE", "/v1/share/mixtapes/\(created.id)"),
                               ("POST", "/v1/share/mixtapes/\(created.id)/finalize")] {
            XCTAssertEqual(code(send(method, path, body: Data("{}".utf8), token: other)), "not_owner", "\(method) \(path)")
        }
        XCTAssertEqual(try decode(MixtapeSummary.self, send("GET", "/v1/share/mixtapes/\(created.id)", token: owner)).share.status, .ready,
                       "the owner's mixtape is untouched")
        // Its track uploads too, both before staging is reserved and in the handler.
        let pending = try create(try fixture())
        let (trackID, bytes) = try XCTUnwrap(try fixture().audio.first)
        let head = StreamingUpload.Request(method: "PUT", path: pending.uploads[trackID]!, headers: ["authorization": "Bearer " + other], contentLength: bytes.count)
        XCTAssertEqual(service.refusesUpload(head).flatMap(code), "not_owner")
        XCTAssertEqual(code(try upload(pending, track: trackID, bytes: bytes, token: other)), "not_owner")
        XCTAssertNil(service.refusesUpload(StreamingUpload.Request(method: "PUT", path: pending.uploads[trackID]!,
            headers: ["authorization": "Bearer " + owner], contentLength: bytes.count)), "the owner streams as before")
        let missing = send("GET", "/v1/share/mixtapes/\(Base64URL.encode(Data(repeating: 8, count: 16)))", token: owner)
        XCTAssertEqual(missing.status, 404)
        XCTAssertEqual(code(missing), "not_found", "an id with no mixtape is still not_found")
    }
    /// The sender revoking a held mixtape keeps the operator's case reference.
    func testOwnerRevokeOfAHeldMixtapeKeepsTheOperatorsCaseReference() throws {
        let created = try ready(try fixture(consent: true))
        let start = Int64(clock.now.timeIntervalSince1970)
        let body = try JSONSerialization.data(withJSONObject: ["operationID": UUID().uuidString, "action": "disable-share", "shareID": created.id,
            "caseReference": "case_held", "reasonCode": "review", "reviewUntil": start + 20 * 86400, "preservationDeadline": start + 22 * 86400])
        let plan = send("POST", "/v1/share/admin/enforcement/plan", body: body, token: operatorToken, peer: .loopback)
        XCTAssertEqual(send("POST", "/v1/share/admin/enforcement/apply", body: plan.body, token: operatorToken, peer: .loopback).status, 200)
        XCTAssertEqual(send("DELETE", "/v1/share/mixtapes/\(created.id)", token: owner).status, 204)
        XCTAssertEqual(try service.store.enforcementState(id: created.id)?.caseReference, "case_held")
        XCTAssertEqual(try service.store.enforcementState(id: created.id)?.purged, true)
    }
    func testDuplicateEscapedIDsAndMalformedDescriptorsAreRejectedBeforeReservation() throws {
        let fixture = try fixture(), body = try encode(fixture.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let key = fixture.manifest.tracks[0].id
        let descriptor = try encode(fixture.body.tracks[key]!)
        let duplicate = "{\"" + key + "\":" + String(decoding: descriptor, as: UTF8.self) + ",\"" + key + "\":" + String(decoding: descriptor, as: UTF8.self) + "}"
        var without = object; without.removeValue(forKey: "tracks")
        let prefix = String(decoding: try JSONSerialization.data(withJSONObject: without), as: UTF8.self).dropLast()
        XCTAssertEqual(send("POST", "/v1/share/mixtapes", body: Data((prefix + ",\"tracks\":" + duplicate + "}").utf8), token: owner).status, 400)
        var invalid = fixture.body; invalid.tracks[key]!.audioSHA256 = String(repeating: "A", count: 64)
        XCTAssertEqual(send("POST", "/v1/share/mixtapes", body: try encode(invalid), token: owner).status, 400)
        invalid = fixture.body; invalid.tracks[key]!.audioBytes = Int.max
        XCTAssertEqual(send("POST", "/v1/share/mixtapes", body: try encode(invalid), token: owner).status, 400)
        XCTAssertEqual(try decode(MixtapeList.self, send("GET", "/v1/share/mixtapes", token: owner)).mixtapes.count, 0)
    }
    func testConcurrentAdmissionsAcrossRestartedConnectionsConsumeOnlyOneCap() throws {
        let fixture = try fixture(cap: 1), created = try ready(fixture)
        let second = try reopen(), first = service!
        let request = HTTPRequestMessage(method: "POST", path: "/v1/share/m/\(created.id)/sessions", query: [:], headers: [:], body: Data())
        final class Results: @unchecked Sendable {
            let lock = NSLock(); var statuses: [Int] = []
            func append(_ status: Int) { lock.lock(); statuses.append(status); lock.unlock() }
        }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 2) { index in results.append((index == 0 ? first : second).handle(request).status) }
        XCTAssertEqual(results.statuses.sorted(), [201, 410])
        service = try reopen()
        XCTAssertEqual(try decode(MixtapeList.self, send("GET", "/v1/share/mixtapes", token: owner)).mixtapes[0].share.stats.fetches, 1)
    }
    func testFailedFilesystemCleanupRetainsQuotaUntilDurableRetry() throws {
        let fixture = try fixture(), created = try ready(fixture)
        let quota = Int64(fixture.body.audioBytes + Data(base64Encoded: fixture.body.encryptedManifest)!.count)
        service = try reopen(quota: quota)
        let blobs = root.appendingPathComponent("blobs")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blobs.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blobs.path) }
        XCTAssertEqual(send("DELETE", "/v1/share/mixtapes/\(created.id)", token: owner).status, 204)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobs.appendingPathComponent(created.id).path))
        service = try reopen(quota: quota)
        XCTAssertEqual(send("POST", "/v1/share/mixtapes", body: try encode(try self.fixture().body), token: owner).status, 503)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blobs.path)
        try service.sweep()
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobs.appendingPathComponent(created.id).path))
        XCTAssertEqual(send("POST", "/v1/share/mixtapes", body: try encode(try self.fixture().body), token: owner).status, 201)
    }

    func testCompetingSingleAndMixtapeCreatesShareOneAtomicQuota() throws {
        let fixture = try fixture(), single = fixture.audio.values.first!
        let reserve = fixture.body.audioBytes + Data(base64Encoded: fixture.body.encryptedManifest)!.count
        let quota = Int64(max(reserve, single.count))
        service = try reopen(quota: quota)
        let second = try reopen(quota: quota), first = service!
        let singleBody = CreateShareRequest(expiresInSeconds: 86400, playCap: 1, preview: .init(title: "Single", durationSeconds: 10), encryptedMeta: nil, durationBucket: nil, audioBytes: single.count, audioSHA256: ShareHash.sha256Hex(single), client: .init(platform: "macos", appVersion: "test"))
        let requests = [HTTPRequestMessage(method: "POST", path: "/v1/share/mixtapes", query: [:], headers: ["authorization": "Bearer " + owner], body: try encode(fixture.body)), HTTPRequestMessage(method: "POST", path: "/v1/share/shares", query: [:], headers: ["authorization": "Bearer " + other], body: try encode(singleBody))]
        let results = ConcurrentResults()
        DispatchQueue.concurrentPerform(iterations: 2) { index in results.append((index == 0 ? first : second).handle(requests[index]).status) }
        XCTAssertEqual(results.statuses.sorted(), [201,503])
        service = try reopen(quota: quota)
        let singles = try decode(ShareList.self, send("GET", "/v1/share/shares", token: other)).shares.count
        let multi = try decode(MixtapeList.self, send("GET", "/v1/share/mixtapes", token: owner)).mixtapes.count
        XCTAssertEqual(singles + multi, 1)
    }
    func testConcurrentTrackReadsCannotOverspendPersistedSessionBudget() throws {
        let fixture = try fixture(), created = try ready(fixture), admitted = try session(created.id)
        let consumed = fixture.manifest.tracks[1]
        XCTAssertEqual(send("GET", "/v1/share/m/\(created.id)/tracks/\(consumed.id)", token: admitted.token).status, 200)
        let first = service!, second = try reopen(), track = fixture.manifest.tracks[0]
        let request = HTTPRequestMessage(method: "GET", path: "/v1/share/m/\(created.id)/tracks/\(track.id)", query: [:], headers: ["authorization": "Bearer " + admitted.token], body: Data())
        let results = ConcurrentResults()
        DispatchQueue.concurrentPerform(iterations: 2) { index in results.append((index == 0 ? first : second).handle(request).status) }
        XCTAssertEqual(results.statuses.sorted(), [200,409])
        service = try reopen()
        XCTAssertEqual(send("GET", request.path, token: admitted.token, range: "bytes=0-0").status, 409)
        XCTAssertEqual(try decode(MixtapeSummary.self, send("GET", "/v1/share/mixtapes/\(created.id)", token: owner)).share.stats.fetches, 1)
    }
    func testCapReductionFencesOnlyDisallowedSessionOrdinals() throws {
        let fixture = try fixture(cap: 3), created = try ready(fixture)
        let first = try session(created.id), second = try session(created.id)
        XCTAssertEqual(send("PATCH", "/v1/share/mixtapes/\(created.id)", body: try encode(PatchShareRequest(playCap: 1)), token: owner).status, 200)
        service = try reopen()
        let path = "/v1/share/m/\(created.id)/tracks/\(fixture.manifest.tracks[0].id)"
        XCTAssertEqual(send("GET", path, token: first.token).status, 200)
        XCTAssertEqual(send("GET", path, token: second.token).status, 401)
        XCTAssertEqual(send("POST", "/v1/share/m/\(created.id)/sessions").status, 410)
        XCTAssertEqual(try decode(MixtapeSummary.self, send("GET", "/v1/share/mixtapes/\(created.id)", token: owner)).share.stats.fetches, 2)
    }
    func testExtensionDoesNotLengthenAlreadyIssuedSessionDeadline() throws {
        let fixture = try fixture(), created = try ready(fixture)
        clock.advance(86400 - 10)
        let admitted = try session(created.id)
        XCTAssertEqual(send("PATCH", "/v1/share/mixtapes/\(created.id)", body: try encode(PatchShareRequest(extendBySeconds: 86400)), token: owner).status, 200)
        clock.advance(10); service = try reopen()
        let path = "/v1/share/m/\(created.id)/tracks/\(fixture.manifest.tracks[0].id)"
        XCTAssertEqual(send("GET", path, token: admitted.token).status, 401)
        XCTAssertEqual(send("GET", "/v1/share/m/\(created.id)").status, 200)
        XCTAssertEqual(send("GET", path, token: try session(created.id).token).status, 200)
    }
    func testSuspensionRestorationAndOffSwitchPreserveOwnerRevocation() throws {
        let fixture = try fixture(cap: 3, consent: true), created = try ready(fixture), admitted = try session(created.id)
        let start = Int64(clock.now.timeIntervalSince1970)
        func apply(_ action: String, dates: Bool = false) throws {
            var request: [String: Any] = ["operationID": UUID().uuidString, "action": action, "shareID": created.id, "caseReference": "suspension_case", "reasonCode": "review"]
            if dates { request["reviewUntil"] = start + 20 * 86400; request["preservationDeadline"] = start + 22 * 86400 }
            let plan = send("POST", "/v1/share/admin/enforcement/plan", body: try JSONSerialization.data(withJSONObject: request), token: operatorToken, peer: .loopback)
            XCTAssertEqual(plan.status, 200)
            XCTAssertEqual(send("POST", "/v1/share/admin/enforcement/apply", body: plan.body, token: operatorToken, peer: .loopback).status, 200)
        }
        try apply("suspend-sharer", dates: true); service = try reopen()
        let path = "/v1/share/m/\(created.id)/tracks/\(fixture.manifest.tracks[0].id)"
        XCTAssertEqual(send("HEAD", path, token: admitted.token).status, 410)
        XCTAssertEqual(send("POST", "/v1/share/mixtapes", body: try encode(try self.fixture().body), token: owner).status, 403)
        XCTAssertEqual(send("POST", "/v1/share/mixtapes/\(created.id)/finalize", token: owner).status, 403)
        try apply("unsuspend-sharer")
        XCTAssertEqual(send("GET", path, token: admitted.token).status, 410)
        try apply("restore-share")
        XCTAssertEqual(send("GET", path, token: admitted.token).status, 401)
        XCTAssertEqual(send("GET", path, token: try session(created.id).token).status, 200)
        try apply("disable-share", dates: true)
        service = try reopen(enabled: false)
        let held = try decode(MixtapeSummary.self, send("GET", "/v1/share/mixtapes/\(created.id)", token: owner))
        XCTAssertNotNil(held.reviewDeadline)
        XCTAssertEqual(send("DELETE", "/v1/share/mixtapes/\(created.id)", token: owner).status, 204)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("blobs/\(created.id)").path))
    }

    func testSerializedHeadAndRangeHaveOneCorrectLengthAndNoHeadPayload() throws {
        let fixture = try fixture(), created = try ready(fixture), admitted = try session(created.id)
        let id = fixture.manifest.tracks[0].id, path = "/v1/share/m/\(created.id)/tracks/\(id)"
        let head = send("HEAD", path, token: admitted.token, range: "bytes=0-9").data
        let delimiter = try XCTUnwrap(head.range(of: Data("\r\n\r\n".utf8)))
        let header = String(decoding: head[..<delimiter.lowerBound], as: UTF8.self)
        XCTAssertEqual(header.components(separatedBy: "Content-Length:").count - 1, 1)
        XCTAssertTrue(header.contains("Content-Length: 10\r\n"))
        XCTAssertTrue(head[delimiter.upperBound...].isEmpty)
        let get = send("GET", path, token: admitted.token, range: "bytes=0-9").data
        let split = try XCTUnwrap(get.range(of: Data("\r\n\r\n".utf8)))
        XCTAssertEqual(get[split.upperBound...], fixture.audio[id]!.prefix(10))
        XCTAssertEqual(String(decoding: get[..<split.lowerBound], as: UTF8.self).components(separatedBy: "Content-Length:").count - 1, 1)
    }

}
