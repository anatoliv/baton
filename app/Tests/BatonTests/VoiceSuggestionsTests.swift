import BatonAgentKit
import BatonDocuments
import Foundation
import XCTest
@testable import Baton

/// The import sheet's narrator suggestion (M4.4): which model sources it uses, what it does when
/// none can be used, and what it plays. The model is a fake that counts its calls, so "a cloud
/// source is never sent book text without consent" is asserted, not hoped for.
final class VoiceSuggestionsTests: XCTestCase {

    private let voices = ["kokoro:af_heart", "kokoro:bf_emma", "kokoro:bm_george", "kokoro:bf_isabella", "kokoro:am_adam"]

    private func document() -> ImportedDocument {
        ImportedDocument(sourceSHA256: "doc", sourceKind: .pdf, title: "The Machine Stops", author: "E. M. Forster",
                         language: "en",
                         chapters: [DocumentChapter(index: 0, title: "The Air-Ship", paragraphs: [
                            "Imagine, if you can, a small room, hexagonal in shape, like the cell of a bee.",
                            "It is lighted neither by window nor by lamp, yet it is filled with a soft radiance.",
                            "There are no apertures for ventilation, yet the air is fresh. The key is sk-abcdefghijklmnopqrstuv.",
                         ])])
    }

    private func agent(base: String, provider: RemoteControlSettings.LLMProvider, enabled: Bool = true) -> RemoteControlSettings.NaturalLanguageConfig {
        var config = RemoteControlSettings.NaturalLanguageConfig()
        config.isEnabled = enabled
        config.baseURL = base
        config.provider = provider
        config.model = "chat"
        config.apiKey = "test-key"
        return config
    }

    /// Counts calls and answers with a fixed reply.
    final class FakeModel: @unchecked Sendable {
        var calls: [String] = []
        let reply: String
        init(reply: String) { self.reply = reply }
        var executor: ModelRouter.Executor {
            { source, _, _ in self.calls.append(source.name); return self.reply }
        }
    }

    func testSourcesAreThisMacsOllamaThenTheMusicFriendsModel() {
        let sources = VoiceSuggestions.sources(agent: agent(base: "http://10.0.0.8:8000/v1", provider: .openAICompatible),
                                               ollamaModel: "qwen3:8b")
        XCTAssertEqual(sources.map(\.name), ["qwen3:8b on this Mac", "the Baton server"])
        XCTAssertEqual(sources.map(\.provider), [.ollama, .openAICompatible])
        XCTAssertTrue(sources.allSatisfy(\.isLocal))

        let cloud = VoiceSuggestions.sources(agent: agent(base: "https://api.anthropic.com", provider: .anthropic), ollamaModel: nil)
        XCTAssertEqual(cloud.map(\.name), ["Anthropic"])
        XCTAssertFalse(cloud[0].isLocal)

        XCTAssertEqual(VoiceSuggestions.sources(agent: agent(base: "http://10.0.0.8:8000/v1", provider: .openAICompatible,
                                                             enabled: false), ollamaModel: nil), [])
    }

    func testASuggestionFromThisMacsModelNamesItsSource() async {
        let model = FakeModel(reply: #"{"genre":"dystopia","era":"1909","tone":"grave","primary_voice":"bf_emma","alternates":["bm_george","bf_isabella"],"speed":0.95,"rationale":"An Edwardian English story wants a measured British voice."}"#)
        let sources = VoiceSuggestions.sources(agent: agent(base: "", provider: .openAICompatible, enabled: false), ollamaModel: "qwen3:8b")
        let suggestion = await VoiceSuggestions.suggest(for: document(), languageDefault: "kokoro:af_heart", sources: sources,
                                                        available: voices, executor: model.executor)
        XCTAssertNil(suggestion.fallbackReason)
        XCTAssertEqual(suggestion.primary, "kokoro:bf_emma")
        XCTAssertEqual(suggestion.alternates, ["kokoro:bm_george", "kokoro:bf_isabella"])
        XCTAssertEqual(suggestion.source, "qwen3:8b on this Mac")
        XCTAssertEqual(model.calls, ["qwen3:8b on this Mac"])
        XCTAssertEqual(DocumentImportSheet.suggestionLine(suggestion),
                       "Suggested by qwen3:8b on this Mac: An Edwardian English story wants a measured British voice.")
    }

    /// The consent rule (M4.6 adds the screen): a cloud model is never sent book text until
    /// the person allows it, so with only a cloud source the sheet falls back and says why.
    func testACloudModelIsNeverAskedWithoutConsent() async {
        let model = FakeModel(reply: #"{"primary_voice":"bf_emma"}"#)
        let sources = VoiceSuggestions.sources(agent: agent(base: "https://api.anthropic.com", provider: .anthropic), ollamaModel: nil)
        let suggestion = await VoiceSuggestions.suggest(for: document(), languageDefault: "kokoro:af_heart", sources: sources,
                                                        available: voices, executor: model.executor)
        XCTAssertEqual(model.calls, [], "no book text may go to a cloud source without consent")
        XCTAssertEqual(suggestion.primary, "kokoro:af_heart")
        XCTAssertNotNil(suggestion.fallbackReason)
        XCTAssertEqual(suggestion.alternates.count, 2)
    }

    func testWithNoModelTheLanguageDefaultIsUsedAndSaysWhy() async {
        let suggestion = await VoiceSuggestions.suggest(for: document(), languageDefault: "kokoro:af_heart", sources: [],
                                                        available: voices, executor: { _, _, _ in "" })
        XCTAssertEqual(suggestion.primary, "kokoro:af_heart")
        XCTAssertEqual(DocumentImportSheet.suggestionLine(suggestion),
                       "The default voice for the book's language, because no model is set up.")
    }

    func testOllamaDetectionSkipsEmbeddingModelsAndSurvivesItBeingDown() async {
        let tags = #"{"models":[{"name":"nomic-embed-text:latest"},{"name":"qwen3:8b"}]}"#
        let found = await VoiceSuggestions.detectOllamaModel(fetch: { request in
            (Data(tags.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        XCTAssertEqual(found, "qwen3:8b")
        let down = await VoiceSuggestions.detectOllamaModel(fetch: { _ in throw URLError(.cannotConnectToHost) })
        XCTAssertNil(down)
    }

    func testTheVoiceListIsReadFromKokoro() async {
        let body = #"{"voices":[{"id":"af_heart","name":"af_heart"},{"id":"bf_emma","name":"bf_emma"}]}"#
        let listed = await VoiceSuggestions.availableVoices(kokoroBase: "http://127.0.0.1:8880", others: [], fetch: { request in
            XCTAssertEqual(request.url?.path, "/v1/audio/voices")
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        XCTAssertEqual(listed, ["kokoro:af_heart", "kokoro:bf_emma"])
    }

    /// TBX-10916 under Voice engine for books: Emma narrates a British book with no
    /// suggestion only when the engine that will render has her. Built-in counts only the built-in
    /// voices; Voice server only the server's.
    func testTheNarratorDefaultFollowsTheVoiceEngineForBooks() async {
        var british = document()
        british.languageRegion = "gb"
        let serverBody = #"{"voices": ["af_heart", "bm_george"]}"#
        let up: DocumentImporter.Fetch = { request in
            (Data(serverBody.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let builtIn = ["kokoro:af_heart", "kokoro:bf_emma", "kokoro:bm_george"]
        func narrator(_ engine: BookVoiceSettings.Engine) async -> String {
            let list = await VoiceSuggestions.availableVoices(kokoroBase: "http://127.0.0.1:8880", others: [], builtIn: builtIn,
                                                              engine: engine, fetch: up)
            return await VoiceSuggestions.suggest(for: british, languageDefault: "kokoro:bm_george", sources: [],
                                                  available: list, executor: { _, _, _ in "" }).primary
        }
        let onBuiltIn = await narrator(.builtIn)
        XCTAssertEqual(onBuiltIn, "kokoro:bf_emma")
        let onServer = await narrator(.server)
        XCTAssertEqual(onServer, "kokoro:bm_george", "the server has no Emma: the configured default")
    }

    func testThePreviewIsTheBooksOpeningWithoutAnySecret() {
        let text = VoiceSuggestions.previewText(for: document())
        XCTAssertTrue(text.hasPrefix("Imagine, if you can, a small room"))
        XCTAssertFalse(text.contains("sk-abcdefghijklmnopqrstuv"))
        XCTAssertLessThanOrEqual(text.count, 221)
        XCTAssertTrue(text.hasSuffix("."), "cut at a sentence end: \(text)")
    }

    func testSavedSourcesComeFirstAndADetectedModelIsNotListedTwice() {
        let saved = [ModelSource(name: "qwen3:8b on this Mac", provider: .ollama, baseURL: "http://127.0.0.1:11434",
                                 model: "qwen3:8b", contextTokens: 8_192),
                     ModelSource(name: "LM Studio", provider: .openAICompatible, baseURL: "http://127.0.0.1:1234/v1",
                                 model: "local-model", contextTokens: 4_096)]
        let sources = VoiceSuggestions.sources(agent: agent(base: "http://10.0.0.8:8000/v1", provider: .openAICompatible),
                                               ollamaModel: "qwen3:8b", saved: saved)
        XCTAssertEqual(sources.map(\.name), ["qwen3:8b on this Mac", "LM Studio", "the Baton server"])
    }
}

/// The import sheet's Hear buttons (M4.4): one preview at a time, Hear then Stop then Hear again,
/// and a second voice stops the first. A fake voice server and a fake speaker stand in for Kokoro
/// and the Mac's audio, so the states are asserted without a sound.
@MainActor
final class VoicePreviewPlayerTests: XCTestCase {

    /// What the fake speaker was asked to do.
    @MainActor
    final class Speaker {
        var played: [Data] = []
        var stopped: [Data] = []
        var duration: TimeInterval = 60

        func play(_ wav: Data) -> VoicePreviewPlayer.Sound {
            played.append(wav)
            return .init(duration: duration, stop: { [weak self] in self?.stopped.append(wav) })
        }
    }

    private func player(_ speaker: Speaker, failing: Bool = false) -> VoicePreviewPlayer {
        VoicePreviewPlayer(synthesize: { _, voice in
            if failing { throw SynthesisError.transient("kokoro did not answer: offline") }
            return Data(voice.utf8)
        }, play: { speaker.play($0) })
    }

    private func until(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    func testHearThenStopThenHearAgain() async {
        let speaker = Speaker()
        let preview = player(speaker)

        preview.toggle("kokoro:bf_isabella", text: "Imagine a small room.")
        XCTAssertEqual(preview.playing, "kokoro:bf_isabella", "the button reads Stop at once")
        await until { speaker.played.count == 1 }
        XCTAssertEqual(speaker.played, [Data("kokoro:bf_isabella".utf8)])

        preview.toggle("kokoro:bf_isabella", text: "Imagine a small room.")
        XCTAssertNil(preview.playing, "pressed again, it stops and the button reads Hear")
        XCTAssertEqual(speaker.stopped, [Data("kokoro:bf_isabella".utf8)])

        preview.toggle("kokoro:bf_isabella", text: "Imagine a small room.")
        XCTAssertEqual(preview.playing, "kokoro:bf_isabella")
        await until { speaker.played.count == 2 }
        // The first, cancelled preview must not clear the second one's state as it unwinds.
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(preview.playing, "kokoro:bf_isabella", "still playing: Stop, not Hear")
        XCTAssertNil(preview.failure)
    }

    func testASecondVoiceStopsTheFirst() async {
        let speaker = Speaker()
        let preview = player(speaker)

        preview.toggle("kokoro:bf_isabella", text: "Opening.")
        await until { speaker.played.count == 1 }
        preview.toggle("kokoro:bm_george", text: "Opening.")
        XCTAssertEqual(preview.playing, "kokoro:bm_george", "only the second reads Stop")
        XCTAssertEqual(speaker.stopped, [Data("kokoro:bf_isabella".utf8)], "the first is cut short")
        await until { speaker.played.count == 2 }
        XCTAssertEqual(speaker.played.last, Data("kokoro:bm_george".utf8))
    }

    func testThePreviewEndsByItselfAndTheButtonReadsHearAgain() async {
        let speaker = Speaker()
        speaker.duration = 0.05
        let preview = player(speaker)
        preview.toggle("kokoro:bf_alice", text: "Opening.")
        await until { preview.playing == nil }
        XCTAssertEqual(speaker.played.count, 1)
        XCTAssertNil(preview.failure)
    }

    func testAVoiceThatCannotBePlayedSaysSo() async {
        let speaker = Speaker()
        let preview = player(speaker, failing: true)
        preview.toggle("kokoro:bf_alice", text: "Opening.")
        await until { preview.failure != nil }
        XCTAssertNil(preview.playing)
        XCTAssertEqual(preview.failure, "That voice could not be played: the voice server isn't answering.")
        XCTAssertTrue(speaker.played.isEmpty)
    }
}

/// The Mac's voice list is read with the Baton server's cap: 1 MB, refused as it
/// streams, as `SpeechEngines.listVoices` reads it on the server.
final class VoiceListingCapTests: XCTestCase {
    func testAVoiceListLargerThanTheCapIsRefusedAndOneWithinItIsRead() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let huge = Data(("{\"voices\":[" + Array(repeating: "\"af_heart\"", count: 120_000).joined(separator: ",") + "]}").utf8)
        XCTAssertGreaterThan(huge.count, CappedDownload.listingLimit)
        let big = dir.appendingPathComponent("big.json"), small = dir.appendingPathComponent("small.json")
        try huge.write(to: big)
        try Data(#"{"voices":["af_heart"]}"#.utf8).write(to: small)
        do {
            _ = try await VoiceSuggestions.listingFetch(URLRequest(url: big))
            XCTFail("a list over 1 MB should be refused")
        } catch let error as CappedDownload.TooLarge {
            XCTAssertEqual(error.limit, 1_024 * 1_024)
        }
        let (data, _) = try await VoiceSuggestions.listingFetch(URLRequest(url: small))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"voices":["af_heart"]}"#)
    }
}
