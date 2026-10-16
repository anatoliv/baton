import Foundation
import XCTest
@testable import BatonDocuments

/// The client half of `POST /v1/books/complete`: the home server is a source the
/// router may always use, reached through `HTTPModelClient` with the gateway token, and a gateway
/// without the route (404) or one that refuses (403) is one more source that did not answer.
final class BookCompletionTests: XCTestCase {
    private let home = BookCompletion.source(gatewayURL: "https://home.example.net:8788/")
    private static let cloud = ModelSource(name: "Anthropic", provider: .anthropic, baseURL: "https://api.anthropic.com",
                                           model: "claude-haiku-4-5-20251001", contextTokens: 200_000)

    func testTheHomeServerIsLocalWhateverAddressReachesIt() {
        XCTAssertTrue(home.isLocal, "the gateway refuses a cloud model itself, so book text stays home")
        XCTAssertTrue(ModelConsent().allows(home, .chapter))
        XCTAssertGreaterThanOrEqual(home.contextTokens, ModelTask.recap.minimumContextTokens)
    }

    func testTheRequestIsTheRouteWithTheTokenAndTheTask() throws {
        let request = try HTTPModelClient.request(for: home, system: "S", user: "U", apiKey: "gateway-token", maxTokens: 512)
        XCTAssertEqual(request.url?.absoluteString, "https://home.example.net:8788/v1/books/complete")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gateway-token")
        let body = try JSONDecoder().decode(BookCompletion.Request.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(body, BookCompletion.Request(system: "S", user: "U", maxTokens: 512))
        XCTAssertGreaterThan(request.timeoutInterval, BookCompletion.modelTimeout, "the gateway's own timeout answers first")
    }

    func testTheAnswerIsTheText() throws {
        let data = try JSONEncoder().encode(BookCompletion.Response(text: "Previously, Ada.", model: "qwen3:8b"))
        XCTAssertEqual(try HTTPModelClient.text(from: data, provider: .homeServer), "Previously, Ada.")
        XCTAssertThrowsError(try HTTPModelClient.text(from: Data(#"{"error":"x"}"#.utf8), provider: .homeServer))
    }

    /// An older gateway answers 404 and one with a cloud model 403: the router writes it down and
    /// goes on to the next source, and the person is not told about the home server at all.
    func testARefusalOrAMissingRouteFallsThroughToTheNextSource() async throws {
        let onDevice = AppleOnDeviceModel.source()
        for status in [404, 403, 503] {
            let router = ModelRouter(sources: [home, onDevice])
            let answer = try await router.complete(.recap, system: "S", user: "U") { source, _, _ in
                if source.provider == .homeServer { throw HTTPModelClient.Failure.status(status, "no") }
                return "Previously, on the phone."
            }
            XCTAssertEqual(answer.source, onDevice.name, "after \(status)")
        }
    }

    /// The phone asks in the Mac's words (M4.6), naming the provider and what goes.
    func testTheConsentQuestionIsTheMacsRule() {
        XCTAssertEqual(ModelConsentWording.recapQuestion(Self.cloud),
                       "Send the chapters you have heard to Anthropic to write a recap?")
        let detail = ModelConsentWording.recapQuestionDetail(Self.cloud, device: "iPhone", settings: "Settings, Documents")
        XCTAssertTrue(detail.hasPrefix("Nothing on this iPhone, your network or the Baton server could write one. "))
        XCTAssertTrue(detail.contains("Nothing past where you are is sent."))
        XCTAssertTrue(detail.hasSuffix("You can change this any time in Settings, Documents."))
        let openAI = ModelSource(name: "x", provider: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "gpt", contextTokens: 8_192)
        XCTAssertEqual(ModelConsentWording.providerName(openAI), "OpenAI")
    }
}
