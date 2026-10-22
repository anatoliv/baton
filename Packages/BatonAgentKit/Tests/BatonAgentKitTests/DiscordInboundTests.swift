#if canImport(AVFoundation)
import XCTest
@testable import BatonAgentKit
import BatonSubsonicKit
import BatonSubsonicModels

/// One ordered record of what happened, shared by the REST stub and the tool surface.
private final class EventLog: @unchecked Sendable {
    static let shared = EventLog()
    private let lock = NSLock()
    private var events: [String] = []
    private var bodies: [String: [String: Any]] = [:]
    func add(_ event: String, body: [String: Any]? = nil) {
        lock.withLock { events.append(event); if let body { bodies[event] = body } }
    }
    func reset() { lock.withLock { events = []; bodies = [:] } }
    var all: [String] { lock.withLock { events } }
    func body(_ event: String) -> [String: Any]? { lock.withLock { bodies[event] } }
}

/// Discord's REST API, answering every call with an empty success.
private final class DiscordRESTStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "discord.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var body: Data? = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 4096); if n <= 0 { break }; data.append(buffer, count: n) }
            body = data
        }
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        EventLog.shared.add("\(request.httpMethod ?? "") \(url.path.replacingOccurrences(of: "/api/v10", with: ""))", body: json)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// C-11 and C-12: a tap must be answered inside Discord's 3 seconds however long Baton takes,
/// and a slow message must not stop the read loop (which is what reads heartbeat ACKs).
@MainActor
final class DiscordInboundTests: XCTestCase {
    private final class IdlePlayer: RemotePlayerContext {
        var nowPlaying: NavidromeSong? { nil }
        var queue: [NavidromeSong] { [] }
        var currentIndex: Int { 0 }
    }

    /// A tool that takes a while, as a model or a busy server does.
    private final class SlowSurface: RemoteToolSurface {
        func definitions() -> [[String: Any]] { TestToolFixtures.definitions }
        func run(name: String, arguments: [String: Any], sessionID: String?) async -> (text: String, isError: Bool) {
            EventLog.shared.add("tool \(name) started")
            try? await Task.sleep(for: .milliseconds(800))
            EventLog.shared.add("tool \(name) finished")
            return (#"{"ok":true}"#, false)
        }
    }

    private var suiteName: String!
    override func tearDown() {
        if let suiteName { UserDefaults().removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    private func bridge() -> DiscordBridge {
        EventLog.shared.reset()
        suiteName = ThrowawayDefaults.name("baton.discord.inbound")
        let settings = RemoteControlSettings(environment: .testing, defaults: UserDefaults(suiteName: suiteName)!,
                                             secrets: InMemorySecretStore())
        settings.authorize(sender: "42", on: .discord)
        let router = RemoteCommandRouter(player: IdlePlayer(), tools: SlowSurface(), settings: settings)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscordRESTStub.self]
        return DiscordBridge(token: "synthetic", router: router, configuration: configuration, onStateChange: { _ in })
    }

    private func waitFor(_ event: String, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !EventLog.shared.all.contains(event), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testATapIsAcknowledgedBeforeItsWorkAndAnsweredByEditingTheAcknowledgement() async {
        let bridge = bridge()
        await bridge.dispatch(["op": 0, "t": "INTERACTION_CREATE", "d": [
            "id": "900", "token": "tap-token", "application_id": "700", "channel_id": "c1",
            "user": ["id": "42", "username": "owner"], "data": ["custom_id": "pause"],
        ]])
        await waitFor("PATCH /webhooks/700/tap-token/messages/@original")
        let events = EventLog.shared.all
        let ack = events.firstIndex(of: "POST /interactions/900/tap-token/callback")
        let finished = events.firstIndex(of: "tool music_pause finished")
        XCTAssertNotNil(ack, "\(events)")
        XCTAssertNotNil(finished, "\(events)")
        if let ack, let finished { XCTAssertLessThan(ack, finished, "acknowledged before the work ends: \(events)") }
        XCTAssertEqual(EventLog.shared.body("POST /interactions/900/tap-token/callback")?["type"] as? Int, 5, "deferred")
        XCTAssertNotNil(EventLog.shared.body("PATCH /webhooks/700/tap-token/messages/@original")?["content"], "\(events)")
    }

    /// Turning the bridge off ends what is still queued: a message waiting behind a slow one
    /// must not act after stop() (REVIEW 4E333337).
    func testStopEndsWhatIsStillQueued() async {
        let bridge = bridge()
        await bridge.dispatch(["op": 0, "t": "MESSAGE_CREATE", "d": [
            "channel_id": "c1", "content": "pause", "author": ["id": "42", "username": "owner"],
        ]])
        await bridge.dispatch(["op": 0, "t": "MESSAGE_CREATE", "d": [
            "channel_id": "c1", "content": "next", "author": ["id": "42", "username": "owner"],
        ]])
        await bridge.dispatch(["op": 0, "t": "MESSAGE_CREATE", "d": [
            "channel_id": "c1", "content": "resume", "author": ["id": "42", "username": "owner"],
        ]])
        await waitFor("tool music_pause started")
        bridge.stop()
        await waitFor("tool music_pause finished")
        try? await Task.sleep(for: .milliseconds(1200))
        let events = EventLog.shared.all
        XCTAssertFalse(events.contains("tool music_next started"), "a queued message acted after stop: \(events)")
        XCTAssertFalse(events.contains("tool music_resume started"), "a queued message acted after stop: \(events)")
    }

    func testAMessageIsQueuedSoTheReadLoopKeepsReading() async {
        let bridge = bridge()
        await bridge.dispatch(["op": 0, "t": "MESSAGE_CREATE", "d": [
            "channel_id": "c1", "content": "pause", "author": ["id": "42", "username": "owner"],
        ]])
        XCTAssertFalse(EventLog.shared.all.contains("tool music_pause finished"),
                       "dispatch returned only after the work: \(EventLog.shared.all)")
        await waitFor("POST /channels/c1/messages")
        XCTAssertTrue(EventLog.shared.all.contains("tool music_pause finished"), "\(EventLog.shared.all)")
    }
}
#endif
