import BatonAgentKit
import BatonDocuments
import Foundation
import XCTest
@testable import Baton

/// Apple's on-device model in the Mac's source list (M7.1): first when it can answer, never
/// listed when it cannot, and never in need of consent.
final class AppleOnDeviceSourceTests: XCTestCase {
    private func agent() -> RemoteControlSettings.NaturalLanguageConfig {
        var config = RemoteControlSettings.NaturalLanguageConfig()
        config.isEnabled = true
        config.provider = .anthropic
        config.baseURL = "https://api.anthropic.com"
        config.model = "chat"
        return config
    }

    func testOnDeviceComesFirstAndNeedsNoConsent() {
        let onDevice = AppleOnDeviceModel.source(contextTokens: 4_096)
        let sources = VoiceSuggestions.sources(agent: agent(), ollamaModel: "qwen3:8b", onDevice: onDevice)
        XCTAssertEqual(sources.map(\.name), ["Apple Intelligence on this Mac", "qwen3:8b on this Mac", "Anthropic"])
        let plan = ModelRouter(sources: sources).plan(for: .voiceSuggestion)
        XCTAssertEqual(plan.usable.map(\.name), ["Apple Intelligence on this Mac", "qwen3:8b on this Mac"])
        XCTAssertFalse(CloudModelConsent.cloudSources(agent: agent()).contains(onDevice), "never on the consent screen")
    }

    func testWithoutItTheListIsUnchanged() {
        XCTAssertEqual(VoiceSuggestions.sources(agent: agent(), ollamaModel: nil, onDevice: nil).map(\.name), ["Anthropic"])
    }

    /// The live value on this Mac, and that the source is offered exactly when it is available.
    func testOfferedExactlyWhenAvailable() {
        let availability = AppleOnDeviceModel.availability
        print("Apple on-device availability in the Mac test host: \(availability)")
        XCTAssertEqual(AppleOnDeviceModel.sourceIfAvailable() != nil, availability.isAvailable)
    }

    func testTheRecapCanBeWrittenOnDevice() async throws {
        try XCTSkipUnless(AppleOnDeviceModel.availability.isAvailable, AppleOnDeviceModel.availability.explanation)
        let router = ModelRouter(sources: [AppleOnDeviceModel.source()])
        let reply = try await router.complete(.recap, system: "Answer in one short sentence.", user: "Say hello to Vashti.",
                                              executor: AppleOnDeviceModel.executor(otherwise: { _, _, _ in
                                                  XCTFail("the on-device source is not HTTP"); return "" }))
        XCTAssertEqual(reply.source, "Apple Intelligence on this Mac")
        XCTAssertFalse(reply.text.isEmpty)
    }
}
