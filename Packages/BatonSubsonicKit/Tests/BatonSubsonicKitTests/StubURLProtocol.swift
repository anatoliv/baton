import Foundation

/// A stubbed transport, so nothing in this target touches a network.
///
/// The same shape as the macOS app target's `NavidromeMockURLProtocol`, moved here because
/// this package had no test target of its own: its coverage was borrowed from the app, which
/// meant `swift test` in the package ran nothing and the iPhone gate ran none of it while
/// shipping the same code.
///
/// `handler` is called once per attempt, and `attempts` counts them, which is how the
/// read-versus-write retry question gets answered without a clock or a real server.
final class StubURLProtocol: URLProtocol {
    /// Called for each attempt, with the attempt number starting at 1. Return a response and
    /// body, or throw to simulate a transport failure.
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Int) throws -> (HTTPURLResponse, Data))?

    /// How many requests reached the stub since `reset()`.
    nonisolated(unsafe) static var attempts = 0

    /// Every URL the stub was asked for, newest last.
    nonisolated(unsafe) static var requestedURLs: [URL] = []

    static func reset() {
        handler = nil
        attempts = 0
        requestedURLs = []
    }

    /// A session wired to this stub and nothing else.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.attempts += 1
        if let url = request.url { Self.requestedURLs.append(url) }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request, Self.attempts)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Building responses

extension StubURLProtocol {
    static func http(_ status: Int, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    /// A 200 carrying a `subsonic-response` envelope whose body is `body`.
    static func ok(_ body: String, for request: URLRequest) -> (HTTPURLResponse, Data) {
        let json = #"{"subsonic-response":{"status":"ok","version":"1.16.1"\#(body.isEmpty ? "" : "," + body)}}"#
        return (http(200, for: request), Data(json.utf8))
    }

    /// A 200 carrying a Subsonic protocol error, which is how Subsonic reports a bad password.
    static func subsonicError(_ code: Int, _ message: String, for request: URLRequest) -> (HTTPURLResponse, Data) {
        let json = #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":\#(code),"message":"\#(message)"}}}"#
        return (http(200, for: request), Data(json.utf8))
    }
}
