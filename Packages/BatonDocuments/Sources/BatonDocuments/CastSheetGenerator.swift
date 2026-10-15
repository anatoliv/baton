import Foundation

/// The cast sheet, written by a model and checked against the text (G3).
///
/// The rules attribute speech only through the sheet: its names and the phrases the text uses
/// for each person ("his mother", "the tall fellow"). On the sample and the held-out texts the
/// sheets were written by hand. This writes one from what the book itself offers: the subjects
/// of its speech tags ("said his mother" ×12), the names it repeats, and a few passages where
/// people talk. The person then corrects it on the import sheet (G4); nothing is used unseen.
///
/// The model's sheet is not trusted as written. A character the text never names, an alias the
/// text never uses, a gender or age outside the sheet's vocabulary, and pronouns as aliases are
/// all dropped here, because a made-up alias is how a wrong voice would reach a quote.
public enum CastSheetGenerator {
    public struct Evidence: Sendable, Equatable {
        /// Speech-tag subjects with how often each occurs, most frequent first.
        public var tags: [(phrase: String, count: Int)]
        /// Repeated names (the lexicon's candidates, without the spell-check filter).
        public var names: [String]
        /// A few passages of dialogue, opening characters of the book's talk.
        public var passages: [String]

        public static func == (a: Evidence, b: Evidence) -> Bool {
            a.tags.map(\.phrase) == b.tags.map(\.phrase) && a.tags.map(\.count) == b.tags.map(\.count)
                && a.names == b.names && a.passages == b.passages
        }
    }

    /// About 1,500 tokens of passages, sampled across the whole book: with the tag phrases and
    /// names the prompt stays near 2,500 tokens however long the book is. A novel's sheet is
    /// slow because of the reply, not the prompt: qwen3:8b ran past the three-minute timeout on
    /// the whole of Pride and Prejudice, and the home server's model repeated "my dear" in an
    /// alias list until it was cut off (G4, 2026-10-15). So the reply is bounded too: at most
    /// `maxCharacters` people with `maxAliases` phrases each, inside `ModelTask.castSheet`'s
    /// reply budget, and a reply cut off at that budget still gives the people it finished.
    static let passageBudget = 6_000
    static let passageLength = 300
    static let maxTags = 30
    static let maxCharacters = 24
    static let maxAliases = 4

    public static func evidence(_ document: ImportedDocument) -> Evidence {
        let spans = DialogueCast.segment(document)
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        for (i, s) in spans.enumerated() where s.kind == .quote {
            let next = i + 1 < spans.count ? spans[i + 1] : nil
            let prev = i > 0 ? spans[i - 1] : nil
            let after = next?.kind == .narration && next?.paragraph == s.paragraph && next?.chapter == s.chapter ? next?.text : nil
            let before = prev?.kind == .narration && prev?.paragraph == s.paragraph && prev?.chapter == s.chapter ? prev?.text : nil
            // The longest phrase a tag offers is the subject as written ("the tallest of the men").
            guard let phrase = DialogueCast.tagPhrases(after: after, before: before).max(by: { $0.count < $1.count })?.lowercased(),
                  !DialogueCast.pronouns.contains(phrase), phrase.count <= 40 else { continue }
            counts[phrase, default: 0] += 1
            if firstSeen[phrase] == nil { firstSeen[phrase] = i }
        }
        let tags = counts.sorted { $0.value != $1.value ? $0.value > $1.value : firstSeen[$0.key]! < firstSeen[$1.key]! }
            .prefix(maxTags).map { (phrase: $0.key, count: $0.value) }

        let names = PronunciationLexicon.candidates(in: document, limit: 30).map(\.word)

        // Paragraphs that hold dialogue, spread over the book: every k-th one until the budget.
        let talky = document.chapters.flatMap { c in c.paragraphs.filter { $0.contains("\u{201C}") } }
        var passages: [String] = []
        var used = 0
        if !talky.isEmpty {
            let stride = max(1, talky.count / (passageBudget / passageLength))
            for p in Swift.stride(from: 0, to: talky.count, by: stride).map({ talky[$0] }) {
                let piece = String(p.prefix(passageLength))
                if used + piece.count > passageBudget { break }
                passages.append(piece)
                used += piece.count
            }
        }
        return Evidence(tags: tags, names: names, passages: passages)
    }

    public static let system = """
        You prepare the cast list for an audiobook narrated with a different voice for each \
        speaking character. You get the phrases the book uses in its speech tags (as in "said \
        his mother"), the names it repeats, and some passages of its dialogue. List every \
        character who speaks, at most 24, those who speak most first. For each: "name" (as the \
        book calls them), "gender" ("f", "m", or "x" if unknown or a group), "age" ("child", \
        "young", "adult" or "old"), "aliases" (at most 4 exact lower-case phrases from the \
        speech tags and the text that mean only this person, such as "his mother" or "the tall \
        fellow"; never pronouns, and never a way of addressing someone such as "my dear", "sir" \
        or "madam"), and "group" (true for a crowd or committee). Use only what the text \
        supports; leave out anyone who never speaks. Answer with JSON only, no notes: \
        {"characters": [...]}.
        """

    public static func prompt(_ evidence: Evidence, title: String) -> String {
        var out = "Book: \(title)\n\nSpeech-tag phrases (how often):\n"
        for t in evidence.tags { out += "- \(t.phrase) (\(t.count))\n" }
        if !evidence.names.isEmpty { out += "\nNames the text repeats: \(evidence.names.joined(separator: ", "))\n" }
        out += "\nDialogue passages:\n"
        for p in evidence.passages { out += "\(p)\n\n" }
        return out
    }

    /// A way of addressing someone rather than a name for them: "my dear", "sir", "your
    /// honour". Said by everyone to many people, so as a phrase for one person it would give
    /// them other people's lines (the vocative rule reads it as "spoken to them").
    static func isAddress(_ phrase: String) -> Bool {
        let words = phrase.split(separator: " ").map(String.init)
        guard let first = words.first else { return true }
        if ["my", "your", "o", "oh", "dear"].contains(first) { return true }
        return addressWords.contains(phrase)
    }

    static let addressWords: Set<String> = [
        "sir", "madam", "madame", "ma'am", "ma\u{2019}am", "miss", "mister", "dear", "dearest", "darling", "love",
        "honey", "sweetheart", "friend", "child", "boy", "girl", "man", "woman", "gentlemen", "ladies",
        "lady", "lord", "master", "mistress", "everyone", "everybody", "all", "you",
    ]

    /// The people in a reply: the whole `{"characters": [...]}` when it parses, otherwise each
    /// person's object that was finished before the reply was cut off.
    static func items(in reply: String) -> [[String: Any]] {
        let text = ModelReply.stripThinking(reply)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
           let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
           let items = object["characters"] as? [[String: Any]] {
            return items
        }
        guard let re = try? NSRegularExpression(pattern: #"\{[^{}]*\}"#) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let r = Range(m.range, in: text) else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(text[r].utf8))) as? [String: Any]
        }
    }

    /// The model's sheet, kept only where the text agrees with it.
    public static func parse(_ reply: String, document: ImportedDocument) -> DialogueCast.CastSheet {
        let items = items(in: reply)
        guard !items.isEmpty else { return DialogueCast.CastSheet(characters: []) }
        let original = document.paragraphs.joined(separator: "\n")
        let body = original.lowercased()
        func inText(_ phrase: String) -> Bool {
            body.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: phrase) + #"\b"#, options: .regularExpression) != nil
        }
        var seen = Set<String>()
        var characters: [DialogueCast.Character] = []
        for item in items {
            guard characters.count < maxCharacters else { break }
            guard let raw = item["name"] as? String else { continue }
            var name = LayoutTextImporter.collapse(raw)
            guard !name.isEmpty, name.count <= 40, seen.insert(name.lowercased()).inserted else { continue }
            // A name written in lower case (the home model copied "mrs. bennet" from the tag
            // phrases) takes the book's own spelling, which is what the person reads and edits.
            if name == name.lowercased(),
               let r = original.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#,
                                      options: [.regularExpression, .caseInsensitive]) {
                name = String(original[r])
            }
            var aliases: [String] = []
            for a in (item["aliases"] as? [String] ?? []) {
                let alias = LayoutTextImporter.collapse(a.lowercased())
                guard aliases.count < maxAliases, !alias.isEmpty, alias.count <= 40, !DialogueCast.pronouns.contains(alias),
                      !isAddress(alias), alias != name.lowercased(), !aliases.contains(alias), inText(alias) else { continue }
                aliases.append(alias)
            }
            // A character must be in the text by name or by one of the phrases kept.
            guard inText(name.lowercased()) || !aliases.isEmpty else { continue }
            let gender = (item["gender"] as? String).map { $0.lowercased().prefix(1) }.map(String.init)
            let age = (item["age"] as? String)?.lowercased()
            characters.append(DialogueCast.Character(
                name: name,
                gender: ["f", "m", "x"].contains(gender ?? "") ? gender! : "x",
                age: ["child", "young", "adult", "old"].contains(age ?? "") ? age! : "adult",
                aliases: aliases, notes: (item["notes"] as? String).map { String($0.prefix(200)) } ?? "",
                group: (item["group"] as? Bool) ?? false))
        }
        // An alias two characters claim says nothing about either: it goes from both.
        var claims: [String: Int] = [:]
        for c in characters { for a in c.aliases { claims[a, default: 0] += 1 } }
        for i in characters.indices { characters[i].aliases.removeAll { claims[$0, default: 0] > 1 } }
        // Another character's name is that character's, never a phrase for this one: kept, it
        // would give one person's tagged lines to someone else.
        let names = Set(characters.map { $0.name.lowercased() })
        for i in characters.indices { characters[i].aliases.removeAll { names.contains($0) } }
        return DialogueCast.CastSheet(characters: characters)
    }

    /// Evidence → one model call → a checked sheet. Empty when no model answered: the person
    /// can write one, or the book is read by the narrator alone, as it is by default.
    public static func generate(for document: ImportedDocument, complete: VoiceCaster.Complete) async -> (sheet: DialogueCast.CastSheet, source: String?) {
        let ev = evidence(document)
        guard !ev.passages.isEmpty || !ev.tags.isEmpty,
              let reply = try? await complete(system, SecretRedactor.redact(prompt(ev, title: document.title))) else {
            // The app routes this as `ModelTask.castSheet`: excerpts, not chapters.
            return (DialogueCast.CastSheet(characters: []), nil)
        }
        return (parse(reply.text, document: document), reply.source)
    }
}
