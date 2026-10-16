@testable import BatonShareKit
import BatonMCPProtocol
@testable import BatonGatewayCore
@testable import BatonShareServer
import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class MixtapeHTTPBridge: @unchecked Sendable {
    enum Alteration { case none, mismatchedReady, foreignCreate, foreignUpload, descriptor, manifest, audio, oversizedError }
    let service: ShareService
    let root: URL
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    var alteration = Alteration.none
    init(service: ShareService, root: URL) { self.service = service; self.root = root }
    func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    func respond(_ request: URLRequest) throws -> ShareResponse {
        lock.lock(); captured.append(request); let alteration = self.alteration; lock.unlock()
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        var headers = [String: String]()
        for (name, value) in request.allHTTPHeaderFields ?? [:] { headers[name.lowercased()] = value }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { throw URLError(.cannotDecodeContentData) }
                if count == 0 { break }; body.append(contentsOf: buffer.prefix(count))
            }
        }
        var response: ShareResponse
        if method == "PUT" {
            let file = root.appendingPathComponent("bridge-upload-" + UUID().uuidString)
            try body.write(to: file)
            response = service.handleUpload(.init(method: method, path: path, headers: headers, contentLength: body.count), file: file)
        } else { response = service.handle(.init(method: method, path: path, query: [:], headers: headers, body: body)) }
        if method == "POST", path == "/v1/share/mixtapes", response.status == 201 {
            var value = try JSONDecoder().decode(CreateMixtapeResponse.self, from: response.body)
            if alteration == .foreignCreate { value.url = "https://foreign.invalid/m/" + value.id }
            if alteration == .foreignUpload, let first = value.uploads.keys.first { value.uploads[first] = "https://foreign.invalid/upload" }
            response.body = try JSONEncoder().encode(value)
        }
        if method == "GET", path.hasPrefix("/v1/share/m/"), !path.contains("/tracks/"), response.status == 200 {
            var value = try JSONDecoder().decode(PublicMixtape.self, from: response.body)
            if alteration == .descriptor, let first = value.tracks.keys.first { value.tracks[first]!.audioSHA256 = String(repeating: "0", count: 64) }
            if alteration == .manifest, var bytes = Data(base64Encoded: value.encryptedManifest) { bytes[bytes.count - 1] ^= 1; value.encryptedManifest = bytes.base64EncodedString() }
            response.body = try JSONEncoder().encode(value)
        }
        if alteration == .mismatchedReady, method == "GET", path.hasPrefix("/v1/share/mixtapes/"), response.status == 200 {
            var value = try JSONDecoder().decode(MixtapeSummary.self, from: response.body)
            value.share.id = Base64URL.encode(Data(repeating: 17, count: 16)); value.share.status = .ready
            response.body = try JSONEncoder().encode(value)
        }
        if alteration == .audio, path.contains("/tracks/"), response.status == 200 { response.body[response.body.count - 1] ^= 1 }
        if alteration == .oversizedError, path.contains("/tracks/"), method == "GET" { response = .init(status: 409, contentType: "application/json", body: Data(repeating: 32, count: 4097)) }
        return response
    }
}
private final class MixtapeBridgeProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bridge: MixtapeHTTPBridge?
    nonisolated(unsafe) static var loseNext: String?
    nonisolated(unsafe) static var errorPath: String?
    nonisolated(unsafe) static var advertisedError = false
    nonisolated(unsafe) static var started: XCTestExpectation?
    nonisolated(unsafe) static var stopped: XCTestExpectation?
    nonisolated(unsafe) static var activeError: MixtapeBridgeProtocol?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == Self.errorPath {
            Self.activeError = self
            let headers = Self.advertisedError ? ["Content-Length": "5000"] : [:]
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(repeating: 32, count: 4096))
            client?.urlProtocol(self, didLoad: Data([32]))
            Self.started?.fulfill()
            return // Peer deliberately stays open; cancellation must precede completion.
        }
        do {
            let response = try Self.bridge!.respond(request)
            if let lose = Self.loseNext, request.url!.path.contains(lose) {
                Self.loseNext = nil
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            let headers = response.headers.merging(["Content-Type": response.contentType, "Content-Length": String(response.body.count)], uniquingKeysWith: { _, rhs in rhs })
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {
        if Self.activeError === self { Self.stopped?.fulfill(); Self.stopped = nil }
    }
    func finishError() { client?.urlProtocolDidFinishLoading(self) }
}

final class ShareMixtapeClientTests: XCTestCase {
    var root: URL!
    private var bridge: MixtapeHTTPBridge!
    var client: ShareClient!
    var session: URLSession!
    let operatorToken = String(repeating: "Z", count: 40)
    let owner = Base64URL.encode(Data(repeating: 4, count: 32))
    let base = URL(string: "https://batonmusic.app")!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mixtape-client-" + UUID().uuidString)
        var config = ShareConfiguration(dataDirectory: root, blobDelivery: .direct); config.mixtapesEnabled = true
        config.enforcement = try .init(token: operatorToken, retentionSeconds: 90 * 86400, auditRetentionSeconds: 90 * 86400, reasonCodes: ["review"])
        bridge = MixtapeHTTPBridge(service: try ShareService(config: config), root: root)
        MixtapeBridgeProtocol.bridge = bridge
        session = URLSession(configuration: Self.configuration())
        client = ShareClient(base: base, secret: owner, session: session)
    }
    override func tearDownWithError() throws {
        MixtapeBridgeProtocol.activeError?.finishError()
        MixtapeBridgeProtocol.errorPath = nil; MixtapeBridgeProtocol.activeError = nil
        MixtapeBridgeProtocol.started = nil; MixtapeBridgeProtocol.stopped = nil
        session.invalidateAndCancel(); MixtapeBridgeProtocol.loseNext = nil; MixtapeBridgeProtocol.bridge = nil; bridge = nil
        try? FileManager.default.removeItem(at: root)
    }
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MixtapeBridgeProtocol.self]; return config
    }
    func receiver() throws -> ShareMixtapeReceiver {
        try ShareMixtapeReceiver(base: base, transport: BoundedShareReceiverTransport(makeConfiguration: Self.configuration))
    }
    func prepared(cap: Int = 1) throws -> PreparedMixtape {
        try PreparedMixtape.make(tracks: [.init(audio: Data("second sound".utf8), metadata: .init(title: "Second selected", durationSeconds: 10)), .init(audio: Data("first sound".utf8), metadata: .init(title: "First selected", durationSeconds: 15))], title: "Chosen order", preview: nil, expiresInSeconds: 86400, playCap: cap, client: .init(platform: "macos", appVersion: "synthetic"))
    }
    func testProtectedContainerReopensAfterLostCreateTrackAndFinalizeResponses() async throws {
        for loss in ["/v1/share/mixtapes", "/tracks/", "/finalize"] {
            let prepared = try prepared(cap: 2)
            let directory = root.appendingPathComponent("tickets-" + UUID().uuidString)
            let ledgerURL = directory.deletingLastPathComponent().appendingPathComponent("ledger-" + UUID().uuidString + ".json")
            let store = ShareUploadStore(directory: directory, ledgerURL: ledgerURL)
            let job = try store.stage(prepared, base: base, songIDs: ["local-second", "local-first"])
            let before = bridge.requests().count
            MixtapeBridgeProtocol.loseNext = loss
            do { _ = try await MixtapeUploadCoordinator(store: store).resume(job.id, client: client); XCTFail("lost response must retain an interrupted job") }
            catch {}
            let reopened = ShareUploadStore(directory: directory, ledgerURL: ledgerURL)
            XCTAssertEqual(try reopened.load().jobs.count, 1)
            let record = try await MixtapeUploadCoordinator(store: reopened).resume(job.id, client: client)
            XCTAssertEqual(record.songIDs, ["local-second", "local-first"])
            XCTAssertEqual(record.containerKind, .mixtape)
            let invitation = try XCTUnwrap(ShareInvitation(url: try XCTUnwrap(URL(string: record.link))))
            XCTAssertEqual(invitation.key, prepared.key)
            let details = try await receiver().details(invitation)
            XCTAssertEqual(details.manifest.tracks.map { $0.metadata.title }, ["Second selected", "First selected"])
            XCTAssertTrue(try reopened.load().jobs.isEmpty)
            XCTAssertEqual(ShareLedger.load(from: ledgerURL).records.count, 1)
            let requests = Array(bridge.requests().dropFirst(before))
            let creates = requests.filter { $0.httpMethod == "POST" && $0.url?.path == "/v1/share/mixtapes" }
            XCTAssertEqual(creates.count, loss == "/v1/share/mixtapes" ? 2 : 1)
            if creates.count == 2 { XCTAssertEqual(creates[0].httpBody, creates[1].httpBody) }
            let ownerList = try await client.listMixtapes()
            XCTAssertEqual(ownerList.filter { $0.share.id == record.id }.count, 1)
            let perms = try FileManager.default.attributesOfItem(atPath: ledgerURL.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(perms?.intValue, 0o600)
        }
    }

    func testUnreachableRecoveryRetainsProtectedCiphertextAndLegacyTicket() async throws {
        let store = ShareUploadStore(directory: root.appendingPathComponent("protected-tickets"), ledgerURL: root.appendingPathComponent("protected-ledger.json"))
        let prepared = try prepared()
        let job = try store.stage(prepared, base: base, songIDs: ["second", "first"])
        MixtapeBridgeProtocol.loseNext = "/v1/share/mixtapes"
        do { _ = try await MixtapeUploadCoordinator(store: store).resume(job.id, client: client); XCTFail() } catch {}
        let retained = try XCTUnwrap(store.load().jobs.first)
        XCTAssertEqual(retained.key, prepared.key)
        XCTAssertEqual(retained.createBody, try prepared.encodedRequest())
        for item in retained.bodies {
            XCTAssertEqual(try Data(contentsOf: store.file(job.id, kind: item.kind)).count, item.bytes)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.file(job.id, kind: item.kind).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        let single = try PreparedShare.make(audio: Data("legacy".utf8), metadata: .init(title: "Legacy", durationSeconds: 2), isPrivate: true, expiresInSeconds: 86400, playCap: 1, client: .init(platform: "macos", appVersion: "synthetic"))
        let old = try store.stage(single, base: base, songID: "legacy", title: "Legacy", artist: "")
        XCTAssertEqual(try store.load().jobs.count, 2)
        XCTAssertFalse(try XCTUnwrap(store.load().jobs.first { $0.id == old.id }).isMixtape)
    }

    func testHeldContainerRecoveryKeepsKeyAndStopsUploadsUntilReviewed() async throws {
        let original = try prepared(cap: 3)
        let prepared = try PreparedMixtape.make(tracks: [.init(audio: Data("second".utf8), metadata: original.manifest.tracks[0].metadata), .init(audio: Data("first".utf8), metadata: original.manifest.tracks[1].metadata)], title: "Held order", preview: nil, expiresInSeconds: 86400, playCap: 3, client: .init(platform: "macos", appVersion: "synthetic"), reviewPreservationConsent: CreateShareRequest.reviewConsentVersion)
        let store = ShareUploadStore(directory: root.appendingPathComponent("held-tickets"), ledgerURL: root.appendingPathComponent("held-ledger.json"))
        let job = try store.stage(prepared, base: base, songIDs: ["second", "first"])
        MixtapeBridgeProtocol.loseNext = "/tracks/"
        do { _ = try await MixtapeUploadCoordinator(store: store).resume(job.id, client: client); XCTFail() } catch {}
        let owned = try await client.listMixtapes()
        let containerID = try XCTUnwrap(owned.first).share.id
        let now = Int64(Date().timeIntervalSince1970)
        let body = try JSONSerialization.data(withJSONObject: ["operationID": UUID().uuidString, "action": "disable-share", "shareID": containerID, "caseReference": "recovery", "reasonCode": "review", "reviewUntil": now + 86400, "preservationDeadline": now + 3 * 86400])
        let headers = ["authorization": "Bearer " + operatorToken]
        let plan = bridge.service.handle(.init(method: "POST", path: "/v1/share/admin/enforcement/plan", query: [:], headers: headers, body: body), peer: .loopback)
        XCTAssertEqual(plan.status, 200)
        let applied = bridge.service.handle(.init(method: "POST", path: "/v1/share/admin/enforcement/apply", query: [:], headers: headers, body: plan.body), peer: .loopback)
        XCTAssertEqual(applied.status, 200)
        let before = bridge.requests().count
        do { _ = try await MixtapeUploadCoordinator(store: store).resume(job.id, client: client); XCTFail() }
        catch MixtapeUploadCoordinator.Failure.held {} catch { XCTFail("expected held refusal") }
        let retained = try XCTUnwrap(store.load().jobs.first)
        XCTAssertEqual(retained.key, prepared.key)
        XCTAssertEqual(retained.mixtapeCreated?.id, containerID)
        XCTAssertEqual(bridge.requests().dropFirst(before).filter { $0.httpMethod == "PUT" || $0.httpMethod == "POST" }.count, 0)
        XCTAssertTrue(ShareLedger.load(from: store.ledgerURL).records.isEmpty)
    }

    func testPreVersionTicketReopensAndAtomicReceiptDoesNotDuplicateCompletion() async throws {
        let store = ShareUploadStore(directory: root.appendingPathComponent("old-tickets"), ledgerURL: root.appendingPathComponent("old-ledger.json"))
        let single = try PreparedShare.make(audio: Data("legacy".utf8), metadata: .init(title: "Legacy", durationSeconds: 2), isPrivate: true, expiresInSeconds: 86400, playCap: 1, client: .init(platform: "macos", appVersion: "synthetic"))
        let old = try store.stage(single, base: base, songID: "legacy", title: "Legacy", artist: "")
        let ticket = store.folder(old.id).appendingPathComponent("ticket.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ticket)) as? [String: Any])
        XCTAssertNil(object["version"]); XCTAssertNil(object["mixtapeCreated"]); XCTAssertNil(object["mixtapeFinalized"])
        let reopened = ShareUploadStore(directory: store.directory, ledgerURL: store.ledgerURL)
        XCTAssertEqual(try XCTUnwrap(reopened.load().jobs.first).record.songID, "legacy")
        let prepared = try prepared()
        var multi = try store.stage(prepared, base: base, songIDs: ["second", "first"])
        try store.attach(try await client.createMixtape(body: prepared.encodedRequest()), to: &multi)
        for track in prepared.manifest.tracks { try await client.uploadMixtape(multi.record.id, trackID: track.id, data: prepared.sealedTracks[track.id]!) }
        multi.mixtapeFinalized = try await client.finalizeMixtape(multi.record.id)
        try store.save(multi)
        _ = try store.commit(multi) // Simulates the accepted ledger write before ticket removal.
        let record = try await MixtapeUploadCoordinator(store: reopened).resume(multi.id, client: client)
        XCTAssertEqual(record.id, multi.record.id)
        XCTAssertEqual(ShareLedger.load(from: store.ledgerURL).records.count, 1)
        XCTAssertEqual(try reopened.load().jobs.map(\.id), [old.id])
    }

    func testRecoveryRejectsForeignReadyOwnerIdentityBeforeLedgerReceipt() async throws {
        let prepared = try prepared()
        let store = ShareUploadStore(directory: root.appendingPathComponent("identity-tickets"), ledgerURL: root.appendingPathComponent("identity-ledger.json"))
        var job = try store.stage(prepared, base: base, songIDs: ["second", "first"])
        try store.attach(try await client.createMixtape(body: prepared.encodedRequest()), to: &job)
        bridge.alteration = .mismatchedReady
        do { _ = try await MixtapeUploadCoordinator(store: store).resume(job.id, client: client); XCTFail("foreign ready ID must refuse") } catch {}
        XCTAssertTrue(ShareLedger.load(from: store.ledgerURL).records.isEmpty)
        XCTAssertTrue(ShareUploadStore.receipts(at: store.ledgerURL).isEmpty)
        XCTAssertEqual(try store.load().jobs.count, 1)
        bridge.alteration = .none
        var cached = try await client.mixtape(job.record.id)
        cached.share.id = Base64URL.encode(Data(repeating: 18, count: 16)); cached.share.status = .ready
        var poisoned = job; poisoned.mixtapeFinalized = cached; try store.save(poisoned)
        let beforeCached = bridge.requests().count
        do { _ = try await MixtapeUploadCoordinator(store: store).resume(job.id, client: client); XCTFail("foreign cached finalize must refuse") } catch {}
        XCTAssertEqual(bridge.requests().count, beforeCached)
        XCTAssertTrue(ShareLedger.load(from: store.ledgerURL).records.isEmpty)
        XCTAssertTrue(ShareUploadStore.receipts(at: store.ledgerURL).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folder(job.id).path))
        try store.save(job)
        let recovered = try await MixtapeUploadCoordinator(store: store).resume(job.id, client: client)
        XCTAssertEqual(recovered.id, job.record.id)
        XCTAssertEqual(ShareInvitation(url: URL(string: recovered.link)!)?.key, prepared.key)
    }

    func testWrongRetainedKeyRefusesBeforeNetworkAndPreservesTicket() async throws {
        let prepared = try prepared()
        let store = ShareUploadStore(directory: root.appendingPathComponent("wrong-key-tickets"), ledgerURL: root.appendingPathComponent("wrong-key-ledger.json"))
        var job = try store.stage(prepared, base: base, songIDs: ["second", "first"])
        job.key = Data(repeating: 19, count: 16); try store.save(job)
        let before = bridge.requests().count
        do { _ = try await MixtapeUploadCoordinator(store: store).resume(job.id, client: client); XCTFail("unauthenticated retained manifest must refuse") } catch {}
        XCTAssertEqual(bridge.requests().count, before)
        XCTAssertTrue(ShareLedger.load(from: store.ledgerURL).records.isEmpty)
        XCTAssertTrue(ShareUploadStore.receipts(at: store.ledgerURL).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folder(job.id).appendingPathComponent("ticket.json").path))
        do {
            let loaded = try store.load()
            XCTAssertTrue(loaded.orphans.isEmpty, "invalid v2 material must not enter legacy destructive orphan cleanup")
        } catch {} // Protected unresolved material is refused, not erased.
    }

    func testMalformedVersionedTicketIsRetainedOutsideLegacyOrphanCleanup() async throws {
        for damage in ["typed-key", "truncated", "missing-ticket"] {
            let prepared = try prepared()
            let store = ShareUploadStore(directory: root.appendingPathComponent("malformed-" + damage), ledgerURL: root.appendingPathComponent("malformed-" + damage + ".json"))
            let job = try store.stage(prepared, base: base, songIDs: ["second", "first"])
            let ticket = store.folder(job.id).appendingPathComponent("ticket.json")
            if damage == "typed-key" {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ticket)) as? [String: Any])
                object["key"] = "not-base64!"
                try ShareUploadStore.writeProtected(JSONSerialization.data(withJSONObject: object), to: ticket)
            } else if damage == "truncated" { try ShareUploadStore.writeProtected(Data(#"{"version":2,"#.utf8), to: ticket) }
            else { try FileManager.default.removeItem(at: ticket) }
            let before = bridge.requests().count
            do { _ = try await MixtapeUploadCoordinator(store: store).resume(job.id, client: client); XCTFail("malformed container must refuse") } catch {}
            do { let loaded = try store.load(); XCTAssertTrue(loaded.orphans.isEmpty, "versioned recovery material cannot enter destructive legacy cleanup") } catch {}
            XCTAssertEqual(bridge.requests().count, before)
            XCTAssertTrue(ShareLedger.load(from: store.ledgerURL).records.isEmpty)
            XCTAssertTrue(ShareUploadStore.receipts(at: store.ledgerURL).isEmpty)
            for body in job.bodies {
                XCTAssertEqual(try Data(contentsOf: store.file(job.id, kind: body.kind)).count, body.bytes)
            }
        }
        let legacy = ShareUploadStore(directory: root.appendingPathComponent("legacy-corrupt"), ledgerURL: root.appendingPathComponent("legacy-corrupt.json"))
        let single = try PreparedShare.make(audio: Data("old".utf8), metadata: .init(title: "Old", durationSeconds: 1), isPrivate: true, expiresInSeconds: 86400, playCap: 1, client: .init(platform: "macos", appVersion: "synthetic"))
        let old = try legacy.stage(single, base: base, songID: "old", title: "Old", artist: "")
        try ShareUploadStore.writeProtected(Data("{not json".utf8), to: legacy.folder(old.id).appendingPathComponent("ticket.json"))
        XCTAssertEqual(try legacy.load().orphans, [old.id])
    }

    func testOrderedOwnerAndRecipientFlowAuthenticatesBeforeExplicitAdmission() async throws {
        let prepared = try prepared(), result = try await client.shareMixtape(prepared)
        let invitation = try XCTUnwrap(ShareInvitation(url: result.link)), receiver = try receiver()
        XCTAssertEqual(invitation.kind, .mixtape); XCTAssertTrue(invitation.key == prepared.key)
        XCTAssertEqual(result.summary.share.status, .ready)
        let details = try await receiver.details(invitation)
        XCTAssertEqual(details.manifest.tracks.map(\.metadata.title), ["Second selected", "First selected"])
        XCTAssertEqual(bridge.requests().filter { $0.url!.path.hasSuffix("/sessions") }.count, 0)
        XCTAssertEqual(bridge.requests().filter { $0.httpMethod == "GET" && $0.url!.path.contains("/tracks/") }.count, 0)
        let wrongInvitation = ShareInvitation(id: Base64URL.encode(Data(repeating: 9, count: 16)), key: prepared.key, kind: .mixtape)
        do { _ = try await receiver.admit(wrongInvitation, details: details); XCTFail("unrelated details accepted") }
        catch { XCTAssertEqual(error as? ShareMixtapeReceiver.Failure, .incomplete) }
        XCTAssertEqual(bridge.requests().filter { $0.url!.path.hasSuffix("/sessions") }.count, 0)
        let admitted = try await receiver.admit(invitation, details: details)
        for (index, track) in details.manifest.tracks.enumerated() {
            let plain = try await receiver.audio(invitation, details: details, trackID: track.id, session: admitted)
            XCTAssertEqual(plain, Data((index == 0 ? "second sound" : "first sound").utf8))
        }
        do { _ = try await receiver.audio(invitation, details: details, trackID: details.manifest.tracks[0].id, session: admitted); XCTFail("exhausted refetch escaped") }
        catch { XCTAssertEqual(error as? ShareMixtapeReceiver.Failure, .transferBudget) }
        XCTAssertEqual(bridge.requests().filter { $0.url!.path.hasSuffix("/sessions") }.count, 1, "No automatic admission after budget exhaustion")
        try await receiver.react(invitation.id, session: admitted, reaction: .init(emoji: "❤️", name: "Synthetic friend"))
        let summary = try await client.mixtape(invitation.id)
        XCTAssertEqual(summary.share.stats.fetches, 1); XCTAssertEqual(summary.share.reactions.count, 1)
        XCTAssertTrue(bridge.requests().allSatisfy { $0.url?.fragment == nil && !($0.url?.absoluteString.contains(Base64URL.encode(prepared.key)) ?? true) })
        let recipient = bridge.requests().filter { $0.url!.path.hasPrefix("/v1/share/m/") }
        XCTAssertTrue(recipient.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") != "Bearer " + owner })
        XCTAssertTrue(recipient.filter { $0.url!.path.contains("/tracks/") || $0.url!.path.hasSuffix("/reactions") }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer " + admitted.token })
        XCTAssertFalse(String(describing: admitted).contains(admitted.token))
        XCTAssertTrue(bridge.requests().allSatisfy { !String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains(Base64URL.encode(prepared.key)) })
        XCTAssertTrue(recipient.allSatisfy { !String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains(admitted.token) && !($0.url?.absoluteString.contains(admitted.token) ?? true) })
        XCTAssertTrue(bridge.requests().filter { $0.url!.path == "/v1/share/config" }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        try await client.revokeMixtape(invitation.id)
        let revoked = try await client.mixtape(invitation.id)
        XCTAssertEqual(revoked.share.status, .revoked)
    }
    func testManifestAndCiphertextTamperingNeverReturnsPlayableBytes() async throws {
        let result = try await client.shareMixtape(prepared(cap: 3))
        let invitation = try XCTUnwrap(ShareInvitation(url: result.link)), receiver = try receiver()
        for mode in [MixtapeHTTPBridge.Alteration.descriptor, .manifest] {
            bridge.alteration = mode
            do { _ = try await receiver.details(invitation); XCTFail("unauthenticated manifest escaped") }
            catch { XCTAssertEqual(error as? ShareMixtapeReceiver.Failure, .invalidData) }
        }
        XCTAssertEqual(bridge.requests().filter { $0.url!.path.hasSuffix("/sessions") }.count, 0)
        bridge.alteration = .none
        let details = try await receiver.details(invitation), admitted = try await receiver.admit(invitation, details: details)
        bridge.alteration = .audio
        do { _ = try await receiver.audio(invitation, details: details, trackID: details.manifest.tracks[0].id, session: admitted); XCTFail("tampered audio escaped") }
        catch { XCTAssertEqual(error as? ShareMixtapeReceiver.Failure, .invalidData) }
    }
    func testOwnerErrorReceiveCeilingCancelsBeforePeerCompletion() async throws {
        let ownerClient = client!
        for declared in [false, true] {
            let started = expectation(description: "owner error peer began"), stopped = expectation(description: "owner error peer observed early cancellation")
            MixtapeBridgeProtocol.errorPath = "/v1/share/mixtapes"
            MixtapeBridgeProtocol.advertisedError = declared
            MixtapeBridgeProtocol.started = started; MixtapeBridgeProtocol.stopped = stopped
            let request = Task { try await ownerClient.listMixtapes() }
            await fulfillment(of: [started], timeout: 2)
            await fulfillment(of: [stopped], timeout: 1)
            MixtapeBridgeProtocol.activeError?.finishError()
            do { _ = try await request.value; XCTFail("oversized owner error accepted") }
            catch { XCTAssertTrue(error is ShareClient.Failure) }
            MixtapeBridgeProtocol.errorPath = nil; MixtapeBridgeProtocol.activeError = nil
        }
    }
    func testLargeTrackErrorReceiveCeilingCancelsBeforePeerCompletion() async throws {
        let prepared = try PreparedMixtape.make(tracks: [.init(audio: Data(repeating: 1, count: 6000), metadata: .init(title: "A", durationSeconds: 10)), .init(audio: Data(repeating: 2, count: 6000), metadata: .init(title: "B", durationSeconds: 10))], title: "Large success budget", preview: nil, expiresInSeconds: 86400, playCap: 1, client: .init(platform: "macos", appVersion: "test"))
        let result = try await client.shareMixtape(prepared), invitation = try XCTUnwrap(ShareInvitation(url: result.link)), receiver = try receiver()
        let details = try await receiver.details(invitation), admitted = try await receiver.admit(invitation, details: details), track = details.manifest.tracks[0]
        for declared in [false, true] {
            let started = expectation(description: "track error peer began"), stopped = expectation(description: "track error peer observed early cancellation")
            MixtapeBridgeProtocol.errorPath = "/v1/share/m/\(invitation.id)/tracks/\(track.id)"
            MixtapeBridgeProtocol.advertisedError = declared
            MixtapeBridgeProtocol.started = started; MixtapeBridgeProtocol.stopped = stopped
            let request = Task { try await receiver.audio(invitation, details: details, trackID: track.id, session: admitted) }
            await fulfillment(of: [started], timeout: 2)
            await fulfillment(of: [stopped], timeout: 1)
            MixtapeBridgeProtocol.activeError?.finishError()
            do { _ = try await request.value; XCTFail("oversized track error accepted") }
            catch { XCTAssertEqual(error as? ShareMixtapeReceiver.Failure, .tooLarge) }
            MixtapeBridgeProtocol.errorPath = nil; MixtapeBridgeProtocol.activeError = nil
        }
        XCTAssertEqual(bridge.requests().filter { $0.url!.path.hasSuffix("/sessions") }.count, 1)
        let plain = try await receiver.audio(invitation, details: details, trackID: track.id, session: admitted)
        XCTAssertEqual(plain, Data(repeating: 1, count: 6000), "Large exact authenticated success remains allowed")
    }
    func testAuthenticatedDetailsRejectDifferentKeyBeforeAdmissionOrTransfer() async throws {
        let result = try await client.shareMixtape(prepared(cap: 2)), invitation = try XCTUnwrap(ShareInvitation(url: result.link)), receiver = try receiver()
        let details = try await receiver.details(invitation)
        let otherKey = ShareInvitation(id: invitation.id, key: Data(repeating: 12, count: 16), kind: .mixtape)
        do { _ = try await receiver.admit(otherKey, details: details); XCTFail("mismatched key consumed admission") }
        catch { XCTAssertEqual(error as? ShareMixtapeReceiver.Failure, .incomplete) }
        XCTAssertEqual(bridge.requests().filter { $0.url!.path.hasSuffix("/sessions") }.count, 0)
        let admitted = try await receiver.admit(invitation, details: details)
        do { _ = try await receiver.audio(otherKey, details: details, trackID: details.manifest.tracks[0].id, session: admitted); XCTFail("mismatched key consumed transfer") }
        catch { XCTAssertEqual(error as? ShareMixtapeReceiver.Failure, .invalidData) }
        XCTAssertEqual(bridge.requests().filter { $0.httpMethod == "GET" && $0.url!.path.contains("/tracks/") }.count, 0)
        let summary = try await client.mixtape(invitation.id)
        XCTAssertEqual(summary.share.stats.fetches, 1)
    }
    func testErrorEnvelopeCannotExceedItsSeparateFixedCeiling() async throws {
        let result = try await client.shareMixtape(prepared())
        let invitation = try XCTUnwrap(ShareInvitation(url: result.link)), receiver = try receiver()
        let details = try await receiver.details(invitation), admitted = try await receiver.admit(invitation, details: details)
        bridge.alteration = .oversizedError
        do { _ = try await receiver.audio(invitation, details: details, trackID: details.manifest.tracks[0].id, session: admitted); XCTFail("unbounded error accepted") }
        catch { XCTAssertEqual(error as? ShareMixtapeReceiver.Failure, .tooLarge) }
        XCTAssertEqual(bridge.requests().filter { $0.url!.path.hasSuffix("/sessions") }.count, 1)
    }
    func testForeignCreateAndUploadLocationsAreRefusedBeforeBearerTransfer() async throws {
        for mode in [MixtapeHTTPBridge.Alteration.foreignCreate, .foreignUpload] {
            bridge.alteration = mode
            do { _ = try await client.shareMixtape(prepared()); XCTFail("foreign location accepted") }
            catch { XCTAssertEqual(error as? ShareClient.Failure, .unexpected(0)) }
        }
        XCTAssertTrue(bridge.requests().allSatisfy { $0.url?.host == "batonmusic.app" })
        XCTAssertEqual(bridge.requests().filter { $0.httpMethod == "PUT" }.count, 0)
    }
    func testMissingKeyAndDefaultOffReportTypedFailuresWithoutTransfers() async throws {
        let receiver = try receiver()
        do { _ = try await receiver.details(.init(id: Base64URL.encode(Data(repeating: 3, count: 16)), key: nil, kind: .mixtape)); XCTFail() }
        catch { XCTAssertEqual(error as? ShareMixtapeReceiver.Failure, .incomplete) }
        let old = try ShareReceiverClient(base: base, transport: BoundedShareReceiverTransport(makeConfiguration: Self.configuration))
        do { _ = try await old.details(.init(id: Base64URL.encode(Data(repeating: 3, count: 16)), key: Data(repeating: 2, count: 16), kind: .mixtape), platform: "macos"); XCTFail("old song channel accepted a mixtape") }
        catch { XCTAssertEqual(error as? ShareReceiverClient.Failure, .invalidData) }
        XCTAssertEqual(bridge.requests().count, 0)
        var config = ShareConfiguration(dataDirectory: root, blobDelivery: .direct)
        config.mixtapesEnabled = false
        bridge = MixtapeHTTPBridge(service: try ShareService(config: config), root: root); MixtapeBridgeProtocol.bridge = bridge
        do { _ = try await client.shareMixtape(prepared()); XCTFail() }
        catch { guard case .service(_, "unsupported", _) = error as? ShareClient.Failure else { return XCTFail("expected unsupported") } }
        XCTAssertEqual(bridge.requests().filter { $0.httpMethod == "POST" || $0.httpMethod == "PUT" }.count, 0)
    }
    func testPreparedOrderLimitsConsentAndCanonicalInvitation() throws {
        let prepared = try prepared()
        XCTAssertNil(prepared.request.reviewPreservationConsent)
        XCTAssertNil(prepared.request.preview)
        XCTAssertEqual(try prepared.encodedRequest(), try prepared.encodedRequest(), "Durable retry bytes are stable")
        for count in [1,13] {
            XCTAssertThrowsError(try PreparedMixtape.make(tracks: Array(repeating: .init(audio: Data([1]), metadata: .init(title: "Synthetic", durationSeconds: 10)), count: count), title: "Limits", preview: nil, expiresInSeconds: 86400, playCap: 1, client: .init(platform: "macos", appVersion: "test")))
        }
        XCTAssertThrowsError(try PreparedMixtape.make(tracks: [.init(audio: Data([1]), metadata: .init(title: "A", durationSeconds: 601)), .init(audio: Data([2]), metadata: .init(title: "B", durationSeconds: 600))], title: "Limits", preview: nil, expiresInSeconds: 86400, playCap: 1, client: .init(platform: "macos", appVersion: "test")))
        let twelve = try PreparedMixtape.make(tracks: (0..<12).map { .init(audio: Data([UInt8($0)]), metadata: .init(title: "Track \($0)", durationSeconds: 1)) }, title: "Twelve", preview: .init(title: "Only container", from: "Synthetic"), expiresInSeconds: 86400, playCap: 1, client: .init(platform: "macos", appVersion: "test"), reviewPreservationConsent: "review-v1")
        XCTAssertEqual(twelve.manifest.tracks.count, 12)
        XCTAssertEqual(twelve.request.reviewPreservationConsent, "review-v1")
        XCTAssertEqual(twelve.request.preview?.title, "Only container")
        var limits = ShareLimits.standard; limits.maxAudioBytes = 100
        XCTAssertThrowsError(try PreparedMixtape.make(tracks: [.init(audio: Data(repeating: 1, count: 30), metadata: .init(title: "A", durationSeconds: 1)), .init(audio: Data(repeating: 2, count: 30), metadata: .init(title: "B", durationSeconds: 1))], title: "Encrypted overhead", preview: nil, expiresInSeconds: 86400, playCap: 1, client: .init(platform: "macos", appVersion: "test"), limits: limits))
        let invitation = ShareInvitation(id: Base64URL.encode(Data(repeating: 7, count: 16)), key: prepared.key, kind: .mixtape)
        XCTAssertEqual(ShareInvitation(url: invitation.url())?.kind, .mixtape)
        XCTAssertEqual(invitation.browserURL.path, "/m/" + invitation.id)
        XCTAssertTrue(invitation.browserURL.fragment == Base64URL.encode(prepared.key))
        XCTAssertNil(ShareInvitation(url: invitation.browserURL))
        XCTAssertFalse(invitation.description.contains(Base64URL.encode(prepared.key)))
        for prefix in ["https://foreign.invalid/m/", "https://batonmusic.app/m/%41", "https://user@batonmusic.app/m/"] { XCTAssertNil(ShareInvitation(url: URL(string: prefix + invitation.id)!)) }
        XCTAssertEqual(ShareInvitation(url: URL(string: "baton://mixtape/" + invitation.id)!)?.kind, .mixtape)
    }
}
