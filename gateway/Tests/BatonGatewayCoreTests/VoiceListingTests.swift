import BatonDocuments
import BatonMCPProtocol
import Foundation
import XCTest
@testable import BatonGatewayCore

/// `GET /v1/voices`, through the real `Router` with stand-in voice servers: what
/// the phone's narrator choice reads. Not `@MainActor` as a class, for Linux test discovery
/// (see `BookRoutesTests`); the tests that dispatch are main-actor one by one.
final class VoiceListingTests: XCTestCase {
    private let token = "correct-horse"

    /// Voice servers by host: a body, or nil for one that does not answer. Counts requests.
    final class StandIns: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [String: Data?]
        private(set) var asked: [String] = []
        init(_ bodies: [String: Data?]) { self.bodies = bodies }
        var count: Int { lock.withLock { asked.count } }
        func set(_ host: String, _ body: Data?) { lock.withLock { bodies[host] = body } }
        func fetch(_ request: URLRequest) throws -> (Data, Int) {
            try lock.withLock {
                let host = request.url?.host ?? ""
                asked.append("\(host)\(request.url?.path ?? "")")
                guard let body = bodies[host] ?? nil else { throw URLError(.cannotConnectToHost) }
                return (body, 200)
            }
        }
    }

    private let engines = ["kokoro": URL(string: "http://kokoro.test:8880")!,
                           "chatterbox": URL(string: "http://chatterbox.test:8004")!]

    private func request(_ path: String, token: String? = "correct-horse") -> HTTPRequestMessage {
        var headers: [String: String] = [:]
        if let token { headers["authorization"] = "Bearer \(token)" }
        return HTTPRequestMessage(method: "GET", path: path, query: [:], headers: headers, body: Data())
    }

    private func status(_ data: Data) -> String {
        String(data: data.prefix(64), encoding: .utf8)?.components(separatedBy: "\r\n").first?
            .replacingOccurrences(of: "HTTP/1.1 ", with: "") ?? ""
    }

    private func body(_ data: Data) -> Data {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return Data() }
        return data[range.upperBound...]
    }

    @MainActor
    private func router(_ listing: VoiceListing?) -> Router {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voices-\(UUID().uuidString)")
        let routes = BookRoutes(renderer: nil, store: BookStore(directory: dir), synthesizer: nil,
                                unavailableReason: nil, voices: listing)
        return Router(token: token, routes: routes.routes())
    }

    /// The servers' own lists, Kokoro's `{"voices":[{"id":…}]}` and Chatterbox's bare names, each
    /// as `engine:id` specs with the language a Kokoro id declares; behind the token like every
    /// book route.
    @MainActor
    func testListsEachVoiceServersOwnVoicesBehindTheToken() async throws {
        let servers = StandIns([
            "kokoro.test": Data(#"{"voices":[{"id":"af_heart"},{"id":"bf_emma"},{"id":"zf_xiaobei"}]}"#.utf8),
            "chatterbox.test": Data(#"{"voices":["Emily.wav"]}"#.utf8),
        ])
        let router = router(VoiceListing(engines: engines, fetch: { try servers.fetch($0) }))

        let refused = await router.dispatch(request("/v1/voices", token: "wrong"))
        XCTAssertEqual(status(refused), "401 Unauthorized")
        let anonymous = await router.dispatch(request("/v1/voices", token: nil))
        XCTAssertEqual(status(anonymous), "401 Unauthorized")
        XCTAssertEqual(servers.count, 0, "an unauthenticated request must not reach the voice server")

        let answer = await router.dispatch(request("/v1/voices"))
        XCTAssertEqual(status(answer), "200 OK")
        let list = try JSONDecoder().decode(GatewayVoiceList.self, from: body(answer))
        // Engines in name order, each server's voices in its own order.
        XCTAssertEqual(list.specs, ["chatterbox:Emily.wav", "kokoro:af_heart", "kokoro:bf_emma", "kokoro:zf_xiaobei"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: list.voices.map { ($0.spec, $0.language) }),
                       ["kokoro:af_heart": "en", "kokoro:bf_emma": "en", "kokoro:zf_xiaobei": "zh", "chatterbox:Emily.wav": nil])
        XCTAssertEqual(list.voices.first { $0.spec == "kokoro:bf_emma" }?.id, "bf_emma")
        XCTAssertEqual(list.sources, ["kokoro": "server", "chatterbox": "server"])
        XCTAssertEqual(Set(servers.asked), ["kokoro.test/v1/audio/voices", "chatterbox.test/v1/audio/voices"])
        // The raw JSON carries "language" only where it is known.
        let raw = String(decoding: body(answer), as: UTF8.self)
        XCTAssertTrue(raw.contains(#""spec":"kokoro:af_heart""#), raw)
    }

    /// Kokoro not answering: the English voices Kokoro ships stand in, Heart and Emma among them
    /// and the avoided two listed too (the phone's catalogue leaves them out of suggestions); a
    /// Chatterbox that does not answer lists nothing.
    @MainActor
    func testKokorosShippedVoicesStandInWhenItDoesNotAnswer() async throws {
        let servers = StandIns(["kokoro.test": nil, "chatterbox.test": nil])
        let answer = await router(VoiceListing(engines: engines, fetch: { try servers.fetch($0) }))
            .dispatch(request("/v1/voices"))
        XCTAssertEqual(status(answer), "200 OK")
        let list = try JSONDecoder().decode(GatewayVoiceList.self, from: body(answer))
        XCTAssertEqual(list.sources, ["kokoro": "built-in", "chatterbox": "unavailable"])
        XCTAssertTrue(list.voices.allSatisfy { $0.engine == "kokoro" && $0.language == "en" })
        XCTAssertEqual(list.voices.count, 28)
        for spec in ["kokoro:af_heart", "kokoro:bf_emma", "kokoro:af_aoede", "kokoro:bm_lewis"] {
            XCTAssertTrue(list.specs.contains(spec), spec)
        }
    }

    /// Kept for the cache's lifetime, asked again after it: two import screens in a row cost the
    /// voice server one listing.
    func testTheListIsKeptBriefly() async {
        let servers = StandIns(["kokoro.test": Data(#"{"voices":["af_heart"]}"#.utf8)])
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 0) }
        let clock = Clock()
        let listing = VoiceListing(engines: ["kokoro": engines["kokoro"]!], ttl: 60,
                                   fetch: { try servers.fetch($0) }, now: { clock.now })
        let first = await listing.list()
        servers.set("kokoro.test", Data(#"{"voices":["af_heart","bf_emma"]}"#.utf8))
        clock.now = Date(timeIntervalSince1970: 59)
        let again = await listing.list()
        XCTAssertEqual(first, again)
        XCTAssertEqual(servers.count, 1)
        clock.now = Date(timeIntervalSince1970: 61)
        let later = await listing.list()
        XCTAssertEqual(later.specs, ["kokoro:af_heart", "kokoro:bf_emma"])
        XCTAssertEqual(servers.count, 2)
    }

    @MainActor
    func testWithoutAVoiceListingTheRouteSaysWhy() async {
        let answer = await router(nil).dispatch(request("/v1/voices"))
        XCTAssertEqual(status(answer), "503 Service Unavailable")
    }
}
