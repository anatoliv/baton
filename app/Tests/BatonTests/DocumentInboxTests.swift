import BatonPlaybackKit
import Foundation
import XCTest
@testable import Baton

/// "Send to my Mac" on the Mac: a document the iPhone parked on the gateway is picked
/// up once, opened for import, and removed from the gateway only when the person imported or
/// discarded it. The gateway is a stand-in speaking the real `/v1/files` rules; the phone's half
/// is the same `PendingImportRelay.send` the iPhone calls.
@MainActor
final class DocumentInboxTests: XCTestCase {
    private var root: URL!
    private var gateway: InboxGatewayStandIn!
    private var documentsOn = true
    private var gatewayUp = true

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        gateway = InboxGatewayStandIn()
        documentsOn = true
        gatewayUp = true
    }

    override func tearDownWithError() throws {
        gateway.unregister()
        try? FileManager.default.removeItem(at: root)
    }

    private func relay() -> PendingImportRelay { PendingImportRelay(files: gateway.files, settle: .milliseconds(50)) }

    private func inbox(_ name: String = "mac", poll: Duration = .seconds(60), active: Bool = false) -> DocumentInbox {
        DocumentInbox(directory: root.appendingPathComponent(name), documentsOn: { [unowned self] in documentsOn },
                      relay: { [unowned self] in gatewayUp ? relay() : nil }, pollInterval: poll, isAppActive: { active })
    }

    /// What the iPhone does when the person taps Send to my Mac.
    @discardableResult
    private func phoneSends(_ title: String = "Two Rooms") async throws -> PendingImport {
        let file = root.appendingPathComponent("\(title).md")
        try Data("# \(title)\n\nA small room, like the cell of a bee.".utf8).write(to: file)
        return try await relay().send(file: file, title: title, contentType: "text/markdown", fromDevice: "Anatoli’s iPhone")
    }

    /// The probe's relay override (DEBUG only) is ignored unless both variables are set, and never
    /// reaches past this Mac: a missing one leaves the configured gateway in charge.
    func testTheDebugRelayOverrideIsIgnoredWhenAbsent() {
        XCTAssertNil(DocumentInbox.debugRelay(environment: [:]))
        XCTAssertNil(DocumentInbox.debugRelay(environment: ["BATON_DEBUG_INBOX_GATEWAY_URL": "http://127.0.0.1:18790"]))
        XCTAssertNil(DocumentInbox.debugRelay(environment: ["BATON_DEBUG_INBOX_GATEWAY_TOKEN": "throwaway"]))
        XCTAssertNil(DocumentInbox.debugRelay(environment: ["BATON_DEBUG_INBOX_GATEWAY_URL": "http://192.168.1.20:8788",
                                                            "BATON_DEBUG_INBOX_GATEWAY_TOKEN": "throwaway"]),
                     "a probe is never pointed at a gateway off this Mac")
        XCTAssertNotNil(DocumentInbox.debugRelay(environment: ["BATON_DEBUG_INBOX_GATEWAY_URL": "http://127.0.0.1:18790",
                                                               "BATON_DEBUG_INBOX_GATEWAY_TOKEN": "throwaway"]))
    }

    func testASentDocumentIsPickedUpOnceAndOffered() async throws {
        let sent = try await phoneSends()
        let mac = inbox()
        await mac.pickUp()
        await mac.pickUp()
        XCTAssertEqual(mac.items.map(\.id), [sent.id], "picked up exactly once")
        XCTAssertEqual(mac.arrivals, 1)
        let offer = try XCTUnwrap(mac.nextOffer)
        XCTAssertEqual(offer.record.title, "Two Rooms")
        XCTAssertEqual(offer.record.fromDevice, "Anatoli’s iPhone")
        let text = try String(contentsOf: XCTUnwrap(offer.source), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# Two Rooms"), "the import sheet reads the phone's own file")
        XCTAssertEqual(offer.source?.lastPathComponent, "Two Rooms.md")
    }

    /// The ids come from the gateway. One that is not a gateway id ("..") must never reach a path
    /// on this Mac, least of all the cleanup after a failed fetch, which would remove the folder
    /// the inbox lives in.
    func testAnIdThatIsNotAGatewayIdIsNeverUsedAsAPath() async throws {
        let mac = inbox()
        let sentinel = root.appendingPathComponent("sentinel")
        try Data("keep me".utf8).write(to: sentinel)
        gateway.plant(id: "..", contentType: PendingImport.contentType)
        gateway.plant(id: PendingImport.claimID(for: "..", device: mac.deviceID), contentType: PendingImport.claimContentType)

        await mac.pickUp()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path), "a gateway id deleted a folder outside the inbox")
        XCTAssertTrue(mac.items.isEmpty)
    }

    func testTwoMacsTakeItExactlyOnce() async throws {
        try await phoneSends()
        let a = inbox("mac-a"), b = inbox("mac-b")
        async let one: Void = a.pickUp()
        async let two: Void = b.pickUp()
        _ = await (one, two)
        XCTAssertEqual(a.items.count + b.items.count, 1, "one Mac has it, the other moves on")
        // And later pickups do not move it.
        await a.pickUp(); await b.pickUp()
        XCTAssertEqual(a.items.count + b.items.count, 1)
    }

    func testImportingRemovesItHereAndOnTheGateway() async throws {
        let sent = try await phoneSends()
        let mac = inbox()
        await mac.pickUp()
        let file = try XCTUnwrap(mac.items.first?.file)
        mac.finish(sent.id)   // what Make Audiobook does for a sent document
        await mac.settle()
        XCTAssertTrue(mac.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "this Mac's copy is gone")
        let left = try await gateway.files.list()
        XCTAssertEqual(left, [], "record, document and claim are gone from the gateway")
        await mac.pickUp()
        XCTAssertTrue(mac.items.isEmpty, "it does not come back")
    }

    /// The gateway removed the document before this Mac collected it (its age limit, or cap
    /// eviction, which takes the document first). The Mac says so once, clears the record on the
    /// gateway so it is not asked for every minute, and Dismiss removes the row.
    func testADocumentTheGatewayAlreadyRemovedIsListedAsMissingAndFinished() async throws {
        let sent = try await phoneSends()
        gateway.remove(PendingImport.documentID(for: sent.id))
        let mac = inbox()
        await mac.pickUp()
        let item = try XCTUnwrap(mac.items.first)
        XCTAssertEqual(item.id, sent.id)
        XCTAssertTrue(item.isMissing)
        XCTAssertNil(item.source)
        XCTAssertNil(mac.nextOffer, "nothing to open in the import sheet")
        XCTAssertEqual(mac.arrivals, 1, "Clippings comes forward so the person sees it")
        await mac.settle()
        let left = try await gateway.files.list()
        XCTAssertEqual(left.map(\.id), [], "the orphaned record and its claim are gone from the gateway")

        let relaunched = inbox()
        XCTAssertEqual(relaunched.items.map(\.id), [sent.id], "still listed after a relaunch")
        XCTAssertTrue(relaunched.items[0].isMissing)
        relaunched.finish(sent.id)   // Dismiss
        await relaunched.settle()
        XCTAssertTrue(relaunched.items.isEmpty)
        await relaunched.pickUp()
        XCTAssertTrue(relaunched.items.isEmpty, "it does not come back")
    }

    func testNotNowKeepsItListedHeldAndQuiet() async throws {
        let sent = try await phoneSends()
        let mac = inbox()
        await mac.pickUp()
        mac.notNow(sent.id)
        XCTAssertNil(mac.nextOffer, "Not Now does not open it again by itself")
        XCTAssertEqual(mac.items.map(\.id), [sent.id], "it stays listed")
        await mac.pickUp()
        let listed = try await gateway.files.list()
        XCTAssertTrue(listed.contains { $0.id == sent.id }, "the gateway copy stays for later")

        // After a relaunch it is still here, still set aside, and still this Mac's.
        let relaunched = inbox()
        XCTAssertEqual(relaunched.items.map(\.id), [sent.id])
        XCTAssertNil(relaunched.nextOffer)
        await relaunched.pickUp()
        XCTAssertEqual(relaunched.items.count, 1)
        let other = inbox("other-mac")
        await other.pickUp()
        XCTAssertTrue(other.items.isEmpty, "another Mac leaves a held one alone")

        relaunched.reopen(sent.id)
        XCTAssertEqual(relaunched.nextOffer?.id, sent.id, "Import… from the list opens it again")
    }

    func testDiscardWhileTheGatewayIsAwayIsFinishedLater() async throws {
        let sent = try await phoneSends()
        let mac = inbox()
        await mac.pickUp()
        gatewayUp = false
        mac.finish(sent.id)   // Discard
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(mac.items.isEmpty)
        XCTAssertEqual(mac.awaitingRemoval, [sent.id], "remembered, so it is removed when the gateway is back")

        // A relaunch with the gateway back: removed there, and not picked up again.
        gatewayUp = true
        let relaunched = inbox()
        XCTAssertEqual(relaunched.awaitingRemoval, [sent.id])
        await relaunched.pickUp()
        XCTAssertTrue(relaunched.items.isEmpty)
        XCTAssertTrue(relaunched.awaitingRemoval.isEmpty)
        let left = try await gateway.files.list()
        XCTAssertEqual(left, [])
    }

    func testNothingIsAskedWhileDocumentsIsOff() async throws {
        try await phoneSends()
        documentsOn = false
        let mac = inbox(poll: .milliseconds(40), active: true)
        mac.start()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(mac.pickups, 0, "Documents off: the gateway is never asked")
        XCTAssertTrue(gateway.requests.filter { $0.method == "GET" }.isEmpty)
        XCTAssertTrue(mac.items.isEmpty)

        documentsOn = true
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(mac.pickups, 0, "on again: the next poll asks")
        XCTAssertEqual(mac.items.count, 1)
        mac.stop()
        XCTAssertFalse(mac.isPolling)
    }

    func testThePollStopsWhenBatonIsNotActive() async throws {
        let mac = inbox(poll: .milliseconds(40), active: false)
        mac.startPolling()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(mac.isPolling, "in the background nothing polls; activation asks again")
        XCTAssertEqual(mac.pickups, 0)
    }
}

/// The gateway's `/v1/files` routes in process, with the rules of `FileStore` and
/// `GatewayRoutes.file`: hex-and-dash ids, PUT replaces, GET of nothing is 404, DELETE is always
/// 200, listings newest first and stamped to the second.
final class InboxGatewayStandIn: @unchecked Sendable {
    struct Seen { let method: String; let path: String }
    /// The gateway's `FileStore.Metadata`, as it goes on the wire.
    private struct Meta: Codable {
        var id: String, name: String, contentType: String, size: Int
        var sha256: String?, createdAt: Date, origin: String?
    }
    private struct Stored { var meta: Meta; var body: Data }
    private let lock = NSLock()
    private var stored: [String: Stored] = [:]
    private var seen: [Seen] = []
    let host = "inbox-\(UUID().uuidString.lowercased().prefix(8)).test"
    let files: GatewayFiles

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InboxGatewayProtocol.self]
        files = GatewayFiles(gatewayURL: URL(string: "http://\(host)")!, token: "t",
                             session: URLSession(configuration: configuration))
        InboxGatewayProtocol.register(self, host: host)
    }

    func unregister() { InboxGatewayProtocol.unregister(host: host) }
    /// A listing entry the real gateway's id rule would never have let in, for the tests of what
    /// the Mac does with one anyway.
    func plant(id: String, contentType: String) {
        lock.withLock {
            stored[id] = Stored(meta: Meta(id: id, name: "planted", contentType: contentType, size: 0, sha256: nil,
                                           createdAt: Date(timeIntervalSince1970: 1_700_000_000), origin: nil),
                                body: Data())
        }
    }
    var requests: [Seen] { lock.withLock { seen } }
    /// What the gateway's age limit or cap eviction does to one file.
    func remove(_ id: String) { lock.withLock { stored[id] = nil } }

    func answer(_ request: URLRequest, body: Data) -> (Int, Data, [String: String]) {
        lock.withLock {
            let method = request.httpMethod ?? "GET"
            let path = request.url?.path ?? ""
            seen.append(Seen(method: method, path: path))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if path == "/v1/files", method == "GET" {
                return (200, try! encoder.encode(stored.values.map(\.meta).sorted { $0.createdAt > $1.createdAt }), [:])
            }
            let id = String(path.dropFirst("/v1/files/".count)).lowercased()
            guard path.hasPrefix("/v1/files/"), !id.isEmpty, id.allSatisfy({ "0123456789abcdef-".contains($0) }) else {
                return (400, Data(), [:])
            }
            switch method {
            case "PUT":
                let meta = Meta(
                    id: id, name: request.value(forHTTPHeaderField: "X-Baton-Name") ?? "file",
                    contentType: request.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream",
                    size: body.count, sha256: request.value(forHTTPHeaderField: "X-Baton-SHA256"),
                    createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
                    origin: request.value(forHTTPHeaderField: "X-Baton-Origin"))
                stored[id] = Stored(meta: meta, body: body)
                return (201, try! encoder.encode(meta), [:])
            case "DELETE":
                stored[id] = nil
                return (200, Data(#"{"ok":true}"#.utf8), [:])
            default:
                guard let file = stored[id] else { return (404, Data(#"{"error":"no such file"}"#.utf8), [:]) }
                return (200, file.body, ["Content-Type": file.meta.contentType])
            }
        }
    }
}

final class InboxGatewayProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var standIns: [String: InboxGatewayStandIn] = [:]
    private static let lock = NSLock()
    static func register(_ standIn: InboxGatewayStandIn, host: String) { lock.withLock { standIns[host] = standIn } }
    static func unregister(host: String) { lock.withLock { standIns[host] = nil } }

    override class func canInit(with request: URLRequest) -> Bool { lock.withLock { standIns[request.url?.host ?? ""] != nil } }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let standIn = Self.lock.withLock({ Self.standIns[request.url?.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                guard n > 0 else { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let (status, data, headers) = standIn.answer(request, body: body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                                              headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
