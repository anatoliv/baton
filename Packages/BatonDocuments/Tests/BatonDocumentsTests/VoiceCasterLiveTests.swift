import Foundation
import XCTest
@testable import BatonDocuments

/// The voice suggestion against a real model, end to end: `VoiceCaster` → `ModelRouter` →
/// `HTTPModelClient` → Ollama's native API.
///
/// Opt-in, like the conversation eval: set `BATON_LIVE_OLLAMA_MODEL` (and `BATON_LIVE_OLLAMA_URL`
/// if it is not on this machine). It **skips** unless the model answers a trivial prompt first,
/// because a host that is up but still loading answers nonsense, and that was once reported as a
/// broken feature (CLAUDE.md, *The conversation eval*). `BATON_DOCS_SAMPLE` adds the real book.
final class VoiceCasterLiveTests: XCTestCase {
    private func liveSource() async throws -> ModelSource {
        guard let model = ProcessInfo.processInfo.environment["BATON_LIVE_OLLAMA_MODEL"] else {
            throw XCTSkip("set BATON_LIVE_OLLAMA_MODEL to run against a real model")
        }
        let base = ProcessInfo.processInfo.environment["BATON_LIVE_OLLAMA_URL"] ?? "http://127.0.0.1:11434"
        let source = ModelSource(name: "\(model) (live)", provider: .ollama, baseURL: base, model: model, contextTokens: 8_192)
        let probe = HTTPModelClient.executor(apiKey: { _ in nil })
        guard let answer = try? await probe(source, "Answer with one word.", "Say OK."),
              answer.lowercased().contains("ok") else {
            throw XCTSkip("\(model) at \(base) did not answer a trivial prompt; not measurable")
        }
        return source
    }

    func testSuggestsARealVoiceForTheSample() async throws {
        let source = try await liveSource()
        let document: ImportedDocument
        if let path = ProcessInfo.processInfo.environment["BATON_DOCS_SAMPLE"] {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let r = LayoutTextImporter().extract(pages: text.components(separatedBy: "\u{0C}"))
            document = ImportedDocument(sourceSHA256: "live", sourceKind: .pdf, title: r.title ?? "", author: r.author,
                                        language: "en", chapters: r.chapters, frontMatter: r.frontMatter)
        } else {
            throw XCTSkip("set BATON_DOCS_SAMPLE for the real book")
        }
        let available = VoiceCatalogue.kokoroGrades.keys.sorted().map { "kokoro:\($0)" }
        let router = ModelRouter(sources: [source])
        let executor = HTTPModelClient.executor(apiKey: { _ in nil })
        let started = Date()
        let suggestion = await VoiceCaster.suggest(
            for: document, available: available, languageDefault: "kokoro:af_heart",
            complete: { system, user in try await router.complete(.voiceSuggestion, system: system, user: user, executor: executor) })
        let seconds = Date().timeIntervalSince(started)
        print("LIVE voice suggestion in \(String(format: "%.1f", seconds)) s by \(suggestion.source ?? "fallback"): "
              + "\(suggestion.primary) + \(suggestion.alternates); \(suggestion.genre ?? "-"), \(suggestion.era ?? "-"), "
              + "\(suggestion.tone ?? "-"); \(suggestion.rationale) \(suggestion.fallbackReason ?? "")")
        XCTAssertFalse(suggestion.isFallback, suggestion.fallbackReason ?? "")
        XCTAssertTrue(available.contains(suggestion.primary))
    }
}
