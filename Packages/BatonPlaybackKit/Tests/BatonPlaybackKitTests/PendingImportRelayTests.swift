import Foundation
import XCTest
@testable import BatonPlaybackKit

/// "Send to my Mac" through the gateway's file store: the phone parks a document,
/// a Mac picks it up exactly once, and finishing removes everything it left on the gateway.
///
/// The stand-in speaks the gateway's real `/v1/files` rules (`gateway/.../FileStore.swift` and
/// `GatewayRoutes.file`): ids are hex and dashes, a `PUT` replaces, a `GET` of nothing is 404, a
/// `DELETE` is 200 whether or not the file was there, listings are newest first and stamped to the
/// second. `testAgainstARealGateway` runs the same round trip against a running gateway.
final class PendingImportRelayTests: XCTestCase {
    private var dir: URL!
    private var gateway: RelayStandIn!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("baton-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        gateway = RelayStandIn()
    }

    override func tearDownWithError() throws {
        gateway.unregister()
        try? FileManager.default.removeItem(at: dir)
    }

    private func document(_ name: String = "Two Rooms.md", _ text: String = "# Two Rooms\n\nA small room.") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private var mac: String { UUID().uuidString.lowercased() }

    func testTheDocumentTravelsWithoutADigestHeaderAndTheRecordCarriesEverything() async throws {
        let relay = PendingImportRelay(files: gateway.files, settle: .milliseconds(50))
        let file = try document("Café notes.md")
        let sent = try await relay.send(file: file, title: "Café notes", contentType: "text/markdown",
                                        fromDevice: "Anatoli’s iPhone")

        let puts = gateway.requests.filter { $0.method == "PUT" }
        XCTAssertEqual(puts.map(\.path), ["/v1/files/\(sent.id)-d0c", "/v1/files/\(sent.id)"],
                       "the document goes first, then the record that points at it")
        // No digest header on either: the phone's clipping collector takes every file with one.
        XCTAssertTrue(puts.allSatisfy { $0.headers["X-Baton-SHA256"] == nil })
        XCTAssertEqual(puts[0].headers["Content-Type"], "text/markdown")
        XCTAssertEqual(puts[1].headers["Content-Type"], PendingImport.contentType)
        XCTAssertEqual(puts[0].headers["X-Baton-Origin"], "Anatoli_s iPhone", "header values stay ASCII")

        let listing = try await gateway.files.list()
        XCTAssertTrue(listing.allSatisfy { $0.sha256 == nil }, "nothing the relay stores looks like a clipping")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(PendingImport.self, from: gateway.body(of: sent.id))
        XCTAssertEqual(record.title, "Café notes")
        XCTAssertEqual(record.filename, "Café notes.md")
        XCTAssertEqual(record.kind, "md")
        XCTAssertEqual(record.fromDevice, "Anatoli’s iPhone")
        XCTAssertEqual(record.documentID, "\(sent.id)-d0c")
        XCTAssertEqual(record.sha256, try GatewayFiles.sha256(of: file))
        XCTAssertNil(record.link)
    }

    func testALinkTravelsAsTheRecordAlone() async throws {
        let relay = PendingImportRelay(files: gateway.files, settle: .milliseconds(50))
        let sent = try await relay.send(link: URL(string: "https://example.com/essay")!, title: "An essay", fromDevice: "iPhone")
        XCTAssertEqual(gateway.requests.filter { $0.method == "PUT" }.count, 1)
        let mac = self.mac
        let held = try await relay.claim(as: mac)
        XCTAssertEqual(held, [sent.id])
        let fetched = try await relay.fetch(sent.id, into: dir.appendingPathComponent("in"))
        XCTAssertNil(fetched.file)
        XCTAssertEqual(fetched.record.link, "https://example.com/essay")
        XCTAssertEqual(fetched.record.kind, "link")
    }

    /// The Mac reads the page itself and needs no fragment, and a fragment can be a key: a Baton
    /// share link's is the song's. It never reaches the gateway.
    func testALinkTravelsWithoutItsFragment() async throws {
        let relay = PendingImportRelay(files: gateway.files, settle: .milliseconds(50))
        let sent = try await relay.send(link: URL(string: "https://example.com/essay?page=2#a-secret")!, title: "An essay", fromDevice: "iPhone")
        XCTAssertEqual(sent.link, "https://example.com/essay?page=2")
        XCTAssertFalse(String(decoding: gateway.body(of: sent.id), as: UTF8.self).contains("a-secret"))
    }

    /// The round trip: the phone's send, the Mac's claim and fetch, and finishing.
    func testPhoneToMacRoundTripLeavesNothingBehind() async throws {
        let phone = PendingImportRelay(files: gateway.files, settle: .milliseconds(50))
        let file = try document()
        let sent = try await phone.send(file: file, title: "Two Rooms", contentType: "text/markdown", fromDevice: "iPhone")

        let macRelay = PendingImportRelay(files: gateway.files, settle: .milliseconds(50))
        let mac = self.mac
        let held = try await macRelay.claim(as: mac)
        XCTAssertEqual(held, [sent.id])
        let fetched = try await macRelay.fetch(sent.id, into: dir.appendingPathComponent("in"))
        XCTAssertEqual(fetched.record.title, "Two Rooms")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(fetched.file)), try Data(contentsOf: file))
        XCTAssertEqual(fetched.file?.lastPathComponent, "Two Rooms.md")

        // Held again on the next pickup ("Not Now" leaves it), and not claimed twice.
        let again = try await macRelay.claim(as: mac)
        XCTAssertEqual(again, [sent.id])
        XCTAssertEqual(gateway.requests.filter { $0.method == "PUT" && $0.path.hasSuffix("-\(mac)") }.count, 1)

        try await macRelay.finish(sent.id)
        let left = try await gateway.files.list()
        XCTAssertEqual(left, [], "record, document and claim are all gone")
    }

    func testTwoMacsAtOnceTakeItExactlyOnce() async throws {
        let phone = PendingImportRelay(files: gateway.files, settle: .milliseconds(50))
        let sent = try await phone.send(file: try document(), title: "Two Rooms", contentType: "text/markdown", fromDevice: "iPhone")

        for _ in 0..<5 {
            let a = PendingImportRelay(files: gateway.files, settle: .milliseconds(300))
            let b = PendingImportRelay(files: gateway.files, settle: .milliseconds(300))
            let macA = self.mac, macB = self.mac
            async let heldA = a.claim(as: macA)
            async let heldB = b.claim(as: macB)
            let (x, y) = try await (heldA, heldB)
            XCTAssertEqual(x.count + y.count, 1, "exactly one Mac holds it")
            XCTAssertEqual(Set(x + y), [sent.id])
            // The loser took its claim back; the winner's stays.
            let claims = try await gateway.files.list().filter { $0.contentType == PendingImport.claimContentType }
            XCTAssertEqual(claims.count, 1)
            // A third Mac later finds it held and leaves it alone.
            let lateMac = self.mac
            let late = try await PendingImportRelay(files: gateway.files, settle: .milliseconds(50)).claim(as: lateMac)
            XCTAssertEqual(late, [])
            for claim in claims { try await gateway.files.delete(id: claim.id) }
        }
    }

    func testAFinishedRecordIsGoneForTheOtherMac() async throws {
        let phone = PendingImportRelay(files: gateway.files, settle: .milliseconds(50))
        let sent = try await phone.send(file: try document(), title: "Two Rooms", contentType: "text/markdown", fromDevice: "iPhone")
        let relay = PendingImportRelay(files: gateway.files, settle: .milliseconds(50))
        let mac = self.mac
        _ = try await relay.claim(as: mac)
        try await relay.finish(sent.id)
        do {
            _ = try await relay.fetch(sent.id, into: dir.appendingPathComponent("late"))
            XCTFail("a finished record cannot be fetched")
        } catch let GatewayFiles.TransferError.rejected(status, _) {
            XCTAssertEqual(status, 404)
        }
    }

    /// The gateway's own bounds can remove the document before the Mac collects it: the age
    /// limit, or cap eviction, which takes the document first because it was stored first
    /// The record is still there, so the Mac must be told the document is
    /// gone, not handed a plain 404 it would retry every minute.
    func testADocumentTheGatewayAlreadyRemovedReadsAsMissing() async throws {
        let phone = PendingImportRelay(files: gateway.files, settle: .milliseconds(50))
        let sent = try await phone.send(file: try document(), title: "Two Rooms", contentType: "text/markdown", fromDevice: "iPhone")
        gateway.remove("\(sent.id)-d0c")
        let mac = self.mac
        _ = try await phone.claim(as: mac)
        do {
            _ = try await phone.fetch(sent.id, into: dir.appendingPathComponent("in"))
            XCTFail("a record whose document is gone must not be handed over")
        } catch let PendingImportRelay.FetchError.documentMissing(record) {
            XCTAssertEqual(record.id, sent.id)
            XCTAssertEqual(record.title, "Two Rooms")
        }
        // Finishing then clears the orphaned record and the claim, so nothing is retried.
        try await phone.finish(sent.id)
        let left = try await gateway.files.list()
        XCTAssertTrue(left.isEmpty, "left behind: \(left.map(\.id))")
    }

    func testADamagedDocumentIsRefused() async throws {
        let phone = PendingImportRelay(files: gateway.files, settle: .milliseconds(50))
        let sent = try await phone.send(file: try document(), title: "Two Rooms", contentType: "text/markdown", fromDevice: "iPhone")
        gateway.corrupt("\(sent.id)-d0c")
        let mac = self.mac
        _ = try await phone.claim(as: mac)
        do {
            _ = try await phone.fetch(sent.id, into: dir.appendingPathComponent("in"))
            XCTFail("a document that fails its digest must not be handed over")
        } catch GatewayFiles.TransferError.corrupted {}
    }

    /// The same round trip against a running gateway: a local `baton-gateway` or the household's.
    /// Skipped unless `BATON_RELAY_GATEWAY_URL` and `BATON_RELAY_GATEWAY_TOKEN` are set. It leaves
    /// nothing behind: every file it made is deleted, and the listing is checked afterwards.
    func testAgainstARealGateway() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["BATON_RELAY_GATEWAY_URL"].flatMap(URL.init(string:)),
              let token = env["BATON_RELAY_GATEWAY_TOKEN"], !token.isEmpty else {
            throw XCTSkip("set BATON_RELAY_GATEWAY_URL and BATON_RELAY_GATEWAY_TOKEN to run against a real gateway")
        }
        // Each request's method, path and status, printed at the end as evidence. Never the token.
        let recorder = StatusRecorder()
        let session = URLSession(configuration: .ephemeral, delegate: recorder, delegateQueue: nil)
        defer { print("relay statuses:\n" + recorder.lines.joined(separator: "\n")) }
        let files = GatewayFiles(gatewayURL: base, token: token, session: session)
        let phone = PendingImportRelay(files: files)
        let file = try document("Relay test \(UUID().uuidString.prefix(6)).md", "# Relay test\n\nDeleted straight after.")
        let sent = try await phone.send(file: file, title: "Relay test", contentType: "text/markdown", fromDevice: "Relay test")
        var finished = false
        defer {
            if !finished {
                let id = sent.id
                Task { try? await PendingImportRelay(files: files).finish(id) }
            }
        }

        let listed = try await files.list()
        XCTAssertNil(listed.first { $0.id == sent.id }?.sha256, "no digest on the record, so phones do not collect it")
        XCTAssertNil(listed.first { $0.id == "\(sent.id)-d0c" }?.sha256)

        let macA = PendingImportRelay(files: files), macB = PendingImportRelay(files: files)
        let idA = self.mac, idB = self.mac
        async let heldA = macA.claim(as: idA)
        async let heldB = macB.claim(as: idB)
        let (x, y) = try await (heldA, heldB)
        XCTAssertEqual(x.filter { $0 == sent.id }.count + y.filter { $0 == sent.id }.count, 1, "exactly one Mac holds it")

        let fetched = try await macA.fetch(sent.id, into: dir.appendingPathComponent("live"))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(fetched.file)), try Data(contentsOf: file))
        try await macA.finish(sent.id)
        finished = true
        let after = try await files.list()
        XCTAssertFalse(after.contains { $0.id.hasPrefix(sent.id) }, "nothing of the test is left on the gateway")
        do {
            _ = try await macB.fetch(sent.id, into: dir.appendingPathComponent("late"))
            XCTFail("the record should be gone")
        } catch let GatewayFiles.TransferError.rejected(status, _) {
            XCTAssertEqual(status, 404)
        }
    }
}

/// Method, path and status of every finished request, for the live test's evidence.
final class StatusRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var lines: [String] { lock.withLock { recorded } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let method = task.originalRequest?.httpMethod ?? "?"
        let path = task.originalRequest?.url?.path ?? "?"
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        lock.withLock { recorded.append("\(method) \(path) \(status)") }
    }
}

/// The gateway's `/v1/files` routes, in process.
final class RelayStandIn: @unchecked Sendable {
    struct Seen { let method: String; let path: String; let headers: [String: String] }
    private struct Stored { var meta: GatewayFiles.RemoteFile; var body: Data }

    private let lock = NSLock()
    private var stored: [String: Stored] = [:]
    private var seen: [Seen] = []
    let host = "relay-\(UUID().uuidString.lowercased().prefix(8)).test"
    let files: GatewayFiles

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayStandInProtocol.self]
        files = GatewayFiles(gatewayURL: URL(string: "http://\(host)")!, token: "t",
                             session: URLSession(configuration: configuration))
        RelayStandInProtocol.register(self, host: host)
    }

    func unregister() { RelayStandInProtocol.unregister(host: host) }

    var requests: [Seen] { lock.withLock { seen } }
    func body(of id: String) -> Data { lock.withLock { stored[id]?.body ?? Data() } }
    func corrupt(_ id: String) { lock.withLock { stored[id]?.body.append(0x21) } }
    /// What the gateway's age limit or cap eviction does to one file.
    func remove(_ id: String) { lock.withLock { stored[id] = nil } }

    func answer(_ request: URLRequest, body: Data) -> (Int, Data, [String: String]) {
        lock.withLock {
            let method = request.httpMethod ?? "GET"
            let path = request.url?.path ?? ""
            seen.append(Seen(method: method, path: path, headers: request.allHTTPHeaderFields ?? [:]))
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer t" else { return (401, Data(), [:]) }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if path == "/v1/files", method == "GET" {
                let listing = stored.values.map(\.meta).sorted { $0.createdAt > $1.createdAt }
                return (200, try! encoder.encode(listing), [:])
            }
            guard path.hasPrefix("/v1/files/") else { return (404, Data(), [:]) }
            let raw = String(path.dropFirst("/v1/files/".count))
            guard !raw.isEmpty, raw.count <= 128, raw.allSatisfy({ "0123456789abcdefABCDEF-".contains($0) }) else {
                return (400, Data(#"{"error":"bad file id"}"#.utf8), [:])
            }
            let id = raw.lowercased()
            switch method {
            case "PUT":
                // Stamped to the second, as the gateway's ISO-8601 encoder writes it.
                let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
                let meta = GatewayFiles.RemoteFile(
                    id: id, name: request.value(forHTTPHeaderField: "X-Baton-Name") ?? "file",
                    contentType: request.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream",
                    size: body.count, sha256: request.value(forHTTPHeaderField: "X-Baton-SHA256"), createdAt: now,
                    origin: request.value(forHTTPHeaderField: "X-Baton-Origin"))
                stored[id] = Stored(meta: meta, body: body)
                return (201, try! encoder.encode(meta), [:])
            case "DELETE":
                stored[id] = nil
                return (200, Data(#"{"ok":true}"#.utf8), [:])
            default:
                guard let file = stored[id] else { return (404, Data(#"{"error":"no such file"}"#.utf8), [:]) }
                var headers = ["X-Baton-Name": file.meta.name, "Content-Type": file.meta.contentType]
                if let sha = file.meta.sha256 { headers["X-Baton-SHA256"] = sha }
                return (200, file.body, headers)
            }
        }
    }
}

final class RelayStandInProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var standIns: [String: RelayStandIn] = [:]
    private static let lock = NSLock()

    static func register(_ standIn: RelayStandIn, host: String) { lock.withLock { standIns[host] = standIn } }
    static func unregister(host: String) { lock.withLock { standIns[host] = nil } }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock { standIns[request.url?.host ?? ""] != nil }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let standIn = Self.lock.withLock({ Self.standIns[request.url?.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        let (status, data, headers) = standIn.answer(request, body: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
