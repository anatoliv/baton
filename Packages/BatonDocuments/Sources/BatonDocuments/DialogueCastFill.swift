import Foundation

/// The quotes the rules leave, placed by a model.
///
/// Owner decision, 2026-10-15: rules first, then a model for the quotes they leave, so most
/// quotes get a voice. The rules held 100% on the held-out texts but voiced only about two in
/// five quotes; the rest went to the narrator. Here each chapter's unplaced quotes go to a model
/// with the passages around them and the corrected cast, and a reply is read strictly: an answer
/// counts only when it is a cast name exactly as the sheet writes it. "narrator", "unknown", a
/// name off the cast or an id that was not asked leave the quote with the narrator, as before.
///
/// The answers are kept apart from the rules' (`Fill`), so a book is made from the same cast and
/// the same answers without asking again, and a book with no answers is the rules-only book.
extension DialogueCast {
    /// A model's speakers for quotes the rules left, by quote id ("c3q14").
    public struct Fill: Codable, Sendable, Equatable {
        public var speakers: [String: String]
        /// Prompts sent, and how many came back with a reply that could be read.
        public var asked: Int
        public var answered: Int
        /// Who answered ("chat on the home server"); nil when nobody did.
        public var source: String?
        /// Answers set aside because the model contradicted the rules next to them.
        public var setAside: Int
        /// The book's quotes, and how many the rules placed, for the line the sheet shows.
        public var quotes: Int
        public var placedByRules: Int

        public init(speakers: [String: String] = [:], asked: Int = 0, answered: Int = 0, source: String? = nil,
                    setAside: Int = 0, quotes: Int = 0, placedByRules: Int = 0) {
            self.speakers = speakers
            self.asked = asked
            self.answered = answered
            self.source = source
            self.setAside = setAside
            self.quotes = quotes
            self.placedByRules = placedByRules
        }
    }

    public static let fillSystem = """
        You attribute quoted dialogue in fiction to speakers. You get a cast list and passages \
        from one chapter of a book, in which every quote is wrapped as [Q id]...[/Q]. For each \
        quote id listed under ASK, answer with the cast member who speaks it, written exactly as in the \
        cast list, or "narrator" if it is not speech (a title, a quoted word or phrase, a sign) \
        or the passage does not show who speaks it. In an exchange between two people, lines \
        with no speech tag usually alternate between them. Reply with one JSON object mapping \
        each asked id to a name, and nothing else.
        """

    /// Characters of passages per prompt: about 2,500 tokens, so a prompt with a long cast list
    /// still fits `ModelTask.dialogueCast`'s 8,000 with room for the reply.
    static let fillBudget = 10_000
    /// Paragraphs of context around each unplaced quote: who was talking before it matters more
    /// than what comes after.
    static let fillBefore = 4
    static let fillAfter = 1
    /// Quotes asked about in one prompt: about ten tokens of reply each, inside
    /// `ModelTask.dialogueCast`'s reply budget.
    static let fillMaxAsked = 60

    public struct FillPrompt: Sendable, Equatable {
        public var chapter: Int
        /// The quotes this prompt asks about.
        public var asked: [String]
        public var text: String
    }

    /// The prompts for every chapter with quotes the rules left: those quotes with the paragraphs
    /// around them, cut to `fillBudget`. Every quote in the passages is asked about, the ones the
    /// rules placed too, and their answers are not shown: the model's answers on those are the
    /// check on its answers for the rest (`fill`). Shown the rules' answers, the home model
    /// swapped speakers in long exchanges more often (TBX-10894, *The Machine Stops*).
    public static func fillPrompts(_ spans: [Span], cast: [Character]) -> [FillPrompt] {
        var castLines = ["CAST:"]
        for c in cast {
            let aka = c.aliases.isEmpty ? "" : "; also called: \(c.aliases.joined(separator: ", "))"
            castLines.append("- \(c.name) (\(c.gender == "f" ? "female" : c.gender == "m" ? "male" : "unknown"), \(c.age)\(c.group ? ", a group" : "")\(aka))")
        }
        let castBlock = castLines.joined(separator: "\n")

        var prompts: [FillPrompt] = []
        for chapter in Set(spans.map(\.chapter)).sorted() {
            // The chapter's paragraphs in order, each with its spans.
            var paragraphs: [[Span]] = []
            var current: Int?
            for s in spans where s.chapter == chapter {
                if s.paragraph != current { paragraphs.append([]); current = s.paragraph }
                paragraphs[paragraphs.count - 1].append(s)
            }
            let unplaced = paragraphs.indices.filter { paragraphs[$0].contains { $0.kind == .quote && $0.speaker == nil } }
            let unplacedIDs = Set(unplaced.flatMap { paragraphs[$0] }.filter { $0.kind == .quote && $0.speaker == nil }.map(\.id))
            guard !unplaced.isEmpty else { continue }

            // Windows around the unplaced quotes, merged where they touch.
            var windows: [ClosedRange<Int>] = []
            for k in unplaced {
                let w = max(0, k - fillBefore)...min(paragraphs.count - 1, k + fillAfter)
                if let last = windows.last, w.lowerBound <= last.upperBound + 1 {
                    windows[windows.count - 1] = last.lowerBound...max(last.upperBound, w.upperBound)
                } else {
                    windows.append(w)
                }
            }

            func render(_ k: Int) -> String {
                paragraphs[k].map { $0.kind == .narration ? $0.text : "[Q \($0.id)]\($0.text)[/Q]" }.joined(separator: " ")
            }
            func quoteIDs(_ k: Int) -> [String] {
                paragraphs[k].filter { $0.kind == .quote }.map(\.id)
            }

            // A part is a run of paragraphs (nil: a gap between windows). The first `context`
            // entries were asked in the part before and are there for who was talking. A part
            // that runs over the budget is cut at a paragraph without speech in its second half
            // when there is one, so an exchange is not split in the middle.
            var part: [Int?] = []
            var context = 0
            func asked(_ entries: ArraySlice<Int?>) -> [String] { entries.compactMap { $0 }.flatMap(quoteIDs) }
            func size(_ entries: [Int?]) -> Int { entries.reduce(0) { $0 + ($1.map { render($0).count + 1 } ?? 6) } }
            func emit(_ entries: ArraySlice<Int?>, context: Int) {
                let ask = asked(entries.dropFirst(context))
                // A part holding only quotes the rules placed asks nothing worth a call.
                guard ask.contains(where: unplacedIDs.contains) else { return }
                var shown = Array(entries)
                while shown.first == .some(nil) { shown.removeFirst() }
                while shown.last == .some(nil) { shown.removeLast() }
                let text = castBlock + "\n\nCHAPTER \(chapter + 1), passages:\n"
                    + shown.map { $0.map(render) ?? "[...]" }.joined(separator: "\n")
                    + "\n\nASK: " + ask.joined(separator: ", ")
                prompts.append(FillPrompt(chapter: chapter, asked: ask, text: text))
            }
            for w in windows {
                if !part.isEmpty { part.append(nil) }
                for k in w {
                    part.append(k)
                    guard part.count - context > 1,
                          size(part) > fillBudget || asked(part.dropFirst(context)).count > fillMaxAsked else { continue }
                    var cut = part.count - 1
                    let floor = context + (part.count - context) / 2
                    if let quiet = (floor..<cut).last(where: { i in part[i].map { quoteIDs($0).isEmpty } ?? true }), quiet > context {
                        cut = quiet
                    }
                    emit(part[..<cut], context: context)
                    let start = max(0, cut - 2)
                    part = Array(part[start...])
                    context = cut - start
                }
            }
            emit(part[...], context: context)
        }
        return prompts
    }

    /// A reply read strictly: each asked id's answer counts only when it is a cast name exactly
    /// as the sheet writes it (letter case aside). Everything else is the narrator's.
    public static func parseFill(_ reply: String, asked: [String], cast: [Character]) -> [String: String] {
        guard let object = VoiceCaster.jsonObject(in: reply) else { return [:] }
        var names: [String: String] = [:]
        for c in cast { names[c.name.lowercased()] = c.name }
        var out: [String: String] = [:]
        for id in asked {
            guard let raw = object[id] as? String,
                  let name = names[raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] else { continue }
            out[id] = name
        }
        return out
    }

    /// Ask a model about every quote the rules left in `document`, prompt by prompt.
    /// `progress(done, total)` is called before each prompt. When the first prompts all fail the
    /// rest are not tried: nothing is answering, and each failure can take a whole timeout.
    ///
    /// An answer is kept only when the model agrees with the rules on the nearest quotes they
    /// placed before and after it in the same prompt (where it answered for them): a model that
    /// has lost the thread of an exchange shows it there first.
    public static func fill(_ document: ImportedDocument, cast: CastSheet, complete: VoiceCaster.Complete,
                            progress: (@Sendable (Int, Int) async -> Void)? = nil) async -> Fill {
        var spans = segment(SecretRedactor.redact(document))
        attributeRules(&spans, cast: cast.characters)
        let prompts = fillPrompts(spans, cast: cast.characters)
        var rules: [String: String] = [:]
        for s in spans where s.kind == .quote { if let who = s.speaker { rules[s.id] = who } }
        var fill = Fill(quotes: spans.filter { $0.kind == .quote }.count, placedByRules: rules.count)
        var failures = 0
        for (n, prompt) in prompts.enumerated() {
            if Task.isCancelled { break }
            await progress?(n, prompts.count)
            fill.asked += 1
            guard let reply = try? await complete(fillSystem, prompt.text) else {
                failures += 1
                if fill.answered == 0 && failures >= 2 { break }
                continue
            }
            fill.answered += 1
            fill.source = reply.source
            let answers = parseFill(reply.text, asked: prompt.asked, cast: cast.characters)
            for (k, id) in prompt.asked.enumerated() where rules[id] == nil && fill.speakers[id] == nil {
                guard let who = answers[id] else { continue }
                let before = prompt.asked[..<k].last { rules[$0] != nil }
                let after = prompt.asked[(k + 1)...].first { rules[$0] != nil }
                let contradicted = [before, after].compactMap { $0 }.contains { anchor in
                    answers[anchor].map { $0 != rules[anchor] } ?? false
                }
                if contradicted { fill.setAside += 1 } else { fill.speakers[id] = who }
            }
        }
        await progress?(prompts.count, prompts.count)
        return fill
    }

    /// Give the quotes the rules left the model's speakers. A quote the rules placed keeps its
    /// speaker; a name no longer on the cast (renamed or removed since) is ignored.
    public static func applyFill(_ fill: Fill, to spans: inout [Span], cast: [Character]) {
        let names = Set(cast.map(\.name))
        for i in spans.indices where spans[i].kind == .quote && spans[i].speaker == nil {
            guard let who = fill.speakers[spans[i].id], names.contains(who) else { continue }
            spans[i].speaker = who
            spans[i].method = "model"
        }
    }
}
