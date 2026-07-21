import XCTest
@testable import Baton

/// : the Agents settings pane reads the running server's mcp.json discovery file. Pin the parse.
final class AgentAccessInfoTests: XCTestCase {
    private func writeDiscovery(_ json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.data(using: .utf8)!.write(to: dir.appendingPathComponent("mcp.json"))
        return dir
    }

    func testParsesEndpointTokenAndFastPath() throws {
        let dir = try writeDiscovery(#"""
        {
          "schemaVersion": 1,
          "url": "http://127.0.0.1:8768/mcp",
          "token": "secret-abc",
          "pid": 4242,
          "app": { "version": "0.1.0" },
          "fastPath": { "unixSocket": "/tmp/baton/control.sock" }
        }
        """#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let info = try XCTUnwrap(AgentAccessInfo.load(from: dir))
        XCTAssertEqual(info.url, "http://127.0.0.1:8768/mcp")
        XCTAssertEqual(info.token, "secret-abc")
        XCTAssertEqual(info.unixSocket, "/tmp/baton/control.sock")
        XCTAssertEqual(info.pid, 4242)
        XCTAssertEqual(info.version, "0.1.0")
    }

    func testMissingFileReturnsNil() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-none-\(UUID().uuidString)")
        XCTAssertNil(AgentAccessInfo.load(from: dir))
    }

    func testMalformedOrIncompleteReturnsNil() throws {
        let dir = try writeDiscovery(#"{"url": "http://127.0.0.1:8768/mcp"}"#) // no token
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(AgentAccessInfo.load(from: dir), "a file without a token isn't a usable endpoint")
    }
}
