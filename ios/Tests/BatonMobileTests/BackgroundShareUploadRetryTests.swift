import BatonShareKit
import XCTest
@testable import BatonMobile

/// C-20, C-21 and C-24: what the background upload engine does when a body
/// keeps failing, when no upload can start, and when the service's conflict wording changes.
@MainActor
final class BackgroundShareUploadRetryTests: XCTestCase {
    private var directory: URL!
    private let base = URL(string: "https://retry.invalid")!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("background-share-retry-\(UUID())")
        RetryFixture.reset()
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func engine(secret: @escaping () -> String? = { "fixture-install-secret" }) -> BackgroundShareUploadEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RetryFixture.self]
        return BackgroundShareUploadEngine(directory: directory.appendingPathComponent("jobs"),
                                           ledgerURL: directory.appendingPathComponent("ledger.json"),
                                           configuration: config, secretProvider: secret)
    }

    private func prepared() throws -> PreparedShare {
        try PreparedShare.make(audio: Data("SYNTHETIC_SONG".utf8),
                               metadata: ShareMetadata(title: "Fixture", durationSeconds: 1), isPrivate: true,
                               expiresInSeconds: 86400, playCap: 100,
                               client: ShareClientInfo(platform: "ios", appVersion: "test"))
    }

    /// C-20: three failed audio uploads deleted the ticket, key and all, so a link a later
    /// launch could have finished was lost. The ticket now stays, unfailed, for the next restore.
    func testExhaustedAudioRetriesKeepTheTicketForTheNextLaunch() async throws {
        RetryFixture.mode = .audioAlwaysLost
        let engine = engine()
        do {
            _ = try await engine.enqueue(prepared(), client: ShareClient(base: base, secret: "fixture-install-secret"),
                                         songID: "fixture", title: "Fixture", artist: "")
            XCTFail("an upload that never got through must not report success")
        } catch {}
        XCTAssertEqual(RetryFixture.count("PUT", RetryFixture.audioPath), 3)
        let jobs = try engine.store.load().jobs
        XCTAssertEqual(jobs.count, 1, "the ticket, with its key, is kept")
        XCTAssertNil(jobs.first?.failure)
        XCTAssertEqual(jobs.first?.nextKind, "audio")
        XCTAssertTrue(ShareLedger.load(from: engine.store.ledgerURL).pendingFailures.isEmpty, "not counted as a failure yet")
        XCTAssertEqual(BackgroundShareUploadEngine.retryDelay(attempt: 1), nil)
        XCTAssertEqual(BackgroundShareUploadEngine.retryDelay(attempt: 2), 30)
        XCTAssertEqual(BackgroundShareUploadEngine.retryDelay(attempt: 3), 120)
    }

    /// C-21: with the install secret unreadable after the create (a Keychain still locked), no
    /// upload could start and nothing ever resumed the caller.
    func testACallerIsAnsweredWhenNoUploadCanStart() async throws {
        let engine = engine(secret: { nil })
        let prepared = try prepared()
        var finished = false
        let call = Task { @MainActor in
            defer { finished = true }
            _ = try? await engine.enqueue(prepared, client: ShareClient(base: self.base, secret: "fixture-install-secret"),
                                          songID: "fixture", title: "Fixture", artist: "")
        }
        for _ in 0..<150 where !finished { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(finished, "enqueue never returned")
        if !finished { call.cancel() }
        XCTAssertEqual(try engine.store.load().jobs.count, 1, "the ticket stays for the next restore")
    }

    /// C-24: an upload conflict was recognised by the service's English sentence only. Any other
    /// wording retried the same body until the ticket was failed. A pending share's conflict now
    /// means the body is stored, whatever the words.
    func testAnUploadConflictInOtherWordsStillCountsAsStored() async throws {
        RetryFixture.mode = .audioConflictInOtherWords
        let record = try await engine().enqueue(prepared(), client: ShareClient(base: base, secret: "fixture-install-secret"),
                                                songID: "fixture", title: "Fixture", artist: "")
        XCTAssertEqual(record.summary?.status, .ready)
        XCTAssertEqual(RetryFixture.count("PUT", RetryFixture.audioPath), 1)
        XCTAssertEqual(RetryFixture.count("POST", RetryFixture.finalizePath), 1)
    }
}

private final class RetryFixture: URLProtocol, @unchecked Sendable {
    enum Mode { case audioAlwaysLost, audioConflictInOtherWords }
    private static let lock = NSLock()
    nonisolated(unsafe) static var mode: Mode = .audioAlwaysLost
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    static let id = Base64URL.encode(Data(repeating: 7, count: 16))
    static var audioPath: String { "/v1/share/shares/\(id)/audio" }
    static var finalizePath: String { "/v1/share/shares/\(id)/finalize" }
    static func reset() { lock.lock(); counts = [:]; mode = .audioAlwaysLost; lock.unlock() }
    static func count(_ method: String, _ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[method + " " + path] ?? 0 }

    private static func summary(_ status: ShareStatus) -> ShareSummary {
        ShareSummary(id: id, status: status, createdAt: ShareDate.string(Date()), expiresAt: ShareDate.string(Date() + 86400),
                     playCap: 100, preview: nil, stats: ShareStats(), reactions: [])
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "retry.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        Self.lock.lock(); Self.counts[method + " " + path, default: 0] += 1; let mode = Self.mode; Self.lock.unlock()
        let status: Int, data: Data
        switch (method, path) {
        case ("POST", "/v1/share/shares"):
            status = 201
            data = try! JSONEncoder().encode(CreateShareResponse(
                id: Self.id, url: "https://retry.invalid/s/\(Self.id)", expiresAt: ShareDate.string(Date() + 86400),
                uploads: .init(audio: Self.audioPath, art: "/v1/share/shares/\(Self.id)/art", card: "/v1/share/shares/\(Self.id)/card")))
        case ("PUT", Self.audioPath) where mode == .audioAlwaysLost:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
        case ("PUT", Self.audioPath):
            status = 409; data = Data(#"{"code":"state","error":"Die Audiodatei ist bereits hochgeladen."}"#.utf8)
        case ("GET", "/v1/share/shares"):
            status = 200; data = try! JSONEncoder().encode(ShareList(shares: [Self.summary(.pending)]))
        case ("POST", Self.finalizePath):
            status = 200; data = try! JSONEncoder().encode(Self.summary(.ready))
        default:
            status = 200; data = Data(#"{"ok":true}"#.utf8)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                                             headerFields: ["Content-Type": "application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
