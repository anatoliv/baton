#if canImport(AVFoundation)
import XCTest
@testable import BatonAgentKit
import BatonSubsonicKit
import BatonSubsonicModels

/// A synthetic Bot API. `getMe` answers from a script (a network failure, a refusal or the
/// bot); `getUpdates` holds the long poll open until the bridge stops.
private final class BotAPIStub: URLProtocol, @unchecked Sendable {
    enum GetMe { case offline, unauthorized, bot }
    nonisolated(unsafe) static var script: [GetMe] = []
    nonisolated(unsafe) static var getMeCalls = 0
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.telegram.org" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        guard url.lastPathComponent == "getMe" else { return }  // the long poll never answers
        let step: GetMe = Self.lock.withLock {
            Self.getMeCalls += 1
            return Self.script.isEmpty ? .bot : Self.script.removeFirst()
        }
        let body: String
        switch step {
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        case .unauthorized: body = #"{"ok":false,"error_code":401,"description":"Unauthorized"}"#
        case .bot: body = #"{"ok":true,"result":{"id":1,"is_bot":true,"username":"baton_test_bot"}}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: step == .unauthorized ? 401 : 200,
                                                              httpVersion: "HTTP/1.1", headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// C-14: a getMe that failed at start (no network yet) left the bridge dead until toggled.
@MainActor
final class TelegramBridgeStartTests: XCTestCase {
    private final class IdlePlayer: RemotePlayerContext {
        var nowPlaying: NavidromeSong? { nil }
        var queue: [NavidromeSong] { [] }
        var currentIndex: Int { 0 }
    }
    private final class NoSurface: RemoteToolSurface {
        func definitions() -> [[String: Any]] { [] }
        func run(name: String, arguments: [String: Any], sessionID: String?) async -> (text: String, isError: Bool) { ("", true) }
    }

    private var suiteName: String!
    override func tearDown() {
        if let suiteName { UserDefaults().removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    private func bridge(_ states: @escaping (RemoteConnectionState) -> Void) -> TelegramBridge {
        suiteName = ThrowawayDefaults.name("baton.telegram.start")
        let settings = RemoteControlSettings(environment: .testing, defaults: UserDefaults(suiteName: suiteName)!,
                                             secrets: InMemorySecretStore())
        let router = RemoteCommandRouter(player: IdlePlayer(), tools: NoSurface(), settings: settings)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotAPIStub.self]
        return TelegramBridge(token: "0:synthetic", router: router, configuration: configuration, onStateChange: states)
    }

    func testAFailedFirstGetMeIsRetriedUntilTheBotAnswers() async {
        BotAPIStub.lock.withLock { BotAPIStub.script = [.offline]; BotAPIStub.getMeCalls = 0 }
        let connected = expectation(description: "the bridge connects after the network returns")
        var states: [RemoteConnectionState] = []
        let bridge = bridge { state in
            states.append(state)
            if case .connected = state { connected.fulfill() }
        }
        bridge.start()
        await fulfillment(of: [connected], timeout: 5)
        bridge.stop()
        XCTAssertEqual(BotAPIStub.lock.withLock { BotAPIStub.getMeCalls }, 2)
        XCTAssertTrue(states.contains { if case .failed = $0 { true } else { false } }, "the outage was shown: \(states)")
    }

    func testARejectedTokenStopsWithoutRetrying() async throws {
        BotAPIStub.lock.withLock { BotAPIStub.script = [.unauthorized]; BotAPIStub.getMeCalls = 0 }
        let failed = expectation(description: "the bridge reports the refusal")
        let bridge = bridge { state in if case .failed = state { failed.fulfill() } }
        bridge.start()
        await fulfillment(of: [failed], timeout: 5)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(BotAPIStub.lock.withLock { BotAPIStub.getMeCalls }, 1, "a refused token is not retried")
        bridge.stop()
    }
}
#endif
