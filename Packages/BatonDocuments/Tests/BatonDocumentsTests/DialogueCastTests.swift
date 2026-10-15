import Foundation
import XCTest
@testable import BatonDocuments

/// The Swift port of the dialogue-cast proof of concept (board G1). The synthetic tests pin each
/// rule; the sample tests reproduce the POC's numbers on the real book when `BATON_DOCS_SAMPLE`
/// is set, and the agreement policy's when `BATON_CAST_MODEL_ANSWERS` is too (a recorded model
/// run, quote text → speaker, so the test needs no model).
final class DialogueCastTests: XCTestCase {
    private let cast = [
        DialogueCast.Character(name: "Mary", gender: "f", age: "old", aliases: ["his mother", "mother", "the woman"]),
        DialogueCast.Character(name: "Tom", gender: "m", age: "young", aliases: ["her son"]),
    ]

    private func doc(_ paragraphs: [String]) -> ImportedDocument {
        ImportedDocument(sourceSHA256: "x", sourceKind: .text, title: "T",
                         chapters: [DocumentChapter(index: 0, title: "One", paragraphs: paragraphs)])
    }

    private let exchange = [
        "Mary sat in her chair in the small room, and the bell rang.",
        "\u{201C}Who is it?\u{201D} she called.",
        "\u{201C}It is me, mother,\u{201D} said Tom. \u{201C}I want to talk.\u{201D}",
        "\u{201C}Then talk.\u{201D}",
        "\u{201C}I want to see the surface.\u{201D}",
        "\u{201C}Tom, you cannot.\u{201D}",
        "\u{201C}Why?\u{201D}",
        "\u{201C}Because nobody does,\u{201D} said his mother.",
    ]

    func testEachRuleOnASmallExchange() {
        var spans = DialogueCast.segment(doc(exchange))
        DialogueCast.attributeRules(&spans, cast: cast)
        let quotes = spans.filter { $0.kind == .quote }
        XCTAssertEqual(quotes.map(\.text), ["Who is it?", "It is me, mother,", "I want to talk.", "Then talk.",
                                            "I want to see the surface.", "Tom, you cannot.", "Why?", "Because nobody does,"])
        // Strict (the default): a turn is attributed only when both sweeps agree. "Tom, you
        // cannot." names the other party, so the backward sweep knows the exchange is Mary and
        // Tom and agrees with the forward one on "Then talk." and "I want to see the surface."
        // (before G2 it met Mary twice and stopped, leaving both with the narrator). "Why?" is
        // still reached by one sweep only.
        XCTAssertEqual(quotes.map(\.speaker), ["Mary", "Tom", "Tom", "Mary", "Tom", "Mary", nil, "Mary"])
        XCTAssertEqual(quotes[0].method, "tag")          // "she called", she = the focal Mary
        XCTAssertEqual(quotes[1].method, "tag")          // "said Tom"
        XCTAssertEqual(quotes[2].method, "paragraph")    // same paragraph as a tagged quote
        XCTAssertEqual(quotes[5].method, "vocative")     // "Tom, you cannot." is not Tom's
        XCTAssertEqual(quotes[7].method, "tag")          // "said his mother"

        // One-way (the agreement policy's second opinion) fills them by turn-taking.
        var loose = DialogueCast.segment(doc(exchange))
        DialogueCast.attributeRules(&loose, cast: cast, agreeBothWays: false)
        let looseQuotes = loose.filter { $0.kind == .quote }
        XCTAssertEqual(looseQuotes.map(\.speaker), ["Mary", "Tom", "Tom", "Mary", "Tom", "Mary", "Tom", "Mary"])
        XCTAssertEqual(looseQuotes[3].method, "alternation")
    }

    func testNumberingMatchesDocumentSpeechSoTheCastLandsOnTheRightLines() {
        let d = doc(exchange)
        var spans = DialogueCast.segment(d)
        DialogueCast.attributeRules(&spans, cast: cast)
        let plan = VoicePlan(narrator: "kokoro:bm_george", characters: ["Mary": "kokoro:bf_emma", "Tom": "kokoro:bm_fable"])
        let book = DocumentSpeech.prepare(d, voices: plan, attribution: DialogueCast.attribution(spans))
        let quoted = book.chapters[0].segments.filter { $0.kind == .quote }
        XCTAssertEqual(quoted.first?.speaker, "Mary")
        XCTAssertTrue(quoted.contains { $0.text.contains("It is me, mother") && $0.speaker == "Tom" })
        XCTAssertTrue(quoted.contains { $0.text.contains("Tom, you cannot") && $0.speaker == "Mary" })
    }

    func testABareDescriptionAndAnAmbiguousPronounDecline() {
        // Two women on stage: "she" is nobody in particular, so the narrator reads it.
        let twoWomen = [DialogueCast.Character(name: "Ann", gender: "f"), DialogueCast.Character(name: "Bea", gender: "f")]
        var spans = DialogueCast.segment(doc(["Ann and Bea sat down together.", "\u{201C}Well?\u{201D} she said."]))
        DialogueCast.attributeRules(&spans, cast: twoWomen)
        XCTAssertNil(spans.first { $0.kind == .quote }?.speaker)
    }

    func testTheModelStepIsValidatedAndTheAgreementPolicyFiltersIt() {
        var spans = DialogueCast.segment(doc(exchange))
        // Rules off, to give the model something to fill.
        let ids = spans.filter { $0.kind == .quote }.map(\.id)
        let reply = "```json\n{\"\(ids[3])\": \"Mary\", \"\(ids[4])\": \"The Ghost\", \"\(ids[6])\": \"narrator\"}\n```"
        let filled = DialogueCast.applyModel(reply, to: &spans, chapter: 0, cast: cast)
        XCTAssertEqual(filled, 1)
        XCTAssertEqual(spans.first { $0.id == ids[3] }?.speaker, "Mary")
        XCTAssertNil(spans.first { $0.id == ids[4] }?.speaker, "an invented name is discarded")
        XCTAssertEqual(spans.first { $0.id == ids[6] }?.method, "model-narrator")
        let prompt = DialogueCast.chapterPrompt(spans, chapter: 0, cast: cast)
        XCTAssertTrue(prompt.contains("[Q \(ids[3])=Mary]Then talk.[/Q]"))
        XCTAssertTrue(prompt.contains("- Tom: m, young (also: her son)."))

        // Agreement: one-way turn-taking says ids[3] is Mary, so a model "Mary" stays and a
        // model "Tom" there would go.
        var agreeing = DialogueCast.segment(doc(exchange))
        DialogueCast.applyModel("{\"\(ids[3])\": \"Mary\"}", to: &agreeing, chapter: 0, cast: cast)
        DialogueCast.keepOnlyAgreeing(&agreeing, document: doc(exchange), cast: cast)
        XCTAssertEqual(agreeing.first { $0.id == ids[3] }?.speaker, "Mary")
        var disagreeing = DialogueCast.segment(doc(exchange))
        DialogueCast.applyModel("{\"\(ids[3])\": \"Tom\"}", to: &disagreeing, chapter: 0, cast: cast)
        DialogueCast.keepOnlyAgreeing(&disagreeing, document: doc(exchange), cast: cast)
        XCTAssertNil(disagreeing.first { $0.id == ids[3] }?.speaker)
        XCTAssertEqual(disagreeing.first { $0.id == ids[3] }?.method, "model-unconfirmed")
    }

    func testVoicesAreDistinctAndNeverTheNarrators() {
        var spans = DialogueCast.segment(doc(exchange))
        DialogueCast.attributeRules(&spans, cast: cast)
        let voices = DialogueCast.assignVoices(spans, cast: cast, narrator: "kokoro:bf_emma",
                                               available: ["kokoro:bf_emma", "kokoro:bf_isabella", "kokoro:bm_george",
                                                           "kokoro:af_heart", "kokoro:am_michael"])
        XCTAssertEqual(voices["Mary"], "kokoro:bf_isabella", "a woman, the narrator's accent, the best remaining grade")
        XCTAssertEqual(voices["Tom"], "kokoro:bm_george")
        XCTAssertFalse(voices.values.contains("kokoro:bf_emma"))
    }

    // MARK: - The sample

    struct Gold: Decodable {
        struct Label: Decodable { var speaker: String; var starts: String }
        var labels: [String: Label]
    }

    private func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private func sample() throws -> ImportedDocument {
        guard let path = ProcessInfo.processInfo.environment["BATON_DOCS_SAMPLE"] else {
            throw XCTSkip("set BATON_DOCS_SAMPLE to `pdftotext -layout` output of the Machine Stops PDF")
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let r = LayoutTextImporter().extract(pages: text.components(separatedBy: "\u{0C}"))
        return ImportedDocument(sourceSHA256: "sample", sourceKind: .pdf, title: r.title ?? "", author: r.author,
                                chapters: r.chapters, frontMatter: r.frontMatter)
    }

    /// Precision and coverage against the hand labels. Quotes are matched to labels by chapter
    /// and the label's opening characters, in order: the importer keeps two lines of quoted verse
    /// inside their sentence where the POC split them, so ids drift after that point.
    private func score(_ spans: [DialogueCast.Span]) throws -> (correct: Int, assigned: Int, labelled: Int, unmatched: Int) {
        let gold = try fixture("machine-stops.gold", as: Gold.self).labels
        func key(_ id: String) -> (Int, Int) {
            let parts = id.dropFirst().split(separator: "q")
            return (Int(parts[0])!, Int(parts[1])!)
        }
        var correct = 0, assigned = 0, labelled = 0, unmatched = 0
        var cursor: [Int: Int] = [:]
        let quotes = spans.filter { $0.kind == .quote }
        for (id, label) in gold.sorted(by: { key($0.key) < key($1.key) }) {
            let chapter = key(id).0 - 1
            let start = cursor[chapter] ?? 0
            let candidates = quotes.enumerated().filter { $0.element.chapter == chapter && $0.offset >= start }
            guard let hit = candidates.first(where: { $0.element.text.hasPrefix(label.starts) }) else { unmatched += 1; continue }
            cursor[chapter] = hit.offset + 1
            guard label.speaker != "narrator" else { continue }
            labelled += 1
            if let who = hit.element.speaker {
                assigned += 1
                if who == label.speaker { correct += 1 }
            }
        }
        return (correct, assigned, labelled, unmatched)
    }

    func testRulesAloneReproduceThePOCOnTheSample() throws {
        let document = try sample()
        let sheet = try fixture("machine-stops.cast", as: DialogueCast.CastSheet.self)
        var spans = DialogueCast.segment(document)
        DialogueCast.attributeRules(&spans, cast: sheet.characters)
        let r = try score(spans)
        let precision = Double(r.correct) / Double(r.assigned)
        let coverage = Double(r.assigned) / Double(r.labelled)
        print("CAST rules: \(r.correct)/\(r.assigned) precision \(precision), coverage \(r.assigned)/\(r.labelled) \(coverage), unmatched labels \(r.unmatched)")
        XCTAssertLessThanOrEqual(r.unmatched, 4, "segmentation drifted from the POC's")
        XCTAssertGreaterThanOrEqual(precision, 0.98)
        XCTAssertGreaterThanOrEqual(coverage, 0.35)
    }

    func testTheAgreementPolicyReproducesThePOCWithARecordedModel() async throws {
        let document = try sample()
        guard let path = ProcessInfo.processInfo.environment["BATON_CAST_MODEL_ANSWERS"] else {
            throw XCTSkip("set BATON_CAST_MODEL_ANSWERS to a recorded model run (quote text → speaker)")
        }
        let answers = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let sheet = try fixture("machine-stops.cast", as: DialogueCast.CastSheet.self)
        // A stand-in model that answers what the recorded run answered, for each quote it is shown.
        let spans = await DialogueCast.attribute(document, cast: sheet) { _, user in
            var reply: [String: String] = [:]
            let re = try NSRegularExpression(pattern: #"\[Q (c\d+q\d+)\](.*?)\[/Q\]"#)
            for m in re.matches(in: user, range: NSRange(user.startIndex..., in: user)) {
                let id = String(user[Range(m.range(at: 1), in: user)!])
                let text = String(user[Range(m.range(at: 2), in: user)!])
                if let who = answers[text] { reply[id] = who }
            }
            return (String(data: try JSONSerialization.data(withJSONObject: reply), encoding: .utf8)!, "recorded qwen3.5:4b")
        }
        let r = try score(spans)
        let precision = Double(r.correct) / Double(r.assigned)
        print("CAST agree: \(r.correct)/\(r.assigned) precision \(precision), coverage \(r.assigned)/\(r.labelled)")
        XCTAssertGreaterThanOrEqual(precision, 0.98)
        XCTAssertGreaterThan(r.assigned, 85, "the model's agreed answers add coverage over rules alone")
    }
}

/// G3: the cast sheet from the book's own evidence, and the checks that keep a model's sheet
/// honest.
final class CastSheetGeneratorTests: XCTestCase {
    private let doc = ImportedDocument(sourceSHA256: "g", sourceKind: .text, title: "T", chapters: [
        DocumentChapter(index: 0, title: "One", paragraphs: [
            "Mary sat in her chair, and Tom came in.",
            "\u{201C}Who is it?\u{201D} said his mother.",
            "\u{201C}It is me,\u{201D} said Tom. \u{201C}I want to talk.\u{201D}",
            "\u{201C}Then talk,\u{201D} said his mother.",
            "\u{201C}Tom, sit down,\u{201D} said Mary.",
            "\u{201C}No,\u{201D} said Tom.",
        ]),
    ])

    func testEvidenceIsTheBooksOwnTagsAndTalk() {
        let ev = CastSheetGenerator.evidence(doc)
        XCTAssertEqual(ev.tags.map(\.phrase), ["his mother", "tom", "mary"])
        XCTAssertEqual(ev.tags.map(\.count), [2, 2, 1])
        XCTAssertEqual(ev.passages.count, 5)
        let prompt = CastSheetGenerator.prompt(ev, title: "T")
        XCTAssertTrue(prompt.contains("- his mother (2)"))
    }

    func testAModelsSheetIsCheckedAgainstTheText() {
        let reply = """
        <think>cast</think>{"characters": [
          {"name": "Mary", "gender": "female", "age": "old", "aliases": ["his mother", "she", "the queen"], "notes": "Tom's mother"},
          {"name": "Tom", "gender": "m", "age": "teen", "aliases": ["her son", "tom"]},
          {"name": "Bob", "gender": "m", "age": "adult", "aliases": ["the butler"]},
          {"name": "mary", "gender": "f", "age": "old", "aliases": []}
        ]}
        """
        let sheet = CastSheetGenerator.parse(reply, document: doc)
        XCTAssertEqual(sheet.characters.map(\.name), ["Mary", "Tom"], "Bob is never in the text; a second Mary is a duplicate")
        XCTAssertEqual(sheet.characters[0].aliases, ["his mother"], "a pronoun and an alias the text never uses are dropped")
        XCTAssertEqual(sheet.characters[0].gender, "f")
        XCTAssertEqual(sheet.characters[1].age, "adult", "an age outside the vocabulary falls back")
        XCTAssertEqual(sheet.characters[1].aliases, [], "\"her son\" is not in the text, \"tom\" is the name itself")
        XCTAssertTrue(CastSheetGenerator.parse("no JSON", document: doc).characters.isEmpty)
    }

    func testAnAliasTwoCharactersClaimGoesFromBoth() {
        let reply = #"{"characters": [{"name": "Mary", "gender": "f", "aliases": ["his mother"]}, {"name": "Tom", "gender": "m", "aliases": ["his mother"]}]}"#
        let sheet = CastSheetGenerator.parse(reply, document: doc)
        XCTAssertEqual(sheet.characters.map(\.aliases), [[], []])
    }

    func testTheGeneratedSheetDrivesTheRules() async {
        let made = await CastSheetGenerator.generate(for: doc) { _, user in
            XCTAssertTrue(user.contains("his mother"))
            return (#"{"characters": [{"name": "Mary", "gender": "f", "age": "old", "aliases": ["his mother"]}, {"name": "Tom", "gender": "m", "age": "young"}]}"#, "test model")
        }
        XCTAssertEqual(made.source, "test model")
        var spans = DialogueCast.segment(doc)
        DialogueCast.attributeRules(&spans, cast: made.sheet.characters)
        XCTAssertEqual(spans.filter { $0.kind == .quote }.map(\.speaker), ["Mary", "Tom", "Tom", "Mary", "Mary", "Tom"])
    }
}
