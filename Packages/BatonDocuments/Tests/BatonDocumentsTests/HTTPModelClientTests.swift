import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BatonDocuments

/// What `HTTPModelClient` needs so that it is the app's only model client (card M4.2b): the
/// summarizer's tolerant base URLs, its two-minute timeout, no temperature, an empty key sent as
/// given, and the server's own error message rather than a slice of raw JSON.
final class HTTPModelClientTests: XCTestCase {
    override func tearDown() {
        ModelStubProtocol.reset()
        super.tearDown()
    }

    private func source(_ provider: ModelSource.Provider, _ base: String?) -> ModelSource {
        ModelSource(name: "test", provider: provider, baseURL: base, model: "m", contextTokens: 8_192)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    // MARK: - Endpoint

    /// People paste either the bare root or the full endpoint out of a provider's docs, and a
    /// second path appended to the full one is a 404 that explains nothing.
    func testEveryWayABaseURLIsPastedReachesTheSameEndpoint() throws {
        for base in ["http://h:8000", "http://h:8000/", " http://h:8000/v1 ", "http://h:8000/v1/",
                     "http://h:8000/v1/chat/completions", "http://h:8000/v1/chat/completions/",
                     "http://h:8000/chat/completions"] {
            XCTAssertEqual(try HTTPModelClient.endpoint(for: source(.openAICompatible, base)).absoluteString,
                           "http://h:8000/v1/chat/completions", "openAI-compatible base \(base)")
        }
        for base in ["https://api.anthropic.com", "https://api.anthropic.com/v1", "https://api.anthropic.com/v1/messages/",
                     " https://api.anthropic.com/ "] {
            XCTAssertEqual(try HTTPModelClient.endpoint(for: source(.anthropic, base)).absoluteString,
                           "https://api.anthropic.com/v1/messages", "anthropic base \(base)")
        }
        XCTAssertEqual(try HTTPModelClient.endpoint(for: source(.ollama, "http://127.0.0.1:11434/")).absoluteString,
                       "http://127.0.0.1:11434/api/chat")
        // A path in front of the version stays: LiteLLM and gateways are often mounted under one.
        XCTAssertEqual(try HTTPModelClient.endpoint(for: source(.openAICompatible, "http://h/llm/v1")).absoluteString,
                       "http://h/llm/v1/chat/completions")
    }

    func testAnAddressThatIsNotAURLIsRefusedBeforeAnyRequest() {
        XCTAssertThrowsError(try HTTPModelClient.endpoint(for: source(.openAICompatible, "192.168.1.5:8000"))) {
            XCTAssertEqual($0 as? HTTPModelClient.Failure, .badURL("192.168.1.5:8000/v1/chat/completions"))
        }
        XCTAssertThrowsError(try HTTPModelClient.endpoint(for: source(.openAICompatible, nil)))
        XCTAssertThrowsError(try HTTPModelClient.endpoint(for: source(.appleOnDevice, nil))) {
            XCTAssertEqual($0 as? HTTPModelClient.Failure, .notHTTP)
        }
    }

    // MARK: - Request options

    /// The router's tasks want a fixed answer (temperature 0) and room to think (180 s); the
    /// transcript summarizer has always used the server's own temperature and two minutes, and
    /// its summaries must not change because its client did.
    func testTimeoutAndTemperatureAreTheCallersChoice() throws {
        let defaults = try HTTPModelClient.request(for: source(.openAICompatible, "http://h"), system: "s", user: "u", apiKey: nil)
        XCTAssertEqual(defaults.timeoutInterval, 180)
        XCTAssertEqual(try body(defaults)["temperature"] as? Double, 0)

        for provider in [ModelSource.Provider.openAICompatible, .anthropic] {
            let r = try HTTPModelClient.request(for: source(provider, "http://h"), system: "s", user: "u", apiKey: "k",
                                                timeout: 120, temperature: nil)
            XCTAssertEqual(r.timeoutInterval, 120)
            XCTAssertNil(try body(r)["temperature"], "\(provider)")
            XCTAssertEqual(try body(r)["max_tokens"] as? Int, 1_024)
        }

        let anthropic = try HTTPModelClient.request(for: source(.anthropic, "http://h"), system: "s", user: "u", apiKey: "k")
        XCTAssertNil(try body(anthropic)["temperature"], "Anthropic has never been sent one, by either caller")

        let ollama = try HTTPModelClient.request(for: source(.ollama, "http://h"), system: "s", user: "u", apiKey: nil,
                                                 temperature: nil)
        let options = try XCTUnwrap(try body(ollama)["options"] as? [String: Any])
        XCTAssertNil(options["temperature"])
        XCTAssertEqual(options["num_ctx"] as? Int, 8_192, "the context is still asked for")
    }

    /// `nil` is "this source has no key"; a string is sent as it is, even an empty one, because
    /// a server can answer "no key" and "an empty key" differently and the summarizer's errors
    /// must read the same as before. The Anthropic version header is not a credential.
    func testAKeyIsSentAsGivenAndNoKeyIsNotSent() throws {
        let emptyBearer = try HTTPModelClient.request(for: source(.openAICompatible, "http://h"), system: "", user: "", apiKey: "")
        XCTAssertEqual(emptyBearer.value(forHTTPHeaderField: "Authorization"), "Bearer ")

        let anthropicNoKey = try HTTPModelClient.request(for: source(.anthropic, "http://h"), system: "", user: "", apiKey: nil)
        XCTAssertNil(anthropicNoKey.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(anthropicNoKey.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let anthropicEmpty = try HTTPModelClient.request(for: source(.anthropic, "http://h"), system: "", user: "", apiKey: "")
        XCTAssertEqual(anthropicEmpty.value(forHTTPHeaderField: "x-api-key"), "")
        XCTAssertNil(anthropicEmpty.value(forHTTPHeaderField: "Authorization"))

        let ollamaNoKey = try HTTPModelClient.request(for: source(.ollama, "http://h"), system: "", user: "", apiKey: nil)
        XCTAssertNil(ollamaNoKey.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Errors

    func testTheServersOwnErrorMessageIsPreferredToItsJSON() {
        XCTAssertEqual(HTTPModelClient.errorMessage(from: Data(#"{"error":{"message":"invalid x-api-key","type":"x"}}"#.utf8)),
                       "invalid x-api-key")
        XCTAssertEqual(HTTPModelClient.errorMessage(from: Data(#"{"error":"model 'q' not found"}"#.utf8)),
                       #"{"error":"model 'q' not found"}"#, "Ollama's string error is relayed whole")
        XCTAssertEqual(HTTPModelClient.errorMessage(from: Data(String(repeating: "x", count: 500).utf8)).count, 200)
    }

    func testSendReturnsTheReplyText() async throws {
        ModelStubProtocol.respond(200, #"{"choices":[{"message":{"content":"hello"}}]}"#)
        let request = try HTTPModelClient.request(for: source(.openAICompatible, "http://h"), system: "s", user: "u", apiKey: nil)
        let text = try await HTTPModelClient.send(request, provider: .openAICompatible, session: ModelStubProtocol.session())
        XCTAssertEqual(text, "hello")
    }

    /// LM Studio with Qwen3 on a small budget, as captured live on 2026-10-15.
    func testAnEmptyReplyWhoseReasoningUsedTheBudgetSaysSo() {
        let body = #"{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"","reasoning_content":"Okay, the user wants"}}]}"#
        XCTAssertThrowsError(try HTTPModelClient.text(from: Data(body.utf8), provider: .openAICompatible)) { error in
            XCTAssertEqual(error as? HTTPModelClient.Failure, .reasoningUsedTheBudget)
        }
    }

    func testAReplyAfterReasoningIsReturnedAndAnEmptyFinishedReplyStaysEmpty() throws {
        let answered = #"{"choices":[{"finish_reason":"stop","message":{"content":"{\"ready\": true}","reasoning_content":"thinking"}}]}"#
        XCTAssertEqual(try HTTPModelClient.text(from: Data(answered.utf8), provider: .openAICompatible), #"{"ready": true}"#)
        // Empty but finished, or cut off with no reasoning: the caller judges an empty answer.
        let emptyStop = #"{"choices":[{"finish_reason":"stop","message":{"content":"","reasoning_content":"x"}}]}"#
        XCTAssertEqual(try HTTPModelClient.text(from: Data(emptyStop.utf8), provider: .openAICompatible), "")
        let cutNoReasoning = #"{"choices":[{"finish_reason":"length","message":{"content":""}}]}"#
        XCTAssertEqual(try HTTPModelClient.text(from: Data(cutNoReasoning.utf8), provider: .openAICompatible), "")
    }

    func testTheModelTestLeavesRoomToReason() {
        XCTAssertGreaterThanOrEqual(LocalModelTest.maxTokens, 512)
    }

    func testSendReportsAFailedStatusWithTheServersMessage() async throws {
        ModelStubProtocol.respond(401, #"{"error":{"message":"bad key"}}"#)
        let request = try HTTPModelClient.request(for: source(.anthropic, "http://h"), system: "s", user: "u", apiKey: "k")
        do {
            _ = try await HTTPModelClient.send(request, provider: .anthropic, session: ModelStubProtocol.session())
            XCTFail("a 401 must throw")
        } catch {
            XCTAssertEqual(error as? HTTPModelClient.Failure, .status(401, "bad key"))
        }
    }

    /// A transport failure stays a `URLError`, so a caller can tell "nothing answered" from
    /// "the local network is blocked" the way the agent does.
    func testSendLetsATransportFailureThroughAsItIs() async throws {
        ModelStubProtocol.fail(URLError(.cannotConnectToHost))
        let request = try HTTPModelClient.request(for: source(.ollama, "http://h"), system: "s", user: "u", apiKey: nil)
        do {
            _ = try await HTTPModelClient.send(request, provider: .ollama, session: ModelStubProtocol.session())
            XCTFail("a refused connection must throw")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
    }

    func testSendCallsAnUnreadableReplyUnreadable() async throws {
        ModelStubProtocol.respond(200, "<html>proxy</html>")
        let request = try HTTPModelClient.request(for: source(.openAICompatible, "http://h"), system: "s", user: "u", apiKey: nil)
        do {
            _ = try await HTTPModelClient.send(request, provider: .openAICompatible, session: ModelStubProtocol.session())
            XCTFail("HTML is not a model reply")
        } catch {
            XCTAssertEqual(error as? HTTPModelClient.Failure, .unreadable)
        }
    }

    /// The router's executor is `send` over the source's request, so the import sheet's "says
    /// why" carries the same server message.
    func testTheExecutorUsesTheSamePath() async throws {
        ModelStubProtocol.respond(404, #"{"error":{"message":"no such model"}}"#)
        let executor = HTTPModelClient.executor(session: ModelStubProtocol.session(), apiKey: { _ in "k" })
        do {
            _ = try await executor(source(.openAICompatible, "http://h/v1/chat/completions"), "s", "u")
            XCTFail("a 404 must throw")
        } catch {
            XCTAssertEqual(error as? HTTPModelClient.Failure, .status(404, "no such model"))
        }
        let sent = try XCTUnwrap(ModelStubProtocol.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "http://h/v1/chat/completions")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }
}

extension HTTPModelClientTests {
    /// TBX-10894: the executor asks for the running task's reply budget, as `max_tokens` and as
    /// Ollama's `num_predict`, so a model repeating itself stops at the budget.
    func testTheExecutorAsksForTheTasksReplyBudget() async throws {
        ModelStubProtocol.reset()
        defer { ModelStubProtocol.reset() }
        let executor = HTTPModelClient.executor(session: ModelStubProtocol.session(), apiKey: { _ in nil })
        func sentBody() throws -> [String: Any] {
            let request = try XCTUnwrap(ModelStubProtocol.requests.last)
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n <= 0 { break }
                    data.append(buffer, count: n)
                }
            }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        ModelStubProtocol.respond(200, #"{"message": {"role": "assistant", "content": "ok"}}"#)
        let ollama = ModelRouter(sources: [ModelSource(name: "o", provider: .ollama, baseURL: "http://127.0.0.1:11434", model: "m", contextTokens: 8_192)])
        _ = try await ollama.complete(.castSheet, system: "s", user: "u", executor: executor)
        XCTAssertEqual((try sentBody()["options"] as? [String: Any])?["num_predict"] as? Int, 2_048)
        _ = try await ollama.complete(.voiceSuggestion, system: "s", user: "u", executor: executor)
        XCTAssertEqual((try sentBody()["options"] as? [String: Any])?["num_predict"] as? Int, 1_024)

        ModelStubProtocol.respond(200, #"{"choices": [{"message": {"content": "ok"}}]}"#)
        let home = ModelRouter(sources: [ModelSource(name: "h", provider: .openAICompatible, baseURL: "http://192.168.4.21:8000/v1", model: "chat", contextTokens: 8_192)])
        _ = try await home.complete(.castSheet, system: "s", user: "u", executor: executor)
        XCTAssertEqual(try sentBody()["max_tokens"] as? Int, 2_048)
        _ = try await home.complete(.dialogueCast, system: "s", user: "u", executor: executor)
        XCTAssertEqual(try sentBody()["max_tokens"] as? Int, 1_536)
        _ = try await home.complete(.recap, system: "s", user: "u", executor: executor)
        XCTAssertEqual(try sentBody()["max_tokens"] as? Int, 1_024, "the default, as before")
    }
}

/// A transport that records each request and answers from `handler`, so nothing touches a network.
final class ModelStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        requests = []
    }

    static func respond(_ status: Int, _ body: String) {
        handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }

    static func fail(_ error: Error) {
        handler = { _ in throw error }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelStubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
