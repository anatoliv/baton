import XCTest
import Network
import BatonSubsonicKit
@testable import Baton

/// TBX-7306: the server binds the first free port from the user's preferred one, writes the
/// port it landed on back into the setting, keeps a notice for Settings and posts a user
/// notification through the injected poster. Everything here runs on ports in 30000...40000,
/// below the OS's ephemeral range (`testPorts`), never 8765 / 8784 / 8787 / 8789: Tonebox,
/// Threadstow, Baton and Seedbed are live on the machine that runs this suite, and a test that
/// touched their ports would either fail on them or, worse, move them.
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
        suiteName = ThrowawayDefaults.name("MCPPortSurfacingTests")
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

    /// Where these tests take ports: explicit ports below the OS's ephemeral range
    /// (`net.inet.ip.portrange.first`, 49152), which nothing is handed automatically. The tests
    /// used to take an OS-assigned ephemeral port and expect the ones just above it to be free,
    /// but macOS hands ephemeral ports out in sequence: under a loaded full suite every outgoing
    /// socket on the machine takes the next one, so the ports above were in use, or the counter
    /// sat near 65535 with no room above. Far from the siblings' 87xx defaults.
    private static let testPorts: ClosedRange<UInt16> = 30_000...40_000

    /// Bind a loopback listener on `port`, the way the server binds (no address reuse). Nil when
    /// the port is taken.
    private func bindBlocker(_ port: UInt16) async -> NWListener? {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = false
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: params, on: nwPort) else { return nil }
        listener.newConnectionHandler = { $0.cancel() }
        let ready: Bool = await withCheckedContinuation { continuation in
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; continuation.resume(returning: true) }
                case .failed, .cancelled:
                    if !resumed { resumed = true; continuation.resume(returning: false) }
                default: break
                }
            }
            listener.start(queue: .main)
        }
        if ready { return listener }
        listener.cancel()
        return nil
    }

    /// Take a port in `testPorts` and keep it for the whole test, so the port stays taken. A
    /// random start, so parallel runs and repeated iterations do not meet; a taken one is
    /// simply passed over.
    private func occupyPort() async throws -> UInt16 {
        for _ in 0..<64 {
            let port = UInt16.random(in: Self.testPorts.lowerBound...(Self.testPorts.upperBound - 64))
            if let listener = await bindBlocker(port) {
                blockers.append(listener)
                return port
            }
        }
        XCTFail("no free port in \(Self.testPorts)")
        throw CancellationError()
    }

    /// A port that was free a moment ago: taken in `testPorts` and released again. Nothing
    /// hands it to another socket meanwhile, as the OS would an ephemeral one.
    private func freePort() async throws -> UInt16 {
        let port = try await occupyPort()
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
        let port = try await freePort()
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
        let taken = try await occupyPort()
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

    /// Every value `lastError` takes, as it changes (Observation), so a transient error is seen
    /// however briefly it was set.
    @MainActor private final class ErrorRecorder {
        private(set) var seen: [String] = []
        private let server: BatonMCPServer
        init(_ server: BatonMCPServer) { self.server = server; track() }
        private func track() {
            withObservationTracking { _ = server.lastError } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    if let error = self.server.lastError { self.seen.append(error) }
                    self.track()
                }
            }
        }
    }

    /// TBX-11105: a taken port on the way up is part of the scan, not an error. The server used
    /// to publish "Listener failed: Address already in use" for it while still trying the next
    /// port, and `waitForBind` (like Settings) took that as the outcome: under a loaded full
    /// suite the next port was not ready within the poll, and the move test failed at 0.3 s
    /// with the taken port's EADDRINUSE. Watching every change, not polling, so it does not
    /// depend on timing.
    func testATakenPortDuringTheScanIsNotReportedAsAnError() async throws {
        let taken = try await occupyPort()
        defaults.set(Int(taken), forKey: BatonMCPConstants.preferredPortDefaultsKey)
        let s = makeServer()
        let recorder = ErrorRecorder(s)
        s.start()
        let deadline = Date().addingTimeInterval(5)
        while s.boundPort == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(s.boundPort, "the scan moved past the taken port")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.seen, [], "no error was published while the scan moved past \(taken)")
        XCTAssertNil(s.lastError)
    }

    func testReapplyingTheBoundPortDoesNotRestartTheServer() async throws {
        let taken = try await occupyPort()
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
        let first = try await freePort()
        defaults.set(Int(first), forKey: BatonMCPConstants.preferredPortDefaultsKey)
        let s = makeServer()
        s.start()
        try await waitForBind(s)
        XCTAssertEqual(s.boundPort, first)

        let second = try await freePort()
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
        let port = try await freePort()
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
        let taken = try await occupyPort()
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
