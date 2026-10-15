import BatonDocuments
import BatonSubsonicKit
import Foundation
import XCTest
@testable import Baton

/// The sources saved from Models on this Mac (M7.2, M7.3), as the router will read them.
final class LocalModelSourcesTests: XCTestCase {

    private let ollama = OllamaAPI.source(for: LocalModel(name: "qwen3:8b", contextLength: 40_960))
    private let lmStudio = LMStudioAPI.source(for: LocalModel(name: "qwen2.5-7b-instruct"))

    func testNothingSavedIsAnEmptyList() {
        XCTAssertEqual(LocalModelSources.configuredSources(in: ThrowawayDefaults.make("local-models-empty")), [])
    }

    func testRoundTripKeepsSavedOrder() {
        let defaults = ThrowawayDefaults.make("local-models-order")
        LocalModelSources.save(lmStudio, in: defaults)
        LocalModelSources.save(ollama, in: defaults)
        XCTAssertEqual(LocalModelSources.configuredSources(in: defaults), [lmStudio, ollama])
    }

    /// Saving the same model again (after a re-test) replaces it where it was, rather than
    /// listing it twice or moving it to the end.
    func testSavingAgainReplacesInPlace() {
        let defaults = ThrowawayDefaults.make("local-models-replace")
        LocalModelSources.save(ollama, in: defaults)
        LocalModelSources.save(lmStudio, in: defaults)
        var retested = ollama
        retested.contextTokens = 4_096
        LocalModelSources.save(retested, in: defaults)
        XCTAssertEqual(LocalModelSources.configuredSources(in: defaults), [retested, lmStudio])
    }

    func testRemove() {
        let defaults = ThrowawayDefaults.make("local-models-remove")
        LocalModelSources.save(ollama, in: defaults)
        LocalModelSources.save(lmStudio, in: defaults)
        LocalModelSources.remove(id: ollama.id, in: defaults)
        XCTAssertEqual(LocalModelSources.configuredSources(in: defaults), [lmStudio])
    }

    /// The list is "what runs on this Mac": a cloud source in it (planted by hand or by a later
    /// build) is never handed to the router from here, because it needs consent.
    func testOnlyLocalSourcesAreHandedOut() {
        let defaults = ThrowawayDefaults.make("local-models-cloud")
        let cloud = ModelSource(name: "Cloud", provider: .anthropic, baseURL: "https://api.anthropic.com",
                                model: "claude-haiku-4-5", contextTokens: 200_000)
        LocalModelSources.save(cloud, in: defaults)
        LocalModelSources.save(ollama, in: defaults)
        XCTAssertEqual(LocalModelSources.configuredSources(in: defaults), [ollama])
    }

    /// A damaged blob is not "nothing saved" to be written over: it is kept aside.
    func testADamagedBlobIsKeptAside() {
        let (name, defaults) = ThrowawayDefaults.suite("local-models-corrupt")
        defaults.set(Data("not json".utf8), forKey: LocalModelSources.key)
        XCTAssertEqual(LocalModelSources.configuredSources(in: defaults), [])
        let keys = UserDefaults(suiteName: name)?.dictionaryRepresentation().keys.filter { $0.hasPrefix(LocalModelSources.key) } ?? []
        XCTAssertTrue(keys.contains { $0.contains("corrupt") }, "keys: \(keys)")
    }
}
