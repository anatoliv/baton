import BatonShareKit
import Foundation
import XCTest
@testable import BatonMobile

final class BackgroundShareUploadTests: XCTestCase {
    private var directory: URL!
    private var store: BackgroundShareUploadStore!
    private let base = URL(string: "https://share.invalid")!
    private let shareID = Base64URL.encode(Data(repeating: 2, count: 16))

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("background-share-test-\(UUID())")
        store = BackgroundShareUploadStore(directory: directory.appendingPathComponent("jobs"),
                                           ledgerURL: directory.appendingPathComponent("ledger.json"))
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func prepared(privateMode: Bool = true) throws -> PreparedShare {
        try PreparedShare.make(audio: Data("PLAINTEXT_SONG_DO_NOT_PERSIST".utf8),
                               metadata: ShareMetadata(title: "Synthetic", artist: "Fixture", durationSeconds: 1),
                               isPrivate: privateMode, expiresInSeconds: 86400, playCap: 100,
                               client: ShareClientInfo(platform: "ios", appVersion: "test"),
                               artwork: Data([0xff, 0xd8, 0xff, 1]), card: Data([0xff, 0xd8, 0xff, 2]))
    }
    private func stage() throws -> BackgroundShareUploadStore.Job {
        try store.stage(prepared(), base: base, songID: "fixture", title: "Synthetic", artist: "Fixture")
    }
    private func created() -> CreateShareResponse {
        CreateShareResponse(id: shareID, url: "\(base.absoluteString)/s/\(shareID)",
                            expiresAt: ShareDate.string(Date() + 86400),
                            uploads: .init(audio: "/v1/share/shares/\(shareID)/audio", art: "/v1/share/shares/\(shareID)/art",
                                           card: "/v1/share/shares/\(shareID)/card"))
    }
    private func ready() -> ShareSummary {
        ShareSummary(id: shareID, status: .ready, createdAt: ShareDate.string(Date()),
                     expiresAt: ShareDate.string(Date() + 86400), playCap: 100,
                     preview: nil, stats: ShareStats(), reactions: [])
    }

    func testRelaunchRetainsKeyAndCiphertextWithoutPlaintextSong() throws {
        let prepared = try prepared()
        let job = try store.stage(prepared, base: base, songID: "fixture", title: "Synthetic", artist: "Fixture")
        let reopened = BackgroundShareUploadStore(directory: store.directory, ledgerURL: store.ledgerURL)
        let loaded = try reopened.load()
        XCTAssertEqual(loaded.jobs.count, 1)
        XCTAssertEqual(loaded.jobs[0].key, prepared.key)
        let cipher = try Data(contentsOf: reopened.file(job.id, kind: "audio"))
        XCTAssertEqual(cipher, prepared.sealedAudio)
        XCTAssertEqual(try ShareCrypto.open(cipher, key: loaded.jobs[0].key, purpose: .audio),
                       Data("PLAINTEXT_SONG_DO_NOT_PERSIST".utf8))
        for url in try FileManager.default.contentsOfDirectory(at: reopened.folder(job.id), includingPropertiesForKeys: nil) {
            XCTAssertNil(try Data(contentsOf: url).range(of: Data("PLAINTEXT_SONG_DO_NOT_PERSIST".utf8)))
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
        }
        let mode = try FileManager.default.attributesOfItem(atPath: reopened.folder(job.id).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
    }

    func testUploadBoundaryPersistsProgressAndDoesNotCreateAgain() throws {
        var job = try stage()
        try store.attach(created(), to: &job)
        job.completedKinds.insert("audio")
        job.attempts["audio"] = 1
        try store.save(job)
        let restored = try XCTUnwrap(store.load().jobs.first)
        XCTAssertEqual(restored.created?.id, shareID)
        XCTAssertEqual(restored.nextKind, "art")
        XCTAssertEqual(restored.attempts["audio"], 1)
        XCTAssertEqual(ShareLink(url: URL(string: restored.record.link)!, allowedHosts: nil)?.key, restored.key)
    }

    func testLostCreateResponseIsNotAnUploadOrAutomaticCreateRetry() throws {
        let job = try stage()
        let restored = try XCTUnwrap(store.load().jobs.first)
        XCTAssertEqual(restored.id, job.id)
        XCTAssertNil(restored.created)
        XCTAssertNil(restored.nextKind)
        XCTAssertEqual(restored.record.id, "")
    }

    func testCorruptTicketAndInterruptedStagingAreOrphans() throws {
        let job = try stage()
        try Data("invalid".utf8).write(to: store.folder(job.id).appendingPathComponent("ticket.json"))
        let interrupted = UUID()
        try FileManager.default.createDirectory(at: store.folder(interrupted), withIntermediateDirectories: true)
        let loaded = try store.load()
        XCTAssertTrue(loaded.jobs.isEmpty)
        XCTAssertEqual(Set(loaded.orphans), [job.id, interrupted])
    }

    func testLostFinalizeCommitReplaysWithoutDuplicateLedgerRows() throws {
        var job = try stage()
        try store.attach(created(), to: &job)
        job.finalized = ready()
        try store.save(job)
        _ = try store.commit(job) // Simulate termination before ticket removal.
        let restored = try XCTUnwrap(store.load().jobs.first)
        let ledger = try store.commit(restored)
        XCTAssertEqual(ledger.records.count, 1)
        XCTAssertEqual(ledger.records[0].summary?.status, .ready)
        XCTAssertEqual(ShareLink(url: URL(string: ledger.records[0].link)!, allowedHosts: nil)?.key, job.key)
        try store.remove(job.id)
        XCTAssertTrue(try store.load().jobs.isEmpty)
    }

    func testFailureReceiptSurvivesUiSaveAndOnlyCountsOnce() throws {
        var job = try stage()
        job.failure = "network"
        try store.save(job)
        var ledger = try store.commit(job)
        XCTAssertEqual(ledger.pendingFailures.count, 1)
        ledger.noteFailure("transcode")
        try BackgroundShareUploadStore.saveLedger(ledger, to: store.ledgerURL)
        ledger = try store.commit(try XCTUnwrap(store.load().jobs.first))
        XCTAssertEqual(ledger.pendingFailures.map(\.reason), ["network", "transcode"])
        try store.remove(job.id)
        XCTAssertTrue(try store.load().jobs.isEmpty)
    }

    func testUnreadableTicketDoesNotBecomeAnOrphanOrDeleteItsPayload() throws {
        let job = try stage()
        let ticket = store.folder(job.id).appendingPathComponent("ticket.json")
        try FileManager.default.removeItem(at: ticket)
        try FileManager.default.createDirectory(at: ticket, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.file(job.id, kind: "audio").path))
    }

    func testForeignOriginUploadIsRejectedBeforeCredentialRequest() throws {
        var job = try stage()
        var response = created()
        response.uploads.audio = "https://foreign.invalid/upload"
        XCTAssertThrowsError(try store.attach(response, to: &job))
        XCTAssertNil(job.created)
    }

    func testEmptyOrLegacyLedgerRemainsCompatibleWithReceiptFormat() throws {
        var ledger = ShareLedger()
        ledger.noteFailure("network")
        try ledger.save(to: store.ledgerURL)
        XCTAssertTrue(BackgroundShareUploadStore.receipts(at: store.ledgerURL).isEmpty)
        try BackgroundShareUploadStore.saveLedger(ledger, to: store.ledgerURL)
        XCTAssertEqual(ShareLedger.load(from: store.ledgerURL), ledger)
    }
}

/// Exercise the real URLSession delegate state machine using a local protocol
/// fixture. This proves retries/reconciliation, not device suspension scheduling.
@MainActor
final class BackgroundShareUploadEngineTests: XCTestCase {
    private var directory: URL!
    private var engine: BackgroundShareUploadEngine!
    private var config: URLSessionConfiguration!
    private let base = URL(string: "https://share.invalid")!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("background-share-engine-test-\(UUID())")
        config = .ephemeral
        config.protocolClasses = [BackgroundShareProtocolFixture.self]
        BackgroundShareProtocolFixture.reset()
        engine = BackgroundShareUploadEngine(directory: directory.appendingPathComponent("jobs"),
                                            ledgerURL: directory.appendingPathComponent("ledger.json"),
                                            configuration: config, secretProvider: { "fixture-install-secret" })
    }
    override func tearDownWithError() throws {
        engine = nil
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private func prepared() throws -> PreparedShare {
        try PreparedShare.make(audio: Data("SYNTHETIC_SONG".utf8),
                               metadata: ShareMetadata(title: "Fixture", durationSeconds: 1), isPrivate: true,
                               expiresInSeconds: 86400, playCap: 100,
                               client: ShareClientInfo(platform: "ios", appVersion: "test"))
    }

    func testHandOffIsPerJobAfterDurabilityAndNotUnlockedByAnotherPendingUpload() async throws {
        BackgroundShareProtocolFixture.holdAudio(true)
        defer { BackgroundShareProtocolFixture.holdAudio(false) }
        var firstSignals = 0
        engine.onCreated = {
            XCTAssertEqual(firstSignals, 0, "create acknowledgement precedes task handoff")
        }
        let client = ShareClient(base: base, secret: "fixture-install-secret")
        let prepared = try prepared()
        let first = Task { @MainActor in
            try await engine.enqueue(prepared, client: client, songID: "first", title: "First", artist: "",
                onHandOff: {
                    firstSignals += 1
                    let job = try? self.engine.store.load().jobs.first
                    XCTAssertNotNil(job?.created)
                    if let job {
                        XCTAssertTrue(FileManager.default.fileExists(atPath: self.engine.store.file(job.id, kind: "audio").path))
                    }
                })
        }
        for _ in 0..<150 where firstSignals == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(firstSignals, 1)
        XCTAssertEqual(try engine.store.load().jobs.count, 1)
        var rejectedSignals = 0
        var sawTwoPendingJobs = false
        engine.onCreated = nil
        engine.onPendingChanged = { count in
            if count == 2 { sawTwoPendingJobs = true }
            XCTAssertEqual(rejectedSignals, 0, "another pending upload cannot unlock this rejected invocation")
        }
        BackgroundShareProtocolFixture.failCreates(status: 401)
        do {
            _ = try await engine.enqueue(prepared, client: client, songID: "rejected", title: "Rejected", artist: "",
                                         onHandOff: { rejectedSignals += 1 })
            XCTFail("the synthetic create must reject")
        } catch {}
        XCTAssertTrue(sawTwoPendingJobs)
        XCTAssertEqual(rejectedSignals, 0)
        XCTAssertEqual(ShareLedger.load(from: engine.store.ledgerURL).pendingFailures.count, 1)
        engine.onPendingChanged = nil
        BackgroundShareProtocolFixture.holdAudio(false)
        _ = try await first.value
        XCTAssertEqual(firstSignals, 1)
        let ledger = ShareLedger.load(from: engine.store.ledgerURL)
        XCTAssertEqual(ledger.records.count, 1)
        XCTAssertEqual(ledger.pendingFailures.count, 1)
        XCTAssertEqual(BackgroundShareUploadStore.receipts(at: engine.store.ledgerURL).count, 2)
        XCTAssertTrue(try engine.store.load().jobs.isEmpty)
    }

    func testIsolatedUploadConfigurationDoesNotMoveCreateOrOwnershipReads() async throws {
        let upload = URLSessionConfiguration.ephemeral
        upload.protocolClasses = [BackgroundShareProtocolFixture.self]
        upload.httpAdditionalHeaders = ["X-Upload-Fixture": "separate-upload-session"]
        engine = BackgroundShareUploadEngine(directory: directory.appendingPathComponent("jobs"),
            ledgerURL: directory.appendingPathComponent("ledger.json"), configuration: config,
            backgroundConfiguration: upload, secretProvider: { "fixture-install-secret" })
        let record = try await engine.enqueue(prepared(), client: ShareClient(base: base, secret: "fixture-install-secret"),
                                             songID: "fixture", title: "Fixture", artist: "")
        XCTAssertEqual(record.summary?.status, .ready)
        XCTAssertEqual(BackgroundShareProtocolFixture.uploadMarkers("POST", "/v1/share/shares"), [""])
        XCTAssertEqual(BackgroundShareProtocolFixture.uploadMarkers("GET", "/v1/share/shares"), [""])
        XCTAssertEqual(BackgroundShareProtocolFixture.uploadMarkers("PUT", BackgroundShareProtocolFixture.audioPath),
                       ["separate-upload-session", "separate-upload-session"])
        XCTAssertEqual(BackgroundShareProtocolFixture.uploadMarkers("POST", BackgroundShareProtocolFixture.finalizePath),
                       ["separate-upload-session"])
        XCTAssertEqual(ShareLedger.load(from: engine.store.ledgerURL).records.count, 1)
        XCTAssertTrue(try engine.store.load().jobs.isEmpty)
    }

    func testLostUploadAndFinalizeResponsesReconcileWithoutSecondCreate() async throws {
        let record = try await engine.enqueue(prepared(), client: ShareClient(base: base, secret: "fixture-install-secret"),
                                               songID: "fixture", title: "Fixture", artist: "")
        XCTAssertEqual(record.summary?.status, .ready)
        XCTAssertEqual(BackgroundShareProtocolFixture.count("POST", "/v1/share/shares"), 1)
        XCTAssertEqual(BackgroundShareProtocolFixture.count("PUT", BackgroundShareProtocolFixture.audioPath), 2)
        XCTAssertEqual(BackgroundShareProtocolFixture.count("POST", BackgroundShareProtocolFixture.finalizePath), 1)
        XCTAssertEqual(BackgroundShareProtocolFixture.count("GET", "/v1/share/shares"), 1)
        XCTAssertTrue(try engine.store.load().jobs.isEmpty)
        XCTAssertEqual(ShareLedger.load(from: engine.store.ledgerURL).records.count, 1)
    }

    func testUnmeasurableFinalizationRetainsKeyUntilNextLaunchResolvesIt() async throws {
        BackgroundShareProtocolFixture.loseAllFinalizeResponses()
        do {
            _ = try await engine.enqueue(prepared(), client: ShareClient(base: base, secret: "fixture-install-secret"),
                                         songID: "fixture", title: "Fixture", artist: "")
            XCTFail("An unmeasurable finalize should leave a durable ticket")
        } catch { }
        let pending = try XCTUnwrap(engine.store.load().jobs.first)
        XCTAssertEqual(pending.nextKind, "finalize")
        XCTAssertNil(pending.failure)
        XCTAssertEqual(BackgroundShareProtocolFixture.count("POST", "/v1/share/shares"), 1)
        XCTAssertEqual(BackgroundShareProtocolFixture.count("POST", BackgroundShareProtocolFixture.finalizePath), 3)
        BackgroundShareProtocolFixture.allowOwnershipRead()
        await engine.restore()
        let record = try XCTUnwrap(ShareLedger.load(from: engine.store.ledgerURL).records.first)
        XCTAssertEqual(ShareLink(url: URL(string: record.link)!, allowedHosts: nil)?.key, pending.key)
        XCTAssertEqual(BackgroundShareProtocolFixture.count("POST", "/v1/share/shares"), 1)
        XCTAssertTrue(try engine.store.load().jobs.isEmpty)
    }

    func testRelaunchWithUnacknowledgedFinalizeRestoresSameLinkOnce() async throws {
        var job = try engine.store.stage(prepared(), base: base, songID: "fixture", title: "Fixture", artist: "")
        try engine.store.attach(BackgroundShareProtocolFixture.created(), to: &job)
        job.completedKinds = ["audio"]
        job.attempts["finalize"] = 1
        try engine.store.save(job)
        await engine.restore()
        await engine.restore()
        let ledger = ShareLedger.load(from: engine.store.ledgerURL)
        XCTAssertEqual(ledger.records.count, 1)
        XCTAssertEqual(ShareLink(url: URL(string: ledger.records[0].link)!, allowedHosts: nil)?.key, job.key)
        XCTAssertEqual(BackgroundShareProtocolFixture.count("POST", "/v1/share/shares"), 0)
        XCTAssertEqual(BackgroundShareProtocolFixture.count("POST", BackgroundShareProtocolFixture.finalizePath), 0)
        XCTAssertTrue(try engine.store.load().jobs.isEmpty)
    }

    func testSignedLostCreateTicketReplaysExactBodyAndProofAfterRelaunch() async throws {
        var job = try engine.store.stage(prepared(), base: base, songID: "fixture", title: "Fixture", artist: "")
        let body = try JSONEncoder().encode(prepared().request)
        let proof = ShareAttestationProof(keyID: Data(repeating: 8, count: 32).base64EncodedString(),
            challengeID: UUID().uuidString, requestID: job.id.uuidString, assertion: Data([1,2,3]).base64EncodedString())
        job.createBody = body; job.createProof = proof
        try engine.store.save(job)
        let originalKey = job.key
        BackgroundShareProtocolFixture.failCreates(status: 503)
        await engine.restore()
        XCTAssertEqual(try engine.store.load().jobs.first?.key, originalKey)
        XCTAssertTrue(ShareLedger.load(from: engine.store.ledgerURL).pendingFailures.isEmpty)
        // Simulate termination after a signed create's unknown result, then re-open.
        engine = BackgroundShareUploadEngine(directory: engine.store.directory, ledgerURL: engine.store.ledgerURL,
            configuration: config, secretProvider: { "fixture-install-secret" })
        BackgroundShareProtocolFixture.failCreates(status: nil)
        await engine.restore()
        for _ in 0..<100 where ShareLedger.load(from: engine.store.ledgerURL).records.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        await engine.restore()
        let record = try XCTUnwrap(ShareLedger.load(from: engine.store.ledgerURL).records.first)
        XCTAssertEqual(ShareLink(url: URL(string: record.link)!, allowedHosts: nil)?.key, originalKey)
        XCTAssertEqual(BackgroundShareProtocolFixture.count("POST", "/v1/share/shares"), 2)
        XCTAssertEqual(BackgroundShareProtocolFixture.signedHeaders(), [try proof.headerValue(), try proof.headerValue()])
        XCTAssertTrue(try engine.store.load().jobs.isEmpty)
    }

    func testRejectedSignedCreateCleansTicketAndRecordsOnlyOneFailure() async throws {
        var job = try engine.store.stage(prepared(), base: base, songID: "fixture", title: "Fixture", artist: "")
        job.createBody = try JSONEncoder().encode(prepared().request)
        job.createProof = .init(keyID: "fixture", challengeID: "fixture", requestID: job.id.uuidString, assertion: "fixture")
        try engine.store.save(job)
        BackgroundShareProtocolFixture.failCreates(status: 401)
        await engine.restore(); await engine.restore()
        XCTAssertEqual(BackgroundShareProtocolFixture.count("POST", "/v1/share/shares"), 1)
        XCTAssertEqual(ShareLedger.load(from: engine.store.ledgerURL).pendingFailures.count, 1)
        XCTAssertTrue(try engine.store.load().jobs.isEmpty)
    }

    func testRelaunchWithLostCreateResponseCountsFailureOnceAndDoesNotRetryCreate() async throws {
        _ = try engine.store.stage(prepared(), base: base, songID: "fixture", title: "Fixture", artist: "")
        await engine.restore()
        await engine.restore()
        XCTAssertEqual(ShareLedger.load(from: engine.store.ledgerURL).pendingFailures.map(\.reason), ["network"])
        XCTAssertEqual(BackgroundShareProtocolFixture.count("POST", "/v1/share/shares"), 0)
        XCTAssertTrue(try engine.store.load().jobs.isEmpty)
    }
}

private final class BackgroundShareProtocolFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var heldAudio: [BackgroundShareProtocolFixture] = []
    nonisolated(unsafe) private static var shouldHoldAudio = false
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var markers: [String: [String]] = [:]
    nonisolated(unsafe) private static var createStatus: Int?
    nonisolated(unsafe) private static var headers: [String] = []
    nonisolated(unsafe) private static var loseFinalization = false
    nonisolated(unsafe) private static var failOwnershipRead = false
    static let id = Base64URL.encode(Data(repeating: 9, count: 16))
    static var audioPath: String { "/v1/share/shares/\(id)/audio" }
    static var finalizePath: String { "/v1/share/shares/\(id)/finalize" }
    static func reset() { lock.lock(); heldAudio = []; shouldHoldAudio = false; counts = [:]; markers = [:]; headers = []; createStatus = nil; loseFinalization = false; failOwnershipRead = false; lock.unlock() }
    static func holdAudio(_ value: Bool) {
        lock.lock()
        shouldHoldAudio = value
        let pending = value ? [] : heldAudio
        if !value { heldAudio = [] }
        lock.unlock()
        for task in pending { task.startLoading() }
    }
    static func failCreates(status: Int?) { lock.lock(); createStatus = status; lock.unlock() }
    static func signedHeaders() -> [String] { lock.lock(); defer { lock.unlock() }; return headers }
    static func loseAllFinalizeResponses() { lock.lock(); loseFinalization = true; failOwnershipRead = true; lock.unlock() }
    static func allowOwnershipRead() { lock.lock(); failOwnershipRead = false; lock.unlock() }
    static func uploadMarkers(_ method: String, _ path: String) -> [String] {
        lock.lock(); defer { lock.unlock() }; return markers[method + " " + path] ?? []
    }
    static func count(_ method: String, _ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }; return counts[method + " " + path] ?? 0
    }
    static func created() -> CreateShareResponse {
        CreateShareResponse(id: id, url: "https://share.invalid/s/\(id)", expiresAt: ShareDate.string(Date() + 86400),
                            uploads: .init(audio: audioPath, art: "/v1/share/shares/\(id)/art", card: "/v1/share/shares/\(id)/card"))
    }
    private static func ready() -> ShareSummary {
        ShareSummary(id: id, status: .ready, createdAt: ShareDate.string(Date()), expiresAt: ShareDate.string(Date() + 86400),
                     playCap: 100, preview: nil, stats: ShareStats(), reactions: [])
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "share.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let method = request.httpMethod ?? "GET"
        let key = method + " " + path
        Self.lock.lock()
        if path == Self.audioPath && Self.shouldHoldAudio {
            Self.heldAudio.append(self)
            Self.lock.unlock()
            return
        }
        Self.counts[key, default: 0] += 1
        Self.markers[key, default: []].append(request.value(forHTTPHeaderField: "X-Upload-Fixture") ?? "")
        let attempt = Self.counts[key]!
        let createStatus = Self.createStatus
        if path == "/v1/share/shares", method == "POST", let proof = request.value(forHTTPHeaderField: ShareAttestationProof.header) { Self.headers.append(proof) }
        let loseFinalization = Self.loseFinalization
        let failOwnershipRead = Self.failOwnershipRead
        Self.lock.unlock()
        if (path == Self.finalizePath && loseFinalization) || (path == "/v1/share/shares" && method == "GET" && failOwnershipRead) {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        // The service accepted the first audio/finalize but the client never got
        // the response. The next attempt gets the real service's conflict body.
        if (path == Self.audioPath || path == Self.finalizePath) && attempt == 1 {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let status: Int
        let data: Data
        if path == "/v1/share/shares", method == "POST" {
            status = createStatus ?? 201; data = try! JSONEncoder().encode(Self.created())
        } else if path == "/v1/share/shares", method == "GET" {
            status = 200; data = try! JSONEncoder().encode(ShareList(shares: [Self.ready()]))
        } else if path == Self.audioPath {
            status = 409; data = Data(#"{"code":"state","error":"The audio is already uploaded."}"#.utf8)
        } else if path == Self.finalizePath {
            status = 409; data = Data(#"{"code":"state","error":"This share is already ready."}"#.utf8)
        } else {
            status = 200; data = Data(#"{"ok":true}"#.utf8)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                             httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.lock.lock(); Self.heldAudio.removeAll { $0 === self }; Self.lock.unlock()
    }
}
