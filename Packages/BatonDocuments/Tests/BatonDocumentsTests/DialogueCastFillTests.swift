import Foundation
import XCTest
@testable import BatonDocuments

/// The quotes the rules leave, placed by a model and read strictly, and what happens
/// when no model answers.
final class DialogueCastFillTests: XCTestCase {
    private let cast = [
        DialogueCast.Character(name: "Mary", gender: "f", age: "old", aliases: ["his mother"]),
        DialogueCast.Character(name: "Tom", gender: "m", age: "young", aliases: ["her son"]),
    ]

    private func doc(_ chapters: [[String]]) -> ImportedDocument {
        ImportedDocument(sourceSHA256: String(repeating: "ef", count: 32), sourceKind: .text, title: "The Room",
                         chapters: chapters.enumerated().map { DocumentChapter(index: $0.offset, title: "Chapter \($0.offset + 1)", paragraphs: $0.element) })
    }

    /// One tagged line, then two the rules cannot place (a stranger has just come in, so
    /// turn-taking has no pair), then a tagged one.
    private var room: ImportedDocument {
        doc([[
            "Mary sat in her chair in the small room, and the bell rang twice.",
            "\u{201C}Who is it at this hour?\u{201D} said his mother.",
            "The door opened slowly and a long while passed in the corridor before anything else happened at all, and the cold came in with it.",
            "\u{201C}Only me.\u{201D}",
            "\u{201C}Come in, then.\u{201D}",
            "\u{201C}I came to see the surface,\u{201D} said Tom.",
        ]])
    }

    private var sheet: DialogueCast.CastSheet { DialogueCast.CastSheet(characters: cast) }

    /// The passages around the quotes the rules left, with every quote in them asked about and
    /// none of the rules' answers shown: the model's answers on the placed ones are the check.
    func testThePromptAsksAboutEveryQuoteAroundTheOnesTheRulesLeft() {
        var spans = DialogueCast.segment(room)
        DialogueCast.attributeRules(&spans, cast: cast)
        let unplaced = spans.filter { $0.kind == .quote && $0.speaker == nil }.map(\.id)
        XCTAssertEqual(unplaced, ["c1q2", "c1q3"])
        let prompts = DialogueCast.fillPrompts(spans, cast: cast)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts[0].asked, ["c1q1", "c1q2", "c1q3", "c1q4"])
        let text = prompts[0].text
        XCTAssertTrue(text.contains("- Mary (female, old; also called: his mother)"))
        XCTAssertTrue(text.contains("[Q c1q1]Who is it at this hour?[/Q] said his mother."))
        XCTAssertFalse(text.contains("=Mary]"), "the rules' answers are not shown")
        XCTAssertTrue(text.contains("[Q c1q2]Only me.[/Q]"))
        XCTAssertTrue(text.hasSuffix("ASK: c1q1, c1q2, c1q3, c1q4"))
    }

    func testAChapterWithNothingLeftIsNotAsked() {
        var spans = DialogueCast.segment(doc([["\u{201C}Hello,\u{201D} said Tom."]]))
        DialogueCast.attributeRules(&spans, cast: cast)
        XCTAssertEqual(DialogueCast.fillPrompts(spans, cast: cast), [])
    }

    /// A long chapter is asked in parts, each within the budget, each quote asked once, and each
    /// part after the first opens with the paragraphs before it.
    func testALongChapterIsAskedInPartsWithinTheBudget() {
        let filler = String(repeating: "The machine hummed in the walls of the room and nobody moved. ", count: 12)
        var paragraphs: [String] = []
        for k in 0..<60 { paragraphs.append(filler); paragraphs.append("\u{201C}Line \(k).\u{201D}") }
        var spans = DialogueCast.segment(doc([paragraphs]))
        DialogueCast.attributeRules(&spans, cast: cast)
        let prompts = DialogueCast.fillPrompts(spans, cast: cast)
        XCTAssertGreaterThan(prompts.count, 1)
        let asked = prompts.flatMap(\.asked)
        XCTAssertEqual(asked, (1...60).map { "c1q\($0)" }, "every quote once, in order")
        for p in prompts {
            XCTAssertLessThan(p.text.count, DialogueCast.fillBudget + 1_500, "passages within the budget, plus the cast and the ask")
            XCTAssertLessThanOrEqual(p.asked.count, DialogueCast.fillMaxAsked)
        }
        XCTAssertTrue(prompts[1].text.contains("Line \(prompts[0].asked.count - 1).") , "context from before the cut")
    }

    func testTheReplyIsReadStrictly() {
        let reply = """
        <think>Mary asks, so the stranger answers.</think>
        ```json
        {"c1q1": "Tom", "c1q2": "tom", "c1q3": "narrator", "c1q4": "The Stranger", "c1q5": "Mary (probably)",
         "c1q6": "unknown", "c1q7": 3, "c1q9": "Mary"}
        ```
        """
        let read = DialogueCast.parseFill(reply, asked: ["c1q2", "c1q3", "c1q4", "c1q5", "c1q6", "c1q7", "c1q8"], cast: cast)
        XCTAssertEqual(read, ["c1q2": "Tom"], "a cast name (any case) only; never an id that was not asked (c1q1, c1q9)")
        XCTAssertEqual(DialogueCast.parseFill("I think Tom says it.", asked: ["c1q2"], cast: cast), [:])
    }

    func testAModelPlacesTheRestAndTheBookVoicesThem() async {
        let asked = Recorder()
        let fill = await DialogueCast.fill(room, cast: sheet) { system, user in
            asked.add(user)
            XCTAssertEqual(system, DialogueCast.fillSystem)
            return (#"{"c1q2": "Tom", "c1q3": "Mary"}"#, "a test model")
        }
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(fill, DialogueCast.Fill(speakers: ["c1q2": "Tom", "c1q3": "Mary"], asked: 1, answered: 1, source: "a test model",
                                               quotes: 4, placedByRules: 2))

        var spans = DialogueCast.segment(room)
        DialogueCast.attributeRules(&spans, cast: cast)
        DialogueCast.applyFill(fill, to: &spans, cast: cast)
        let quotes = spans.filter { $0.kind == .quote }
        XCTAssertEqual(quotes.map(\.speaker), ["Mary", "Tom", "Mary", "Tom"])
        XCTAssertEqual(quotes.map(\.method), ["tag", "model", "model", "tag"])

        let narrator = "kokoro:bf_isabella"
        let casting = DialogueCast.Casting(sheet: sheet, document: room, narrator: narrator,
                                           available: ["kokoro:bf_isabella", "kokoro:bf_emma", "kokoro:bm_george"])
        let plan = VoicePlan(narrator: narrator)
        let rulesOnly = DialogueCast.prepare(room, plan: plan, casting: casting)
        let withFill = DialogueCast.prepare(room, plan: plan, casting: casting, fill: fill)
        func speakers(_ book: PreparedBook) -> [String] { book.chapters[0].segments.compactMap(\.speaker) }
        XCTAssertEqual(speakers(rulesOnly), ["Mary", "Tom"])
        XCTAssertEqual(speakers(withFill), ["Mary", "Tom", "Mary", "Tom"])
        XCTAssertEqual(DialogueCast.prepare(room, plan: plan, casting: casting, fill: DialogueCast.Fill()), rulesOnly,
                       "no answers: the rules-only book, byte for byte")
    }

    /// A model that contradicts the rules on the nearest quote they placed has lost the thread
    /// there: its answers next to that quote are set aside, and the narrator reads them.
    func testAnswersNextToAContradictionAreSetAside() async {
        let lost = await DialogueCast.fill(room, cast: sheet) { _, _ in
            (#"{"c1q1": "Tom", "c1q2": "Tom", "c1q3": "Mary", "c1q4": "Tom"}"#, "a test model")
        }
        XCTAssertEqual(lost.speakers, [:], "c1q1 is Mary's by its tag, so both answers after it are set aside")
        XCTAssertEqual(lost.setAside, 2)
        let agreeing = await DialogueCast.fill(room, cast: sheet) { _, _ in
            (#"{"c1q1": "Mary", "c1q2": "Tom", "c1q3": "Mary", "c1q4": "Tom"}"#, "a test model")
        }
        XCTAssertEqual(agreeing.speakers, ["c1q2": "Tom", "c1q3": "Mary"])
        XCTAssertEqual(agreeing.setAside, 0)
    }

    /// A rule's answer is never overruled, and a name taken off the cast since is not voiced.
    func testAnswersNeverOverruleTheRulesOrOutliveTheCast() {
        var spans = DialogueCast.segment(room)
        DialogueCast.attributeRules(&spans, cast: cast)
        DialogueCast.applyFill(DialogueCast.Fill(speakers: ["c1q1": "Tom", "c1q2": "Tom", "c1q3": "Thomas"]), to: &spans, cast: cast)
        XCTAssertEqual(spans.filter { $0.kind == .quote }.map(\.speaker), ["Mary", "Tom", nil, "Tom"])
    }

    /// No model answering: two failures and the rest are not tried, and the rules stand.
    func testWhenNoModelAnswersTheRulesStand() async {
        let two = doc([room.chapters[0].paragraphs, room.chapters[0].paragraphs, room.chapters[0].paragraphs])
        let asked = Recorder()
        let fill = await DialogueCast.fill(two, cast: sheet) { _, user in
            asked.add(user)
            throw URLError(.timedOut)
        }
        XCTAssertEqual(asked.count, 2, "three chapters to ask, stopped after two failures")
        XCTAssertEqual(fill, DialogueCast.Fill(speakers: [:], asked: 2, answered: 0, source: nil, quotes: 12, placedByRules: 6))

        // A model that answers once and then fails keeps what it said.
        let calls = Recorder()
        let partial = await DialogueCast.fill(two, cast: sheet) { _, user in
            calls.add(user)
            if calls.count > 1 { throw URLError(.timedOut) }
            return (#"{"c1q2": "Tom"}"#, "a test model")
        }
        XCTAssertEqual(calls.count, 3, "once something answered, every chapter is tried")
        XCTAssertEqual(partial.speakers, ["c1q2": "Tom"])
        XCTAssertEqual(partial.answered, 1)
    }

    /// The walk's exchange as qwen3:8b answered it, Mrs. Bennet for every line
    /// after her husband's first. Her tags on both sides fall on alternate turns, so the
    /// exchange is the two of them taking turns and the answers that break it are replaced.
    func testAnExchangeBetweenTwoTakesTurnsWhereTheModelLostTheThread() async {
        let bennets = [DialogueCast.Character(name: "Mr. Bennet", gender: "m", age: "adult"),
                       DialogueCast.Character(name: "Mrs. Bennet", gender: "f", age: "adult", aliases: ["his wife"])]
        func q(_ text: String) -> String { "\u{201C}\(text)\u{201D}" }
        let exchange = doc([[
            q("Do not you want to know who has taken it?") + " cried his wife, impatiently.",
            q("You want to tell me, and I have no objection to hearing it."),
            "This was invitation enough.",
            q("Why, my dear, you must know, Mrs. Long says that Netherfield is taken by a young man of large fortune."),
            q("What is his name?"),
            q("Bingley."),
            q("Is he married or single?"),
            q("Oh, single, my dear, to be sure!"),
            q("How so? how can it affect them?"),
            q("My dear Mr. Bennet,") + " replied his wife, " + q("how can you be so tiresome?"),
        ]])
        let (mrs, mr) = ("Mrs. Bennet", "Mr. Bennet")
        let lost = [mr, mrs, mrs, mrs, mrs, mrs, mrs]
        var reply = ["c1q1": mrs, "c1q9": mrs, "c1q10": mrs]
        for (n, who) in zip(2...8, lost) { reply["c1q\(n)"] = who }
        let json = String(data: try! JSONSerialization.data(withJSONObject: reply), encoding: .utf8)!
        let fill = await DialogueCast.fill(exchange, cast: DialogueCast.CastSheet(characters: bennets)) { _, _ in (json, "a test model") }
        XCTAssertEqual((2...8).map { fill.speakers["c1q\($0)"] }, [mr, mrs, mr, mrs, mr, mrs, mr])

        // Answers that already take turns are kept as given.
        let right = [mr, mrs, mr, mrs, mr, mrs, mr]
        var fine: [String: String] = [:]
        for (n, who) in zip(2...8, right) { fine["c1q\(n)"] = who }
        let fineJSON = String(data: try! JSONSerialization.data(withJSONObject: fine), encoding: .utf8)!
        let kept = await DialogueCast.fill(exchange, cast: DialogueCast.CastSheet(characters: bennets)) { _, _ in (fineJSON, "a test model") }
        XCTAssertEqual(kept.speakers, fine)
    }

    /// Where the anchors do not fall on alternate turns (she speaks twice running, a beat
    /// between) or the model names a third person, the answers stand as given.
    func testTurnsAreNotForcedWhereTheAnchorsOrTheAnswersSayOtherwise() {
        let bennets = [DialogueCast.Character(name: "Mr. Bennet", gender: "m", age: "adult"),
                       DialogueCast.Character(name: "Mrs. Bennet", gender: "f", age: "adult", aliases: ["his wife"]),
                       DialogueCast.Character(name: "Lizzy", gender: "f", age: "young")]
        func q(_ text: String) -> String { "\u{201C}\(text)\u{201D}" }
        let twice = doc([[
            q("But it is,") + " returned his wife.",
            "Mr. Bennet made no answer.",
            q("Do you not hear me?"),
            q("Do not you want to know who has taken it?") + " cried his wife, impatiently.",
        ]])
        var spans = DialogueCast.segment(twice)
        DialogueCast.attributeRules(&spans, cast: bennets)
        var rules: [String: String] = [:]
        for s in spans where s.kind == .quote { if let who = s.speaker { rules[s.id] = who } }
        XCTAssertEqual(rules, ["c1q1": "Mrs. Bennet", "c1q3": "Mrs. Bennet"])
        XCTAssertEqual(DialogueCast.keepingTurns(["c1q2": "Mrs. Bennet"], spans: spans, rules: rules, cast: bennets),
                       ["c1q2": "Mrs. Bennet"], "two turns from her to her: not an alternation, so nothing to enforce")

        let three = doc([[
            q("Do not you want to know who has taken it?") + " cried his wife.",
            q("What is his name?"),
            q("Bingley."),
            q("Is he married or single?"),
            q("Oh, single!") + " cried his wife.",
        ]])
        var spans3 = DialogueCast.segment(three)
        DialogueCast.attributeRules(&spans3, cast: bennets)
        let rules3 = ["c1q1": "Mrs. Bennet", "c1q5": "Mrs. Bennet"]
        let answers = ["c1q2": "Lizzy", "c1q3": "Mrs. Bennet", "c1q4": "Mr. Bennet"]
        XCTAssertEqual(DialogueCast.keepingTurns(answers, spans: spans3, rules: rules3, cast: bennets), answers,
                       "a third name: not a strict exchange between two")
    }

    func testAFillSurvivesBeingSaved() throws {
        let fill = DialogueCast.Fill(speakers: ["c2q7": "Mary"], asked: 3, answered: 2, source: "chat on the home server")
        XCTAssertEqual(try JSONDecoder().decode(DialogueCast.Fill.self, from: JSONEncoder().encode(fill)), fill)
    }

    /// The an internal task walk's chapter (`docs/evidence/tbx-10886/walk/book-pride-and-prejudice-ch1.md`,
    /// passed as `BATON_WALK_BOOK`) placed by a live model the way the app places it, with the
    /// walk's ten-speaker cast, scored against the right speakers (the G5 pair's rules and the home-network model
    /// `chat` answers, 32 of 32). The caption under the illustration is not a line: voiced, it
    /// counts as one more wrong.
    func testTheWalkChapterWithALiveModel() async throws {
        guard let path = ProcessInfo.processInfo.environment["BATON_WALK_BOOK"] else {
            throw XCTSkip("set BATON_WALK_BOOK and BATON_LIVE_OLLAMA_MODEL (or BATON_LIVE_AGENT_FILE) to place the walk's chapter")
        }
        guard let live = LiveModel.complete(.dialogueCast) else { throw XCTSkip("no live model") }
        let book = try DocumentImporter.importFile(at: URL(fileURLWithPath: path))
        func person(_ name: String, _ gender: String, _ aliases: [String] = []) -> DialogueCast.Character {
            DialogueCast.Character(name: name, gender: gender, age: "adult", aliases: aliases)
        }
        // The walk's cast as qwen3:8b proposed it (walk/cast-editor.png): the Bennets with the
        // aliases it gave, and eight people who never speak in the chapter.
        let walkCast = [person("Mr. Bennet", "m"), person("Mrs. Bennet", "f", ["his wife", "his lady"]),
                        person("Mrs. Long", "f"), person("Mr. Bingley", "m"), person("Lizzy", "f"), person("Jane", "f"),
                        person("Lydia", "f"), person("Sir William", "m"), person("Lady Lucas", "f"), person("Mr. Morris", "m")]
        let (mrs, mr) = ("Mrs. Bennet", "Mr. Bennet")
        let right = [mrs, mrs, mrs, mrs, mrs, mr, mrs, mr, mrs, mr, mrs, mr, mrs, mrs, mr, mrs,
                     mr, mrs, mr, mrs, mr, mrs, mr, mrs, mr, mr, mrs, mr, mrs, mr, mrs, mr]
        let sheet = DialogueCast.CastSheet(characters: walkCast)
        let started = Date()
        let fill = await DialogueCast.fill(book, cast: sheet, complete: live.complete)
        var spans = DialogueCast.segment(book)
        DialogueCast.attributeRules(&spans, cast: walkCast)
        let rules = spans.filter { $0.kind == .quote && $0.speaker != nil }.count
        DialogueCast.applyFill(fill, to: &spans, cast: walkCast)
        let quotes = spans.filter { $0.kind == .quote }
        let caption = quotes.first { $0.text.hasPrefix("He came down to see the place") }
        let lines = quotes.filter { $0 != caption }
        XCTAssertEqual(lines.count, right.count)
        var correct = 0
        for (q, who) in zip(lines, right) {
            if q.speaker == who { correct += 1 } else {
                print("WALK wrong \(q.id) \(q.speaker ?? "narrator")≠\(who) (\(q.method ?? "-")) \(q.text.prefix(40))")
            }
        }
        let voicedCaption = caption?.speaker != nil
        print("WALK \(live.name): \(correct)/\(right.count) lines right, caption \(caption == nil ? "not a quote" : voicedCaption ? "voiced as \(caption!.speaker!)" : "a quote with the narrator"); "
              + "rules \(rules), model kept \(fill.speakers.count), set aside \(fill.setAside), "
              + "\(fill.answered)/\(fill.asked) prompts in \(Int(Date().timeIntervalSince(started))) s; "
              + "right of everything voiced: \(correct)/\(right.count + (voicedCaption ? 1 : 0))")
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var count: Int { lock.withLock { items.count } }
    var all: [String] { lock.withLock { items } }
}
