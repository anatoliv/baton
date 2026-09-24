import XCTest
import Network
import BatonSubsonicKit
@testable import Baton

/// TBX-7306: the server binds the first free port from the user's preferred one, writes the
/// port it landed on back into the setting, keeps a notice for Settings and posts a user
/// notification through the injected poster. Everything here runs on EPHEMERAL ports taken
/// from the OS, never 8765 / 8784 / 8787 / 8789: Tonebox, Threadstow, Baton and Seedbed are
/// live on the machine that runs this suite, and a test that touched their ports would either
/// fail on them or, worse, move them.
@MainActor
final class MCPPortSurfacingTests: XCTestCase {
    private var model: MusicModel!
    private var tempDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    /// What the injected poster received. A `@MainActor` box is `Sendable`, so the poster
    /// closure can capture it where it could not capture the test case.
    @MainActor private final class NoticeBox { var notices: [BatonMCPPortNotice] = [] }
    private var box = NoticeBox()
    private var notices: [BatonMCPPortNotice] { box.notices }
    private var server: BatonMCPServer?
    private var blockers: [NWListener] = []

    override func setUp() async throws {
        NavidromeKeychain.inMemoryStore = [:]
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-port-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        suiteName = "MCPPortSurfacingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        model = MusicModel()
        box = NoticeBox()
    }

    override func tearDown() {
        server?.stop()
        server = nil
        for blocker in blockers { blocker.cancel() }
        blockers = []
        defaults.removePersistentDomain(forName: suiteName)
        NavidromeKeychain.inMemoryStore = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Helpers

    /// Bind a loopback listener on a port the OS picks, and keep it so the port stays taken.
    private func occupyEphemeralPort() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        let port: UInt16? = await withCheckedContinuation { continuation in
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; continuation.resume(returning: listener.port?.rawValue) }
                case .failed, .cancelled:
                    if !resumed { resumed = true; continuation.resume(returning: nil) }
                default: break
                }
            }
            listener.start(queue: .main)
        }
        let bound = try XCTUnwrap(port, "could not take an ephemeral port")
        blockers.append(listener)
        return bound
    }

    /// A port the OS just handed out and we released again: free a moment ago, and far above
    /// every sibling default.
    private func freeEphemeralPort() async throws -> UInt16 {
        let port = try await occupyEphemeralPort()
        blockers.removeLast().cancel()
        try await Task.sleep(for: .milliseconds(50))
        return port
    }

    private func makeServer() -> BatonMCPServer {
        let box = box
        let s = BatonMCPServer(music: model, discoveryDirectory: tempDir, defaults: defaults) { notice in
            await MainActor.run { box.notices.append(notice) }
        }
        server = s
        return s
    }

    private func waitForBind(_ s: BatonMCPServer, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while s.boundPort == nil, s.lastError == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(s.boundPort, "server did not bind: \(s.lastError ?? "no error")", file: file, line: line)
    }

    private func waitForNotice(file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(2)
        while notices.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func discoveredURL() -> String? {
        AgentAccessInfo.load(from: tempDir)?.url
    }

    // MARK: - Tests

    func testBindsThePreferredPortWhenItIsFreeAndKeepsQuiet() async throws {
        let port = try await freeEphemeralPort()
        defaults.set(Int(port), forKey: BatonMCPConstants.preferredPortDefaultsKey)
        let s = makeServer()
        s.start()
        try await waitForBind(s)
        XCTAssertEqual(s.boundPort, port)
        XCTAssertNil(s.portNotice)
        XCTAssertEqual(BatonMCPPortScan.preferredPort(from: defaults), port, "setting untouched")
        XCTAssertEqual(discoveredURL(), AgentAccessInfo.endpointURL(port: port))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(notices.isEmpty, "no move, no notification")
    }

    func testMovesToTheNextFreePortPersistsItAndNotifies() async throws {
        let taken = try await occupyEphemeralPort()
        defaults.set(Int(taken), forKey: BatonMCPConstants.preferredPortDefaultsKey)
        let s = makeServer()
        s.start()
        try await waitForBind(s)
        let bound = try XCTUnwrap(s.boundPort)

        XCTAssertNotEqual(bound, taken, "the taken port must not be reported as bound")
        XCTAssertGreaterThan(bound, taken, "the scan walks upward")
        XCTAssertLessThan(bound, taken + UInt16(BatonMCPConstants.portScanRange) + 3)
        XCTAssertFalse(BatonMCPPortScan.siblingDefaultPorts.contains(bound))

        // The setting now shows the live port, so the field and the next launch agree.
        XCTAssertEqual(BatonMCPPortScan.preferredPort(from: defaults), bound)
        // The notice names both ports.
        XCTAssertEqual(s.portNotice, BatonMCPPortNotice(preferred: taken, bound: bound))
        XCTAssertEqual(s.portNotice?.message, "Port \(taken) was in use. Baton is on \(bound). Update your MCP client, or use mcp.json.")
        // mcp.json carries the bound port, as before.
        XCTAssertEqual(discoveredURL(), AgentAccessInfo.endpointURL(port: bound))
        // The user notification went out through the poster.
        try await waitForNotice()
        XCTAssertEqual(notices, [BatonMCPPortNotice(preferred: taken, bound: bound)])
    }

    func testReapplyingTheBoundPortDoesNotRestartTheServer() async throws {
        let taken = try await occupyEphemeralPort()
        defaults.set(Int(taken), forKey: BatonMCPConstants.preferredPortDefaultsKey)
        let s = makeServer()
        s.start()
        try await waitForBind(s)
        let bound = try XCTUnwrap(s.boundPort)
        XCTAssertEqual(s.bindCount, 1)

        // What the Settings field would do after the persist-back re-rendered it with the
        // bound port: apply the value it shows. Must be a no-op, or the persist-back loops.
        await s.apply(preferredPort: bound)
        XCTAssertEqual(s.boundPort, bound)
        XCTAssertEqual(s.bindCount, 1, "no second bind")
        XCTAssertTrue(s.isRunning)
        XCTAssertNil(s.portNotice, "accepting the port clears the notice")
        XCTAssertEqual(BatonMCPPortScan.preferredPort(from: defaults), bound)
    }

    func testChangingThePortRestartsOnTheNewOneAndRewritesDiscovery() async throws {
        let first = try await freeEphemeralPort()
        defaults.set(Int(first), forKey: BatonMCPConstants.preferredPortDefaultsKey)
        let s = makeServer()
        s.start()
        try await waitForBind(s)
        XCTAssertEqual(s.boundPort, first)

        let second = try await freeEphemeralPort()
        await s.apply(preferredPort: second)
        XCTAssertEqual(s.boundPort, second)
        XCTAssertEqual(s.bindCount, 2)
        XCTAssertNil(s.portNotice)
        XCTAssertEqual(BatonMCPPortScan.preferredPort(from: defaults), second)
        XCTAssertEqual(discoveredURL(), AgentAccessInfo.endpointURL(port: second))

        // The old port is released: something else can take it now. `NWListener.cancel` tears
        // the socket down asynchronously, so give it a moment rather than probing on the
        // very next tick.
        let deadline = Date().addingTimeInterval(3)
        var released = false
        while !released, Date() < deadline {
            released = await Self.canBind(first)
            if !released { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertTrue(released, "the previous port \(first) should be free after the move")
    }

    /// Bind and immediately release `port` on loopback, the way the server itself binds. The
    /// connection handler is not optional: an `NWListener` started without one fails with
    /// EINVAL, which reads exactly like "port taken" and cost an hour here.
    private static func canBind(_ port: UInt16) async -> Bool {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        guard let probe = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else { return false }
        probe.newConnectionHandler = { $0.cancel() }
        let ok: Bool = await withCheckedContinuation { continuation in
            nonisolated(unsafe) var resumed = false
            probe.stateUpdateHandler = { state in
                switch state {
                case .ready: if !resumed { resumed = true; continuation.resume(returning: true) }
                case .failed, .cancelled: if !resumed { resumed = true; continuation.resume(returning: false) }
                default: break
                }
            }
            probe.start(queue: .main)
        }
        probe.cancel()
        return ok
    }

    func testAnOutOfRangePortIsIgnored() async throws {
        let port = try await freeEphemeralPort()
        defaults.set(Int(port), forKey: BatonMCPConstants.preferredPortDefaultsKey)
        let s = makeServer()
        s.start()
        try await waitForBind(s)
        await s.apply(preferredPort: 80)
        XCTAssertEqual(s.boundPort, port)
        XCTAssertEqual(s.bindCount, 1)
        XCTAssertEqual(BatonMCPPortScan.preferredPort(from: defaults), port)
    }

    func testThePersistedPortIsHonouredOnTheNextStart() async throws {
        let taken = try await occupyEphemeralPort()
        defaults.set(Int(taken), forKey: BatonMCPConstants.preferredPortDefaultsKey)
        let s = makeServer()
        s.start()
        try await waitForBind(s)
        let moved = try XCTUnwrap(s.boundPort)
        s.stop()
        server = nil

        // "Next launch": a fresh server over the same defaults starts from the moved port and,
        // with the original still taken, lands on it directly without a notice.
        let again = makeServer()
        again.start()
        try await waitForBind(again)
        XCTAssertEqual(again.boundPort, moved)
        XCTAssertNil(again.portNotice)
        XCTAssertEqual(again.preferredPort, moved)
    }

    func testTheDefaultPreferredPortIs8787() {
        XCTAssertEqual(makeServer().preferredPort, 8787)
    }
}
