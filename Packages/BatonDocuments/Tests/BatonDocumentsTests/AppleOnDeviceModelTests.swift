import Foundation
import XCTest
@testable import BatonDocuments

/// Apple's on-device model as a router source (M7.1). The routing and the words are tested
/// everywhere; the live calls run only where the model is available, and otherwise skip with the
/// reason the system gives.
final class AppleOnDeviceModelTests: XCTestCase {

    func testItIsALocalSourceNamedForThePerson() {
        let source = AppleOnDeviceModel.source(contextTokens: 4_096)
        XCTAssertEqual(source.name, "Apple Intelligence on this Mac")
        XCTAssertEqual(source.provider, .appleOnDevice)
        XCTAssertTrue(source.isLocal)
        XCTAssertTrue(ModelConsent().allows(source, .chapter), "on the device: no consent needed")
        let plan = ModelRouter(sources: [source]).plan(for: .voiceSuggestion)
        XCTAssertEqual(plan.usable, [source])
        XCTAssertEqual(ModelRouter(sources: [source]).plan(for: .dialogueCast).usable, [], "chapters do not fit in 4k")
    }

    func testEveryUnavailableReasonIsNamed() {
        let reasons: [OnDeviceModelAvailability] = [.deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .olderSystem, .other("x")]
        XCTAssertEqual(reasons.map(\.explanation), [
            "This Mac cannot run Apple Intelligence.",
            "Apple Intelligence is turned off. Turn it on in System Settings to use it here.",
            "macOS is still downloading Apple's model. Try again later.",
            "Apple's on-device model needs macOS 26 or later.",
            "Apple's on-device model is not available (x).",
        ])
        XCTAssertFalse(reasons.contains(where: \.isAvailable))
        XCTAssertTrue(OnDeviceModelAvailability.available.isAvailable)
    }

    func testOtherSourcesGoToTheHTTPClient() async throws {
        let ollama = ModelSource(name: "qwen", provider: .ollama, baseURL: "http://127.0.0.1:11434", model: "q", contextTokens: 8_192)
        let executor = AppleOnDeviceModel.executor(otherwise: { source, _, _ in "http:\(source.name)" })
        let reply = try await executor(ollama, "s", "u")
        XCTAssertEqual(reply, "http:qwen")
    }

    /// Where the model is not available here, asking it fails with the reason rather than
    /// hanging or answering, and the router moves on to the next source.
    func testWhenUnavailableTheRouterMovesOn() async throws {
        let availability = AppleOnDeviceModel.availability
        try XCTSkipIf(availability.isAvailable, "Apple Intelligence is available here; the live tests below cover it")
        let ollama = ModelSource(name: "qwen", provider: .ollama, baseURL: "http://127.0.0.1:11434", model: "q", contextTokens: 8_192)
        let router = ModelRouter(sources: [AppleOnDeviceModel.source(), ollama])
        let reply = try await router.complete(.recap, system: "s", user: "u",
                                              executor: AppleOnDeviceModel.executor(otherwise: { _, _, _ in "from qwen" }))
        XCTAssertEqual(reply.source, "qwen")
    }

    // MARK: Live, where available

    private func requireAvailable() throws {
        let availability = AppleOnDeviceModel.availability
        print("Apple on-device availability: \(availability) (\(availability.explanation)); context \(AppleOnDeviceModel.contextTokens) tokens")
        try XCTSkipUnless(availability.isAvailable, availability.explanation)
    }

    private let document = ImportedDocument(
        sourceSHA256: "machine", sourceKind: .pdf, title: "The Machine Stops", author: "E. M. Forster", language: "en",
        chapters: [DocumentChapter(index: 0, title: "The Air-Ship", paragraphs: [
            "Imagine, if you can, a small room, hexagonal in shape, like the cell of a bee.",
            "It is lighted neither by window nor by lamp, yet it is filled with a soft radiance.",
            "There are no apertures for ventilation, yet the air is fresh. There are no musical instruments, and yet, at the moment that my meditation opens, this room is throbbing with melodious sounds.",
            "An armchair is in the centre, by its side a reading-desk, that is all the furniture. And in the armchair there sits a swaddled lump of flesh, a woman, about five feet high, with a face as white as a fungus. It is to her that the little room belongs.",
        ])])

    func testLiveTheVoiceSuggestionIsATypedReplyTheCasterReads() async throws {
        try requireAvailable()
        let voices = ["kokoro:af_heart", "kokoro:bf_emma", "kokoro:bm_george", "kokoro:bf_isabella", "kokoro:am_adam"]
        let router = ModelRouter(sources: [AppleOnDeviceModel.source()])
        let executor = AppleOnDeviceModel.executor(otherwise: { _, _, _ in XCTFail("not HTTP"); return "" })
        let suggestion = await VoiceCaster.suggest(for: document, available: voices, languageDefault: "kokoro:af_heart") { system, user in
            try await router.complete(.voiceSuggestion, system: system, user: user, executor: executor)
        }
        XCTAssertNil(suggestion.fallbackReason, "the caster read the typed reply: \(suggestion)")
        XCTAssertEqual(suggestion.source, "Apple Intelligence on this Mac")
        XCTAssertTrue(voices.contains(suggestion.primary))
        XCTAssertEqual(suggestion.alternates.count, 2)
        print("Apple on-device suggestion: \(suggestion.primary) \(suggestion.alternates) \(suggestion.rationale)")
    }

    func testLiveTheRecapIsPlainText() async throws {
        try requireAvailable()
        let reply = try await AppleOnDeviceModel.respond(task: .recap, system: "Answer in one short sentence.",
                                                         user: "Say that the room was small and hexagonal.")
        XCTAssertFalse(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(reply.hasPrefix("{"), "plain text, not JSON: \(reply)")
    }
}
