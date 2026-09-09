import BatonMCPProtocol
import XCTest
@testable import BatonGatewayCore

/// The gateway's dispatch, which until now lived in `main.swift` where a test target cannot
/// import it (S-F24). The table these build is the same shape `GatewayRoutes.router()` builds
/// in the executable, so a route added there and not here shows up as a hole in this file
/// rather than as nothing at all.
@MainActor
final class RouterTests: XCTestCase {
    private let token = "correct-horse"

    // MARK: - Helpers

    private func request(_ method: String, _ path: String, token: String? = nil,
                         body: Data = Data()) -> HTTPRequestMessage {
        var headers: [String: String] = [:]
        if let token { headers["authorization"] = "Bearer \(token)" }
        return HTTPRequestMessage(method: method, path: path, query: [:], headers: headers, body: body)
    }

    /// The status line of a rendered response, e.g. `404 Not Found`.
    private func status(_ data: Data) -> String {
        let text = String(data: data.prefix(64), encoding: .utf8) ?? ""
        let line = text.components(separatedBy: "\r\n").first ?? ""
        return line.replacingOccurrences(of: "HTTP/1.1 ", with: "")
    }

    private func header(_ name: String, in data: Data) -> String? {
        let text = String(data: data.prefix(512), encoding: .utf8) ?? ""
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[line.startIndex ..< colon].lowercased() == name.lowercased() {
                return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// A router over the real table's shape, whose handlers only record that they ran.
    private func recordingRouter(_ log: Recorder) -> Router {
        func handler(_ name: String) -> Router.Handler {
            { _, parameter in
                log.record(name, parameter: parameter)
                return httpResponse(status: "200 OK", body: #"{"handler":"\#(name)"}"#)
            }
        }
        return Router(token: token, routes: [
            Router.Route(methods: ["GET"], pattern: .exact("/health"), isPublic: true,
                         handler: handler("health")),
            Router.Route(methods: ["GET"], pattern: .exact("/v1/state"), handler: handler("readState")),
            Router.Route(methods: ["PUT"], pattern: .exact("/v1/state"), handler: handler("writeState")),
            Router.Route(methods: ["GET"], pattern: .exact("/v1/files"), handler: handler("listFiles")),
            Router.Route(methods: ["GET", "DELETE"], pattern: .prefix("/v1/files/"), handler: handler("file")),
            Router.Route(methods: ["GET"], pattern: .exact("/v1/device/poll"), handler: handler("devicePoll")),
            Router.Route(methods: ["POST"], pattern: .exact("/v1/device/result"), handler: handler("deviceResult")),
            Router.Route(methods: ["POST"], pattern: .exact("/v1/agent"), handler: handler("agent")),
        ])
    }

    final class Recorder: @unchecked Sendable {
        private(set) var calls: [(name: String, parameter: String)] = []
        func record(_ name: String, parameter: String) { calls.append((name, parameter)) }
        var names: [String] { calls.map(\.name) }
    }

    // MARK: - Every known route reaches its handler

    func testEachKnownRouteReachesItsHandler() async {
        let cases: [(method: String, path: String, handler: String, parameter: String)] = [
            ("GET", "/health", "health", ""),
            ("GET", "/v1/state", "readState", ""),
            ("PUT", "/v1/state", "writeState", ""),
            ("GET", "/v1/files", "listFiles", ""),
            ("GET", "/v1/files/abc123", "file", "abc123"),
            ("DELETE", "/v1/files/abc123", "file", "abc123"),
            ("GET", "/v1/device/poll", "devicePoll", ""),
            ("POST", "/v1/device/result", "deviceResult", ""),
            ("POST", "/v1/agent", "agent", ""),
        ]
        for testCase in cases {
            let log = Recorder()
            let router = recordingRouter(log)
            let response = await router.dispatch(request(testCase.method, testCase.path, token: token))
            XCTAssertEqual(log.names, [testCase.handler],
                           "\(testCase.method) \(testCase.path) should reach \(testCase.handler)")
            XCTAssertEqual(log.calls.first?.parameter, testCase.parameter,
                           "\(testCase.path) should hand its handler the path parameter")
            XCTAssertEqual(status(response), "200 OK")
        }
    }

    /// The exact `/v1/files` row has to win over the `/v1/files/` prefix row. Both match a
    /// path that starts the same way, and the table's order is the only thing separating them.
    func testFileListingIsNotSwallowedByTheFilePrefixRoute() async {
        let log = Recorder()
        _ = await recordingRouter(log).dispatch(request("GET", "/v1/files", token: token))
        XCTAssertEqual(log.names, ["listFiles"])
    }

    // MARK: - Unknown path

    func testUnknownPathIs404ForAnAuthenticatedCaller() async {
        let log = Recorder()
        let response = await recordingRouter(log).dispatch(request("GET", "/v1/nope", token: token))
        XCTAssertEqual(status(response), "404 Not Found")
        XCTAssertTrue(log.names.isEmpty, "no handler should run for an unknown path")
    }

    /// The path is not even looked at without a token, so an anonymous caller cannot tell a
    /// real route from an invented one and map the gateway by status code.
    func testUnknownAndKnownPathsAreIndistinguishableWithoutAToken() async {
        let log = Recorder()
        let router = recordingRouter(log)
        let unknown = await router.dispatch(request("GET", "/v1/nope"))
        let known = await router.dispatch(request("GET", "/v1/state"))
        XCTAssertEqual(status(unknown), "401 Unauthorized")
        XCTAssertEqual(status(known), "401 Unauthorized")
        XCTAssertTrue(log.names.isEmpty)
    }

    func testWrongTokenIs401OnEveryAuthenticatedRoute() async {
        for path in ["/v1/state", "/v1/files", "/v1/files/x", "/v1/device/poll",
                     "/v1/device/result", "/v1/agent"] {
            let log = Recorder()
            let response = await recordingRouter(log)
                .dispatch(request("GET", path, token: "wrong-horse"))
            XCTAssertEqual(status(response), "401 Unauthorized", "\(path) must refuse a bad token")
            XCTAssertTrue(log.names.isEmpty, "\(path) must not run its handler on a bad token")
        }
    }

    func testHealthAnswersWithoutAToken() async {
        let log = Recorder()
        let response = await recordingRouter(log).dispatch(request("GET", "/health"))
        XCTAssertEqual(status(response), "200 OK")
        XCTAssertEqual(log.names, ["health"])
    }

    // MARK: - Method mismatch

    func testMethodMismatchOnAKnownPathIs405WithAnAllowHeader() async {
        let log = Recorder()
        let response = await recordingRouter(log).dispatch(request("DELETE", "/v1/state", token: token))
        XCTAssertEqual(status(response), "405 Method Not Allowed")
        XCTAssertEqual(header("Allow", in: response), "GET, PUT",
                       "the Allow header should name every method the path answers to")
        XCTAssertTrue(log.names.isEmpty)
    }

    /// `PUT /v1/files/{id}` is absent from the table on purpose: the transport streams an
    /// upload's body to disk and calls `handleUpload` directly, so one that reaches the
    /// router is a request that took the wrong path and must not be handled twice.
    func testUploadPutIsNotARouterRoute() async {
        let log = Recorder()
        let response = await recordingRouter(log).dispatch(request("PUT", "/v1/files/abc", token: token))
        XCTAssertEqual(status(response), "405 Method Not Allowed")
        XCTAssertEqual(header("Allow", in: response), "DELETE, GET")
        XCTAssertTrue(log.names.isEmpty)
    }

    func testMethodMismatchOnAPublicPathIs405WithoutAToken() async {
        let log = Recorder()
        let response = await recordingRouter(log).dispatch(request("POST", "/health"))
        XCTAssertEqual(status(response), "405 Method Not Allowed")
        XCTAssertEqual(header("Allow", in: response), "GET")
    }

    /// 405 is an answer only somebody with the token gets, on every route but `/health`.
    /// Otherwise the status code itself would say which paths exist.
    func testMethodMismatchWithoutATokenIs401NotA405() async {
        let response = await recordingRouter(Recorder())
            .dispatch(request("DELETE", "/v1/state"))
        XCTAssertEqual(status(response), "401 Unauthorized")
    }

    // MARK: - resolve, directly

    func testResolveIsPureAndReportsWhatItDecided() {
        let router = recordingRouter(Recorder())
        XCTAssertEqual(router.resolve(method: "GET", path: "/v1/files/id-9", isAuthenticated: true),
                       .route(index: 4, parameter: "id-9"))
        XCTAssertEqual(router.resolve(method: "POST", path: "/v1/files/id-9", isAuthenticated: true),
                       .methodNotAllowed(allowed: ["DELETE", "GET"]))
        XCTAssertEqual(router.resolve(method: "GET", path: "/nothing", isAuthenticated: true), .notFound)
        XCTAssertEqual(router.resolve(method: "GET", path: "/v1/state", isAuthenticated: false), .unauthorized)
    }

    /// HTTP methods are case-sensitive on the wire and the parser already uppercases them,
    /// but the table must not depend on that having happened.
    func testMethodMatchingIsCaseInsensitive() {
        let router = recordingRouter(Recorder())
        XCTAssertEqual(router.resolve(method: "get", path: "/v1/state", isAuthenticated: true),
                       .route(index: 1, parameter: ""))
    }

    /// The prefix route hands over everything after the prefix, untouched. Whether an id is
    /// legal is `FileStore`'s question, and it answers it with a 400; a router that silently
    /// trimmed or rejected here would move that decision somewhere nothing tests.
    func testPrefixRouteHandsTheWholeRemainderToTheHandler() {
        let router = recordingRouter(Recorder())
        XCTAssertEqual(router.resolve(method: "GET", path: "/v1/files/../etc/passwd", isAuthenticated: true),
                       .route(index: 4, parameter: "../etc/passwd"))
        XCTAssertEqual(router.resolve(method: "GET", path: "/v1/files/", isAuthenticated: true),
                       .route(index: 4, parameter: ""))
    }

    // MARK: - Token compare

    /// The router compares with `BatonMCPAuth.constantTimeEquals`, so a token that is a
    /// prefix of the real one, or differs only in case, is refused.
    func testAuthenticationRejectsNearMisses() {
        let router = recordingRouter(Recorder())
        XCTAssertTrue(router.isAuthenticated(request("GET", "/v1/state", token: token)))
        XCTAssertFalse(router.isAuthenticated(request("GET", "/v1/state", token: "correct-hors")))
        XCTAssertFalse(router.isAuthenticated(request("GET", "/v1/state", token: "CORRECT-HORSE")))
        XCTAssertFalse(router.isAuthenticated(request("GET", "/v1/state")))
    }

    /// `Authorization: bearer <token>` is spec-legal and must work: one auth check written
    /// twice is one that will disagree with itself (TBX-5308, S-F26).
    func testAuthenticationAcceptsALowercaseBearerScheme() {
        let router = recordingRouter(Recorder())
        let message = HTTPRequestMessage(method: "GET", path: "/v1/state", query: [:],
                                         headers: ["authorization": "bearer \(token)"], body: Data())
        XCTAssertTrue(router.isAuthenticated(message))
    }
}
