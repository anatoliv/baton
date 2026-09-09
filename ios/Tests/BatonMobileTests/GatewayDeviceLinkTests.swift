import XCTest
@testable import BatonMobile

/// The device link is the app's one long-lived authenticated connection, and both of the
/// things wrong with it were invisible from the outside.
///
/// It captured the gateway token once and looped, so "Disconnect and delete my data" left a
/// foregrounded app presenting a credential the user had just revoked, running whatever
/// commands came back against the local player. And `poll` returned nil for every answer
/// that was not a well-formed 200 with a command in it, which the loop read as "the hold
/// expired, go again" — so a gateway answering 401 or 404 as fast as the LAN allows produced
/// an unbounded request loop for as long as the app was on screen. Neither shows up as an
/// error, a crash, or anything on screen. Only a test that counts requests can see them.
@MainActor
final class GatewayDeviceLinkTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // An isolated suite, so configuring a stub gateway is not a side effect on the
        // app's own agent settings.
        suiteName = "baton.devicelink.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        StubGatewayProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - What an answer means

    func testAnEmptyHoldIsIdleAndACommandIsACommand() {
        XCTAssertEqual(GatewayDeviceLink.classify(status: 200, hasCommand: false), .idle)
        XCTAssertEqual(GatewayDeviceLink.classify(status: 200, hasCommand: true), .command)
        XCTAssertEqual(GatewayDeviceLink.classify(status: 204, hasCommand: false), .idle)
    }

    /// The four cases that used to be indistinguishable from "nothing to do".
    func testEveryNonEmptyHoldIsSeparatedFromIt() {
        XCTAssertEqual(GatewayDeviceLink.classify(status: 401, hasCommand: false), .unauthorized)
        XCTAssertEqual(GatewayDeviceLink.classify(status: 403, hasCommand: false), .unauthorized)
        XCTAssertEqual(GatewayDeviceLink.classify(status: 404, hasCommand: false), .transient)
        XCTAssertEqual(GatewayDeviceLink.classify(status: 500, hasCommand: false), .transient)
        // A 200 whose body will not parse is not an empty hold either; it is a broken answer.
        XCTAssertEqual(GatewayDeviceLink.classify(status: 200, hasCommand: false), .idle)
    }

    func testBackoffDoublesAndStops() {
        var backoff = GatewayDeviceLink.minimumBackoff
        for _ in 0 ..< 20 { backoff = GatewayDeviceLink.escalate(backoff) }
        XCTAssertEqual(backoff, GatewayDeviceLink.maximumBackoff,
                       "backoff must have a ceiling, or a dead gateway becomes a dead battery")
        XCTAssertEqual(GatewayDeviceLink.escalate(.seconds(1)), .seconds(2))
    }

    // MARK: - The loop against a real (stubbed) server

    /// A gateway that answers 401 as fast as it can must not be asked again and again.
    ///
    /// On the old code this issued as many requests as a second allowed — hundreds — because
    /// nil meant "poll again at once". It now stops on the first 401, so one request is the
    /// whole run.
    func testA401StopsTheLoopInsteadOfSpinning() async throws {
        StubGatewayProtocol.reset()
        StubGatewayProtocol.status = 401

        let link = makeLink()
        link.start()
        XCTAssertTrue(link.isRunning, "the stub gateway is configured, so the loop should run")

        try await Task.sleep(for: .seconds(1))

        XCTAssertLessThanOrEqual(StubGatewayProtocol.requestCount, 3, """
            \(StubGatewayProtocol.requestCount) requests in one second against a gateway \
            answering 401. A rejected token is not a reason to try harder.
            """)
        XCTAssertFalse(link.isRunning, "a rejected token must stop the link, not slow it down")
        link.stop()
    }

    /// A 500 is not fatal, but it is not free either: the loop must sleep between attempts.
    func testAServerErrorIsRateLimited() async throws {
        StubGatewayProtocol.reset()
        StubGatewayProtocol.status = 500

        let link = makeLink()
        link.start()
        try await Task.sleep(for: .seconds(1))
        link.stop()

        XCTAssertLessThanOrEqual(StubGatewayProtocol.requestCount, 3, """
            \(StubGatewayProtocol.requestCount) requests in one second against a gateway \
            answering 500. The first backoff is \(GatewayDeviceLink.minimumBackoff).
            """)
    }

    /// The token is read per iteration, so deleting it ends the loop rather than leaving it
    /// holding a revoked credential.
    func testTheLoopStopsOnceTheTokenIsGone() async throws {
        StubGatewayProtocol.reset()
        // An empty hold, held briefly. The real gateway holds for about 25 seconds; a
        // hold of zero here would be a legitimate busy loop and would tell us nothing.
        StubGatewayProtocol.status = 200
        StubGatewayProtocol.holdMilliseconds = 50

        nonisolated(unsafe) var token: String? = "a-token"
        let link = makeLink(token: { _ in token })
        link.start()
        try await Task.sleep(for: .milliseconds(200))
        token = nil
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertFalse(link.isRunning, """
            the loop kept running after the gateway token was deleted — which is what the \
            purge does, and what left the app long-polling with a revoked credential
            """)
        link.stop()
    }

    // MARK: - The purge names it

    /// `SessionPurge` documents itself as "one function that names every store". The device
    /// link is a live authenticated connection it did not name: `deviceLink.stop()` appeared
    /// in exactly one place, the `.background` scene phase.
    func testPurgeStopsTheDeviceLink() {
        let model = MobileModel()
        model.agentConfig.gatewayURL = "http://127.0.0.1:59999"
        model.deviceLink.start()
        XCTAssertTrue(model.deviceLink.isRunning, "precondition: a link to stop")

        SessionPurge.purge(model, keepDownloads: true)

        XCTAssertFalse(model.deviceLink.isRunning, """
            after "Disconnect and delete my data" the app was still holding an authenticated \
            long-poll open with the token it had just deleted
            """)
    }

    // MARK: - Helpers

    private func makeLink(
        token: @escaping (String) -> String? = { _ in "a-token" }
    ) -> GatewayDeviceLink {
        let model = MobileModel()
        let config = AgentConfig(defaults: defaults, secrets: InMemorySecretStore())
        config.gatewayURL = "http://127.0.0.1:59999"
        return GatewayDeviceLink(
            tools: AgentTools(model: model),
            config: config,
            makeSession: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [StubGatewayProtocol.self]
                return URLSession(configuration: configuration)
            },
            token: token
        )
    }
}

/// Answers every gateway request with a fixed status, and counts how many were asked.
final class StubGatewayProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static let lock = NSLock()
    nonisolated(unsafe) private static var _requestCount = 0
    nonisolated(unsafe) private static var _status = 200
    nonisolated(unsafe) private static var _hold = 0

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _requestCount
    }

    static var status: Int {
        get { lock.lock(); defer { lock.unlock() }; return _status }
        set { lock.lock(); _status = newValue; lock.unlock() }
    }

    /// How long the stub holds the request before answering, in milliseconds.
    static var holdMilliseconds: Int {
        get { lock.lock(); defer { lock.unlock() }; return _hold }
        set { lock.lock(); _hold = newValue; lock.unlock() }
    }

    static func reset() {
        lock.lock(); _requestCount = 0; _status = 200; _hold = 0; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._requestCount += 1
        let status = Self._status
        let hold = Self._hold
        Self.lock.unlock()

        let respond = { [weak self] in
            guard let self, let url = self.request.url else { return }
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data("{}".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if hold > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(hold), execute: respond)
        } else {
            respond()
        }
    }

    override func stopLoading() {}
}
