import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BatonDocuments

/// M8.6's evidence: one passage of "The Machine Stops" rendered twice by the real
/// path, `PronunciationLexicon.apply` → `PreparedBook.request` → `BookRenderer` → Kokoro, once
/// with the lexicon a model proposed and once after a person corrected Kuno and Vashti. What each
/// request actually sent is written beside the audio. Opt-in and live: it needs a Kokoro host.
///
/// - `BATON_M86_OUT`: where the two WAVs, the sent texts and the lexicons go.
/// - `BATON_M86_KOKORO_URL`: the Kokoro host.
/// - `BATON_M86_STORY`: optional, the whole story as plain text (paragraphs between blank lines),
///   so the model is asked about the names the app would find in the book, not in one passage.
/// - `BATON_LIVE_AGENT_FILE` or `BATON_LIVE_OLLAMA_MODEL` (`LiveModel`): the model that proposes.
///   Without one, or when it does not answer, a plausible wrong reading stands in, marked "model",
///   and `model-proposal.json` says so.
final class PronunciationListeningSampleTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    /// E. M. Forster, "The Machine Stops" (1909), part I; Project Gutenberg #72890.
    static let passage = [
        "Vashti was seized with the terrors of direct experience. She shrank back into the room, and the wall closed up again.",
        "\u{201C}Kuno,\u{201D} she said, \u{201C}I cannot come to see you. I am not well.\u{201D}",
        "Immediately an enormous apparatus fell on to her out of the ceiling, a thermometer was automatically inserted between her lips, a stethoscope was automatically laid upon her heart. She lay powerless. Cool pads soothed her forehead. Kuno had telegraphed to her doctor.",
        "So the human passions still blundered up and down in the Machine. Vashti drank the medicine that the doctor projected into her mouth, and the machinery retired into the ceiling. The voice of Kuno was heard asking how she felt.",
    ]

    func testHearACorrectedPronunciation() async throws {
        guard let outPath = env["BATON_M86_OUT"], let kokoro = env["BATON_M86_KOKORO_URL"].flatMap(URL.init(string:)) else {
            throw XCTSkip("set BATON_M86_OUT and BATON_M86_KOKORO_URL to make the M8.6 before-and-after pair")
        }
        let out = URL(fileURLWithPath: outPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let narrator = env["BATON_M86_VOICE"] ?? "kokoro:af_heart"
        let document = ImportedDocument(sourceSHA256: "machine-stops-m86-passage", sourceKind: .text,
                                        title: "The Machine Stops", author: "E. M. Forster", language: "en",
                                        chapters: [DocumentChapter(index: 0, title: "", paragraphs: Self.passage)])

        // (a) What the model proposes, asked as the import sheet asks.
        var story = document
        if let path = env["BATON_M86_STORY"] {
            let text = try String(contentsOfFile: path, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
            let paragraphs = text.components(separatedBy: "\n\n")
                .map { $0.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            story = ImportedDocument(sourceSHA256: "machine-stops", sourceKind: .text, title: "The Machine Stops",
                                     author: "E. M. Forster", language: "en",
                                     chapters: [DocumentChapter(index: 0, title: "", paragraphs: paragraphs)])
        }
        let candidates = PronunciationLexicon.candidates(in: story)
        let reply = Box()
        var modelLexicon = PronunciationLexicon()
        var proposedBy: String?
        if let live = LiveModel.complete(.pronunciations) {
            let proposal = await PronunciationLexicon.propose(for: story) { system, user in
                let answer = try await live.complete(system, user)
                reply.set(answer.text)
                return answer
            }
            modelLexicon = proposal.lexicon
            proposedBy = proposal.source
        }
        let proposed = modelLexicon

        // (b) The person corrects the two names, as the pronunciation sheet does: their rows
        // replace the model's, the rest stays.
        func corrected(_ lexicon: PronunciationLexicon) -> PronunciationLexicon {
            var out = lexicon
            out.set("Kuno", ipa: "/ˈkuːnoʊ/", source: "person")
            out.set("Vashti", ipa: "/ˈvæʃti/", source: "person")
            return out
        }
        // A before-and-after needs a "before" that differs. When no model answered, or it already
        // proposed what the person says, a plausible wrong reading stands in, still marked "model":
        // KYOO-noh, and VASH-tie as Esther's Vashti is often said.
        let phonemes = { (l: PronunciationLexicon) in l.entries.filter { ["Kuno", "Vashti"].contains($0.word) }.map(\.phonemes) }
        var fallback: String?
        if proposedBy == nil || phonemes(modelLexicon) == phonemes(corrected(PronunciationLexicon())) {
            fallback = proposedBy == nil
                ? "no model answered; a plausible wrong reading stands in for the model's Kuno and Vashti"
                : "the model proposed the person's own readings for Kuno and Vashti; a plausible wrong reading stands in for them"
            modelLexicon.set("Kuno", ipa: "ˈkjuːnoʊ", source: "model")
            modelLexicon.set("Vashti", ipa: "ˈvæʃtaɪ", source: "model")
        }
        let personLexicon = corrected(modelLexicon)
        XCTAssertEqual(personLexicon.entries.filter { ["Kuno", "Vashti"].contains($0.word) }.map(\.source), ["person", "person"])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let proposal: [String: Any] = [
            "proposedBy": proposedBy ?? NSNull(), "fallback": fallback ?? NSNull(),
            "candidates": candidates.map { ["word": $0.word, "count": $0.count, "example": $0.example] },
            "reply": reply.value ?? NSNull(),
            "proposed": proposed.entries.map { ["word": $0.word, "phonemes": $0.phonemes, "source": $0.source] },
        ]
        try JSONSerialization.data(withJSONObject: proposal, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: out.appendingPathComponent("model-proposal.json"))

        for (name, lexicon) in [("model", modelLexicon), ("person", personLexicon)] {
            try encoder.encode(lexicon).write(to: out.appendingPathComponent("lexicon-\(name).json"))
            var book = DocumentSpeech.prepare(document, voices: VoicePlan(narrator: narrator))
            book.lexicon = lexicon
            let work = out.appendingPathComponent("work-\(name)")
            try? FileManager.default.removeItem(at: work)
            let recorder = RecordingSynthesizer(HTTPSpeechSynthesizer(engines: ["kokoro": kokoro], timeout: 120))
            let store = BookStore(directory: work.appendingPathComponent("books"))
            let renderer = BookRenderer(store: store, cacheDirectory: work.appendingPathComponent("cache"),
                                        synthesizer: recorder, muxer: CopyMuxer(), concurrency: 1)
            let id = BookJob.id(for: book)
            _ = try await renderer.submit(book, id: id)
            await renderer.waitUntilIdle()
            let job = try XCTUnwrap(store.load(id))
            guard case let .ready(file, _, seconds, _) = job.chapters[0] else { return XCTFail("\(name): \(job.chapters[0])") }
            let wav = out.appendingPathComponent("\(name).wav")
            try? FileManager.default.removeItem(at: wav)
            try FileManager.default.copyItem(at: try XCTUnwrap(store.chapterURL(id, file: file)), to: wav)
            let sent = recorder.sent
            XCTAssertEqual(sent.count, book.chapters[0].segments.count, "\(name): every chunk was synthesized fresh")
            try sent.map { "\($0.voice)\t\($0.text)" }.joined(separator: "\n").appending("\n")
                .write(to: out.appendingPathComponent("sent-\(name).txt"), atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: work)
            print("M86 \(name): \(String(format: "%.1f", seconds)) s, \(sent.count) requests")
            for s in sent { print("M86 \(name) sent: \(s.text)") }
        }
        let personSent = try String(contentsOf: out.appendingPathComponent("sent-person.txt"), encoding: .utf8)
        XCTAssertTrue(personSent.contains("[Kuno](/ˈkuːnO/)"), personSent)
        XCTAssertTrue(personSent.contains("[Vashti](/ˈvæʃti/)"), personSent)
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ text: String) { lock.lock(); stored = text; lock.unlock() }
}

/// Forwards to the real synthesizer and keeps what each request sent, in order.
private final class RecordingSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    private let inner: HTTPSpeechSynthesizer
    private let lock = NSLock()
    private var log: [(voice: String, text: String)] = []

    init(_ inner: HTTPSpeechSynthesizer) { self.inner = inner }

    var sent: [(voice: String, text: String)] { lock.withLock { log } }

    private func record(voice: String, text: String) { lock.withLock { log.append((voice, text)) } }

    func synthesize(text: String, voice: String, speed: Double?) async throws -> Data {
        try await synthesize(text: text, voice: voice, speed: speed, style: nil)
    }

    func synthesize(text: String, voice: String, speed: Double?, style: SpeechStyle?) async throws -> Data {
        record(voice: voice, text: text)
        return try await inner.synthesize(text: text, voice: voice, speed: speed, style: style)
    }
}
