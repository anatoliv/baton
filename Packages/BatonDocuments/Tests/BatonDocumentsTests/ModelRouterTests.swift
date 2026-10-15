import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BatonDocuments

final class ModelRouterTests: XCTestCase {
    private let onDevice = ModelSource(name: "Apple's model on this Mac", provider: .appleOnDevice, baseURL: nil,
                                       model: "system", contextTokens: 4_096)
    private let ollama = ModelSource(name: "qwen3.5:4b on this Mac", provider: .ollama,
                                     baseURL: "http://127.0.0.1:11434", model: "qwen3.5:4b", contextTokens: 8_192)
    private let home = ModelSource(name: "the home server", provider: .openAICompatible,
                                   baseURL: "http://192.168.1.20:8000/v1", model: "chat", contextTokens: 32_000)
    private let cloud = ModelSource(name: "Anthropic", provider: .anthropic, baseURL: "https://api.anthropic.com",
                                    model: "claude-haiku-4-5-20251001", contextTokens: 200_000)

    func testLocalMeansThisMachineOrTheLAN() {
        XCTAssertTrue(onDevice.isLocal)
        XCTAssertTrue(ollama.isLocal)
        XCTAssertTrue(home.isLocal)
        XCTAssertFalse(cloud.isLocal)
        XCTAssertTrue(ModelSource.isPrivateHost("gpu-box.local"))
        XCTAssertTrue(ModelSource.isPrivateHost("100.101.1.2"), "Tailscale")
        XCTAssertFalse(ModelSource.isPrivateHost("127.example.com"), "a prefix is not an address")
        XCTAssertFalse(ModelSource.isPrivateHost("172.32.0.1"))
    }

    func testPlanSkipsSmallContextsAndUnconsentedCloud() {
        let router = ModelRouter(sources: [onDevice, ollama, home, cloud])
        let voice = router.plan(for: .voiceSuggestion)
        XCTAssertEqual(voice.usable.map(\.name), [onDevice.name, ollama.name, home.name])
        XCTAssertEqual(voice.skipped.map(\.1), [.needsConsent(.excerpt)])

        let cast = router.plan(for: .dialogueCast)
        XCTAssertEqual(cast.usable.map(\.name), [ollama.name, home.name])
        XCTAssertEqual(cast.skipped.map(\.1), [.contextTooSmall(have: 4_096, need: 8_000), .needsConsent(.chapter)])
    }

    func testConsentIsPerKindOfContent() {
        var consent = ModelConsent()
        consent.grant(cloud, .excerpt)
        let router = ModelRouter(sources: [cloud], consent: consent)
        XCTAssertEqual(router.plan(for: .voiceSuggestion).usable.map(\.name), ["Anthropic"])
        XCTAssertEqual(router.plan(for: .dialogueCast).usable, [], "excerpts were allowed, chapters were not")
    }

    func testFallsThroughInOrderAndNamesWhoAnswered() async throws {
        let router = ModelRouter(sources: [onDevice, ollama, home])
        let tried = Tried()
        let reply = try await router.complete(.voiceSuggestion, system: "s", user: "u") { source, _, _ in
            tried.add(source.name)
            if source.provider == .appleOnDevice { throw HTTPModelClient.Failure.notHTTP }
            if source.provider == .ollama { return "  " }
            return "{\"primary_voice\":\"bf_emma\"}"
        }
        XCTAssertEqual(reply.source, "the home server")
        XCTAssertEqual(tried.all, [onDevice.name, ollama.name, home.name])
    }

    func testWhenNothingAnswersTheFailureSaysWhyForEach() async {
        let router = ModelRouter(sources: [onDevice, cloud])
        do {
            _ = try await router.complete(.dialogueCast, system: "s", user: "u") { _, _, _ in "never called" }
            XCTFail("expected a failure")
        } catch let failure as ModelRouter.Failure {
            XCTAssertEqual(failure.attempts, [
                "Apple's model on this Mac: 4096 tokens of context, needs 8000",
                "Anthropic: not allowed to send chapters",
            ])
        } catch {
            XCTFail("\(error)")
        }
        do {
            _ = try await ModelRouter(sources: []).complete(.recap, system: "", user: "") { _, _, _ in "" }
        } catch {
            XCTAssertEqual(String(describing: error), "no model is set up")
        }
    }

    // MARK: - HTTP dialects

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testOllamaAsksForItsContextAndNoThinking() throws {
        let r = try HTTPModelClient.request(for: ollama, system: "sys", user: "hello", apiKey: nil)
        XCTAssertEqual(r.url?.absoluteString, "http://127.0.0.1:11434/api/chat")
        let b = try body(r)
        XCTAssertEqual((b["options"] as? [String: Any])?["num_ctx"] as? Int, 8_192)
        XCTAssertEqual(b["think"] as? Bool, false)
        XCTAssertEqual(b["stream"] as? Bool, false)
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(try HTTPModelClient.text(from: Data(#"{"message":{"role":"assistant","content":"hi"}}"#.utf8),
                                                provider: .ollama), "hi")
    }

    func testOpenAICompatibleAndAnthropicShapes() throws {
        let o = try HTTPModelClient.request(for: home, system: "sys", user: "hello", apiKey: "k1")
        XCTAssertEqual(o.url?.absoluteString, "http://192.168.1.20:8000/v1/chat/completions")
        XCTAssertEqual(o.value(forHTTPHeaderField: "Authorization"), "Bearer k1")
        XCTAssertEqual((try body(o)["messages"] as? [[String: String]])?.first?["role"], "system")
        XCTAssertEqual(try HTTPModelClient.text(from: Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8),
                                                provider: .openAICompatible), "ok")

        let a = try HTTPModelClient.request(for: cloud, system: "sys", user: "hello", apiKey: "k2")
        XCTAssertEqual(a.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(a.value(forHTTPHeaderField: "x-api-key"), "k2")
        XCTAssertEqual(a.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(try body(a)["system"] as? String, "sys")
        XCTAssertEqual(try HTTPModelClient.text(from: Data(#"{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}"#.utf8),
                                                provider: .anthropic), "ab")

        XCTAssertThrowsError(try HTTPModelClient.request(for: onDevice, system: "", user: "", apiKey: nil))
        XCTAssertThrowsError(try HTTPModelClient.text(from: Data("{}".utf8), provider: .anthropic))
    }

    func testABaseURLWithoutV1GetsIt() throws {
        var lmStudio = home
        lmStudio.baseURL = "http://127.0.0.1:1234/"
        XCTAssertEqual(try HTTPModelClient.request(for: lmStudio, system: "", user: "", apiKey: nil).url?.absoluteString,
                       "http://127.0.0.1:1234/v1/chat/completions")
    }
}

final class Tried: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ n: String) { lock.lock(); names.append(n); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
}
