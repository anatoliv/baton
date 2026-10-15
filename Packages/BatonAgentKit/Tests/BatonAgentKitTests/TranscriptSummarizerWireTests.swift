import Foundation
import XCTest
@testable import BatonAgentKit
import BatonSubsonicModels

/// What the summarizer puts on the wire and what the person reads when it goes wrong.
///
/// Written before the summarizer moved onto `HTTPModelClient` (BatonDocuments, card M4.2b) and
/// run against both, so the move is held to "nothing the person sees changes": the same URL for
/// every way a base URL gets pasted, the same headers, the same body (no `temperature`, which
/// would change the summaries), the same two-minute timeout, and every error in the same words.
final class TranscriptSummarizerWireTests: XCTestCase {
    override func tearDown() {
        SummarizerStubProtocol.reset()
        super.tearDown()
    }

    private func config(_ provider: RemoteControlSettings.LLMProvider, baseURL: String,
                        apiKey: String = "k") -> RemoteControlSettings.NaturalLanguageConfig {
        var config = RemoteControlSettings.NaturalLanguageConfig()
        config.isEnabled = true
        config.provider = provider
        config.baseURL = baseURL
        config.model = "chat-model"
        config.apiKey = apiKey
        return config
    }

    private let oneSegment = Transcript(trackID: "x", segments: [.init(start: 0, end: 5, text: "hello there")])

    private func openAIReply(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": text]]]])
    }

    private func anthropicReply(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]]])
    }

    // MARK: - Request shape

    func testOpenAICompatibleRequestIsUnchanged() async throws {
        SummarizerStubProtocol.respond(200, openAIReply("TITLE: Greetings\nSomeone says hello."))
        let summary = try await TranscriptSummarizer.summarize(
            oneSegment, config: config(.openAICompatible, baseURL: "http://127.0.0.1:8000/v1/chat/completions/"),
            session: SummarizerStubProtocol.session()
        )

        XCTAssertEqual(summary.sections.map(\.title), ["Greetings"])
        XCTAssertEqual(summary.overview, "Someone says hello.", "one window is its own overview")
        XCTAssertEqual(summary.model, "chat-model")

        let request = try XCTUnwrap(SummarizerStubProtocol.requests.first)
        XCTAssertEqual(SummarizerStubProtocol.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8000/v1/chat/completions",
                       "a pasted full endpoint must not grow a second path")
        XCTAssertEqual(request.timeoutInterval, 120)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))

        let body = try SummarizerStubProtocol.body(of: request)
        XCTAssertEqual(Set(body.keys), ["model", "max_tokens", "messages"],
                       "no temperature or stream: the summaries depend on the server's defaults")
        XCTAssertEqual(body["model"] as? String, "chat-model")
        XCTAssertEqual(body["max_tokens"] as? Int, 1024)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages[0]["content"], TranscriptSummarizer.sectionSystemPrompt)
        XCTAssertEqual(messages[1]["content"], "Transcript excerpt (0:00 to 0:05):\n\nhello there")
    }

    func testOpenAICompatibleBaseURLVariantsAllReachTheSameEndpoint() async throws {
        for base in ["http://127.0.0.1:8000", "http://127.0.0.1:8000/", "http://127.0.0.1:8000/v1",
                     "http://127.0.0.1:8000/v1/chat/completions", "http://127.0.0.1:8000/chat/completions"] {
            SummarizerStubProtocol.reset()
            SummarizerStubProtocol.respond(200, openAIReply("fine"))
            _ = try await TranscriptSummarizer.summarize(
                text: "Some text.", config: config(.openAICompatible, baseURL: base),
                session: SummarizerStubProtocol.session()
            )
            XCTAssertEqual(SummarizerStubProtocol.requests.first?.url?.absoluteString,
                           "http://127.0.0.1:8000/v1/chat/completions", "base \(base)")
        }
    }

    func testAnthropicRequestIsUnchanged() async throws {
        SummarizerStubProtocol.respond(200, anthropicReply("A short summary."))
        let text = try await TranscriptSummarizer.summarize(
            text: "Some screen text.", config: config(.anthropic, baseURL: "http://192.168.1.9:8080/v1/messages"),
            session: SummarizerStubProtocol.session()
        )
        XCTAssertEqual(text, "A short summary.")

        let request = try XCTUnwrap(SummarizerStubProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://192.168.1.9:8080/v1/messages")
        XCTAssertEqual(request.timeoutInterval, 120)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = try SummarizerStubProtocol.body(of: request)
        XCTAssertEqual(Set(body.keys), ["model", "max_tokens", "system", "messages"])
        XCTAssertEqual(body["system"] as? String, TranscriptSummarizer.sectionSystemPrompt)
        XCTAssertEqual(body["max_tokens"] as? Int, 1024)
        XCTAssertEqual((body["messages"] as? [[String: String]])?.map { $0["role"] }, ["user"])
        XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], "Some screen text.")
    }

    func testAnthropicBaseURLVariantsAllReachTheSameEndpoint() async throws {
        for base in ["http://10.0.0.2:8080", "http://10.0.0.2:8080/v1", "http://10.0.0.2:8080/v1/messages/"] {
            SummarizerStubProtocol.reset()
            SummarizerStubProtocol.respond(200, anthropicReply("fine"))
            _ = try await TranscriptSummarizer.summarize(
                text: "Some text.", config: config(.anthropic, baseURL: base), session: SummarizerStubProtocol.session()
            )
            XCTAssertEqual(SummarizerStubProtocol.requests.first?.url?.absoluteString,
                           "http://10.0.0.2:8080/v1/messages", "base \(base)")
        }
    }

    /// A hosted endpoint the person agreed to, pasted with stray whitespace, still resolves.
    func testAConsentedHostedEndpointWithStrayWhitespaceResolves() async throws {
        SummarizerStubProtocol.respond(200, anthropicReply("fine"))
        _ = try await TranscriptSummarizer.summarize(
            text: "x", config: config(.anthropic, baseURL: " https://api.example.com/v1 "), consented: true,
            session: SummarizerStubProtocol.session()
        )
        XCTAssertEqual(SummarizerStubProtocol.requests.first?.url?.absoluteString, "https://api.example.com/v1/messages")
    }

    /// A model on this Mac with no key set still gets the headers it always got: an empty key is
    /// sent as an empty key, not dropped, so a server that answers the two differently says the
    /// same thing it said before.
    func testAnEmptyKeyIsSentTheWayItAlwaysWas() async throws {
        SummarizerStubProtocol.respond(200, openAIReply("fine"))
        _ = try await TranscriptSummarizer.summarize(
            text: "x", config: config(.openAICompatible, baseURL: "http://127.0.0.1:1234", apiKey: ""),
            session: SummarizerStubProtocol.session()
        )
        let openAI = try XCTUnwrap(SummarizerStubProtocol.requests.first)

        SummarizerStubProtocol.reset()
        SummarizerStubProtocol.respond(200, anthropicReply("fine"))
        _ = try await TranscriptSummarizer.summarize(
            text: "x", config: config(.anthropic, baseURL: "http://127.0.0.1:1234", apiKey: ""),
            session: SummarizerStubProtocol.session()
        )
        let anthropic = try XCTUnwrap(SummarizerStubProtocol.requests.first)

        XCTAssertEqual(openAI.value(forHTTPHeaderField: "Authorization"), SummarizerWireBaseline.emptyBearer)
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "x-api-key"), SummarizerWireBaseline.emptyAnthropicKey)
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01",
                       "the API version is not a credential and goes with or without a key")
    }

    /// Map, then reduce: one call per window, then one for the overview, sequentially, with the
    /// overview prompt and the outline it is given.
    func testALongTranscriptIsOneCallPerWindowThenAnOverview() async throws {
        SummarizerStubProtocol.handler = { request, attempt in
            let reply = attempt <= 2 ? "TITLE: Part \(attempt)\nBody \(attempt)." : "  The whole thing.  "
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": reply]]]]))
        }
        let transcript = Transcript(trackID: "x", segments: [
            .init(start: 0, end: 5, text: "alpha"), .init(start: 5, end: 10, text: "bravo"),
        ])
        let summary = try await TranscriptSummarizer.summarize(
            transcript, config: config(.openAICompatible, baseURL: "http://127.0.0.1:8000/v1"),
            windowSeconds: 5, session: SummarizerStubProtocol.session()
        )
        XCTAssertEqual(SummarizerStubProtocol.requests.count, 3)
        XCTAssertEqual(summary.sections.map(\.title), ["Part 1", "Part 2"])
        XCTAssertEqual(summary.overview, "The whole thing.")
        let reduce = try SummarizerStubProtocol.body(of: SummarizerStubProtocol.requests[2])
        let messages = try XCTUnwrap(reduce["messages"] as? [[String: String]])
        XCTAssertEqual(messages[0]["content"], TranscriptSummarizer.overviewSystemPrompt)
        XCTAssertEqual(messages[1]["content"],
                       "Section summaries, in order:\n\n[0:00] Part 1: Body 1.\n\n[0:05] Part 2: Body 2.")
    }

    // MARK: - Errors, in the person's words

    private func summaryError(_ config: RemoteControlSettings.NaturalLanguageConfig,
                              file: StaticString = #filePath, line: UInt = #line) async -> String? {
        do {
            _ = try await TranscriptSummarizer.summarize(oneSegment, config: config, session: SummarizerStubProtocol.session())
            XCTFail("expected a failure", file: file, line: line)
            return nil
        } catch let error as TranscriptSummarizer.SummaryError {
            XCTAssertFalse(error.needsConsent, file: file, line: line)
            return error.message
        } catch {
            XCTFail("expected SummaryError, got \(error)", file: file, line: line)
            return nil
        }
    }

    func testAnHTTPErrorNamesTheStatusTheServersMessageAndAHint() async {
        SummarizerStubProtocol.respond(401, Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8))
        let message = await summaryError(config(.anthropic, baseURL: "http://127.0.0.1:8000"))
        XCTAssertEqual(message, "The summarizing model returned HTTP 401. invalid x-api-key Check the API key.")
    }

    func testANonJSONErrorBodyIsRelayedAsText() async {
        SummarizerStubProtocol.respond(404, Data("no such route".utf8))
        let message = await summaryError(config(.openAICompatible, baseURL: "http://127.0.0.1:8000"))
        XCTAssertEqual(message, "The summarizing model returned HTTP 404. no such route Check the model name and the base URL.")
    }

    func testLiteLLMsUnrecognisedKeyGetsItsOwnHint() async {
        SummarizerStubProtocol.respond(400, Data(#"{"error":{"message":"No connected db."}}"#.utf8))
        let message = await summaryError(config(.openAICompatible, baseURL: "http://127.0.0.1:4000"))
        XCTAssertEqual(message, "The summarizing model returned HTTP 400. No connected db. That's how LiteLLM reports "
            + "a key it can't recognize: check you're using the key that server expects.")
    }

    func testAnUnreachableHostSaysSoInTheAgentsWords() async {
        SummarizerStubProtocol.fail(URLError(.cannotConnectToHost))
        let message = await summaryError(config(.openAICompatible, baseURL: "http://127.0.0.1:8000/v1"))
        XCTAssertEqual(message, RemoteNaturalLanguage.transportFailure(URLError(.cannotConnectToHost), host: "127.0.0.1")
            .localizedDescription)
    }

    func testAReplyWithNoTextIsNothingUsable() async {
        SummarizerStubProtocol.respond(200, Data(#"{"choices":[]}"#.utf8))
        let message = await summaryError(config(.openAICompatible, baseURL: "http://127.0.0.1:8000"))
        XCTAssertEqual(message, "The summarizing model replied with nothing usable.")
    }

    func testAnEmptyReplyIsNothingUsable() async {
        SummarizerStubProtocol.respond(200, anthropicReply(""))
        let message = await summaryError(config(.anthropic, baseURL: "http://127.0.0.1:8000"))
        XCTAssertEqual(message, "The summarizing model replied with nothing usable.")
    }

    func testAnUnreadableBodyIsNothingUsable() async {
        SummarizerStubProtocol.respond(200, Data("<html>gateway</html>".utf8))
        let message = await summaryError(config(.openAICompatible, baseURL: "http://127.0.0.1:8000"))
        XCTAssertEqual(message, "The summarizing model replied with nothing usable.")
    }
}

/// What the summarizer sent for an empty key before it moved onto `HTTPModelClient`, as
/// URLSession hands it to a protocol. Pinned from the run against the old implementation.
enum SummarizerWireBaseline {
    static let emptyBearer: String? = "Bearer "
    static let emptyAnthropicKey: String? = ""
}

/// A transport that records each request and answers from `handler`, so nothing here touches a
/// network.
final class SummarizerStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Int) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    /// Bodies read off each request's stream as it arrived, keyed by its position in `requests`.
    nonisolated(unsafe) static var bodies: [Data] = []

    static func reset() {
        handler = nil
        requests = []
        bodies = []
    }

    static func respond(_ status: Int, _ data: Data) {
        handler = { request, _ in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, data)
        }
    }

    static func fail(_ error: Error) {
        handler = { _, _ in throw error }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SummarizerStubProtocol.self]
        return URLSession(configuration: config)
    }

    static func body(of request: URLRequest) throws -> [String: Any] {
        let index = try XCTUnwrap(requests.firstIndex(of: request))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[index]) as? [String: Any])
    }

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        Self.bodies.append(Self.read(request))
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request, Self.requests.count)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func read(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
