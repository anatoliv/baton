@testable import BatonMobile
import BatonShareKit
import Foundation
import XCTest

@MainActor
final class MixtapeBackgroundUploadTests: XCTestCase {
    private var directory: URL!
    private var caseDirectory: URL!
    private var engine: BackgroundShareUploadEngine!
    private var configuration: URLSessionConfiguration!
    private let base = URL(string: "https://batonmusic.app")!
    private let secret = Base64URL.encode(Data(repeating: 31, count: 32))
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mixtape-native-" + UUID().uuidString)
        configuration = .ephemeral; configuration.protocolClasses = [MixtapeUploadProtocol.self]
        caseDirectory = directory
        MixtapeUploadProtocol.reset()
    }
    override func tearDownWithError() throws {
        MixtapeUploadProtocol.release(); engine = nil
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private func makeEngine() {
        let fixtureSecret = secret
        engine = BackgroundShareUploadEngine(directory: caseDirectory.appendingPathComponent("jobs"), ledgerURL: caseDirectory.appendingPathComponent("ledger.json"),
            configuration: configuration, secretProvider: { fixtureSecret })
    }
    private func prepared() throws -> PreparedMixtape {
        try .make(tracks: [.init(audio: Data("ordered second".utf8), metadata: .init(title: "Second", durationSeconds: 2)),
                          .init(audio: Data("ordered first".utf8), metadata: .init(title: "First", durationSeconds: 3))],
                  title: "Native order", preview: nil, expiresInSeconds: 86400, playCap: 2, client: .init(platform: "ios", appVersion: "synthetic"))
    }
    private func client() -> ShareClient {
        ShareClient(base: base, secret: secret, session: URLSession(configuration: configuration))
    }
    func testOrderedFileDispatchHandsOffOnlyThisProtectedJob() async throws {
        makeEngine()
        let prepared = try prepared()
        MixtapeUploadProtocol.configure(prepared, hold: true)
        let handoff = expectation(description: "owned upload handed off")
        var handoffs = 0
        engine.onCreated = { XCTAssertEqual(handoffs, 0) }
        let upload = Task { @MainActor in
            try await engine.enqueue(prepared, client: client(), songIDs: ["second", "first"], onHandOff: {
                handoffs += 1
                guard let job = try? self.engine.store.load().jobs.first else { XCTFail("protected ticket required"); return }
                XCTAssertEqual(job.mixtapeCreated?.id, MixtapeUploadProtocol.id)
                XCTAssertEqual(job.record.songIDs, ["second", "first"])
                for body in job.bodies {
                    XCTAssertEqual((try? Data(contentsOf: self.engine.store.file(job.id, kind: body.kind)))?.count, body.bytes)
                }
                handoff.fulfill()
            })
        }
        await fulfillment(of: [handoff], timeout: 5)
        XCTAssertEqual(handoffs, 1)
        MixtapeUploadProtocol.release()
        let record = try await upload.value
        XCTAssertEqual(record.containerKind, .mixtape)
        XCTAssertEqual(record.songIDs, ["second", "first"])
        XCTAssertEqual(ShareInvitation(url: URL(string: record.link)!)?.key, prepared.key)
        XCTAssertEqual(MixtapeUploadProtocol.uploadOrder(), prepared.manifest.tracks.map(\.id))
        XCTAssertEqual(MixtapeUploadProtocol.count("POST", "/v1/share/mixtapes"), 1)
        XCTAssertEqual(MixtapeUploadProtocol.count("POST", "/v1/share/mixtapes/\(record.id)/finalize"), 1)
        XCTAssertEqual(ShareLedger.load(from: engine.store.ledgerURL).records.count, 1)
        XCTAssertTrue(try engine.store.load().jobs.isEmpty)
    }
    func testCompletionReturnsMixtapeWhenSongUsesTheSameRawID() async throws {
        makeEngine()
        let prepared = try prepared(), songKey = Data(repeating: 18, count: 16)
        MixtapeUploadProtocol.configure(prepared)
        var ledger = ShareLedger()
        ledger.add(.init(id: MixtapeUploadProtocol.id,
            link: ShareInvitation(id: MixtapeUploadProtocol.id, key: songKey).url().absoluteString,
            songID: "other-song", title: "Different song", artist: "Synthetic", isPrivate: true,
            createdAt: Date(), expiresAt: Date() + 86400))
        try BackgroundShareUploadStore.saveLedger(ledger, to: engine.store.ledgerURL)
        let record = try await engine.enqueue(prepared, client: client(), songIDs: ["second", "first"])
        XCTAssertEqual(record.containerKind, .mixtape)
        XCTAssertEqual(ShareInvitation(url: URL(string: record.link)!)?.key, prepared.key)
        let records = ShareLedger.load(from: engine.store.ledgerURL).records
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.containerKind)), Set([.song, .mixtape]))
        let song = try XCTUnwrap(records.first(where: { $0.containerKind == .song }))
        XCTAssertEqual(ShareInvitation(url: URL(string: song.link)!)?.key, songKey)
    }
    func testCorruptOwnerReadyResponseKeepsRecoverableTicketWithoutReceipt() async throws {
        for corruption in ["identity", "count", "hold"] {
            caseDirectory = directory.appendingPathComponent(corruption)
            makeEngine(); MixtapeUploadProtocol.reset()
            let prepared = try prepared()
            MixtapeUploadProtocol.configure(prepared, loss: "finalizeOnly", corruptOwner: corruption)
            do {
                _ = try await engine.enqueue(prepared, client: client(), songIDs: ["second", "first"])
                XCTFail("A corrupt or held ownership response cannot complete this upload")
            } catch {}
            XCTAssertTrue(ShareLedger.load(from: engine.store.ledgerURL).records.isEmpty)
            XCTAssertTrue(BackgroundShareUploadStore.receipts(at: engine.store.ledgerURL).isEmpty)
            do {
                let retained = try XCTUnwrap(engine.store.load().jobs.first)
                XCTAssertNil(retained.mixtapeFinalized, "refuse before persisting an untrusted completion checkpoint")
                XCTAssertEqual(retained.key, prepared.key)
                XCTAssertEqual(retained.mixtapeCreated?.id, MixtapeUploadProtocol.id)
            } catch { XCTFail("The protected ticket must remain readable and recoverable") }
            MixtapeUploadProtocol.allowResponses()
            let recovered = expectation(description: "valid owner response resolves retained job")
            engine = nil; makeEngine()
            engine.onLedgerChanged = { ledger in
                if ledger.records.count == 1 { recovered.fulfill() }
            }
            await engine.restore()
            await fulfillment(of: [recovered], timeout: 5)
            XCTAssertEqual(ShareLedger.load(from: engine.store.ledgerURL).records.count, 1)
            XCTAssertEqual(MixtapeUploadProtocol.count("POST", "/v1/share/mixtapes"), 1)
        }
    }
    func testExplicitRetryReturnsTheContainerCompletedDuringRestore() async throws {
        makeEngine()
        let prepared = try prepared()
        MixtapeUploadProtocol.configure(prepared, loss: "finalize")
        do {
            _ = try await engine.enqueue(prepared, client: client(), songIDs: ["second", "first"])
            XCTFail("The lost finalize and owner responses must remain recoverable")
        } catch {}
        let retained = try XCTUnwrap(engine.store.load().jobs.first)
        MixtapeUploadProtocol.allowResponses()
        let recovered = try await engine.resumeMixtape(retained.id)
        XCTAssertEqual(recovered.containerKind, .mixtape)
        XCTAssertEqual(recovered.id, MixtapeUploadProtocol.id)
        XCTAssertEqual(ShareInvitation(url: URL(string: recovered.link)!)?.key, prepared.key)
        XCTAssertEqual(ShareLedger.load(from: engine.store.ledgerURL).records.count, 1)
        XCTAssertEqual(BackgroundShareUploadStore.receipts(at: engine.store.ledgerURL).count, 1)
        XCTAssertTrue(try engine.store.load().jobs.isEmpty)
        XCTAssertEqual(MixtapeUploadProtocol.count("POST", "/v1/share/mixtapes"), 1)
        XCTAssertEqual(MixtapeUploadProtocol.count("POST", "/v1/share/mixtapes/\(recovered.id)/finalize"), 1)
        await engine.restore()
        XCTAssertEqual(ShareLedger.load(from: engine.store.ledgerURL).records.count, 1)
    }
    func testCorruptPendingOwnerResponseCannotMutateOrRedispatchProtectedJob() async throws {
        for corruption in ["identity", "count"] {
            caseDirectory = directory.appendingPathComponent("pending-" + corruption)
            makeEngine(); MixtapeUploadProtocol.reset()
            let prepared = try prepared()
            MixtapeUploadProtocol.configure(prepared, loss: "pendingOwner", corruptOwner: corruption)
            var staged: BackgroundShareUploadStore.Job?
            do {
                _ = try await engine.enqueue(prepared, client: client(), songIDs: ["second", "first"], onHandOff: {
                    staged = try? self.engine.store.load().jobs.first
                })
                XCTFail("A mismatched pending owner response must leave the upload unresolved")
            } catch {}
            let original = try XCTUnwrap(staged)
            let retained = try XCTUnwrap(engine.store.load().jobs.first)
            XCTAssertEqual(retained.id, original.id)
            XCTAssertEqual(retained.key, original.key)
            XCTAssertEqual(retained.createBody, original.createBody)
            XCTAssertEqual(retained.attempts, original.attempts)
            XCTAssertEqual(retained.record.expiresAt, original.record.expiresAt)
            XCTAssertNil(retained.mixtapeFinalized)
            XCTAssertEqual(MixtapeUploadProtocol.uploadOrder().count, 1, "Untrusted owner state cannot authorize another upload")
            XCTAssertEqual(MixtapeUploadProtocol.count("POST", "/v1/share/mixtapes"), 1)
            XCTAssertTrue(ShareLedger.load(from: engine.store.ledgerURL).records.isEmpty)
            XCTAssertTrue(BackgroundShareUploadStore.receipts(at: engine.store.ledgerURL).isEmpty)

            MixtapeUploadProtocol.allowResponses()
            let recovered = try await engine.resumeMixtape(retained.id)
            XCTAssertEqual(recovered.id, MixtapeUploadProtocol.id)
            XCTAssertEqual(recovered.containerKind, .mixtape)
            XCTAssertEqual(ShareInvitation(url: URL(string: recovered.link)!)?.key, prepared.key)
            XCTAssertEqual(ShareLedger.load(from: engine.store.ledgerURL).records.count, 1)
            XCTAssertEqual(BackgroundShareUploadStore.receipts(at: engine.store.ledgerURL).count, 1)
            XCTAssertTrue(try engine.store.load().jobs.isEmpty)
            XCTAssertEqual(MixtapeUploadProtocol.count("POST", "/v1/share/mixtapes"), 1)
        }
    }
    func testLostResponseRelaunchKeepsOneContainerKeyAndReceipt() async throws {
        for phase in ["create", "track", "finalize"] {
            caseDirectory = directory.appendingPathComponent(phase)
            makeEngine()
            MixtapeUploadProtocol.reset()
            let prepared = try prepared()
            MixtapeUploadProtocol.configure(prepared, loss: phase)
            var handoffs = 0
            do { _ = try await engine.enqueue(prepared, client: client(), songIDs: ["second", "first"], onHandOff: { handoffs += 1 }); XCTFail("response is unavailable") }
            catch {}
            let retained = try XCTUnwrap(engine.store.load().jobs.first)
            XCTAssertEqual(retained.key, prepared.key)
            XCTAssertEqual(retained.createBody, try prepared.encodedRequest())
            XCTAssertEqual(handoffs, phase == "create" ? 0 : 1)
            let receipt = expectation(description: "same container resolved after relaunch")
            MixtapeUploadProtocol.allowResponses()
            engine = nil; makeEngine()
            engine.onLedgerChanged = { ledger in
                if ledger.records.contains(where: { $0.id == MixtapeUploadProtocol.id }) { receipt.fulfill() }
            }
            await engine.restore()
            await fulfillment(of: [receipt], timeout: 5)
            await engine.restore()
            let records = ShareLedger.load(from: engine.store.ledgerURL).records
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(ShareInvitation(url: URL(string: records[0].link)!)?.key, prepared.key)
            XCTAssertEqual(records[0].songIDs, ["second", "first"])
            XCTAssertEqual(MixtapeUploadProtocol.count("POST", "/v1/share/mixtapes"), phase == "create" ? 2 : 1)
            XCTAssertTrue(try engine.store.load().jobs.isEmpty)

        }
    }
}

/// Independent HTTP contract fixture, not a second copy of the coordinator.
/// Accepted responses can be lost; ownership exposes pending/ready. No real
/// credential, Apple service, background daemon or TLS claim is involved.
private final class MixtapeUploadProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    static let id = Base64URL.encode(Data(repeating: 29, count: 16))
    nonisolated(unsafe) private static var prepared: PreparedMixtape?
    nonisolated(unsafe) private static var held = [MixtapeUploadProtocol]()
    nonisolated(unsafe) private static var hold = false
    nonisolated(unsafe) private static var loss: String?
    nonisolated(unsafe) private static var corruptOwner: String?
    nonisolated(unsafe) private static var ready = false
    nonisolated(unsafe) private static var accepted = Set<String>()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var order = [String]()
    static func reset() { lock.lock(); prepared = nil; held = []; hold = false; loss = nil; corruptOwner = nil; ready = false; accepted = []; counts = [:]; order = []; lock.unlock() }
    static func configure(_ value: PreparedMixtape, hold: Bool = false, loss: String? = nil, corruptOwner: String? = nil) { lock.lock(); prepared = value; self.hold = hold; self.loss = loss; self.corruptOwner = corruptOwner; lock.unlock() }
    static func release() { lock.lock(); hold = false; let pending = held; held = []; lock.unlock(); for item in pending { item.startLoading() } }
    static func allowResponses() { lock.lock(); loss = nil; corruptOwner = nil; lock.unlock() }
    static func count(_ method: String, _ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[method + " " + path] ?? 0 }
    static func uploadOrder() -> [String] { lock.lock(); defer { lock.unlock() }; return order }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "batonmusic.app" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        Self.lock.lock()
        if method == "PUT", Self.hold { Self.held.append(self); Self.lock.unlock(); return }
        Self.counts[method + " " + path, default: 0] += 1
        let prepared = Self.prepared!, loss = Self.loss
        if method == "PUT", let track = path.split(separator: "/").last { Self.order.append(String(track)); Self.accepted.insert(String(track)) }
        let complete = Self.accepted == Set(prepared.manifest.tracks.map(\.id))
        if path.hasSuffix("/finalize"), complete { Self.ready = true }
        let ready = Self.ready, corruptOwner = Self.corruptOwner
        // A second ownership reply is lost in this case so a broken retry fence
        // fails deterministically instead of opening an unbounded retry loop.
        let pendingOwnerReply = Self.counts["GET /v1/share/mixtapes/" + Self.id, default: 0]
        Self.lock.unlock()
        if (loss == "create" && method == "POST" && path == "/v1/share/mixtapes") ||
           (loss == "track" && method == "PUT") ||
           (loss == "pendingOwner" && method == "GET" && pendingOwnerReply > 1) ||
           (loss == "finalize" && (path.hasSuffix("/finalize") || method == "GET")) ||
           (loss == "finalizeOnly" && path.hasSuffix("/finalize")) {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
        }
        let data: Data, status: Int
        if method == "POST", path == "/v1/share/mixtapes" {
            status = 201; data = try! JSONEncoder().encode(CreateMixtapeResponse(id: Self.id,
                url: "https://batonmusic.app/m/" + Self.id, expiresAt: ShareDate.string(Date() + 86400),
                uploads: Dictionary(uniqueKeysWithValues: prepared.manifest.tracks.map { ($0.id, "/v1/share/mixtapes/\(Self.id)/tracks/\($0.id)") })))
        } else if method == "PUT", loss == "pendingOwner" {
            // An ambiguous transfer result requires an ownership read. The
            // fixture accepted the bytes, but cannot confirm their state here.
            status = 409; data = Data(#"{"code":"state","error":"Transfer state unavailable."}"#.utf8)
        } else if method == "PUT" { status = 200; data = Data(#"{"stored":true}"#.utf8) }
        else if path.hasSuffix("/finalize"), !complete { status = 409; data = Data(#"{"code":"incomplete","error":"pending tracks"}"#.utf8) }
        else {
            status = 200
            let ownerRead = method == "GET"
            let responseID = ownerRead && corruptOwner == "identity" ? Base64URL.encode(Data(repeating: 30, count: 16)) : Self.id
            let responseExpiry = ownerRead && !ready && corruptOwner != nil ? "2099-01-01T00:00:00Z" : ShareDate.string(Date() + 86400)
            data = try! JSONEncoder().encode(MixtapeSummary(share: .init(id: responseID, status: ready ? .ready : .pending,
                createdAt: ShareDate.string(Date()), expiresAt: responseExpiry, playCap: 2,
                preview: nil, stats: .init(), reactions: [], actionRequired: ownerRead && corruptOwner == "hold" ? "review" : nil),
                trackCount: ownerRead && corruptOwner == "count" ? 3 : 2))
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "Content-Length": String(data.count)])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
