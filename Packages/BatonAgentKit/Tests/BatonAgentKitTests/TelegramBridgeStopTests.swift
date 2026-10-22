#if canImport(AVFoundation)
import XCTest
@testable import BatonAgentKit
import BatonSubsonicKit
import BatonSubsonicModels

private final class TelegramStopLog: @unchecked Sendable {
    static let shared = TelegramStopLog()
    private let lock = NSLock()
    private var events: [String] = []
    func add(_ event: String) { lock.withLock { events.append(event) } }
    func reset() { lock.withLock { events = [] } }
    var all: [String] { lock.withLock { events } }
}

/// A synthetic Bot API: one owner message on the first poll, then a long poll that never answers.
private final class TelegramStopStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var polls = 0
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.telegram.org" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let method = request.url!.lastPathComponent
        TelegramStopLog.shared.add("api \(method)")
        let body: String
        switch method {
        case "getMe": body = #"{"ok":true,"result":{"id":1,"is_bot":true,"username":"baton_test_bot"}}"#
        case "getUpdates":
            let first = Self.lock.withLock { Self.polls += 1; return Self.polls == 1 }
            guard first else { return }  // the long poll stays open
            body = #"{"ok":true,"result":[{"update_id":1,"message":{"text":"pause","chat":{"id":7},"from":{"id":42,"username":"owner"}}}]}"#
        default: body = #"{"ok":true,"result":{}}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Turning the bridge off while a slow answer is still being worked out: the answer must not
/// reach the session stop() invalidated, which raises an exception (REVIEW 4E333337 follow-up).
@MainActor
final class TelegramBridgeStopTests: XCTestCase {
    private final class IdlePlayer: RemotePlayerContext {
        var nowPlaying: NavidromeSong? { nil }
        var queue: [NavidromeSong] { [] }
        var currentIndex: Int { 0 }
    }
    private final class SlowSurface: RemoteToolSurface {
        func definitions() -> [[String: Any]] { TestToolFixtures.definitions }
        func run(name: String, arguments: [String: Any], sessionID: String?) async -> (text: String, isError: Bool) {
            TelegramStopLog.shared.add("tool \(name) started")
            try? await Task.sleep(for: .milliseconds(600))
            TelegramStopLog.shared.add("tool \(name) finished")
            return (#"{"ok":true}"#, false)
        }
    }

    private var suiteName: String!
    override func tearDown() {
        if let suiteName { UserDefaults().removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    private func waitFor(_ event: String, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !TelegramStopLog.shared.all.contains(event), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testStoppingWhileAnAnswerIsWorkedOutDoesNotUseTheClosedSession() async throws {
        TelegramStopLog.shared.reset()
        TelegramStopStub.lock.withLock { TelegramStopStub.polls = 0 }
        suiteName = ThrowawayDefaults.name("baton.telegram.stop")
        let settings = RemoteControlSettings(environment: .testing, defaults: UserDefaults(suiteName: suiteName)!,
                                             secrets: InMemorySecretStore())
        settings.authorize(sender: "42", on: .telegram)
        let router = RemoteCommandRouter(player: IdlePlayer(), tools: SlowSurface(), settings: settings)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelegramStopStub.self]
        let bridge = TelegramBridge(token: "0:synthetic", router: router, configuration: configuration, onStateChange: { _ in })
        bridge.start()
        await waitFor("tool music_pause started")
        XCTAssertTrue(TelegramStopLog.shared.all.contains("tool music_pause started"), "\(TelegramStopLog.shared.all)")
        bridge.stop()
        await waitFor("tool music_pause finished")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(TelegramStopLog.shared.all.contains("api sendMessage"), "\(TelegramStopLog.shared.all)")
    }
}
#endif
