@testable import BatonGatewayCore
import BatonMCPProtocol
import BatonShareKit
@testable import BatonShareServer
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

final class ShareEnforcementTests: XCTestCase {
    var root: URL!
    var clock: TestClock!
    var service: ShareService!
    let owner = Base64URL.encode(Data(repeating: 31, count: 32))
    let differentOwner = Base64URL.encode(Data(repeating: 32, count: 32))
    let operatorToken = String(repeating: "O", count: 48)
    let statsToken = String(repeating: "S", count: 48)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("share-enforcement-" + UUID().uuidString)
        clock = TestClock()
        service = try reopen()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func capability() throws -> EnforcementConfiguration {
        try EnforcementConfiguration(token: operatorToken, retentionSeconds: 3600,
                                     auditRetentionSeconds: 7200, reasonCodes: ["review", "correction"])
    }
    func reopen(enabled: Bool = true, delivery: ShareConfiguration.BlobDelivery = .direct) throws -> ShareService {
        var configuration = ShareConfiguration(dataDirectory: root, publicBase: URL(string: "https://batonmusic.app")!,
                                               adminToken: statsToken, blobDelivery: delivery)
        if enabled { configuration.enforcement = try capability() }
        let testClock = clock!
        return try ShareService(config: configuration, clock: { testClock.now })
    }
    func send(_ method: String, _ path: String, body: Data = Data(), secret: String? = nil,
              peer: ConnectionPeer = .unknown, headers: [String: String] = [:]) -> ShareResponse {
        var headers = headers
        if let secret { headers["authorization"] = "Bearer " + secret }
        return service.handle(HTTPRequestMessage(method: method, path: path, query: [:], headers: headers, body: body), peer: peer)
    }
    func encoded<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    func decoded<T: Decodable>(_ type: T.Type, _ response: ShareResponse) throws -> T {
        try JSONDecoder().decode(type, from: response.body)
    }
    func operatorCall(_ route: String, body: Data = Data(), token: String? = nil,
                      peer: ConnectionPeer = .loopback, headers: [String: String] = [:]) -> ShareResponse {
        send(route.hasPrefix("operations/") ? "GET" : "POST", "/v1/share/admin/enforcement/" + route,
             body: body, secret: token ?? operatorToken, peer: peer, headers: headers)
    }
    func operation(_ action: EnforcementAction, id: String, uuid: String = UUID().uuidString.lowercased()) -> EnforcementRequest {
        EnforcementRequest(operationID: uuid, action: action, shareID: id, caseReference: "case_123", reasonCode: "review")
    }
    func plan(_ action: EnforcementAction, id: String) throws -> EnforcementPlan {
        let response = operatorCall("plan", body: try encoded(operation(action, id: id)))
        XCTAssertEqual(response.status, 200)
        return try decoded(EnforcementPlan.self, response)
    }
    @discardableResult
    func apply(_ action: EnforcementAction, id: String) throws -> EnforcementReceipt {
        let response = operatorCall("apply", body: try encoded(plan(action, id: id)))
        XCTAssertEqual(response.status, 200)
        return try decoded(EnforcementReceipt.self, response)
    }
    func makeShare(ready: Bool = true, secret: String? = nil, cap: Int = 5, expires: Int = 86400,
                   art: Bool = false, uploadPending: Bool = false, reviewConsent: Bool = false) throws -> String {
        let secret = secret ?? owner
        let ciphertext = try ShareCrypto.seal(Data(repeating: 77, count: 4096), key: ShareCrypto.newKey(), purpose: .audio)
        let body = CreateShareRequest(expiresInSeconds: expires, playCap: cap,
            preview: ShareMetadata(title: "Synthetic operator song", durationSeconds: 40, note: "Synthetic confidential preview"),
            encryptedMeta: nil, durationBucket: nil, audioBytes: ciphertext.count,
            audioSHA256: ShareHash.sha256Hex(ciphertext), client: ShareClientInfo(platform: "macos", appVersion: "probe"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(body)) as? [String: Any])
        if reviewConsent { object["reviewPreservationConsent"] = "review-v1" }
        let created = send("POST", "/v1/share/shares", body: try JSONSerialization.data(withJSONObject: object), secret: secret)
        XCTAssertEqual(created.status, 201)
        let id = try decoded(CreateShareResponse.self, created).id
        if ready || uploadPending {
            XCTAssertEqual(try upload(id, kind: "audio", bytes: ciphertext, secret: secret).status, 200)
            if art {
                let image = Data([0xff, 0xd8, 0xff]) + Data(repeating: 10, count: 40)
                XCTAssertEqual(try upload(id, kind: "art", bytes: image, secret: secret).status, 200)
                XCTAssertEqual(try upload(id, kind: "card", bytes: image, secret: secret).status, 200)
            }
            if ready { XCTAssertEqual(send("POST", "/v1/share/shares/" + id + "/finalize", secret: secret).status, 200) }
        }
        return id
    }
    func upload(_ id: String, kind: String, bytes: Data, secret: String? = nil) throws -> ShareResponse {
        let staged = root.appendingPathComponent("test-staged-" + UUID().uuidString)
        try bytes.write(to: staged)
        return service.handleUpload(StreamingUpload.Request(method: "PUT", path: "/v1/share/shares/" + id + "/" + kind,
            headers: ["authorization": "Bearer " + (secret ?? owner)], contentLength: bytes.count), file: staged)
    }

    func testContactRelayBindsGrantAndReleasesStoreBeforePrivateReadback() async throws {
        _ = try makeShare()
        let reader = String(repeating: "R", count: 48)
        var configuration = service.config
        configuration.contactBridge = try ShareContactConfiguration(readerDigest: ShareHash.secretDigest(reader), relayPort: 8791)
        let testClock = clock!
        let current = try ShareService(config: configuration, clock: { testClock.now })
        service = current
        let granted = send("POST", "/v1/share/contact/authorization",
            body: try JSONSerialization.data(withJSONObject: ["purpose": "enroll", "include": []]), secret: owner)
        let grant = try XCTUnwrap((try JSONSerialization.jsonObject(with: granted.body) as? [String: String])?["authorization"])
        let privateBody = try JSONSerialization.data(withJSONObject: ["authorization": grant, "address": "PUBLIC@fixture.invalid",
            "consent": "contact-v1", "include": []])
        let request = HTTPRequestMessage(method: "POST", path: "/v1/share/contact/private/enroll", query: [:],
            headers: ["authorization": "Bearer " + owner, "content-type": "application/json"], body: privateBody)
        let response = await current.handleContactRelay(request) { port, path, body in
            XCTAssertEqual(port, 8791); XCTAssertEqual(path, "/enroll"); XCTAssertEqual(body, privateBody)
            // Actual readback re-enters the service; this cannot run if relay holds its store lock.
            let consume = current.handle(HTTPRequestMessage(method: "POST", path: "/v1/share/admin/contact/installation", query: [:],
                headers: ["authorization": "Bearer " + reader],
                body: try JSONSerialization.data(withJSONObject: ["authorization": grant, "purpose": "enroll"])), peer: .loopback)
            XCTAssertEqual(consume.status, 200)
            return ShareResponse.json(["status": "pending"], headers: ["Set-Cookie": "PUBLIC FIXTURE"])
        }
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers, ["Cache-Control": "private, no-store"])
        let replay = await current.handleContactRelay(request) { _, _, _ in XCTFail("Replayed grant was forwarded"); return .noContent }
        XCTAssertEqual(replay.status, 404)
        XCTAssertFalse(send("GET", "/v1/share/shares", secret: owner).body.contains(Data("PUBLIC@fixture.invalid".utf8)))
    }

    func testContactRelayRejectsForeignPurposeOperatorAndOversizedRequests() async throws {
        _ = try makeShare()
        var configuration = service.config
        configuration.contactBridge = try ShareContactConfiguration(readerDigest: ShareHash.secretDigest(String(repeating: "R", count: 48)), relayPort: 8791)
        let testClock = clock!
        service = try ShareService(config: configuration, clock: { testClock.now })
        let granted = send("POST", "/v1/share/contact/authorization",
            body: try JSONSerialization.data(withJSONObject: ["purpose": "status", "include": []]), secret: owner)
        let grant = try XCTUnwrap((try JSONSerialization.jsonObject(with: granted.body) as? [String: String])?["authorization"])
        let body = try JSONSerialization.data(withJSONObject: ["authorization": grant])
        for (endpoint, bearer, raw) in [("status", differentOwner, body), ("withdraw", owner, body),
                                        ("operator/job", owner, body), ("status", owner, Data(repeating: 65, count: 65537))] {
            let response = await service.handleContactRelay(HTTPRequestMessage(method: "POST", path: "/v1/share/contact/private/" + endpoint, query: [:],
                headers: ["authorization": "Bearer " + bearer, "content-type": "application/json"], body: raw)) { _, _, _ in
                XCTFail("Unqualified request was forwarded"); return .noContent
            }
            XCTAssertEqual(response.status, 404)
        }
    }

    /// Installation secrets are self-minted, so a limit per secret does not bound one client: a
    /// fresh secret per request could fill the 10,000-row grant table and turn every installation
    /// away for the grants' minute. One network gets 100 grants an hour (TBX-1000000496 D-16).
    func testContactGrantsAreLimitedPerNetworkNotOnlyPerSelfMintedSecret() throws {
        var configuration = service.config
        configuration.contactBridge = try ShareContactConfiguration(readerDigest: ShareHash.secretDigest(String(repeating: "R", count: 48)))
        let testClock = clock!
        service = try ShareService(config: configuration, clock: { testClock.now })
        let body = try JSONSerialization.data(withJSONObject: ["purpose": "status", "include": []])
        let network = ["cf-connecting-ip": "198.51.100.9"]
        var statuses: [Int] = []
        for index in 0 ..< 101 {
            let fresh = Base64URL.encode(Data(repeating: UInt8(index), count: 32))
            // Half from one IPv4 address, half from addresses across one IPv6 /64: each is one network.
            let from = index < 50 ? network : ["cf-connecting-ip": "2001:db8:5:6::\(index)"]
            statuses.append(send("POST", "/v1/share/contact/authorization", body: body, secret: fresh, headers: from).status)
        }
        XCTAssertEqual(statuses.prefix(50).filter { $0 == 200 }.count, 50, "a busy household is not refused")
        XCTAssertEqual(statuses.suffix(51).filter { $0 == 200 }.count, 51, "the /64 is its own network with its own 100")
        for index in 0 ..< 50 {
            let fresh = Base64URL.encode(Data(repeating: UInt8(200), count: 31) + Data([UInt8(index)]))
            XCTAssertEqual(send("POST", "/v1/share/contact/authorization", body: body, secret: fresh, headers: network).status, 200)
        }
        XCTAssertEqual(send("POST", "/v1/share/contact/authorization", body: body, secret: Base64URL.encode(Data(repeating: 201, count: 32)),
                            headers: network).status, 429, "the 101st fresh secret from one network in an hour is refused")
        XCTAssertEqual(send("POST", "/v1/share/contact/authorization", body: body, secret: Base64URL.encode(Data(repeating: 202, count: 32)),
                            headers: ["cf-connecting-ip": "2001:db8:5:6:ffff::1"]).status, 200, "the /64 has 49 left")
        for index in 0 ..< 48 {
            let fresh = Base64URL.encode(Data(repeating: UInt8(210), count: 31) + Data([UInt8(index)]))
            XCTAssertEqual(send("POST", "/v1/share/contact/authorization", body: body, secret: fresh,
                                headers: ["cf-connecting-ip": "2001:db8:5:6:eeee::\(index)"]).status, 200)
        }
        XCTAssertEqual(send("POST", "/v1/share/contact/authorization", body: body, secret: Base64URL.encode(Data(repeating: 220, count: 32)),
                            headers: ["cf-connecting-ip": "2001:db8:5:6:dddd::1"]).status, 429,
                       "a fresh address in the same /64 does not get a fresh allowance")
        XCTAssertEqual(send("POST", "/v1/share/contact/authorization", body: body, secret: owner,
                            headers: ["cf-connecting-ip": "203.0.113.50"]).status, 200, "another network is unaffected")
        testClock.advance(3600)
        XCTAssertEqual(send("POST", "/v1/share/contact/authorization", body: body, secret: owner, headers: network).status, 200, "and the hour passes")
    }

    func testContactAuthorizationUsesActualInstallationOwnership() throws {
        let id = try makeShare()
        let body = try JSONSerialization.data(withJSONObject: ["purpose": "enroll", "include": [id]])
        XCTAssertEqual(send("POST", "/v1/share/contact/authorization", body: body, secret: owner).status, 404)
        var configuration = service.config
        configuration.contactBridge = try ShareContactConfiguration(readerDigest: ShareHash.secretDigest(String(repeating: "R", count: 48)))
        let testClock = clock!
        service = try ShareService(config: configuration, clock: { testClock.now })
        let response = send("POST", "/v1/share/contact/authorization", body: body, secret: owner)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(send("POST", "/v1/share/contact/authorization", body: body, secret: differentOwner).status, 404)
        XCTAssertEqual(send("POST", "/v1/share/contact/authorization", body: body, secret: id + "#public-fragment").status, 401)
        XCTAssertEqual(send("POST", "/v1/share/contact/authorization", body: body).status, 401)
        configuration.contactBridge = try ShareContactConfiguration(readerDigest: ShareHash.secretDigest(operatorToken))
        XCTAssertThrowsError(try ShareService(config: configuration, clock: { testClock.now }))
    }

    func testContactReadbackConsumesScopeAndRejectsStaleAction() throws {
        let id = try makeShare()
        let reader = String(repeating: "R", count: 48)
        var configuration = service.config
        configuration.contactBridge = try ShareContactConfiguration(readerDigest: ShareHash.secretDigest(reader))
        let testClock = clock!
        service = try ShareService(config: configuration, clock: { testClock.now })
        let authorization = send("POST", "/v1/share/contact/authorization",
            body: try JSONSerialization.data(withJSONObject: ["purpose": "enroll", "include": [id]]), secret: owner)
        let ticket = try XCTUnwrap((try JSONSerialization.jsonObject(with: authorization.body) as? [String: String])?["authorization"])
        XCTAssertEqual(ticket.count, 43)
        XCTAssertFalse(String(decoding: authorization.body, as: UTF8.self).contains(ShareHash.secretDigest(owner)))
        let body = try JSONSerialization.data(withJSONObject: ["authorization": ticket, "purpose": "enroll"])
        let path = "/v1/share/admin/contact/installation"
        XCTAssertEqual(send("POST", path, body: body, secret: reader).status, 404)
        XCTAssertEqual(send("POST", path, body: body, secret: operatorToken, peer: .loopback).status, 404)
        XCTAssertEqual(send("POST", path, body: body, secret: reader, peer: .loopback,
                            headers: ["x-forwarded-for": "127.0.0.1"]).status, 404)
        let wrong = try JSONSerialization.data(withJSONObject: ["authorization": ticket, "purpose": "verify"])
        XCTAssertEqual(send("POST", path, body: wrong, secret: reader, peer: .loopback).status, 404)
        let consumed = send("POST", path, body: body, secret: reader, peer: .loopback)
        XCTAssertEqual(consumed.status, 200)
        XCTAssertEqual(send("POST", path, body: body, secret: reader, peer: .loopback).status, 404)
        service = try ShareService(config: configuration, clock: { testClock.now })
        XCTAssertEqual(send("POST", path, body: body, secret: reader, peer: .loopback).status, 404)
        let expiring = send("POST", "/v1/share/contact/authorization",
            body: try JSONSerialization.data(withJSONObject: ["purpose": "status", "include": [String]()]), secret: owner)
        let expiredTicket = try XCTUnwrap((try JSONSerialization.jsonObject(with: expiring.body) as? [String: String])?["authorization"])
        clock.advance(61)
        let expiredBody = try JSONSerialization.data(withJSONObject: ["authorization": expiredTicket, "purpose": "status"])
        XCTAssertEqual(send("POST", path, body: expiredBody, secret: reader, peer: .loopback).status, 404)
        let receipt = try apply(.disableShare, id: id)
        let actionBody = try JSONSerialization.data(withJSONObject: ["operation": receipt.operationID, "share": id])
        let actionPath = "/v1/share/admin/contact/action"
        let actual = send("POST", actionPath, body: actionBody, secret: reader, peer: .loopback)
        XCTAssertEqual(actual.status, 200)
        let scope = try XCTUnwrap(JSONSerialization.jsonObject(with: actual.body) as? [String: Any])
        XCTAssertEqual(scope["installation"] as? String, ShareHash.secretDigest(owner))
        XCTAssertEqual(scope["case"] as? String, "case_123")
        XCTAssertEqual(scope["action"] as? String, "disable-share")
        _ = try apply(.restoreShare, id: id)
        XCTAssertEqual(send("POST", actionPath, body: actionBody, secret: reader, peer: .loopback).status, 404)
    }

    func testUnsuspendAfterEveryAnchorAndAuditReceiptAreSwept() throws {
        let anchor = try makeShare()
        let revoked = try makeShare()
        let suspended = try plan(.suspendSharer, id: anchor)
        XCTAssertEqual(operatorCall("apply", body: try encoded(suspended)).status, 200)
        XCTAssertEqual(send("DELETE", "/v1/share/shares/" + revoked, secret: owner).status, 204)
        clock.advance(3601)
        _ = try service.sweep()
        clock.advance(401 * 86400)
        _ = try service.sweep()
        service = try reopen()
        XCTAssertEqual(send("GET", "/v1/share/p/" + anchor).status, 404)
        XCTAssertEqual(operatorCall("operations/" + suspended.request.operationID).status, 404)
        XCTAssertEqual(send("POST", "/v1/share/shares", body: Data("{}".utf8), secret: owner).status, 403)
        XCTAssertEqual(operatorCall("plan", body: try encoded(operation(.unsuspendSharer, id: anchor))).status, 404)
        let inventory = send("GET", "/v1/share/admin/enforcement/suspensions", secret: operatorToken, peer: .loopback)
        XCTAssertEqual(inventory.status, 200, "active suspension must remain independently reversible")
        guard inventory.status == 200 else { return }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: inventory.body) as? [String: Any])
        let entries = try XCTUnwrap(object["suspensions"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        let reference = try XCTUnwrap(entries.first?["reference"] as? String)
        let request: [String: String] = ["operationID": UUID().uuidString.lowercased(), "action": "unsuspend-sharer",
            "suspensionReference": reference, "caseReference": "case_appeal", "reasonCode": "correction"]
        let response = operatorCall("plan", body: try JSONSerialization.data(withJSONObject: request))
        XCTAssertEqual(response.status, 200)
        let reviewed = try decoded(EnforcementPlan.self, response)
        XCTAssertEqual(reviewed.affected.count, 0)
        let applied = operatorCall("apply", body: try encoded(reviewed))
        XCTAssertEqual(applied.status, 200)
        XCTAssertEqual(try decoded(EnforcementReceipt.self, applied).affectedCount, 0)
        service = try reopen()
        XCTAssertEqual(operatorCall("apply", body: try encoded(reviewed)).body, applied.body)
        XCTAssertEqual(try decoded(EnforcementRecovery.self,
            operatorCall("operations/" + reviewed.request.operationID)).receipt,
            try decoded(EnforcementReceipt.self, applied))
        _ = try makeShare()
        XCTAssertEqual(send("GET", "/v1/share/p/" + anchor).status, 404)
        XCTAssertEqual(send("GET", "/v1/share/p/" + revoked).status, 404)
    }

    func referencePlan(_ reference: String) throws -> EnforcementPlan {
        let request: [String: String] = ["operationID": UUID().uuidString.lowercased(), "action": "unsuspend-sharer",
            "suspensionReference": reference, "caseReference": "case_appeal", "reasonCode": "correction"]
        let response = operatorCall("plan", body: try JSONSerialization.data(withJSONObject: request))
        XCTAssertEqual(response.status, 200)
        return try decoded(EnforcementPlan.self, response)
    }

    func testReferenceReversalPreservesHoldsRejectsWrongScopeAndRotatesAfterResuspension() throws {
        let held = try makeShare()
        let revoked = try makeShare()
        let receipt = try apply(.suspendSharer, id: held)
        let reference = try XCTUnwrap(receipt.suspensionReference)
        XCTAssertTrue(ShareLink.isValidID(reference))
        XCTAssertEqual(send("DELETE", "/v1/share/shares/" + revoked, secret: owner).status, 204)
        let different = try makeShare(secret: differentOwner)
        let reviewed = try referencePlan(reference)
        XCTAssertEqual(reviewed.affected.count, 0)
        var tampered = reviewed
        tampered = EnforcementPlan(request: reviewed.request, plannedAt: reviewed.plannedAt,
            validUntil: reviewed.validUntil, targetFingerprint: reviewed.targetFingerprint,
            sharerRevision: reviewed.sharerRevision, affected: try plan(.disableShare, id: different).affected,
            signature: reviewed.signature)
        XCTAssertEqual(operatorCall("apply", body: try encoded(tampered)).status, 409)
        var wrongAction = reviewed.request; wrongAction.action = .restoreShare
        XCTAssertEqual(operatorCall("plan", body: try encoded(wrongAction)).status, 400)
        var both = reviewed.request; both.shareID = different
        XCTAssertEqual(operatorCall("plan", body: try encoded(both)).status, 400)
        let applied = operatorCall("apply", body: try encoded(reviewed))
        XCTAssertEqual(applied.status, 200)
        service = try reopen()
        XCTAssertEqual(send("GET", "/v1/share/p/" + held).status, 410)
        XCTAssertEqual(send("GET", "/v1/share/p/" + revoked).status, 410)
        XCTAssertEqual(send("GET", "/v1/share/p/" + different).status, 200)
        let fresh = try makeShare()
        let newReference = try XCTUnwrap(try apply(.suspendSharer, id: fresh).suspensionReference)
        XCTAssertNotEqual(newReference, reference)
        var old = reviewed.request; old.operationID = UUID().uuidString.lowercased()
        XCTAssertEqual(operatorCall("plan", body: try encoded(old)).status, 404)
        XCTAssertEqual(operatorCall("apply", body: try encoded(reviewed)).body, applied.body,
                       "receipt replay must not reverse the new suspension")
        XCTAssertEqual(send("POST", "/v1/share/shares", body: Data("{}".utf8), secret: owner).status, 403)
        let stale = try referencePlan(newReference)
        try apply(.unsuspendSharer, id: fresh)
        _ = try makeShare()
        try apply(.suspendSharer, id: fresh)
        XCTAssertEqual(operatorCall("apply", body: try encoded(stale)).status, 409)
    }

    func testSuspensionInventoryIsPrivatePaginatedAndReferenceOnly() throws {
        var config = ShareConfiguration(dataDirectory: root, publicBase: URL(string: "https://batonmusic.app")!, adminToken: statsToken)
        config.enforcement = try EnforcementConfiguration(token: operatorToken, retentionSeconds: 3600,
            auditRetentionSeconds: 7200, reasonCodes: ["review", "correction"], maximumAffectedShares: 1)
        let currentClock = clock!
        service = try ShareService(config: config, clock: { currentClock.now })
        let first = try makeShare()
        let second = try makeShare(secret: differentOwner)
        let ref1 = try XCTUnwrap(try apply(.suspendSharer, id: first).suspensionReference)
        let ref2 = try XCTUnwrap(try apply(.suspendSharer, id: second).suspensionReference)
        let route = "/v1/share/admin/enforcement/suspensions"
        for peer in [ConnectionPeer.unknown, .other] {
            XCTAssertEqual(send("GET", route, secret: operatorToken, peer: peer).status, 404)
        }
        XCTAssertEqual(send("GET", route, secret: statsToken, peer: .loopback).status, 404)
        XCTAssertEqual(send("GET", route, secret: operatorToken, peer: .loopback, headers: ["forwarded": "for=127.0.0.1"]).status, 404)
        XCTAssertEqual(service.handle(HTTPRequestMessage(method: "GET", path: route, query: ["cursor": ref1],
            headers: ["authorization": "Bearer " + operatorToken], body: Data()), peer: .loopback).status, 404)
        for suffix in ["/bad", "/" + ref1 + "/extra", "/" + String(repeating: "A", count: 21) + "B", "/"] {
            XCTAssertEqual(send("GET", route + suffix, secret: operatorToken, peer: .loopback).status, 400)
        }
        let response = send("GET", route, secret: operatorToken, peer: .loopback)
        let page = try decoded(EnforcementSuspensions.self, response)
        XCTAssertEqual(page.suspensions.count, 1)
        let cursor = try XCTUnwrap(page.nextCursor)
        let final = try decoded(EnforcementSuspensions.self,
            send("GET", route + "/" + cursor, secret: operatorToken, peer: .loopback))
        XCTAssertEqual(final.suspensions.count, 1)
        XCTAssertNil(final.nextCursor)
        XCTAssertEqual(Set(page.suspensions.map(\.reference) + final.suspensions.map(\.reference)), Set([ref1, ref2]))
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let entry = try XCTUnwrap((objects["suspensions"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(entry.keys), Set(["reference", "revision"]))
        let text = String(decoding: response.body, as: UTF8.self)
        for forbidden in [owner, ShareHash.secretDigest(owner), first, second, "case_123", "Synthetic"] {
            XCTAssertFalse(text.contains(forbidden))
        }
        service = try reopen(enabled: false)
        XCTAssertEqual(send("GET", route, secret: operatorToken, peer: .loopback).status, 404)
    }

    func testMultipleLegacyOrphansGetDurableReferencesWithoutAssumingCaseCorrelation() throws {
        // Old release schema is the migration input, not an assertion side channel.
        // There are intentionally no share/audit anchors. References alone do not
        // identify the former cases, so migration must never reverse any overlay.
        service = nil
        let database = try SQLiteDatabase(path: root.appendingPathComponent("share.sqlite").path)
        try database.execute("DROP TABLE sharer_enforcement; CREATE TABLE sharer_enforcement(digest TEXT PRIMARY KEY,suspended INTEGER NOT NULL,revision INTEGER NOT NULL,case_ref TEXT NOT NULL,changed_at INTEGER NOT NULL,case_until INTEGER NOT NULL DEFAULT 0);")
        try database.run("INSERT INTO sharer_enforcement VALUES(?,1,7,'',0,0)", [.text(ShareHash.secretDigest(owner))])
        try database.run("INSERT INTO sharer_enforcement VALUES(?,1,9,'',0,0)", [.text(ShareHash.secretDigest(differentOwner))])
        try database.run("INSERT INTO sharer_enforcement VALUES(?,0,2,'',0,0)", [.text(ShareHash.secretDigest(Base64URL.encode(Data(repeating: 33, count: 32))))])
        service = try reopen(enabled: false)
        XCTAssertEqual(send("POST", "/v1/share/shares", body: Data("{}".utf8), secret: owner).status, 403)
        service = try reopen()
        let route = "/v1/share/admin/enforcement/suspensions"
        let inventory = try decoded(EnforcementSuspensions.self, send("GET", route, secret: operatorToken, peer: .loopback))
        XCTAssertEqual(inventory.suspensions.count, 2)
        XCTAssertEqual(Set(inventory.suspensions.map(\.revision)), Set([7, 9]))
        XCTAssertEqual(Set(inventory.suspensions.map(\.reference)).count, 2)
        XCTAssertTrue(inventory.suspensions.allSatisfy { ShareLink.isValidID($0.reference) })
        service = try reopen()
        XCTAssertEqual(try decoded(EnforcementSuspensions.self, send("GET", route, secret: operatorToken, peer: .loopback)), inventory)
        XCTAssertEqual(send("POST", "/v1/share/shares", body: Data("{}".utf8), secret: owner).status, 403)
        XCTAssertEqual(send("POST", "/v1/share/shares", body: Data("{}".utf8), secret: differentOwner).status, 403)
    }

    func testAbsentReadOnlyWrongTokenAndUntrustedTransportAreHidden() throws {
        let id = try makeShare()
        let body = try encoded(operation(.disableShare, id: id))
        for peer in [ConnectionPeer.unknown, .other] {
            XCTAssertEqual(operatorCall("plan", body: body, peer: peer).status, 404)
        }
        for token in ["", statsToken, String(repeating: "X", count: 48)] {
            XCTAssertEqual(operatorCall("plan", body: body, token: token).status, 404)
        }
        for header in ["x-real-ip", "x-forwarded-for", "x-forwarded-proto", "forwarded", "cf-connecting-ip"] {
            XCTAssertEqual(operatorCall("plan", body: body, headers: [header: "127.0.0.1"]).status, 404)
        }
        XCTAssertEqual(operatorCall("plan", body: body, peer: .other, headers: ["host": "localhost"]).status, 404)
        service = try reopen(enabled: false)
        XCTAssertEqual(operatorCall("plan", body: body).status, 404)
        XCTAssertEqual(send("GET", "/v1/share/admin/stats", secret: statsToken).status, 200)
    }

    func testPlanIsReadOnlyAndRejectsNoticeUrlsUnknownFieldsAndOversizedBody() throws {
        let id = try makeShare()
        let before = try service.store.database.scalar("SELECT COUNT(*) FROM events")
        _ = try plan(.disableShare, id: id)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM enforcement_operations"), 0)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM share_enforcement"), 0)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM events"), before)
        XCTAssertEqual(send("GET", "/v1/share/p/" + id).status, 200)
        var object = try JSONSerialization.jsonObject(with: encoded(operation(.disableShare, id: id))) as! [String: Any]
        object["notice"] = "must never be accepted"
        XCTAssertEqual(operatorCall("plan", body: try JSONSerialization.data(withJSONObject: object)).status, 400)
        object.removeValue(forKey: "notice"); object["shareID"] = "https://batonmusic.app/s/" + id + "#secret"
        XCTAssertEqual(operatorCall("plan", body: try JSONSerialization.data(withJSONObject: object)).status, 400)
        XCTAssertEqual(operatorCall("plan", body: Data(repeating: 32, count: 65537)).status, 400)
    }

    func testDisableDeniesEveryPublicSurfaceWithoutMetadataCounterOrRedirect() throws {
        let id = try makeShare(art: true)
        service = try reopen(delivery: .accel)
        try apply(.disableShare, id: id)
        let before = try service.store.database.scalar("SELECT COUNT(*) FROM events")
        let page = send("GET", "/s/" + id)
        XCTAssertEqual(page.status, 410)
        XCTAssertFalse(String(decoding: page.body, as: UTF8.self).contains("Synthetic"))
        for suffix in ["", "/audio", "/art", "/card"] {
            let response = send("GET", "/v1/share/p/" + id + suffix, headers: ["range": "bytes=0-99"])
            XCTAssertEqual(response.status, 410)
            XCTAssertNil(response.headers["X-Accel-Redirect"])
            XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("case_123"))
        }
        let viaApp = service.handle(HTTPRequestMessage(method: "GET", path: "/v1/share/p/" + id,
                                                        query: ["via": "app"], headers: [:], body: Data()))
        XCTAssertEqual(viaApp.status, 410)
        XCTAssertEqual(send("POST", "/v1/share/p/" + id + "/reactions", body: Data("{}".utf8)).status, 410)
        // A beacon is accepted and dropped, as for an expired or revoked share, so a player cannot
        // tell a hold from an ending (owner decision 2026-10-21, TBX-1000000507 D-9).
        let beacon = send("POST", "/v1/share/p/" + id + "/events", body: Data(#"{"type":"play_started","ms":900}"#.utf8))
        XCTAssertEqual(beacon.status, 204)
        XCTAssertEqual(beacon.body, Data())
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM events"), before, "and nothing is written")
        XCTAssertEqual(try service.store.share(id: id)?.stats.fetches, 0)
        XCTAssertEqual(try service.store.share(id: id)?.stats.plays, 0)
    }

    func testOwnerNoticeDoesNotExposeCaseDigestOrMetadataAndVoluntaryRevokeWorks() throws {
        let id = try makeShare()
        try apply(.disableShare, id: id)
        let response = send("GET", "/v1/share/shares", secret: owner)
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(text.contains("actionRequired"))
        XCTAssertFalse(text.contains("case_123"))
        XCTAssertFalse(text.contains(ShareHash.secretDigest(owner)))
        XCTAssertFalse(text.contains("Synthetic confidential"))
        XCTAssertEqual(send("DELETE", "/v1/share/shares/" + id, secret: owner).status, 204)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.store.blobURL(id: id, kind: .audio).path))
        XCTAssertEqual(try apply(.restoreShare, id: id).outcome, "unrestorable")
    }

    /// The sharer may still revoke a held share, but that must not overwrite the operator's case
    /// reference or its retention: the contact action and the audit trail match on it (TBX-1000000496
    /// 507 D-18).
    func testVoluntaryRevokeOfAHeldShareKeepsTheOperatorsCaseReference() throws {
        let id = try makeShare()
        try apply(.disableShare, id: id)
        let held = try XCTUnwrap(try service.store.enforcementState(id: id))
        let heldUntil = try service.store.database.scalar("SELECT case_until FROM share_enforcement WHERE share_id=?", [.text(id)])
        XCTAssertFalse(held.caseReference.isEmpty)
        XCTAssertEqual(send("DELETE", "/v1/share/shares/" + id, secret: owner).status, 204)
        let revoked = try XCTUnwrap(try service.store.enforcementState(id: id))
        XCTAssertEqual(revoked.caseReference, held.caseReference, "the operator's case reference survives the owner's revoke")
        XCTAssertEqual(try service.store.database.scalar("SELECT case_until FROM share_enforcement WHERE share_id=?", [.text(id)]), heldUntil,
                       "and so does how long it is kept")
        XCTAssertTrue(revoked.disabled && revoked.purged)
        try service.store.sweepEnforcement(now: Int64(clock.now.timeIntervalSince1970) + 1)
        XCTAssertEqual(try service.store.enforcementState(id: id)?.caseReference, held.caseReference, "a sweep before its retention ends keeps it")
    }

    func testReplayRecoveryAndBodyChangeHaveOneImmutableReceipt() throws {
        let id = try makeShare()
        let reviewed = try plan(.disableShare, id: id)
        let first = operatorCall("apply", body: try encoded(reviewed))
        let replay = operatorCall("apply", body: try encoded(reviewed))
        XCTAssertEqual(first.body, replay.body)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM enforcement_operations"), 1)
        clock.advance(700) // The receipt still recovers beyond the plan's apply lifetime.
        service = try reopen()
        XCTAssertEqual(operatorCall("apply", body: try encoded(reviewed)).body, first.body)
        let recovery = try decoded(EnforcementRecovery.self, operatorCall("operations/" + reviewed.request.operationID))
        XCTAssertEqual(try decoded(EnforcementReceipt.self, first), recovery.receipt)
        var changedRequest = reviewed.request; changedRequest.caseReference = "case_changed"
        let changed = try decoded(EnforcementPlan.self, operatorCall("plan", body: encoded(changedRequest)))
        XCTAssertEqual(operatorCall("apply", body: try encoded(changed)).status, 409)
    }

    func testOwnerChangeAndNewSharerScopeMakePlanStale() throws {
        let id = try makeShare()
        let reviewed = try plan(.disableShare, id: id)
        XCTAssertEqual(send("PATCH", "/v1/share/shares/" + id, body: Data("{\"playCap\":4}".utf8), secret: owner).status, 200)
        XCTAssertEqual(operatorCall("apply", body: try encoded(reviewed)).status, 409)
        let suspended = try plan(.suspendSharer, id: id)
        _ = try makeShare()
        XCTAssertEqual(operatorCall("apply", body: try encoded(suspended)).status, 409)
        XCTAssertFalse(try service.store.isSuspended(digest: ShareHash.secretDigest(owner)))
    }

    func testFailedReceiptCommitRollsBackOverlayAndReportsNoSuccess() throws {
        let id = try makeShare()
        let reviewed = try plan(.disableShare, id: id)
        try service.store.database.execute("CREATE TRIGGER fail_receipt BEFORE INSERT ON enforcement_operations BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;")
        XCTAssertEqual(operatorCall("apply", body: try encoded(reviewed)).status, 500)
        XCTAssertEqual(send("GET", "/v1/share/p/" + id).status, 200)
        XCTAssertNil(try service.store.enforcementState(id: id))
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM enforcement_operations"), 0)
    }

    func testSuspensionSurvivesRestartBlocksWritesAndDoesNotClaimIdentityEnforcement() throws {
        let first = try makeShare()
        let pending = try makeShare(ready: false)
        XCTAssertEqual(try apply(.suspendSharer, id: first).affectedCount, 2)
        service = try reopen(enabled: false)
        XCTAssertEqual(send("POST", "/v1/share/shares", body: Data("{}".utf8), secret: owner).status, 403)
        XCTAssertEqual(send("POST", "/v1/share/shares/" + pending + "/finalize", secret: owner).status, 403)
        XCTAssertEqual(send("PATCH", "/v1/share/shares/" + first, body: Data("{\"extendBySeconds\":600}".utf8), secret: owner).status, 403)
        XCTAssertEqual(try upload(pending, kind: "audio", bytes: Data([1, 2, 3])).status, 403)
        XCTAssertEqual(send("GET", "/v1/share/p/" + first).status, 410)
        _ = try makeShare(secret: differentOwner) // Secret rotation is a different pseudonymous digest.
        service = try reopen()
        try apply(.unsuspendSharer, id: first)
        XCTAssertEqual(send("GET", "/v1/share/p/" + first).status, 410, "unsuspend never restores existing links")
        _ = try makeShare()
    }

    func testRestorePreservesCiphertextCountsExpiryAndCappedState() throws {
        let id = try makeShare(cap: 1)
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/audio").status, 200)
        let before = try XCTUnwrap(service.store.share(id: id))
        let bytes = try Data(contentsOf: service.store.blobURL(id: id, kind: .audio))
        try apply(.disableShare, id: id)
        XCTAssertEqual(try apply(.restoreShare, id: id).outcome, "applied")
        let after = try XCTUnwrap(service.store.share(id: id))
        XCTAssertEqual(before.expiresAt, after.expiresAt)
        XCTAssertEqual(before.playCap, after.playCap)
        XCTAssertEqual(before.stats, after.stats)
        XCTAssertEqual(bytes, try Data(contentsOf: service.store.blobURL(id: id, kind: .audio)))
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/audio").status, 410, "restore does not reset a spent cap")
    }

    func testUnexpiredRetainedReadyMaterialCanRestoreWithoutNewLink() throws {
        let id = try makeShare(art: true)
        try apply(.disableShare, id: id)
        XCTAssertEqual(try apply(.restoreShare, id: id).outcome, "applied")
        XCTAssertEqual(send("GET", "/v1/share/p/" + id).status, 200)
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/art").status, 200)
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM shares"), 1)
    }

    func testMissingCorruptExpiredPendingAndSuspendedMaterialCannotRestore() throws {
        let missing = try makeShare()
        try apply(.disableShare, id: missing)
        try FileManager.default.removeItem(at: service.store.blobURL(id: missing, kind: .audio))
        XCTAssertEqual(try apply(.restoreShare, id: missing).outcome, "unrestorable")
        let corrupt = try makeShare()
        try apply(.disableShare, id: corrupt)
        let file = service.store.blobURL(id: corrupt, kind: .audio)
        let count = try Data(contentsOf: file).count
        try Data(repeating: 0, count: count).write(to: file)
        XCTAssertEqual(try apply(.restoreShare, id: corrupt).outcome, "unrestorable")
        let pending = try makeShare(ready: false, uploadPending: true)
        try apply(.disableShare, id: pending)
        XCTAssertEqual(try apply(.restoreShare, id: pending).outcome, "unrestorable")
        let suspended = try makeShare()
        try apply(.suspendSharer, id: suspended)
        XCTAssertEqual(try apply(.restoreShare, id: suspended).outcome, "unrestorable")
        clock.advance(3601)
        XCTAssertEqual(try apply(.restoreShare, id: suspended).outcome, "unrestorable")
    }

    func testRetainedQuotaPendingSweepDeadlineAndAuditRetentionAreBounded() throws {
        let ready = try makeShare()
        try service.store.database.run("UPDATE shares SET expires_at=? WHERE id=?", [.int(Int64(clock.now.timeIntervalSince1970) + 600), .text(ready)])
        let pending = try makeShare(ready: false)
        try apply(.disableShare, id: ready)
        let overlay = try XCTUnwrap(service.store.enforcementState(id: ready))
        XCTAssertEqual(overlay.deadline, try service.store.share(id: ready)?.expiresAt)
        try apply(.disableShare, id: pending)
        let bytes = try service.store.storedBytes()
        XCTAssertGreaterThan(bytes, 0)
        clock.advance(599)
        _ = try service.sweep()
        XCTAssertEqual(try service.store.storedBytes(), bytes)
        XCTAssertNotNil(try service.store.share(id: pending))
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.store.blobURL(id: ready, kind: .audio).path))
        clock.advance(2)
        _ = try service.sweep()
        XCTAssertEqual(try service.store.storedBytes(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.store.blobURL(id: ready, kind: .audio).path))
        XCTAssertEqual(try apply(.restoreShare, id: ready).outcome, "unrestorable")
        clock.advance(7201)
        _ = try service.sweep()
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM enforcement_operations"), 0)
    }

    func testPurgeDenialSurvivesCleanupDatabaseFailureAndReceiptIsImmutable() throws {
        let id = try makeShare()
        try apply(.disableShare, id: id)
        try service.store.database.execute("CREATE TRIGGER fail_cleanup BEFORE UPDATE OF audio_stored ON shares BEGIN SELECT RAISE(ABORT,'synthetic cleanup failure'); END;")
        let reviewed = try plan(.purgeDisabledShare, id: id)
        let response = operatorCall("apply", body: try encoded(reviewed))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try decoded(EnforcementReceipt.self, response).outcome, "purgeQueued")
        let recovery = try decoded(EnforcementRecovery.self, operatorCall("operations/" + reviewed.request.operationID))
        XCTAssertEqual(recovery.cleanupPending, 1)
        XCTAssertEqual(recovery.cleanupFailed, 1)
        XCTAssertGreaterThan(try service.store.storedBytes(), 0, "failed cleanup is charged conservatively")
        service = try reopen()
        XCTAssertEqual(send("GET", "/v1/share/p/" + id).status, 410)
        try service.store.database.execute("DROP TRIGGER fail_cleanup")
        _ = try service.sweep()
        XCTAssertEqual(try service.store.storedBytes(), 0)
        XCTAssertEqual(operatorCall("apply", body: try encoded(reviewed)).body, response.body)
        let completed = try decoded(EnforcementRecovery.self, operatorCall("operations/" + reviewed.request.operationID))
        XCTAssertEqual(completed.cleanupPending, 0)
        XCTAssertEqual(try apply(.restoreShare, id: id).outcome, "unrestorable")
    }

    func testPlanExpiresAndReceiptLifetimeDoesNotAutomaticallyRestore() throws {
        let id = try makeShare()
        let reviewed = try plan(.disableShare, id: id)
        clock.advance(601)
        XCTAssertEqual(operatorCall("apply", body: try encoded(reviewed)).status, 409)
        try apply(.disableShare, id: id)
        clock.advance(7201)
        _ = try service.sweep()
        XCTAssertEqual(send("GET", "/v1/share/p/" + id).status, 410)
    }

    func testConfigurationRequiresExplicitDistinctCapabilityReasonsAndBoundedRetention() throws {
        let base = ["BATON_SHARE_ENFORCEMENT_ENABLED": "1", "BATON_SHARE_OPERATOR_TOKEN": operatorToken,
                    "BATON_SHARE_ENFORCEMENT_RETENTION_SECONDS": "3600", "BATON_SHARE_ENFORCEMENT_AUDIT_SECONDS": "7200",
                    "BATON_SHARE_ENFORCEMENT_REASON_CODES": "review,correction"]
        XCTAssertNil(try ShareConfiguration.fromEnvironment([:]).enforcement)
        XCTAssertNotNil(try ShareConfiguration.fromEnvironment(base).enforcement)
        for key in ["BATON_SHARE_OPERATOR_TOKEN", "BATON_SHARE_ENFORCEMENT_RETENTION_SECONDS", "BATON_SHARE_ENFORCEMENT_AUDIT_SECONDS", "BATON_SHARE_ENFORCEMENT_REASON_CODES"] {
            var invalid = base; invalid.removeValue(forKey: key)
            XCTAssertThrowsError(try ShareConfiguration.fromEnvironment(invalid))
        }
        var same = base; same["BATON_SHARE_ADMIN_TOKEN"] = operatorToken
        XCTAssertThrowsError(try ShareConfiguration.fromEnvironment(same))
        for seconds in ["0", "7776001"] {
            var invalid = base; invalid["BATON_SHARE_ENFORCEMENT_RETENTION_SECONDS"] = seconds
            XCTAssertThrowsError(try ShareConfiguration.fromEnvironment(invalid))
        }
    }

    func testMinimumAuditRetentionOutlastsSignedNoOpPlanAndRotatedCapabilityRecovers() throws {
        XCTAssertThrowsError(try EnforcementConfiguration(token: operatorToken, retentionSeconds: 100,
            auditRetentionSeconds: 599, reasonCodes: ["review"]))
        let id = try makeShare(ready: false)
        let reviewed = try plan(.restoreShare, id: id)
        let original = operatorCall("apply", body: try encoded(reviewed))
        XCTAssertEqual(try decoded(EnforcementReceipt.self, original).outcome, "unrestorable")
        clock.advance(600)
        _ = try service.sweep()
        XCTAssertEqual(operatorCall("apply", body: try encoded(reviewed)).body, original.body)
        let replacement = String(repeating: "N", count: 48)
        var configuration = ShareConfiguration(dataDirectory: root, publicBase: URL(string: "https://batonmusic.app")!, adminToken: statsToken, blobDelivery: .direct)
        configuration.enforcement = try EnforcementConfiguration(token: replacement, retentionSeconds: 3600,
            auditRetentionSeconds: 3600, reasonCodes: ["review"])
        let currentClock = clock!
        service = try ShareService(config: configuration, clock: { currentClock.now })
        XCTAssertEqual(operatorCall("apply", body: try encoded(reviewed), token: replacement).status, 409)
        let recovery = try decoded(EnforcementRecovery.self,
            operatorCall("operations/" + reviewed.request.operationID, token: replacement))
        XCTAssertEqual(recovery.receipt, try decoded(EnforcementReceipt.self, original))
        clock.advance(6601)
        _ = try service.sweep()
        XCTAssertEqual(operatorCall("operations/" + reviewed.request.operationID, token: replacement).status, 404)
        XCTAssertEqual(operatorCall("apply", body: try encoded(reviewed), token: replacement).status, 409)
    }

    func testFilesystemFailurePersistsDenialCleanupAndConservativeQuota() throws {
        let id = try makeShare()
        try apply(.disableShare, id: id)
        let reviewed = try plan(.purgeDisabledShare, id: id)
        let receipt = try service.applyEnforcement(reviewed, capability: capability())
        XCTAssertEqual(receipt.outcome, "purgeQueued")
        _ = try service.store.performEnforcementCleanup(now: Int64(clock.now.timeIntervalSince1970), remove: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.store.blobURL(id: id, kind: .audio).path))
        XCTAssertGreaterThan(try service.store.storedBytes(), 0)
        let recovery = try XCTUnwrap(service.store.enforcementRecovery(id: receipt.operationID))
        XCTAssertEqual(recovery.cleanupPending, 1); XCTAssertEqual(recovery.cleanupFailed, 1)
        service = try reopen(enabled: false)
        XCTAssertEqual(send("GET", "/v1/share/p/" + id + "/audio").status, 410)
        _ = try service.sweep()
        XCTAssertEqual(try service.store.storedBytes(), 0)
        XCTAssertEqual(try service.store.enforcementRecovery(id: receipt.operationID)?.cleanupPending, 0)
    }

    func testConcurrentRequestsAfterCommittedSuspensionCannotFetchOrFinalize() throws {
        let id = try makeShare()
        let pending = try makeShare(ready: false)
        try apply(.suspendSharer, id: id)
        // All queued calls begin after the successful SQL commit. The existing service lock
        // serializes each against enforcement; already-open transfers are outside this boundary.
        let current = service!, owner = owner
        final class Results: @unchecked Sendable {
            let lock = NSLock(); var statuses: [Int] = []
            func append(_ value: Int) { lock.lock(); statuses.append(value); lock.unlock() }
        }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            let request = HTTPRequestMessage(method: index % 2 == 0 ? "GET" : "POST",
                path: index % 2 == 0 ? "/v1/share/p/" + id + "/audio" : "/v1/share/shares/" + pending + "/finalize",
                query: [:], headers: ["authorization": "Bearer " + owner], body: Data())
            let response = current.handle(request)
            results.append(response.status)
        }
        XCTAssertEqual(results.statuses.filter { $0 == 410 }.count, 20)
        XCTAssertEqual(results.statuses.filter { $0 == 403 }.count, 20)
        XCTAssertEqual(try service.store.share(id: id)?.stats.fetches, 0)
        XCTAssertEqual(try service.store.share(id: pending)?.status, .pending)
    }

    func testAuditCaseReferencesExpireWithoutRemovingSuspension() throws {
        let id = try makeShare()
        try apply(.suspendSharer, id: id)
        let audit = try XCTUnwrap(service.store.database.query("SELECT * FROM enforcement_operations").first)
        XCTAssertEqual(audit["reason_code"]?.text, "review")
        XCTAssertEqual(audit["target_id"]?.text, id)
        XCTAssertEqual(audit["affected_ids"]?.text, "[\"" + id + "\"]")
        clock.advance(7201)
        _ = try service.sweep()
        XCTAssertEqual(try service.store.database.scalar("SELECT COUNT(*) FROM enforcement_operations"), 0)
        XCTAssertTrue(try service.store.isSuspended(digest: ShareHash.secretDigest(owner)))
        XCTAssertEqual(try service.store.database.query("SELECT case_ref FROM sharer_enforcement").first?["case_ref"]?.text, "")
        XCTAssertEqual(send("POST", "/v1/share/shares", body: Data("{}".utf8), secret: owner).status, 403)
    }

    func testRealSocketSuppliesTrustedPeerWithoutChangingOriginalHandlerAPI() async throws {
        let id = try makeShare()
        let current = service!
        let transport = POSIXTransport(stagingDirectory: current.stagingDirectory,
                                       maximumBodyBytes: 65536, loopbackOnly: true, log: { _ in })
        let listener = try transport.start(port: 0, handle: { current.handle($0).data },
                                           upload: { current.handleUpload($0, file: $1).data },
                                           peerHandle: { current.handle($0, peer: $1).data })
        defer { listener.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(listener.port)/v1/share/admin/enforcement/plan")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + operatorToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try encoded(operation(.disableShare, id: id))
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        request.setValue("for=127.0.0.1", forHTTPHeaderField: "Forwarded")
        let (_, proxied) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((proxied as? HTTPURLResponse)?.statusCode, 404)
    }
}
