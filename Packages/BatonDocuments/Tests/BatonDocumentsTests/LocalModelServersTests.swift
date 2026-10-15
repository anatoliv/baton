import Foundation
import XCTest
@testable import BatonDocuments

/// Models and voices on this Mac (M7.2 to M7.4): what each server's answer means.
///
/// Fixtures: `ollama-tags.json` and `ollama-pull-installed.jsonl` were captured from Ollama
/// 0.35.0 on the Mac on 2026-10-03 (`qwen3:8b` installed), and `kokoro-voices.json` from
/// Kokoro-FastAPI, trimmed to six voices. `ollama-pull-download.jsonl` (a pull that downloads)
/// and `lmstudio-models.json` follow the vendors' documented formats, because capturing them
/// would mean downloading gigabytes or installing LM Studio.
final class LocalModelServersTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    // MARK: Ollama tags

    func testParsesTheRealTagsResponse() throws {
        let models = try OllamaAPI.parseTags(fixture("ollama-tags", "json"))
        XCTAssertEqual(models.map(\.name), ["qwen3:8b"])
        let qwen = try XCTUnwrap(models.first)
        XCTAssertEqual(qwen.sizeBytes, 5_225_388_164)
        XCTAssertEqual(qwen.parameterSize, "8.2B")
        XCTAssertEqual(qwen.quantization, "Q4_K_M")
        XCTAssertEqual(qwen.contextLength, 40_960)
    }

    func testAnEmptyOllamaHasNoModelsRatherThanAnError() throws {
        XCTAssertEqual(try OllamaAPI.parseTags(Data(#"{"models":[]}"#.utf8)), [])
    }

    func testSomethingElseOnTheTagsPortIsUnreadable() {
        XCTAssertThrowsError(try OllamaAPI.parseTags(Data("<html>nginx</html>".utf8)))
        XCTAssertThrowsError(try OllamaAPI.parseTags(Data(#"{"data":[]}"#.utf8)))
    }

    func testTheSavedOllamaSourceAsksForEightThousandTokensNotTheModelsMaximum() throws {
        let qwen = try XCTUnwrap(try OllamaAPI.parseTags(fixture("ollama-tags", "json")).first)
        let source = OllamaAPI.source(for: qwen)
        XCTAssertEqual(source.provider, .ollama)
        XCTAssertEqual(source.baseURL, "http://127.0.0.1:11434")
        XCTAssertEqual(source.model, "qwen3:8b")
        XCTAssertEqual(source.contextTokens, 8_192)
        XCTAssertEqual(source.name, "This Mac · Ollama · qwen3:8b")
        XCTAssertTrue(source.isLocal)
        // A model with a smaller window is planned against what it has.
        XCTAssertEqual(OllamaAPI.source(for: LocalModel(name: "tiny", contextLength: 2_048)).contextTokens, 2_048)
    }

    /// The test request goes through the router's own client, so what was tested is what runs:
    /// `think: false` and `num_ctx` in the body.
    func testTheOllamaTestRequestSendsNumCtxAndThinkFalse() throws {
        let source = OllamaAPI.source(for: LocalModel(name: "qwen3:8b", contextLength: 40_960))
        let request = try HTTPModelClient.request(for: source, system: LocalModelTest.system, user: LocalModelTest.user, apiKey: nil)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/api/chat")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["think"] as? Bool, false)
        XCTAssertEqual((body["options"] as? [String: Any])?["num_ctx"] as? Int, 8_192)
    }

    // MARK: Detection

    func testDetectionStates() throws {
        let tags = try fixture("ollama-tags", "json")
        let refused = LocalServerProbe.noAnswer("Could not connect to the server.")
        XCTAssertEqual(LocalServerState.detect(installed: false, probe: refused, parse: OllamaAPI.parseTags), .notInstalled)
        XCTAssertEqual(LocalServerState.detect(installed: true, probe: refused, parse: OllamaAPI.parseTags), .notRunning)
        let running = LocalServerState.detect(installed: true, probe: .answered(status: 200, body: tags), parse: OllamaAPI.parseTags)
        XCTAssertEqual(running.models.map(\.name), ["qwen3:8b"])
        XCTAssertTrue(running.isRunning)
    }

    /// A server built from source, or run from a folder, has no app to find. Its answer is
    /// what counts.
    func testAnAnsweringServerIsRunningEvenWhenNothingWasFoundOnDisk() throws {
        let state = LocalServerState.detect(installed: false, probe: .answered(status: 200, body: try fixture("ollama-tags", "json")),
                                            parse: OllamaAPI.parseTags)
        XCTAssertTrue(state.isRunning)
    }

    func testSomethingElseOnThePortIsNotCalledRunning() {
        let html = LocalServerState.detect(installed: true, probe: .answered(status: 200, body: Data("<html/>".utf8)),
                                           parse: OllamaAPI.parseTags)
        guard case .unexpected = html else { return XCTFail("got \(html)") }
        let notFound = LocalServerState.detect(installed: false, probe: .answered(status: 404, body: Data()),
                                               parse: LMStudioAPI.parseModels)
        XCTAssertEqual(notFound, .unexpected("Something on that port answered with HTTP 404."))
        XCTAssertFalse(notFound.isRunning)
        XCTAssertEqual(notFound.models, [])
    }

    // MARK: Pull progress

    private func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    func testPullProgressAcrossLayersOfARealDownloadShape() throws {
        var progress = OllamaPullProgress()
        var fractions: [Double?] = []
        for line in lines(try fixture("ollama-pull-download", "jsonl")) {
            try progress.apply(line: line)
            fractions.append(progress.fraction)
        }
        // Indeterminate on the manifest line, then the weights layer: 0, a quarter, a half.
        XCTAssertNil(fractions[0])
        XCTAssertEqual(fractions[1], 0)
        XCTAssertEqual(try XCTUnwrap(fractions[2]), 0.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(fractions[3]), 0.5, accuracy: 0.001)
        // A small layer appearing late barely moves the bar, and never sends it backwards.
        XCTAssertEqual(try XCTUnwrap(fractions[4]), 0.5, accuracy: 0.001)
        for (earlier, later) in zip(fractions.compactMap { $0 }, fractions.compactMap { $0 }.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier, later + 0.0001)
        }
        XCTAssertTrue(progress.succeeded)
        XCTAssertEqual(progress.fraction, 1)
        XCTAssertEqual(progress.totalBytes, 3_400_001_400)
        XCTAssertEqual(progress.status, "success")
    }

    func testPullOfAnInstalledModelFinishesAtOnce() throws {
        var progress = OllamaPullProgress()
        for line in lines(try fixture("ollama-pull-installed", "jsonl")) { try progress.apply(line: line) }
        XCTAssertTrue(progress.succeeded)
        XCTAssertEqual(progress.completedBytes, progress.totalBytes)
        XCTAssertEqual(progress.totalBytes, 5_225_374_496 + 1_723 + 11_338 + 120 + 487)
    }

    func testAPullErrorIsThrownWithOllamasWords() {
        var progress = OllamaPullProgress()
        XCTAssertThrowsError(try progress.apply(line: #"{"error":"pull model manifest: file does not exist"}"#)) { error in
            XCTAssertEqual(error as? OllamaPullProgress.Failure, .server("pull model manifest: file does not exist"))
        }
        XCTAssertThrowsError(try progress.apply(line: "not json"))
        XCTAssertNoThrow(try progress.apply(line: "   "))
        XCTAssertFalse(progress.succeeded)
    }

    func testThePullRequestStreamsTheNamedModel() throws {
        let request = try XCTUnwrap(OllamaAPI.pullRequest(model: "qwen3.5:4b"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/api/pull")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "qwen3.5:4b")
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    // MARK: Recommendation and free space

    func testTheRecommendationFollowsMemory() {
        let gb: UInt64 = 1 << 30
        XCTAssertEqual(RecommendedModel.forMac(physicalMemory: 8 * gb).name, "qwen3.5:4b")
        XCTAssertEqual(RecommendedModel.forMac(physicalMemory: 16 * gb).name, "qwen3.5:4b")
        XCTAssertEqual(RecommendedModel.forMac(physicalMemory: 24 * gb).name, "qwen3.5:9b")
        XCTAssertEqual(RecommendedModel.forMac(physicalMemory: 128 * gb).downloadBytes, 6_600_000_000)
    }

    func testAPullIsRefusedUpFrontWhenSpaceIsShort() {
        XCTAssertNil(RecommendedModel.pullRefusal(downloadBytes: 3_400_000_000, freeBytes: 100_000_000_000))
        XCTAssertNil(RecommendedModel.pullRefusal(downloadBytes: 3_400_000_000, freeBytes: nil))
        let refusal = RecommendedModel.pullRefusal(downloadBytes: 3_400_000_000, freeBytes: 4_000_000_000)
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.contains("4 GB free") == true, refusal ?? "")
    }

    // MARK: LM Studio

    func testParsesLMStudioModelsAndLeavesOutEmbeddings() throws {
        let models = try LMStudioAPI.parseModels(fixture("lmstudio-models", "json"))
        XCTAssertEqual(models.map(\.name), ["google/gemma-3-4b", "qwen2.5-7b-instruct"])
        XCTAssertThrowsError(try LMStudioAPI.parseModels(Data(#"{"models":[]}"#.utf8)))
    }

    func testTheLMStudioSourceIsOpenAICompatibleUnderV1() throws {
        let source = LMStudioAPI.source(for: LocalModel(name: "qwen2.5-7b-instruct"))
        XCTAssertEqual(source.provider, .openAICompatible)
        XCTAssertEqual(source.contextTokens, 4_096)
        XCTAssertTrue(source.isLocal)
        let request = try HTTPModelClient.request(for: source, system: LocalModelTest.system, user: LocalModelTest.user, apiKey: nil)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:1234/v1/chat/completions")
        XCTAssertEqual(LMStudioAPI.modelsRequest()?.url?.absoluteString, "http://127.0.0.1:1234/v1/models")
    }

    // MARK: The test request

    func testTheTestPassesOnlyOnTheRequestedObject() {
        XCTAssertTrue(LocalModelTest.passed(#"{"ready": true}"#))
        XCTAssertTrue(LocalModelTest.passed("```json\n{\"ready\": true}\n```"))
        XCTAssertTrue(LocalModelTest.passed("<think>\nok\n</think>\n\n{\"ready\":true}"))
        XCTAssertFalse(LocalModelTest.passed("Sure! {\"ready\": true}"))
        XCTAssertFalse(LocalModelTest.passed(#"{"ready": false}"#))
        XCTAssertFalse(LocalModelTest.passed(""))
    }

    // MARK: Kokoro

    func testParsesKokoroVoices() throws {
        let voices = try KokoroAPI.parseVoices(fixture("kokoro-voices", "json"))
        XCTAssertEqual(voices.count, 6)
        XCTAssertEqual(voices.first, "af_alloy")
        XCTAssertEqual(try KokoroAPI.parseVoices(Data(#"{"voices":["Emily.wav"]}"#.utf8)), ["Emily.wav"])
        XCTAssertThrowsError(try KokoroAPI.parseVoices(Data("{}".utf8)))
    }

    func testKokoroPlacement() {
        XCTAssertEqual(KokoroPlacement.classify(configuredBaseURL: "http://127.0.0.1:8880", hasStoredHost: false), .none)
        XCTAssertEqual(KokoroPlacement.classify(configuredBaseURL: "http://127.0.0.1:8880", hasStoredHost: true), .thisMac)
        XCTAssertEqual(KokoroPlacement.classify(configuredBaseURL: "http://localhost:8880/", hasStoredHost: true), .thisMac)
        XCTAssertEqual(KokoroPlacement.classify(configuredBaseURL: "http://10.0.0.5:8880", hasStoredHost: true), .network("10.0.0.5"))
        XCTAssertEqual(KokoroPlacement.classify(configuredBaseURL: "http://models.local:8880", hasStoredHost: true), .network("models.local"))
        XCTAssertEqual(KokoroPlacement.classify(configuredBaseURL: "https://tts.example.com", hasStoredHost: true), .elsewhere("tts.example.com"))
        XCTAssertEqual(KokoroPlacement.classify(configuredBaseURL: "   ", hasStoredHost: true), .none)
    }

    func testKokoroSummariesSayWhichOneBatonUses() {
        XCTAssertEqual(KokoroPlacement.thisMac.summary(localVoices: 54), "Baton speaks through the Kokoro on this Mac, which has 54 voices.")
        XCTAssertEqual(KokoroPlacement.thisMac.summary(localVoices: nil), "Baton is set to use a Kokoro on this Mac, and none is running.")
        XCTAssertEqual(KokoroPlacement.network("10.0.0.5").summary(localVoices: nil),
                       "Baton uses the Kokoro at 10.0.0.5 on your network. None is running on this Mac.")
        XCTAssertTrue(KokoroPlacement.network("10.0.0.5").summary(localVoices: 54).contains("http://127.0.0.1:8880"))
        XCTAssertTrue(KokoroPlacement.none.summary(localVoices: nil).hasPrefix("No Kokoro is set up"))
    }

    /// TBX-10854: with no Kokoro server, the row says what reads a book: the built-in voices when
    /// they are downloaded, and how to get them when they are not.
    func testKokoroSummaryNamesTheBuiltInVoicesWhenNoServerIsSetUp() {
        XCTAssertEqual(KokoroPlacement.none.summary(localVoices: nil, builtInVoicesReady: true),
                       "No Kokoro is set up, and none is running on this Mac. Books made on this Mac read with the built-in voices above, in English.")
        XCTAssertEqual(KokoroPlacement.none.summary(localVoices: nil, builtInVoicesReady: false),
                       "No Kokoro is set up, and none is running on this Mac. Books made on this Mac need one, or the built-in voices above once they are downloaded.")
    }

    /// : what a person reads has no em or en dashes.
    func testUserFacingSentencesHaveNoDashes() {
        let placements: [KokoroPlacement] = [.thisMac, .network("h"), .elsewhere("h"), .none]
        var sentences = placements.flatMap { [$0.summary(localVoices: nil), $0.summary(localVoices: 3),
                                               $0.summary(localVoices: nil, builtInVoicesReady: true)] }
        sentences.append(RecommendedModel.pullRefusal(downloadBytes: 9_000_000_000, freeBytes: 1_000_000_000) ?? "")
        sentences.append(OllamaPullProgress.Failure.server("x").description)
        for sentence in sentences {
            XCTAssertFalse(sentence.contains("\u{2014}") || sentence.contains("\u{2013}"), sentence)
        }
    }
}
