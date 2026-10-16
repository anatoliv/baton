import BatonDocuments
import BatonMCPProtocol
import Foundation
import XCTest
@testable import BatonGatewayCore

/// `POST /v1/books/complete` through the real `Router`, with a stand-in model: it
/// answers from a model on the home network, refuses a cloud one with the reason, is
/// authenticated like every book route, bounded in and out, and leaves the book routes beside it
/// as they were.
final class BookCompletionRouteTests: XCTestCase {
    private let token = "correct-horse"
    private static let lan = BookCompletionRoute.source(provider: "openai-compatible", baseURL: "http://192.168.1.20:8000/v1", model: "qwen3:8b")

    /// What the stand-in model was asked.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(system: String, user: String, maxTokens: Int)] = []
        func add(_ system: String, _ user: String, _ maxTokens: Int) { lock.withLock { calls.append((system, user, maxTokens)) } }
        var all: [(system: String, user: String, maxTokens: Int)] { lock.withLock { calls } }
    }

    private func request(_ method: String, _ path: String, json: [String: Any]? = nil, token: String? = "correct-horse") -> HTTPRequestMessage {
        var headers: [String: String] = [:]
        if let token { headers["authorization"] = "Bearer \(token)" }
        let body = json.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
        return HTTPRequestMessage(method: method, path: path, query: [:], headers: headers, body: body)
    }

    private func status(_ data: Data) -> String {
        String(data: data.prefix(64), encoding: .utf8)?.components(separatedBy: "\r\n").first?
            .replacingOccurrences(of: "HTTP/1.1 ", with: "") ?? ""
    }

    private func body(_ data: Data) -> Data {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return Data() }
        return data[range.upperBound...]
    }

    private func message(_ data: Data) -> String {
        ((try? JSONSerialization.jsonObject(with: body(data))) as? [String: Any])?["error"] as? String ?? ""
    }

    private func router(_ completion: BookCompletionRoute?) -> Router {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("baton-complete-\(UUID().uuidString)")
        let routes = BookRoutes(renderer: nil, store: BookStore(directory: dir), synthesizer: nil,
                                unavailableReason: "ffmpeg is not installed on the gateway", completion: completion)
        return Router(token: token, routes: routes.routes())
    }

    @MainActor
    private func ask(_ router: Router, _ json: [String: Any] = ["system": "Write a recap.", "user": "Ada wound the clock."],
                     token: String? = "correct-horse") async -> Data {
        await router.dispatch(request("POST", "/v1/books/complete", json: json, token: token))
    }

    @MainActor
    func testAModelOnTheHomeNetworkAnswersTheTask() async throws {
        let calls = Calls()
        let route = BookCompletionRoute(source: Self.lan, apiKey: nil) { source, system, user, maxTokens in
            calls.add(system, user, maxTokens)
            XCTAssertEqual(source.model, "qwen3:8b")
            return "Previously, Ada wound the clock."
        }
        XCTAssertNil(route.refusal)
        let key = "sk-" + "abcdefghijklmnopqrstuvwxyz012345"
        let ok = await ask(router(route), ["system": "Write a recap.", "user": "Ada wound the clock. \(key)", "max_tokens": 99_999])
        XCTAssertEqual(status(ok), "200 OK", "even with book rendering off: the route needs no ffmpeg")
        let answer = try JSONDecoder().decode(BookCompletion.Response.self, from: body(ok))
        XCTAssertEqual(answer, BookCompletion.Response(text: "Previously, Ada wound the clock.", model: "qwen3:8b"))
        XCTAssertEqual(calls.all.count, 1)
        XCTAssertEqual(calls.all.first?.system, "Write a recap.")
        XCTAssertFalse(calls.all.first?.user.contains(key) ?? true, "anything like a key is taken out before the model sees it")
        XCTAssertEqual(calls.all.first?.maxTokens, BookCompletion.maximumReplyTokens, "the reply budget is capped")
    }

    @MainActor
    func testACloudModelIsRefusedWithTheReasonAndNeverAsked() async throws {
        let calls = Calls()
        let cloud = BookCompletionRoute.source(provider: nil, baseURL: "https://api.anthropic.com", model: "claude-haiku-4-5-20251001")
        let route = BookCompletionRoute(source: cloud, apiKey: "k") { _, system, user, n in calls.add(system, user, n); return "no" }
        let refused = await ask(router(route))
        XCTAssertEqual(status(refused), "403 Forbidden")
        XCTAssertTrue(message(refused).contains("cloud one (api.anthropic.com)"), message(refused))
        XCTAssertTrue(calls.all.isEmpty, "a cloud model is never sent book text")

        // The operator's word for a home-network name the address rule cannot read.
        let named = BookCompletionRoute.source(provider: "openai-compatible", baseURL: "http://modelbox:8000/v1", model: "chat")
        let undeclared = await ask(router(BookCompletionRoute(source: named, apiKey: nil) { _, _, _, _ in "x" }))
        XCTAssertEqual(status(undeclared), "403 Forbidden")
        let declared = await ask(router(BookCompletionRoute(source: named, apiKey: nil, declaredLocal: true) { _, _, _, _ in "Previously." }))
        XCTAssertEqual(status(declared), "200 OK")

        let none = await ask(router(BookCompletionRoute(source: BookCompletionRoute.source(provider: nil, baseURL: "", model: ""), apiKey: nil)))
        XCTAssertEqual(status(none), "503 Service Unavailable")
        XCTAssertEqual(message(none), "no model is set up on the home server")
        let reply1 = await ask(router(nil))
        XCTAssertEqual(status(reply1), "503 Service Unavailable")
    }

    @MainActor
    func testAuthenticatedAndBounded() async throws {
        let calls = Calls()
        let route = BookCompletionRoute(source: Self.lan, apiKey: nil, timeout: 0.2) { _, system, user, n in
            calls.add(system, user, n)
            if user.contains("slow") { try await Task.sleep(nanoseconds: 5_000_000_000) }
            if user.contains("fail") { throw URLError(.cannotConnectToHost) }
            return user.contains("blank") ? "  " : "ok"
        }
        let r = router(route)
        let reply2 = await ask(r, token: nil)
        XCTAssertEqual(status(reply2), "401 Unauthorized")
        let reply3 = await ask(r, token: "wrong")
        XCTAssertEqual(status(reply3), "401 Unauthorized")
        let reply4 = await ask(r, ["system": "s"])
        XCTAssertEqual(status(reply4), "400 Bad Request")
        let reply5 = await ask(r, ["system": "s", "user": "   "])
        XCTAssertEqual(status(reply5), "400 Bad Request")
        let long = String(repeating: "a", count: BookCompletion.maximumCharacters)
        let reply6 = await ask(r, ["system": "s", "user": long])
        XCTAssertEqual(status(reply6), "413 Payload Too Large")
        XCTAssertTrue(calls.all.isEmpty, "nothing refused reaches the model")

        let started = Date()
        let slow = await ask(r, ["system": "s", "user": "slow"])
        XCTAssertEqual(status(slow), "504 Gateway Timeout")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the timeout bounds the wait")
        let reply7 = await ask(r, ["system": "s", "user": "fail"])
        XCTAssertEqual(status(reply7), "502 Bad Gateway")
        let reply8 = await ask(r, ["system": "s", "user": "blank"])
        XCTAssertEqual(status(reply8), "502 Bad Gateway")
        let reply9 = await r.dispatch(request("GET", "/v1/books/complete"))
        XCTAssertEqual(status(reply9), "400 Bad Request",
                       "a GET is the book-id route's, as before, and \"complete\" is no book id")
    }

    /// The route sits beside the book routes without taking any of their paths.
    @MainActor
    func testTheBookRoutesAreUnchanged() async throws {
        let r = router(BookCompletionRoute(source: Self.lan, apiKey: nil) { _, _, _, _ in "ok" })
        let reply10 = await r.dispatch(request("GET", "/v1/books"))
        XCTAssertEqual(status(reply10), "200 OK")
        let reply11 = await r.dispatch(request("POST", "/v1/books/abc/finished"))
        XCTAssertEqual(status(reply11), "404 Not Found")
        let reply12 = await r.dispatch(request("DELETE", "/v1/books/abc"))
        XCTAssertEqual(status(reply12), "200 OK")
    }

    /// The real client against the real route: what the phone sends is what the gateway reads.
    @MainActor
    func testThePhonesRequestIsWhatTheRouteReads() async throws {
        let r = router(BookCompletionRoute(source: Self.lan, apiKey: nil) { _, system, user, n in "\(system)|\(user)|\(n)" })
        let phone = BookCompletion.source(gatewayURL: "http://gateway.test:8788")
        let made = try HTTPModelClient.request(for: phone, system: "S", user: "U", apiKey: token, maxTokens: 300)
        let message = HTTPRequestMessage(method: made.httpMethod ?? "", path: made.url?.path ?? "", query: [:],
                                         headers: ["authorization": made.value(forHTTPHeaderField: "Authorization") ?? ""],
                                         body: made.httpBody ?? Data())
        let answered = await r.dispatch(message)
        XCTAssertEqual(status(answered), "200 OK")
        XCTAssertEqual(try HTTPModelClient.text(from: body(answered), provider: .homeServer), "S|U|300")
    }
}
