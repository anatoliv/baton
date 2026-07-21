import XCTest
@testable import Baton

/// W-46 (Foundation F5): boot the REAL MCP server on a loopback port with a temp discovery
/// directory and drive it over HTTP — the end-to-end contract for the defining agent surface.
@MainActor
final class MCPServerE2ETests: XCTestCase {
    private var model: MusicModel!
    private var server: BatonMCPServer!
    private var tempDir: URL!

    override func setUp() async throws {
        NavidromeKeychain.inMemoryStore = [:] // the bearer token routes to the in-memory keychain
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        model = MusicModel()
        server = BatonMCPServer(music: model, discoveryDirectory: tempDir)
        server.start()
        // start() binds asynchronously (awaits the listener reaching .ready — W-38); poll.
        let deadline = Date().addingTimeInterval(5)
        while server.boundPort == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        try XCTSkipIf(server.boundPort == nil, "MCP server did not bind a port in time")
    }

    override func tearDown() {
        server?.stop()
        NavidromeKeychain.inMemoryStore = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func post(_ body: String, token: String?) async throws -> (status: Int, json: [String: Any]?) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(server.boundPort!)/mcp")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = Data(body.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (code, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testRejectsMissingToken() async throws {
        let (status, _) = try await post(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#, token: nil)
        XCTAssertEqual(status, 401)
    }

    func testInitializeWithTokenReturnsResult() async throws {
        let (status, json) = try await post(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#, token: server.token)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json?["jsonrpc"] as? String, "2.0")
        XCTAssertNotNil(json?["result"], "initialize should return a result")
    }

    func testToolsListReturnsTheCatalog() async throws {
        let (status, json) = try await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#, token: server.token)
        XCTAssertEqual(status, 200)
        let tools = (json?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertGreaterThan(tools?.count ?? 0, 0, "tools/list should return the tool catalog")
    }

    // MARK: - Session & stream lifecycle (W-39)

    /// The server mints an `Mcp-Session-Id` at initialize (spec: server-assigned, unforgeable).
    func testInitializeMintsSessionIdHeader() async throws {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(server.boundPort!)/mcp")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        req.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8)
        let (_, resp) = try await URLSession.shared.data(for: req)
        let sid = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id")
        XCTAssertNotNil(sid, "initialize must mint a session id")
        XCTAssertFalse(sid?.isEmpty ?? true)
    }

    /// A GET without `Accept: text/event-stream` is a client error, not a stream to open.
    func testPlainGetWithoutEventStreamAcceptIs405() async throws {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(server.boundPort!)/mcp")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept") // deliberately not event-stream
        let (_, resp) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 405)
    }

    /// A request carrying a session id the server never minted is rejected (forged/expired).
    func testPostWithUnknownSessionIs404() async throws {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(server.boundPort!)/mcp")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        req.setValue("00000000-forged-session", forHTTPHeaderField: "Mcp-Session-Id")
        req.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#.utf8)
        let (_, resp) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 404)
    }
}
