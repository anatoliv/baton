import Foundation

/// Who speaks each quote in a book, for a cast of voices (`specs/document-clippings.md`,
/// *Dialogue cast*; board G1).
///
/// A Swift port of the proof of concept in `specs/poc/dialogue-cast/`, rule for rule, so the
/// numbers measured there hold here (98.8% precision with rules alone on the sample; 99.0% with
/// a model kept only where turn-taking agrees). The design bet is unchanged: **a quote nobody is
/// sure about goes to the narrator**, so every rule may decline and only a wrong character voice
/// is a defect.
///
/// Quotes are numbered exactly as `DocumentSpeech.prepare` numbers them (per chapter, in reading
/// order, over the same normalized text), so `attribution(_:)` plugs straight into it.
public enum DialogueCast {

    // MARK: - Cast sheet

    public struct Character: Codable, Sendable, Equatable {
        public var name: String
        /// "f", "m", or "x" (unknown, a committee, a crowd).
        public var gender: String
        /// "child", "young", "adult", "old".
        public var age: String
        /// Lower-cased phrases the text uses for them: "his mother", "the attendant".
        public var aliases: [String]
        public var notes: String
        /// A crowd: never one side of a two-person conversation.
        public var group: Bool

        public init(name: String, gender: String, age: String = "adult", aliases: [String] = [],
                    notes: String = "", group: Bool = false) {
            self.name = name
            self.gender = gender
            self.age = age
            self.aliases = aliases.map { $0.lowercased() }
            self.notes = notes
            self.group = group
        }

        enum CodingKeys: String, CodingKey { case name, gender, age, aliases, notes, group }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(name: try c.decode(String.self, forKey: .name),
                      gender: try c.decodeIfPresent(String.self, forKey: .gender) ?? "x",
                      age: try c.decodeIfPresent(String.self, forKey: .age) ?? "adult",
                      aliases: try c.decodeIfPresent([String].self, forKey: .aliases) ?? [],
                      notes: try c.decodeIfPresent(String.self, forKey: .notes) ?? "",
                      group: try c.decodeIfPresent(Bool.self, forKey: .group) ?? false)
        }
    }

    public struct CastSheet: Codable, Sendable, Equatable {
        public var characters: [Character]
        public init(characters: [Character]) { self.characters = characters }
    }

    // MARK: - Spans

    public struct Span: Sendable, Equatable {
        public enum Kind: Sendable { case quote, narration }
        /// "c{chapter}q{n}" for quotes (1-based, as the proof of concept writes them).
        public var id: String
        public var kind: Kind
        /// The text without its quotation marks.
        public var text: String
        /// Zero-based chapter index and the quote's zero-based index within it (quotes only).
        public var chapter: Int
        public var quoteIndex: Int
        public var paragraph: Int
        public var continues: Bool
        public var speaker: String?
        public var method: String?
    }

    /// Split the document into narration and quotes, numbering quotes the way
    /// `DocumentSpeech.prepare` does.
    public static func segment(_ document: ImportedDocument) -> [Span] {
        var spans: [Span] = []
        for chapter in document.chapters {
            var open = false
            var q = 0
            var n = 0
            for (p, paragraph) in chapter.paragraphs.enumerated() {
                let carried = open
                let pieces = DocumentSpeech.dialogueSpans(DocumentSpeech.normalize(paragraph), continuingQuote: &open)
                for (k, piece) in pieces.enumerated() {
                    let text = stripMarks(piece.text)
                    if piece.isQuote {
                        q += 1
                        spans.append(Span(id: "c\(chapter.index + 1)q\(q)", kind: .quote, text: text,
                                          chapter: chapter.index, quoteIndex: q - 1, paragraph: p,
                                          continues: carried && k == 0, speaker: nil, method: nil))
                    } else if !text.isEmpty {
                        n += 1
                        spans.append(Span(id: "c\(chapter.index + 1)n\(n)", kind: .narration, text: text,
                                          chapter: chapter.index, quoteIndex: -1, paragraph: p,
                                          continues: false, speaker: nil, method: nil))
                    }
                }
            }
        }
        return spans
    }

    static func stripMarks(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{201C}\u{201D}").union(.whitespaces))
    }

    // MARK: - Rules

    /// The verbs of a speech tag. The second group came from the held-out texts (G1, TBX-10894):
    /// Austen's "returned" and "rejoined", Doyle's "ejaculated" and "interposed", Mansfield's
    /// "wailed", "drawled" and "snapped". Verbs that are as often an action ("turned", "smiled",
    /// "looked") stay out: a tag that is really an action would give the line to whoever acted.
    static let speechVerbs = "said|cried|called|asked|replied|exclaimed|answered|repeated|murmured|whispered|"
        + "shouted|continued|thought|added|began|interrupted|remarked|retorted|sobbed|gasped|"
        + "screamed|cried out|went on|resumed|observed|declared|asserted|protested|urged|"
        + "pleaded|explained|insisted|admitted|shrieked|whimpered|moaned|stammered|echoed|"
        + "complained|exploded|spoke|"
        + "returned|rejoined|responded|ejaculated|interposed|wailed|drawled|snapped|muttered|"
        + "groaned|sighed|wheezed|snarled|growled|demanded|inquired|enquired|suggested|warned|"
        + "faltered|persisted|pursued|mumbled|hissed|breathed|chuckled|laughed|says"
    /// Titles written with a full stop. Without them "said Mr. Bennet." ended at "Mr", so the
    /// tag named nobody (G4's open point, fixed in TBX-10894).
    static let titles = #"(?:Mr|Mrs|Ms|Messrs|Mme|Mlle|Dr|St|Sr|Jr|Prof|Rev|Capt|Col|Gen|Lt|Sgt|Hon)\."#
    static let tagAfter = try! NSRegularExpression(
        pattern: #"^[,.!?\u2014\s]*((?:\S+\s+){0,8}?)(?:"# + speechVerbs + #")\b\s*((?:"# + titles + #"|[^,.;:!?\u2014]){0,80})"#)
    static let tagBefore = try! NSRegularExpression(
        pattern: #"((?:\S+\s+){1,8}?)(?:"# + speechVerbs + #")(?:\s+\w+)?\s*[:,]?\s*$"#)
    static let reported = try! NSRegularExpression(
        pattern: #"^(He|She|They)\s+(?:replied|answered|told|asked|said|repeated|complained|retorted|whispered)\b"#)
    static let pronouns: Set<String> = ["he", "she", "they", "i"]
    static let monologue = 400

    static func groups(_ re: NSRegularExpression, _ text: String, anchored: Bool) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = anchored ? re.firstMatch(in: text, options: [.anchored], range: range)
                               : re.firstMatch(in: text, range: range) else { return nil }
        return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }

    static func tagPhrases(after: String?, before: String?) -> [String] {
        var out: [String] = []
        if let after, let g = groups(tagAfter, after, anchored: true) {
            let subject = g[1].trimmingCharacters(in: .whitespaces)
            out.append(subject.isEmpty ? g[2].trimmingCharacters(in: .whitespaces) : subject)
        }
        if let before, let g = groups(tagBefore, before, anchored: false) {
            let words = g[1].split(whereSeparator: \.isWhitespace).map(String.init)
            for k in 1...max(1, words.count) where k <= words.count {
                out.append(words.suffix(k).joined(separator: " "))
            }
        }
        let trim = CharacterSet(charactersIn: " ,;").union(CharacterSet(charactersIn: String(Typography.emDash)))
        return out.map { $0.trimmingCharacters(in: trim) }.filter { !$0.isEmpty }
    }

    struct Resolver {
        let cast: [Character]
        var byAlias: [String: Character] = [:]
        var aliasOrder: [String] = []

        init(_ cast: [Character]) {
            self.cast = cast
            for c in cast {
                for a in [c.name.lower] + c.aliases where byAlias[a] == nil {
                    byAlias[a] = c
                    aliasOrder.append(a)
                }
            }
        }

        func resolve(_ phrase: String, onStage: [String]) -> String? {
            let p = phrase.lowercased().trimmingCharacters(in: .whitespaces)
            if let c = byAlias[p] { return c.name }
            let whole = aliasOrder.filter { $0.contains(" ") && (p == $0 || p.hasPrefix($0 + " ")) }.compactMap { byAlias[$0] }
            if Set(whole.map(\.name)).count == 1 { return whole[0].name }
            if p == "he" || p == "she" {
                let g = p == "he" ? "m" : "f"
                var seen = Set<String>()
                let candidates = onStage.filter { seen.insert($0).inserted }
                    .filter { name in cast.first { $0.name == name }?.gender == g }
                return candidates.count == 1 ? candidates[0] : nil
            }
            return nil
        }
    }

    static func mentions(_ text: String, cast: [Character]) -> [String] {
        let lower = text.lowercased()
        var found: [(Int, String)] = []
        for c in cast {
            for phrase in [c.name.lower] + c.aliases where !pronouns.contains(phrase) {
                guard let re = try? NSRegularExpression(pattern: #"\b"# + NSRegularExpression.escapedPattern(for: phrase) + #"\b"#)
                else { continue }
                for m in re.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
                    found.append((m.range.location, c.name))
                }
            }
        }
        return found.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : false }.map(\.1)
    }

    /// The deterministic rules: speech tags, vocatives, same-paragraph propagation, carried-over
    /// speeches, and two-party turn-taking (filled only where forward and backward agree, unless
    /// `agreeBothWays` is false, which the agreement policy uses as its second opinion).
    public static func attributeRules(_ spans: inout [Span], cast: [Character], window: Int = 40,
                                      agreeBothWays: Bool = true) {
        let resolver = Resolver(cast)
        let gender = Dictionary(cast.map { ($0.name, $0.gender) }, uniquingKeysWith: { a, _ in a })
        let groupNames = Set(cast.filter(\.group).map(\.name))

        var focal: [Int: String] = [:]
        for chapter in Set(spans.map(\.chapter)) {
            var counts: [String: Int] = [:]
            var firstSeen: [String: Int] = [:]
            var order = 0
            for s in spans where s.chapter == chapter && s.kind == .narration {
                for name in mentions(s.text, cast: cast) {
                    counts[name, default: 0] += 1
                    if firstSeen[name] == nil { firstSeen[name] = order; order += 1 }
                }
            }
            // Python's Counter.most_common breaks ties by first insertion.
            if let best = counts.max(by: { a, b in a.value != b.value ? a.value < b.value : firstSeen[a.key]! > firstSeen[b.key]! }) {
                focal[chapter] = best.key
            }
        }

        func onStage(_ index: Int) -> [String] {
            var seen: [String] = []
            let chapter = spans[index].chapter
            var i = index - 1
            while i >= max(0, index - window) {
                let s = spans[i]
                if s.chapter != chapter { break }
                if let who = s.speaker { seen.append(who) }
                if s.kind == .narration { seen.append(contentsOf: mentions(s.text, cast: cast).reversed()) }
                i -= 1
            }
            if let f = focal[chapter] { seen.append(f) }
            var unique = Set<String>()
            return seen.filter { unique.insert($0).inserted && !groupNames.contains($0) }
        }

        // Rule 1: speech tags. A quote whose own tag names nobody on the cast ("the woman
        // answered", for a woman the sheet does not list) is spoken by someone else: it never
        // takes the paragraph's speaker (found on Mansfield's "The Garden-Party", G2).
        var taggedElsewhere = Set<Int>()
        for i in spans.indices where spans[i].kind == .quote {
            let s = spans[i]
            let next = i + 1 < spans.count ? spans[i + 1] : nil
            let prev = i > 0 ? spans[i - 1] : nil
            let after = (next?.kind == .narration && next?.chapter == s.chapter && next?.paragraph == s.paragraph) ? next?.text : nil
            var before: String?
            if let prev, prev.kind == .narration, prev.chapter == s.chapter {
                let trimmed = prev.text.trimmingCharacters(in: .whitespaces)
                if prev.paragraph == s.paragraph || trimmed.hasSuffix(":") || trimmed.hasSuffix(",") { before = prev.text }
            }
            let stage = onStage(i)
            let phrases = tagPhrases(after: after, before: before)
            for phrase in phrases {
                if let who = resolver.resolve(phrase, onStage: stage) {
                    spans[i].speaker = who
                    spans[i].method = "tag"
                    break
                }
            }
            if spans[i].speaker == nil, phrases.contains(where: { !pronouns.contains($0.lowercased()) }) { taggedElsewhere.insert(i) }
        }

        // Rule 2: vocatives.
        var vocatives: [(String, [String])] = []
        for c in cast {
            let phrases = ([c.name.lower] + c.aliases).filter { (!pronouns.contains($0) && !$0.contains(" ")) || $0 == c.name.lower }
            vocatives.append((c.name, phrases))
        }
        func addressedIn(_ text: String) -> Set<String> {
            let lower = text.lowercased()
            var addressed = Set<String>()
            for (name, phrases) in vocatives {
                for ph in phrases {
                    let pattern = #"(?:^|[,;\u2014]\s*)(?:o\s+)?"# + NSRegularExpression.escapedPattern(for: ph) + #"\s*(?:[,!?;\u2014]|$)"#
                    if let re = try? NSRegularExpression(pattern: pattern),
                       re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
                        addressed.insert(name)
                    }
                }
            }
            return addressed
        }
        for i in spans.indices where spans[i].kind == .quote && spans[i].speaker == nil {
            let addressed = addressedIn(spans[i].text)
            guard addressed.count == 1 else { continue }
            let others = onStage(i).filter { !addressed.contains($0) && gender[$0] != "x" }
            if others.count == 1 {
                spans[i].speaker = others[0]
                spans[i].method = "vocative"
            }
        }

        let paragraphKeys = orderedParagraphKeys(spans)
        func propagate() {
            for key in paragraphKeys {
                let quotes = spans.indices.filter { spans[$0].kind == .quote && spans[$0].chapter == key.0 && spans[$0].paragraph == key.1 }
                let speakers = Set(quotes.compactMap { spans[$0].speaker })
                if speakers.count == 1, let who = speakers.first {
                    for q in quotes where spans[q].speaker == nil && !taggedElsewhere.contains(q) {
                        spans[q].speaker = who
                        spans[q].method = "paragraph"
                    }
                }
            }
            let quotes = spans.indices.filter { spans[$0].kind == .quote }
            for (a, b) in zip(quotes, quotes.dropFirst()) where spans[b].continues && spans[b].speaker == nil && !taggedElsewhere.contains(b) {
                if let who = spans[a].speaker {
                    spans[b].speaker = who
                    spans[b].method = "continuation"
                }
            }
        }
        propagate()

        // Rule 3: turn-taking.
        for chapter in Set(spans.map(\.chapter)).sorted() {
            let units = turnUnits(spans, chapter: chapter, paragraphKeys: paragraphKeys)

            func known(_ u: Int) -> String? {
                let (kind, members) = units[u]
                switch kind {
                case .turn:
                    let names = Set(members.compactMap { spans[$0].speaker })
                    guard names.count == 1, let who = names.first else { return names.isEmpty ? nil : "?" }
                    return groupNames.contains(who) ? "?" : who
                case .reported:
                    guard let first = members.first, let g = groups(reported, spans[first].text, anchored: true) else { return nil }
                    return resolver.resolve(g[1], onStage: onStage(first))
                default:
                    return nil
                }
            }

            func sweep(_ order: [Int]) -> [Int: (String, Int)] {
                var guess: [Int: (String, Int)] = [:]
                var last: String?
                var parties: [String] = []
                var distance = 0
                for u in order {
                    let kind = units[u].0
                    if kind == .breakRun { last = nil; parties = []; distance = 0; continue }
                    if kind == .beat {
                        // A beat about someone outside the exchange ("Mrs. Bennet deigned not
                        // to make any reply; but ... began scolding one of her daughters.")
                        // brings them in: the next line may be theirs, so the pair no longer
                        // decides it (found on Austen once "said Mr. Bennet" was read, TBX-10894).
                        if parties.count == 2,
                           units[u].1.contains(where: { m in mentions(spans[m].text, cast: cast).contains { !parties.contains($0) && !groupNames.contains($0) } }) {
                            last = nil; parties = []; distance = 0
                        }
                        continue
                    }
                    let who = known(u)
                    if who == "?" { last = nil; parties = []; distance = 0; continue }
                    if let who {
                        last = who
                        distance = 0
                        if !parties.contains(who) { parties = Array((parties + [who]).suffix(2)) }
                        // A turn that addresses someone outside the exchange by name ("When is
                        // your next ball to be, Lizzy?") hands it to them: the next turn is
                        // between these two, not the old pair (found on Austen, G2).
                        if kind == .turn {
                            let addressed = Set(units[u].1.flatMap { addressedIn(spans[$0].text) })
                                .filter { $0 != who && !groupNames.contains($0) }
                            if addressed.count == 1, let to = addressed.first, !parties.contains(to) { parties = [who, to] }
                        }
                        continue
                    }
                    if kind == .turn, let l = last, parties.count == 2 {
                        let other = parties[1] == l ? parties[0] : parties[1]
                        distance += 1
                        guess[u] = (other, distance)
                        last = other
                    } else {
                        last = nil
                        distance = 0
                    }
                }
                return guess
            }

            let order = Array(units.indices)
            let forward = sweep(order)
            let backward = sweep(order.reversed())
            for u in Set(forward.keys).union(backward.keys) {
                let f = forward[u], b = backward[u]
                var who: String?
                if let f, let b {
                    who = f.0 == b.0 ? f.0 : nil
                } else if let one = f ?? b {
                    who = !agreeBothWays && one.1 <= 2 ? one.0 : nil
                }
                if let who {
                    for m in units[u].1 where spans[m].speaker == nil {
                        spans[m].speaker = who
                        spans[m].method = "alternation"
                    }
                }
            }
        }
        propagate()
    }

    enum UnitKind { case turn, reported, beat, breakRun }

    /// A chapter's paragraphs as turn-taking sees them: a turn (a paragraph of speech, or one led
    /// by a short tag), a reported reply ("She replied that..."), a beat (a short paragraph of
    /// narration) or a break (anything else, or the second of two long speeches in a row).
    static func turnUnits(_ spans: [Span], chapter: Int, paragraphKeys: [(Int, Int)]) -> [(UnitKind, [Int])] {
        var units: [(UnitKind, [Int])] = []
        for key in paragraphKeys where key.0 == chapter {
            let group = spans.indices.filter { spans[$0].chapter == key.0 && spans[$0].paragraph == key.1 }
            guard let lead = group.first else { continue }
            let quotes = group.filter { spans[$0].kind == .quote }
            let leadText = spans[lead].text
            let leadLength = spans[lead].kind == .narration ? leadText.count : 0
            let leadTrimmed = leadText.trimmingCharacters(in: .whitespaces)
            if let first = quotes.first, spans[first].continues, let last = units.last, last.0 == .turn {
                units[units.count - 1].1.append(contentsOf: quotes)
            } else if !quotes.isEmpty && (spans[lead].kind == .quote
                        || (leadLength <= 80 && (leadTrimmed.hasSuffix(",") || leadTrimmed.hasSuffix(":")))) {
                let speech = quotes.reduce(0) { $0 + spans[$1].text.count }
                if let prior = units.last(where: { $0.0 != .beat }), prior.0 == .turn, speech > monologue,
                   prior.1.reduce(0, { $0 + spans[$1].text.count }) > monologue {
                    units.append((.breakRun, []))
                }
                units.append((.turn, quotes))
            } else if quotes.isEmpty, groups(reported, leadText, anchored: true) != nil {
                units.append((.reported, group))
            } else if quotes.isEmpty, leadText.count <= 200, group.count == 1 {
                units.append((.beat, group))
            } else {
                units.append((.breakRun, group))
            }
        }
        return units
    }

    static func orderedParagraphKeys(_ spans: [Span]) -> [(Int, Int)] {
        var seen = Set<String>()
        var keys: [(Int, Int)] = []
        for s in spans where seen.insert("\(s.chapter)|\(s.paragraph)").inserted {
            keys.append((s.chapter, s.paragraph))
        }
        return keys.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
    }

    // MARK: - The model step

    public static let modelSystem = """
        You attribute quoted dialogue in fiction to speakers.
        You get a cast list and a chapter in which every quote is wrapped as [Q id]...[/Q].
        Some quotes are already attributed, shown as [Q id=Name]...[/Q]; trust those.
        For every unattributed quote, answer with the cast member who speaks it, "narrator" if it
        is not speech (a title, a quoted word or phrase), or "unknown" if the text does not make
        it clear. Prefer "unknown" to a guess: a wrong speaker is worse than none.
        Reply with one JSON object mapping quote id to name, and nothing else.
        """

    /// One chapter for the model: the cast, then the chapter with every quote marked, and the
    /// rules' answers shown as given. A chapter of the sample measured 5.8k to 6.8k tokens.
    public static func chapterPrompt(_ spans: [Span], chapter: Int, cast: [Character]) -> String {
        var out = ["CAST:"]
        for c in cast {
            let aka = c.aliases.isEmpty ? "" : " (also: \(c.aliases.joined(separator: ", ")))"
            out.append("- \(c.name): \(c.gender), \(c.age)\(aka). \(c.notes)".trimmingCharacters(in: .whitespaces))
        }
        out.append("")
        out.append("CHAPTER \(chapter + 1):")
        var paragraph: Int?
        var line: [String] = []
        for s in spans where s.chapter == chapter {
            if s.paragraph != paragraph, !line.isEmpty {
                out.append(line.joined(separator: " "))
                line = []
            }
            paragraph = s.paragraph
            switch (s.kind, s.speaker) {
            case (.narration, _): line.append(s.text)
            case let (.quote, who?): line.append("[Q \(s.id)=\(who)]\(s.text)[/Q]")
            case (.quote, nil): line.append("[Q \(s.id)]\(s.text)[/Q]")
            }
        }
        if !line.isEmpty { out.append(line.joined(separator: " ")) }
        return out.joined(separator: "\n")
    }

    /// Apply a model's reply to one chapter's unattributed quotes. Names outside the cast are
    /// discarded, never voiced. Returns how many it filled.
    @discardableResult
    public static func applyModel(_ reply: String, to spans: inout [Span], chapter: Int, cast: [Character]) -> Int {
        guard let object = VoiceCaster.jsonObject(in: reply) else { return 0 }
        let names = Set(cast.map(\.name))
        var filled = 0
        for i in spans.indices where spans[i].chapter == chapter && spans[i].kind == .quote && spans[i].speaker == nil {
            guard let who = object[spans[i].id] as? String else { continue }
            if names.contains(who) {
                spans[i].speaker = who
                spans[i].method = "model"
                filled += 1
            } else if who == "narrator" {
                spans[i].method = "model-narrator"
            }
        }
        return filled
    }

    /// The agreement policy: keep a model answer only where one-way turn-taking, computed
    /// independently, names the same speaker. Two different mistakes would have to coincide.
    /// Measured on the sample: 99.0% precision at 44.3% coverage, with qwen3.5:4b and qwen3:8b.
    public static func keepOnlyAgreeing(_ spans: inout [Span], document: ImportedDocument, cast: [Character]) {
        var second = segment(document)
        attributeRules(&second, cast: cast, agreeBothWays: false)
        var oneWay: [String: String] = [:]
        for s in second where s.method == "alternation" { oneWay[s.id] = s.speaker }
        for i in spans.indices where spans[i].method == "model" && oneWay[spans[i].id] != spans[i].speaker {
            spans[i].speaker = nil
            spans[i].method = "model-unconfirmed"
        }
    }

    /// Run the whole thing: rules, then the model per chapter through `complete` (when given),
    /// then the agreement policy. A model failure leaves the rules' answers standing.
    public static func attribute(_ document: ImportedDocument, cast: CastSheet,
                                 complete: VoiceCaster.Complete?) async -> [Span] {
        var spans = segment(document)
        attributeRules(&spans, cast: cast.characters)
        guard let complete else { return spans }
        for chapter in document.chapters.map(\.index) where spans.contains(where: { $0.chapter == chapter && $0.kind == .quote && $0.speaker == nil }) {
            let prompt = chapterPrompt(spans, chapter: chapter, cast: cast.characters)
            if let reply = try? await complete(modelSystem, SecretRedactor.redact(prompt)) {
                applyModel(reply.text, to: &spans, chapter: chapter, cast: cast.characters)
            }
        }
        keepOnlyAgreeing(&spans, document: document, cast: cast.characters)
        return spans
    }

    /// For `DocumentSpeech.prepare(_:voices:attribution:)`.
    public static func attribution(_ spans: [Span]) -> DocumentSpeech.Attribution {
        var map: [String: String] = [:]
        for s in spans where s.kind == .quote {
            if let who = s.speaker { map["\(s.chapter)|\(s.quoteIndex)"] = who }
        }
        let frozen = map
        return { chapter, quote in frozen["\(chapter)|\(quote)"] }
    }

    // MARK: - Voices

    /// A distinct voice per speaking character, never the narrator's and never one the listening
    /// pass ruled out: plausible gender first; then the voices heard as "good for dialogue", then
    /// "good for narration and dialogue", then the rest; then the narrator's accent,
    /// then best-graded; the characters with most lines first.
    public static func assignVoices(_ spans: [Span], cast: [Character], narrator: String,
                                    available: [String]) -> [String: String] {
        var lines: [String: Int] = [:]
        for s in spans where s.kind == .quote { if let who = s.speaker { lines[who, default: 0] += 1 } }
        let narratorAccent = VoiceCatalogue.describe(narrator).accent
        let narratorLanguage = VoiceCatalogue.describe(narrator).language
        let pool = available.map(VoiceCatalogue.describe)
            .filter { ($0.grade != nil || !$0.tags.isEmpty) && !VoiceCatalogue.avoided.contains($0.spec) }
        var used: Set<String> = [VoiceCatalogue.describe(narrator).spec]
        var out: [String: String] = [:]
        for c in cast.sorted(by: { (lines[$0.name] ?? 0) > (lines[$1.name] ?? 0) }) where (lines[c.name] ?? 0) > 0 {
            let wanted = c.gender == "f" ? "female" : (c.gender == "m" ? "male" : nil)
            let ranked = pool.filter { !used.contains($0.spec) && (wanted == nil || $0.gender == wanted) }
                .sorted { a, b in
                    // A voice native in the narrator's language first: an expressive server's
                    // presets include Chinese, Japanese and Korean speakers. Every
                    // voice Kokoro's pool keeps is English, so its order is unchanged.
                    let la = a.language == narratorLanguage ? 0 : 1, lb = b.language == narratorLanguage ? 0 : 1
                    if la != lb { return la < lb }
                    let ra = VoiceCatalogue.dialogueRank(a), rb = VoiceCatalogue.dialogueRank(b)
                    if ra != rb { return ra < rb }
                    let aa = a.accent == narratorAccent ? 1 : 0, ba = b.accent == narratorAccent ? 1 : 0
                    return aa != ba ? aa > ba : (a.gradeRank != b.gradeRank ? a.gradeRank > b.gradeRank : a.spec < b.spec)
                }
            if let pick = ranked.first {
                out[c.name] = pick.spec
                used.insert(pick.spec)
            }
        }
        return out
    }
}

private extension String {
    var lower: String { lowercased() }
}
