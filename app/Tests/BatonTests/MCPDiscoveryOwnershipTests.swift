import XCTest
import BatonSubsonicKit
@testable import Baton

/// A Baton refused because another live instance owns the MCP endpoint never wrote `mcp.json`,
/// so its `stop()` must not delete the live owner's discovery file.
@MainActor
final class MCPDiscoveryOwnershipTests: XCTestCase {
    private var tempDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var owner: Process?

    override func setUp() async throws {
        NavidromeKeychain.inMemoryStore = [:]
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-own-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        (suiteName, defaults) = ThrowawayDefaults.suite("MCPDiscoveryOwnershipTests")
    }

    override func tearDown() async throws {
        if let owner, owner.isRunning { owner.terminate(); owner.waitUntilExit() }
        owner = nil
        defaults.removePersistentDomain(forName: suiteName)
        NavidromeKeychain.inMemoryStore = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var discoveryFile: URL { tempDir.appendingPathComponent("mcp.json") }

    private func writeDiscoveryFile(pid: Int32) throws {
        let data = try JSONSerialization.data(withJSONObject: ["pid": Int(pid), "token": "live-owner"])
        try data.write(to: discoveryFile)
    }

    private func makeServer() -> BatonMCPServer {
        BatonMCPServer(music: MusicModel(), discoveryDirectory: tempDir, defaults: defaults,
                       portNotifier: { _ in })
    }

    func testARefusedInstanceLeavesTheLiveOwnersFile() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["60"]
        try sleeper.run()
        owner = sleeper
        try writeDiscoveryFile(pid: sleeper.processIdentifier)

        let server = makeServer()
        server.start()
        XCTAssertNotNil(server.lastError, "a live foreign owner should refuse the start")
        server.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: discoveryFile.path),
                      "stop() must not delete a discovery file another live instance wrote")
    }

    func testStopRemovesTheFileThisInstanceWrote() throws {
        try writeDiscoveryFile(pid: ProcessInfo.processInfo.processIdentifier)
        makeServer().stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: discoveryFile.path),
                       "the file naming this process is ours to remove on stop")
    }
}
