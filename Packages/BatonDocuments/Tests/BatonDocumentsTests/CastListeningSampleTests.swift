import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BatonDocuments

/// G5's material: one chapter rendered twice by the real pipeline, once with a checked cast and
/// once by the narrator alone, for a blind listening test. Opt-in and live: it needs a Kokoro
/// host and a Gutenberg text, neither of which is checked in.
///
/// - `BATON_G5_HTML`: a Project Gutenberg HTML file (the held-out fixture's Austen, #1342).
/// - `BATON_G5_OUT`: where the two chapters (WAV), the cast and a line-by-line listing go.
/// - `BATON_G5_KOKORO_URL`: the Kokoro host.
/// - `BATON_G5_CAST`: the corrected cast (`DialogueCast.Casting` JSON). Without it, and with
///   `BATON_LIVE_OLLAMA_MODEL` set, the sheet is generated, saved as `cast.generated.json` for
///   correction, and nothing is rendered.
/// - `BATON_G5_FILL`: also place the lines the rules leave with a live model (`LiveModel`), as
///   the import sheet does; the answers are saved as `fill.json`.
final class CastListeningSampleTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    func testRenderAChapterWithAndWithoutTheCast() async throws {
        guard let html = env["BATON_G5_HTML"], let outPath = env["BATON_G5_OUT"] else {
            throw XCTSkip("set BATON_G5_HTML and BATON_G5_OUT to make the G5 listening samples")
        }
        let out = URL(fileURLWithPath: outPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let imported = HTMLImporter.read(HTMLParser.decode(try Data(contentsOf: URL(fileURLWithPath: html))), fallbackTitle: "pg1342")
        let chapters = imported.result.chapters
        let first = try XCTUnwrap(chapters.first { $0.title == "Chapter I" }, "chapters: \(chapters.map(\.title).prefix(10))")
        let document = ImportedDocument(sourceSHA256: "pg1342-chapter-1", sourceKind: .html,
                                        title: "Pride and Prejudice, Chapter I", author: "Jane Austen",
                                        chapters: [DocumentChapter(index: 0, title: first.title, paragraphs: first.paragraphs)])
        let narrator = "kokoro:bf_isabella"
        let castURL = env["BATON_G5_CAST"].map { URL(fileURLWithPath: $0) }

        // How long the rules take on the whole book, since the import sheet runs them on a novel.
        let wholeDocument = ImportedDocument(sourceSHA256: "pg1342", sourceKind: .html, title: "Pride and Prejudice",
                                     chapters: chapters.enumerated().map { DocumentChapter(index: $0.offset, title: $0.element.title, paragraphs: $0.element.paragraphs) })
        let started = Date()
        let fixtureCast = DialogueCast.CastSheet(characters: [
            DialogueCast.Character(name: "Mr. Bennet", gender: "m", age: "old", aliases: ["her father", "his father"]),
            DialogueCast.Character(name: "Mrs. Bennet", gender: "f", age: "old", aliases: ["his lady", "his wife", "her mother"]),
            DialogueCast.Character(name: "Elizabeth", gender: "f", age: "young", aliases: ["lizzy", "eliza"]),
            DialogueCast.Character(name: "Mr. Darcy", gender: "m", age: "young", aliases: ["darcy"]),
        ])
        let wholeCasting = DialogueCast.Casting(sheet: fixtureCast, document: wholeDocument, narrator: narrator, available: [])
        _ = DialogueCast.prepare(wholeDocument, plan: VoicePlan(narrator: narrator), casting: wholeCasting)
        print("G5 whole book: \(chapters.count) chapters, \(wholeDocument.paragraphs.count) paragraphs, cast lines and plan in "
              + String(format: "%.1f s", Date().timeIntervalSince(started)))

        guard let castURL, let castData = try? Data(contentsOf: castURL) else {
            // The model: `BATON_G5_AGENT_FILE` (a JSON file with base, model, key, provider, such
            // as ~/.baton-live-agent.json; the key is read here and never printed), else Ollama.
            let source: ModelSource
            var key: String?
            if let file = env["BATON_G5_AGENT_FILE"] {
                let agent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: String])
                let provider: ModelSource.Provider = agent["provider"] == "anthropic" ? .anthropic : .openAICompatible
                source = ModelSource(name: "\(agent["model"] ?? "?") on the home server", provider: provider,
                                     baseURL: agent["base"], model: agent["model"] ?? "", contextTokens: 32_768)
                key = agent["key"]
            } else {
                guard let model = env["BATON_LIVE_OLLAMA_MODEL"] else {
                    throw XCTSkip("set BATON_G5_CAST to a corrected cast, or BATON_LIVE_OLLAMA_MODEL to generate one")
                }
                let base = env["BATON_LIVE_OLLAMA_URL"] ?? "http://127.0.0.1:11434"
                source = ModelSource(name: "\(model) on this Mac", provider: .ollama, baseURL: base, model: model, contextTokens: 16_384)
            }
            let apiKey = key
            let router = ModelRouter(sources: [source])
            // `BATON_G5_WHOLE_SHEET`: the sheet from the whole book's evidence, as the import sheet
            // asks for it, with the app's request (an Ollama source at 8k context; the three-minute
            // timeout unless `BATON_G5_LONG`), timed.
            let whole = env["BATON_G5_WHOLE_SHEET"] != nil
            let patient = !whole || env["BATON_G5_LONG"] != nil
            let asked = Date()
            let made = await CastSheetGenerator.generate(for: whole ? wholeDocument : document) { system, user in
                try await router.complete(.castSheet, system: system, user: user) { source, system, user in
                    var asked = source
                    if whole && source.provider == .ollama { asked.contextTokens = 8_192 }
                    var request = try HTTPModelClient.request(for: asked, system: system, user: user, apiKey: apiKey, maxTokens: 4_096)
                    if patient { request.timeoutInterval = 1_800 }
                    let (data, _) = try await URLSession.shared.data(for: request)
                    let text = try HTTPModelClient.text(from: data, provider: source.provider)
                    print("G5 reply: \(text.count) characters, ends \(text.suffix(160).debugDescription)")
                    return text
                }
            }
            print("G5 cast sheet from \(whole ? "the whole book" : "chapter 1") in \(Int(Date().timeIntervalSince(asked))) s by \(made.source ?? "nobody")")
            let casting = DialogueCast.Casting(sheet: made.sheet, document: document, narrator: narrator,
                                               available: (try? kokoroVoices()) ?? [], source: made.source)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(casting).write(to: out.appendingPathComponent("cast.generated.json"))
            for s in casting.speakers { print("G5 generated: \(s.name) \(s.character.aliases) lines \(s.lines) voice \(s.voice ?? "-")") }
            return
        }
        guard let kokoro = env["BATON_G5_KOKORO_URL"].flatMap(URL.init(string:)) else { throw XCTSkip("set BATON_G5_KOKORO_URL") }
        let casting = try JSONDecoder().decode(DialogueCast.Casting.self, from: castData)
        // What the model step would add on this chapter (`BATON_G5_MODEL_STEP` names an Ollama
        // model): the product runs the rules alone, so this is a measurement, not the sample.
        if let model = env["BATON_G5_MODEL_STEP"] {
            let source = ModelSource(name: model, provider: .ollama, baseURL: env["BATON_LIVE_OLLAMA_URL"] ?? "http://127.0.0.1:11434",
                                     model: model, contextTokens: 16_384)
            let router = ModelRouter(sources: [source])
            let redacted = SecretRedactor.redact(document)
            var rules = DialogueCast.segment(redacted)
            DialogueCast.attributeRules(&rules, cast: casting.sheet.characters)
            let started = Date()
            let withModel = await DialogueCast.attribute(redacted, cast: casting.sheet) { system, user in
                try await router.complete(.dialogueCast, system: system, user: user) { source, system, user in
                    var request = try HTTPModelClient.request(for: source, system: system, user: user, apiKey: nil, maxTokens: 4_096)
                    request.timeoutInterval = 1_800
                    let (data, _) = try await URLSession.shared.data(for: request)
                    return try HTTPModelClient.text(from: data, provider: .ollama)
                }
            }
            let quotes = rules.filter { $0.kind == .quote }.count
            print("G5 model step: rules \(rules.filter { $0.kind == .quote && $0.speaker != nil }.count)/\(quotes), "
                  + "rules + model + agreement \(withModel.filter { $0.kind == .quote && $0.speaker != nil }.count)/\(quotes) "
                  + "in \(Int(Date().timeIntervalSince(started))) s")
            for s in withModel where s.kind == .quote { print("G5 model step: \(s.id) \(s.speaker ?? "-") \(s.method ?? "-") \(s.text.prefix(50))") }
            return
        }
        let plan = VoicePlan(narrator: narrator)
        var fill: DialogueCast.Fill?
        if env["BATON_G5_FILL"] != nil {
            let live = try XCTUnwrap(LiveModel.complete(.dialogueCast), "BATON_G5_FILL needs BATON_LIVE_AGENT_FILE or BATON_LIVE_OLLAMA_MODEL")
            let started = Date()
            let made = await DialogueCast.fill(document, cast: casting.sheet, complete: live.complete)
            print("G5 fill: \(made.speakers.count) more lines by \(made.source ?? "nobody") in \(Int(Date().timeIntervalSince(started))) s; "
                  + "rules \(made.placedByRules) of \(made.quotes), set aside \(made.setAside)")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(made).write(to: out.appendingPathComponent("fill.json"))
            fill = made
        }
        let castBook = DialogueCast.prepare(document, plan: plan, casting: casting, fill: fill)
        var spans = DialogueCast.segment(SecretRedactor.redact(document))
        DialogueCast.attributeRules(&spans, cast: casting.sheet.characters)
        if let fill { DialogueCast.applyFill(fill, to: &spans, cast: casting.sheet.characters) }
        let quotes = spans.filter { $0.kind == .quote }
        let voiced = casting.voices(narrator: narrator)
        print("G5 quotes with a character voice: \(quotes.filter { $0.speaker.map { voiced[$0] != nil } ?? false }.count) of \(quotes.count)")
        for q in quotes { print("G5 quote \(q.id) \(q.speaker ?? "-") \(q.method ?? "-") \(q.text.prefix(50))") }
        // Chapter I is labelled in the held-out fixture (the same ids): how many voices are right.
        if let url = Bundle.module.url(forResource: "heldout", withExtension: "json", subdirectory: "Fixtures"),
           let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
           let labels = ((root["texts"] as? [String: Any])?["austen"] as? [String: Any])?["labels"] as? [String: [String: String]] {
            let scored = quotes.compactMap { q -> Bool? in
                guard let who = q.speaker, let truth = labels[q.id]?["speaker"], truth != "?", truth != "narrator" else { return nil }
                return who == truth
            }
            print("G5 voices right against the held-out labels: \(scored.filter { $0 }.count) of \(scored.count)")
        }
        let narratorBook = DocumentSpeech.prepare(document, voices: plan)
        XCTAssertFalse(castBook.voices.characters.isEmpty, "the cast voices nobody")

        // Who reads what, for the person checking the sample against the text.
        var listing = ""
        for s in castBook.chapters[0].segments { listing += "\(castBook.voices.voice(for: s))\t\(s.speaker ?? "-")\t\(s.text)\n" }
        try listing.write(to: out.appendingPathComponent("cast-segments.tsv"), atomically: true, encoding: .utf8)

        let work = out.appendingPathComponent("work")
        let store = BookStore(directory: work.appendingPathComponent("books"))
        let renderer = BookRenderer(store: store, cacheDirectory: work.appendingPathComponent("cache"),
                                    synthesizer: HTTPSpeechSynthesizer(engines: ["kokoro": kokoro], timeout: 120),
                                    muxer: CopyMuxer(), concurrency: 2)
        for (name, book) in [("cast", castBook), ("narrator-only", narratorBook)] {
            let id = BookJob.id(for: book)
            _ = try await renderer.submit(book, id: id)
            await renderer.waitUntilIdle()
            let job = try XCTUnwrap(store.load(id))
            guard case let .ready(file, _, seconds, _) = job.chapters[0] else { return XCTFail("\(name): \(job.chapters[0])") }
            let wav = out.appendingPathComponent("\(name).wav")
            try? FileManager.default.removeItem(at: wav)
            try FileManager.default.copyItem(at: try XCTUnwrap(store.chapterURL(id, file: file)), to: wav)
            print("G5 \(name): \(String(format: "%.1f", seconds)) s, \(book.chapters[0].segments.count) segments, voices \(Set(book.chapters[0].segments.map(book.voices.voice(for:))).sorted())")
        }
    }

    private func kokoroVoices() throws -> [String] {
        guard let base = env["BATON_G5_KOKORO_URL"],
              let data = try? Data(contentsOf: URL(string: base)!.appendingPathComponent("v1/audio/voices")),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let voices = object["voices"] as? [[String: Any]] else { return [] }
        return voices.compactMap { $0["id"] as? String }.map { "kokoro:\($0)" }
    }
}
