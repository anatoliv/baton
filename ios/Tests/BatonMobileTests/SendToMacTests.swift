import XCTest
import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
@testable import BatonMobile

/// "Send to my Mac" on the phone: what the import screen offers for each answer from
/// the home server, and what the send puts on the gateway.
@MainActor
final class SendToMacTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-send-to-mac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        SendCapture.reset()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - What is offered

    func testTheOfferFollowsWhatTheHomeServerSaid() {
        XCTAssertEqual(ImportOffer(nil), .asking)
        XCTAssertEqual(ImportOffer(.available), .makeAudiobook, "books on: Make Audiobook, as before")
        XCTAssertEqual(ImportOffer(.cannotMakeBooks), .sendToMac, "answered, but no books: Send to my Mac")
        XCTAssertEqual(ImportOffer(.notConfigured), .airDrop, "no home server: AirDrop to the Mac")
        XCTAssertEqual(ImportOffer(.unreachable), .unreachable)

        XCTAssertTrue(ImportOffer(.notConfigured).suggestsAirDrop)
        XCTAssertTrue(ImportOffer(.unreachable).suggestsAirDrop, "nothing can travel through a gateway that is away")
        XCTAssertFalse(ImportOffer(.cannotMakeBooks).suggestsAirDrop)
        XCTAssertFalse(ImportOffer(.available).suggestsAirDrop)
    }

    private func books(answering answer: @escaping @Sendable (URLRequest) -> (Data, HTTPURLResponse)) -> HomeServerBooks {
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"),
                                      defaults: UserDefaults(suiteName: ThrowawayDefaults.name("send-to-mac"))!)
        return HomeServerBooks(directory: root.appendingPathComponent("Books"), clippings: clippings,
                               gateway: { GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { answer($0) } })
    }

    nonisolated private static func reply(_ request: URLRequest, _ status: Int, _ body: String) -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    func testTheHomeServersAnswersMapToTheOffer() async {
        let on = books { Self.reply($0, 200, #"{"available":true,"books":[]}"#) }
        let available = await on.availability()
        XCTAssertEqual(available, .available)

        let noVoices = books { Self.reply($0, 200, #"{"available":false,"unavailable_reason":"no voice server is set up","books":[]}"#) }
        let cannot = await noVoices.availability()
        XCTAssertEqual(cannot, .cannotMakeBooks)
        XCTAssertEqual(noVoices.problem, "no voice server is set up")

        let beforeBooks = books { Self.reply($0, 404, #"{"error":"not found"}"#) }
        let old = await beforeBooks.availability()
        XCTAssertEqual(old, .cannotMakeBooks, "a gateway from before books still carries files")

        let refused = books { Self.reply($0, 401, #"{"error":"bad token"}"#) }
        let away = await refused.availability()
        XCTAssertEqual(away, .unreachable, "a refused token cannot carry files either")

        let clippings = ClippingStore(directory: root.appendingPathComponent("C2"),
                                      defaults: UserDefaults(suiteName: ThrowawayDefaults.name("send-to-mac"))!)
        let none = HomeServerBooks(directory: root.appendingPathComponent("B2"), clippings: clippings, gateway: { nil })
        let unset = await none.availability()
        XCTAssertEqual(unset, .notConfigured)
    }

    // MARK: - What is sent

    private func relay() -> PendingImportRelay {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SendCapture.self]
        return PendingImportRelay(files: GatewayFiles(gatewayURL: URL(string: "http://send.test:8788")!, token: "t",
                                                      session: URLSession(configuration: configuration)))
    }

    func testSendingAFileParksItAndARecordWithItsTitleNameKindAndDevice() async throws {
        let file = root.appendingPathComponent("The Machine Stops.pdf")
        try Data("%PDF-1.4 a small test".utf8).write(to: file)
        let sent = try await SendToMac.send(file, title: "The Machine Stops", through: relay(), fromDevice: "Anatoli’s iPhone")

        let puts = SendCapture.requests.filter { $0.method == "PUT" }
        XCTAssertEqual(puts.map(\.path), ["/v1/files/\(sent.id)-d0c", "/v1/files/\(sent.id)"])
        XCTAssertEqual(puts[0].headers["Content-Type"], "application/pdf")
        XCTAssertEqual(puts[0].body, try Data(contentsOf: file), "the original file, byte for byte")
        XCTAssertEqual(puts[1].headers["Content-Type"], PendingImport.contentType, "marked as a pending import")
        XCTAssertTrue(puts.allSatisfy { $0.headers["X-Baton-SHA256"] == nil },
                      "no digest header, so no phone collects it as a clipping")
        XCTAssertTrue(puts.allSatisfy { $0.headers["Authorization"] == "Bearer t" })

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(PendingImport.self, from: puts[1].body)
        XCTAssertEqual(record.title, "The Machine Stops")
        XCTAssertEqual(record.filename, "The Machine Stops.pdf")
        XCTAssertEqual(record.kind, "pdf")
        XCTAssertEqual(record.contentType, "application/pdf")
        XCTAssertEqual(record.fromDevice, "Anatoli’s iPhone")
        XCTAssertEqual(record.sha256, try GatewayFiles.sha256(of: file))
        XCTAssertEqual(record.size, puts[0].body.count)
    }

    func testSendingALinkParksTheAddressOnly() async throws {
        let link = URL(string: "https://example.com/essays/two-rooms")!
        let sent = try await SendToMac.send(link, title: "Two Rooms", through: relay(), fromDevice: "iPhone")
        let puts = SendCapture.requests.filter { $0.method == "PUT" }
        XCTAssertEqual(puts.map(\.path), ["/v1/files/\(sent.id)"], "the Mac reads the page itself")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(PendingImport.self, from: puts[0].body)
        XCTAssertEqual(record.link, link.absoluteString)
        XCTAssertEqual(record.kind, "link")
        XCTAssertNil(record.documentID)
    }

    func testATooBigFileSaysToAirDropIt() {
        let text = SendToMac.failureText(GatewayFiles.TransferError.rejected(413, "at most 67108864 bytes"))
        XCTAssertTrue(text.contains("AirDrop"), text)
        XCTAssertFalse(text.contains("—"), "no em dashes in the screen's words")
    }
}

/// Records what the phone sends and answers as the gateway's file routes do.
final class SendCapture: URLProtocol, @unchecked Sendable {
    struct Seen { let method: String; let path: String; let headers: [String: String]; let body: Data }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [Seen] = []
    static var requests: [Seen] { lock.withLock { seen } }
    static func reset() { lock.withLock { seen = [] } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "send.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        Self.lock.withLock { Self.seen.append(Seen(method: method, path: path, headers: request.allHTTPHeaderFields ?? [:], body: body)) }
        let id = String(path.dropFirst("/v1/files/".count))
        let meta = #"{"id":"\#(id)","name":"x","contentType":"x","size":\#(body.count),"createdAt":"2026-10-15T12:00:00Z"}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: method == "PUT" ? 201 : 200,
                                                              httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(meta.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
