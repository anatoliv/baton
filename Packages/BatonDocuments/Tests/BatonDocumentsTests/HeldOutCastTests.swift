import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BatonDocuments

/// G2: the dialogue-cast rules on text they were not written against. The sample (*The Machine
/// Stops*) is where the rules and the agreement policy were tuned, so its 98.75% says little
/// about a book a listener brings. These are three public-domain texts from Project Gutenberg
/// with different habits: Austen's long unattributed exchanges between two people, Doyle's
/// first-person narrator who is also a speaker, and Mansfield's free indirect style with many
/// voices in one garden.
///
/// Only labels (quote id, its opening characters, the speaker) and cast sheets are checked in,
/// in `Fixtures/heldout.json`; the texts are fetched by the person running the test and passed
/// as `BATON_HELDOUT_DIR` (the Gutenberg HTML files named in the fixture). Labels were made by
/// reading each quote in context; "?" marks a quote a careful reader could not attribute, and
/// "narrator" one that is not speech. Neither is scored.
final class HeldOutCastTests: XCTestCase {
    struct Text: Decodable {
        var file: String
        var source: String
        /// Chapters to score, by their title in the imported document.
        var chapters: [String]
        var cast: [DialogueCast.Character]
        var labels: [String: Label]
    }

    struct Label: Decodable { var speaker: String; var starts: String }
    struct Fixture: Decodable { var texts: [String: Text] }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "heldout", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// The chosen chapters of one text, as a document of their own.
    private func document(_ text: Text, in dir: String) throws -> ImportedDocument {
        let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(text.file))
        let out = HTMLImporter.read(HTMLParser.decode(data), fallbackTitle: text.file)
        let chosen = text.chapters.compactMap { title in out.result.chapters.first { $0.title == title } }
        XCTAssertEqual(chosen.count, text.chapters.count, "\(text.file): chapters \(out.result.chapters.map(\.title).prefix(20))")
        return ImportedDocument(sourceSHA256: text.file, sourceKind: .html, title: out.result.title ?? text.file,
                                chapters: chosen.enumerated().map { DocumentChapter(index: $0.offset, title: $0.element.title, paragraphs: $0.element.paragraphs) })
    }

    private func directory() throws -> String {
        guard let dir = ProcessInfo.processInfo.environment["BATON_HELDOUT_DIR"] else {
            throw XCTSkip("set BATON_HELDOUT_DIR to a folder holding the Gutenberg HTML files named in Fixtures/heldout.json")
        }
        return dir
    }

    /// For labelling: every quote with its id and paragraph, when `BATON_HELDOUT_DUMP` names a
    /// text. Not a check.
    func testDumpForLabelling() throws {
        guard let name = ProcessInfo.processInfo.environment["BATON_HELDOUT_DUMP"] else { throw XCTSkip("labelling aid") }
        let dir = try directory()
        let text = try XCTUnwrap(fixture().texts[name])
        let doc = try document(text, in: dir)
        var lastParagraph = -1
        var out = ""
        for span in DialogueCast.segment(doc) {
            if span.paragraph != lastParagraph { out += "\n"; lastParagraph = span.paragraph }
            if span.kind == .quote {
                out += "  [\(span.id)] \u{201C}\(span.text)\u{201D}\n"
            } else {
                out += "  (\(span.text.prefix(160)))\n"
            }
        }
        // Written to a file when asked: a long dump through the test runner's console loses lines.
        if let path = ProcessInfo.processInfo.environment["BATON_HELDOUT_DUMP_FILE"] {
            try out.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            print(out)
        }
    }

    /// Precision and coverage of rules alone on each text, scored like the sample.
    func testRulesOnTextsTheyWereNotWrittenFor() throws {
        let dir = try directory()
        var totals = (correct: 0, assigned: 0, labelled: 0)
        for (name, text) in try fixture().texts.sorted(by: { $0.key < $1.key }) {
            let doc = try document(text, in: dir)
            var spans = DialogueCast.segment(doc)
            DialogueCast.attributeRules(&spans, cast: text.cast)
            let quotes = Dictionary(uniqueKeysWithValues: spans.filter { $0.kind == .quote }.map { ($0.id, $0) })
            var correct = 0, assigned = 0, labelled = 0, unmatched = 0
            var wrong: [String] = []
            for (id, label) in text.labels {
                guard let q = quotes[id], q.text.hasPrefix(label.starts) else { unmatched += 1; continue }
                guard label.speaker != "narrator", label.speaker != "?" else { continue }
                labelled += 1
                guard let who = q.speaker else { continue }
                assigned += 1
                if who == label.speaker { correct += 1 } else { wrong.append("\(id) \(who)≠\(label.speaker) (\(q.method ?? "-"))") }
            }
            print("HELDOUT \(name): \(correct)/\(assigned) precision \(String(format: "%.3f", Double(correct) / Double(max(assigned, 1)))), "
                  + "coverage \(assigned)/\(labelled) \(String(format: "%.3f", Double(assigned) / Double(max(labelled, 1)))), unmatched \(unmatched)")
            for w in wrong.sorted() { print("   wrong: \(w)") }
            XCTAssertEqual(unmatched, 0, "\(name): labels no longer line up with the segmentation")
            totals.correct += correct
            totals.assigned += assigned
            totals.labelled += labelled
        }
        let precision = Double(totals.correct) / Double(max(totals.assigned, 1))
        print("HELDOUT all: \(totals.correct)/\(totals.assigned) precision \(String(format: "%.3f", precision)), coverage \(totals.assigned)/\(totals.labelled)")
        // The bar the board set for G2. Measured 2026-10-03: 122/122 (100%), coverage 36%;
        // before the two fixes this found, 120/122 (98.4%).
        XCTAssertGreaterThanOrEqual(precision, 0.97)
        XCTAssertGreaterThanOrEqual(Double(totals.assigned) / Double(max(totals.labelled, 1)), 0.30)
    }

    /// The model step with the agreement policy (`--agree`), against a real model, on the texts
    /// named in `BATON_HELDOUT_TEXTS` (comma-separated; all when unset). Opt-in and slow on a
    /// CPU: each chapter is one long prompt. The request timeout is raised for that reason.
    func testAgreementPolicyWithALiveModel() async throws {
        let dir = try directory()
        guard let model = ProcessInfo.processInfo.environment["BATON_LIVE_OLLAMA_MODEL"] else {
            throw XCTSkip("set BATON_LIVE_OLLAMA_MODEL to run the model step")
        }
        let base = ProcessInfo.processInfo.environment["BATON_LIVE_OLLAMA_URL"] ?? "http://127.0.0.1:11434"
        let source = ModelSource(name: "\(model) (live)", provider: .ollama, baseURL: base, model: model, contextTokens: 16_384)
        let complete: VoiceCaster.Complete = { system, user in
            var request = try HTTPModelClient.request(for: source, system: system, user: user, apiKey: nil, maxTokens: 4_096)
            request.timeoutInterval = 3_600
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HTTPModelClient.Failure.unreadable }
            return (try HTTPModelClient.text(from: data, provider: .ollama), source.name)
        }
        let wanted = ProcessInfo.processInfo.environment["BATON_HELDOUT_TEXTS"].map { Set($0.split(separator: ",").map(String.init)) }
        for (name, text) in try fixture().texts.sorted(by: { $0.key < $1.key }) where wanted?.contains(name) ?? true {
            let doc = try document(text, in: dir)
            let started = Date()
            let spans = await DialogueCast.attribute(doc, cast: DialogueCast.CastSheet(characters: text.cast), complete: complete)
            let quotes = Dictionary(uniqueKeysWithValues: spans.filter { $0.kind == .quote }.map { ($0.id, $0) })
            var correct = 0, assigned = 0, labelled = 0
            var wrong: [String] = []
            for (id, label) in text.labels where label.speaker != "narrator" && label.speaker != "?" {
                guard let q = quotes[id], q.text.hasPrefix(label.starts) else { continue }
                labelled += 1
                guard let who = q.speaker else { continue }
                assigned += 1
                if who == label.speaker { correct += 1 } else { wrong.append("\(id) \(who)≠\(label.speaker) (\(q.method ?? "-"))") }
            }
            print("HELDOUT-AGREE \(name) in \(Int(Date().timeIntervalSince(started))) s: \(correct)/\(assigned) precision "
                  + "\(String(format: "%.3f", Double(correct) / Double(max(assigned, 1)))), coverage \(assigned)/\(labelled)")
            for w in wrong.sorted() { print("   wrong: \(w)") }
        }
    }

    /// Rules, then a model for the quotes they leave, against a live model
    /// (`LiveModel`). Prints precision and coverage for the rules alone, rules plus the model,
    /// and rules plus the model where one-way turn-taking does not name someone else (a
    /// measurement of a stricter policy, not the product's). `BATON_FILL_DIR` keeps each text's
    /// answers so they can be rescored without asking again.
    func testRulesThenModelFillWithALiveModel() async throws {
        let dir = try directory()
        guard let live = LiveModel.complete(.dialogueCast) else {
            throw XCTSkip("set BATON_LIVE_AGENT_FILE or BATON_LIVE_OLLAMA_MODEL to measure the model fill")
        }
        let saveDir = ProcessInfo.processInfo.environment["BATON_FILL_DIR"]
        let wanted = ProcessInfo.processInfo.environment["BATON_HELDOUT_TEXTS"].map { Set($0.split(separator: ",").map(String.init)) }
        var totals: [String: (correct: Int, assigned: Int, labelled: Int)] = [:]
        for (name, text) in try fixture().texts.sorted(by: { $0.key < $1.key }) where wanted?.contains(name) ?? true {
            let doc = try document(text, in: dir)
            let sheet = DialogueCast.CastSheet(characters: text.cast)
            let saved = saveDir.map { URL(fileURLWithPath: $0).appendingPathComponent("\(name).fill.json") }
            let fill: DialogueCast.Fill
            if let saved, let data = try? Data(contentsOf: saved) {
                fill = try JSONDecoder().decode(DialogueCast.Fill.self, from: data)
                print("HELDOUT-FILL \(name): answers read from \(saved.lastPathComponent)")
            } else {
                let started = Date()
                fill = await DialogueCast.fill(doc, cast: sheet, complete: live.complete)
                print("HELDOUT-FILL \(name): \(fill.answered)/\(fill.asked) prompts answered by \(fill.source ?? "nobody") "
                      + "in \(Int(Date().timeIntervalSince(started))) s")
                if let saved {
                    try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(fill).write(to: saved)
                }
            }
            var rules = DialogueCast.segment(SecretRedactor.redact(doc))
            DialogueCast.attributeRules(&rules, cast: text.cast)
            var filled = rules
            DialogueCast.applyFill(fill, to: &filled, cast: text.cast)
            var oneWay = DialogueCast.segment(SecretRedactor.redact(doc))
            DialogueCast.attributeRules(&oneWay, cast: text.cast, agreeBothWays: false)
            let turn = Dictionary(uniqueKeysWithValues: oneWay.filter { $0.method == "alternation" }.map { ($0.id, $0.speaker ?? "") })
            var vetoed = filled
            for i in vetoed.indices where vetoed[i].method == "model" {
                if let t = turn[vetoed[i].id], t != vetoed[i].speaker { vetoed[i].speaker = nil; vetoed[i].method = "model-vetoed" }
            }
            for (policy, spans) in [("rules", rules), ("rules+model", filled), ("rules+model-veto", vetoed)] {
                let quotes = Dictionary(uniqueKeysWithValues: spans.filter { $0.kind == .quote }.map { ($0.id, $0) })
                var correct = 0, assigned = 0, labelled = 0
                var wrong: [String] = []
                for (id, label) in text.labels where label.speaker != "narrator" && label.speaker != "?" {
                    guard let q = quotes[id], q.text.hasPrefix(label.starts) else { continue }
                    labelled += 1
                    guard let who = q.speaker else { continue }
                    assigned += 1
                    if who == label.speaker { correct += 1 } else { wrong.append("\(id) \(who)≠\(label.speaker) (\(q.method ?? "-"))") }
                }
                print("HELDOUT-FILL \(name) \(policy): \(correct)/\(assigned) precision \(String(format: "%.3f", Double(correct) / Double(max(assigned, 1)))), "
                      + "coverage \(assigned)/\(labelled) \(String(format: "%.3f", Double(assigned) / Double(max(labelled, 1))))")
                if policy != "rules" { for w in wrong.sorted() { print("   wrong (\(policy)): \(w)") } }
                let t = totals[policy] ?? (0, 0, 0)
                totals[policy] = (t.correct + correct, t.assigned + assigned, t.labelled + labelled)
            }
        }
        for (policy, t) in totals.sorted(by: { $0.key < $1.key }) {
            print("HELDOUT-FILL all \(policy) (\(live.name)): \(t.correct)/\(t.assigned) precision "
                  + "\(String(format: "%.3f", Double(t.correct) / Double(max(t.assigned, 1)))), coverage \(t.assigned)/\(t.labelled) "
                  + String(format: "%.3f", Double(t.assigned) / Double(max(t.labelled, 1))))
        }
    }

    /// G3 on a whole novel: the cast sheet for all of Pride and Prejudice, asked the
    /// way the app asks (`LiveModel`: the three-minute timeout and the task's reply budget), timed,
    /// and checked for the people a listener would expect.
    func testWholeNovelCastSheetWithALiveModel() async throws {
        let dir = try directory()
        guard let live = LiveModel.complete(.castSheet) else {
            throw XCTSkip("set BATON_LIVE_AGENT_FILE or BATON_LIVE_OLLAMA_MODEL to write a whole novel's cast sheet")
        }
        let text = try XCTUnwrap(fixture().texts["austen"])
        let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(text.file))
        let chapters = HTMLImporter.read(HTMLParser.decode(data), fallbackTitle: text.file).result.chapters
        let novel = ImportedDocument(sourceSHA256: "pg1342", sourceKind: .html, title: "Pride and Prejudice",
                                     chapters: chapters.enumerated().map { DocumentChapter(index: $0.offset, title: $0.element.title, paragraphs: $0.element.paragraphs) })
        let prompt = CastSheetGenerator.prompt(CastSheetGenerator.evidence(novel), title: novel.title)
        let started = Date()
        let made = await CastSheetGenerator.generate(for: novel, complete: live.complete)
        let seconds = Date().timeIntervalSince(started)
        print("WHOLE-SHEET \(live.name): \(chapters.count) chapters, prompt \(prompt.count) characters, "
              + "\(made.sheet.characters.count) people in \(String(format: "%.1f", seconds)) s by \(made.source ?? "nobody")")
        for c in made.sheet.characters { print("   \(c.name) [\(c.gender), \(c.age)\(c.group ? ", group" : "")] \(c.aliases)") }
        let found = made.sheet.characters.map { ([$0.name] + $0.aliases).joined(separator: " | ").lowercased() }
        let expected = ["mr. bennet", "mrs. bennet", "elizabeth", "jane", "darcy", "bingley", "lydia"]
        let missing = expected.filter { want in !found.contains { $0.contains(want) } }
        print("WHOLE-SHEET missing: \(missing)")
        XCTAssertNotNil(made.source, "no answer within the app's timeout")
        XCTAssertTrue(missing.isEmpty, "missing \(missing)")
    }

    /// G3 end to end: a model writes each text's cast sheet from the book's evidence, the rules
    /// run with that sheet instead of the hand-written one, and the result is scored.
    ///
    /// Scored for what a listener hears: each generated character is one voice, so it is mapped
    /// to the person most of its attributed lines belong to, and a line is right when its voice's
    /// person said it. A generated name ("practical jose", "his wife") is cosmetic: the person
    /// renames it on the import sheet. A first version credited a line whenever the labelled
    /// speaker was among the generated character's aliases, which let "Holmes" (aliased "the
    /// king" by the model) take the King's lines and still score 100%.
    ///
    /// `BATON_G3_SHEETS` names a folder: sheets are written there after generation and read from
    /// there when present, so scoring can be repeated without the model.
    func testRulesWithAGeneratedCastSheet() async throws {
        let dir = try directory()
        let sheetsDir = ProcessInfo.processInfo.environment["BATON_G3_SHEETS"]
        let model = ProcessInfo.processInfo.environment["BATON_LIVE_OLLAMA_MODEL"]
        guard model != nil || sheetsDir != nil else {
            throw XCTSkip("set BATON_LIVE_OLLAMA_MODEL to generate the cast sheets, or BATON_G3_SHEETS to score saved ones")
        }
        let base = ProcessInfo.processInfo.environment["BATON_LIVE_OLLAMA_URL"] ?? "http://127.0.0.1:11434"
        let wanted = ProcessInfo.processInfo.environment["BATON_HELDOUT_TEXTS"].map { Set($0.split(separator: ",").map(String.init)) }
        for (name, text) in try fixture().texts.sorted(by: { $0.key < $1.key }) where wanted?.contains(name) ?? true {
            let doc = try document(text, in: dir)
            var sheet: DialogueCast.CastSheet
            let saved = sheetsDir.map { URL(fileURLWithPath: $0).appendingPathComponent("\(name).cast.json") }
            if let saved, let data = try? Data(contentsOf: saved) {
                sheet = try JSONDecoder().decode(DialogueCast.CastSheet.self, from: data)
                print("CAST-SHEET \(name) read from \(saved.path)")
            } else {
                guard let model else { throw XCTSkip("no saved sheet for \(name) and no model") }
                let source = ModelSource(name: "\(model) (live)", provider: .ollama, baseURL: base, model: model, contextTokens: 8_192)
                let complete: VoiceCaster.Complete = { system, user in
                    var request = try HTTPModelClient.request(for: source, system: system, user: user, apiKey: nil, maxTokens: 2_048)
                    request.timeoutInterval = 3_600
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HTTPModelClient.Failure.unreadable }
                    return (try HTTPModelClient.text(from: data, provider: .ollama), source.name)
                }
                let started = Date()
                let made = await CastSheetGenerator.generate(for: doc, complete: complete)
                sheet = made.sheet
                print("CAST-SHEET \(name) in \(Int(Date().timeIntervalSince(started))) s by \(made.source ?? "nobody")")
                if let saved {
                    try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(sheet).write(to: saved)
                }
            }
            for c in sheet.characters { print("   \(c.name) [\(c.gender), \(c.age)\(c.group ? ", group" : "")] \(c.aliases)") }

            var spans = DialogueCast.segment(doc)
            DialogueCast.attributeRules(&spans, cast: sheet.characters)
            let quotes = Dictionary(uniqueKeysWithValues: spans.filter { $0.kind == .quote }.map { ($0.id, $0) })
            var pairs: [(id: String, voice: String, truth: String, method: String)] = []
            var labelled = 0
            for (id, label) in text.labels where label.speaker != "narrator" && label.speaker != "?" {
                guard let q = quotes[id], q.text.hasPrefix(label.starts) else { continue }
                labelled += 1
                if let who = q.speaker { pairs.append((id, who, label.speaker, q.method ?? "-")) }
            }
            // Each voice is the person most of its lines belong to.
            var person: [String: String] = [:]
            for voice in Set(pairs.map(\.voice)) {
                let counts = Dictionary(grouping: pairs.filter { $0.voice == voice }, by: \.truth).mapValues(\.count)
                person[voice] = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
            }
            let wrong = pairs.filter { person[$0.voice] != $0.truth }
            let correct = pairs.count - wrong.count
            print("HELDOUT-GENERATED \(name): \(correct)/\(pairs.count) precision \(String(format: "%.3f", Double(correct) / Double(max(pairs.count, 1)))), "
                  + "coverage \(pairs.count)/\(labelled); voices: " + person.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
            for w in wrong.sorted(by: { $0.id < $1.id }) { print("   wrong: \(w.id) voice \(w.voice) (\(person[w.voice] ?? "-")) said by \(w.truth) (\(w.method))") }
        }
    }
}
