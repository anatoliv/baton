import Foundation

// The book's companions: "Previously…" when a book is resumed (M8.4), and answers to "who is
// Kuno again?" (M8.5). Both see only what the listener has already heard, so neither can give
// the story away; that is a property of what goes into the prompt, not a promise the model is
// asked to keep (`specs/document-clippings.md`, *Expansions* 1 and 2).

/// Where the listener is: a chapter, and how far into it.
public struct BookPosition: Codable, Sendable, Equatable, Comparable {
    /// Zero-based chapter of the `PreparedBook`.
    public var chapter: Int
    /// Segments of that chapter already heard in full.
    public var segment: Int

    public init(chapter: Int, segment: Int) {
        self.chapter = chapter
        self.segment = segment
    }

    /// From the player: a chapter is one clipping, so the app knows the chapter and the share of
    /// its audio played. Segments are found by their share of the chapter's characters, which
    /// is close to their share of its time, and the count is **rounded down**: a sentence half
    /// heard is not yet heard.
    public init(chapter: Int, fractionHeard: Double, in book: PreparedBook) {
        self.chapter = max(0, min(chapter, book.chapters.count - 1))
        guard book.chapters.indices.contains(self.chapter) else { self.segment = 0; return }
        let segments = book.chapters[self.chapter].segments
        let total = segments.reduce(0) { $0 + $1.text.count }
        let heard = Double(total) * max(0, min(1, fractionHeard))
        var running = 0
        var count = 0
        for s in segments {
            running += s.text.count
            if Double(running) <= heard + 0.5 { count += 1 } else { break }
        }
        self.segment = count
    }

    public static func < (a: BookPosition, b: BookPosition) -> Bool {
        (a.chapter, a.segment) < (b.chapter, b.segment)
    }
}

/// The part of a book the listener has heard, as passages a model can be shown.
public struct HeardText: Sendable, Equatable {
    public struct Passage: Sendable, Equatable {
        public var chapter: Int
        public var chapterTitle: String
        public var text: String
    }

    public var passages: [Passage]

    /// Paragraphs (the segments of one paragraph joined), chapter by chapter, up to `position`.
    /// Headings are left out; their chapter is named on every passage instead.
    public init(_ book: PreparedBook, upTo position: BookPosition) {
        var passages: [Passage] = []
        for chapter in book.chapters where chapter.index <= position.chapter {
            let limit = chapter.index < position.chapter ? chapter.segments.count : min(position.segment, chapter.segments.count)
            var current: (paragraph: Int, text: String)?
            for segment in chapter.segments.prefix(limit) where segment.kind != .heading {
                if let c = current, c.paragraph == segment.paragraph {
                    current = (c.paragraph, c.text + " " + segment.text)
                } else {
                    if let c = current { passages.append(Passage(chapter: chapter.index, chapterTitle: chapter.title, text: c.text)) }
                    current = (segment.paragraph, segment.text)
                }
            }
            if let c = current { passages.append(Passage(chapter: chapter.index, chapterTitle: chapter.title, text: c.text)) }
        }
        self.passages = passages
    }

    public var characterCount: Int { passages.reduce(0) { $0 + $1.text.count } }

    /// The most recent passages that fit in `budget` characters, in reading order. The newest
    /// passage is cut from its start, not dropped, if it alone is too long.
    public func tail(_ budget: Int) -> [Passage] {
        var out: [Passage] = []
        var used = 0
        for p in passages.reversed() {
            if used + p.text.count > budget {
                if out.isEmpty {
                    var cut = p
                    cut.text = String(p.text.suffix(budget))
                    out.append(cut)
                }
                break
            }
            out.append(p)
            used += p.text.count + 1
        }
        return out.reversed()
    }
}

// MARK: - Recap

/// "Previously…": a short spoken summary when a book is picked up again.
public enum Recap {
    /// The summarizer's window today (`TranscriptSummarizer`): the most recent heard text a
    /// recap is made from.
    public static let window = 6_000
    /// About 30 seconds at the listening rate (`ListeningEstimate`, 175 words a minute).
    public static let maximumWords = 90
    /// Offered when the book was last played more than this long ago...
    public static let idleBeforeOffering: TimeInterval = 24 * 3600
    /// ...and enough of it has been heard for there to be something to recap.
    public static let minimumHeardCharacters = 1_500

    public static func shouldOffer(lastPlayed: Date?, now: Date, heard: HeardText) -> Bool {
        guard let lastPlayed, now.timeIntervalSince(lastPlayed) >= idleBeforeOffering else { return false }
        return heard.characterCount >= minimumHeardCharacters
    }

    public static let system = """
        You write the "Previously" recap a narrator reads when a listener comes back to an \
        audiobook after a break. You get short notes on earlier chapters if there are any, and \
        the most recent text the listener heard, which ends exactly where they stopped. Write at most 80 words of plain spoken English, in the past tense, as \
        flowing sentences: who is involved, what has happened, and where the story was left. \
        Use only what is in the text you were given. Do not guess or hint at what happens next, \
        do not judge the book, and do not address the listener. No headings, lists, quotation \
        marks or markdown. Begin with "Previously".
        """

    /// The user prompt. `earlierNotes` are one-line chapter notes the app may have kept from
    /// `chapterNotePrompt` as chapters finished; they are optional.
    ///
    /// The book's title is left out on purpose. Given *The Machine Stops*, a small model's
    /// first live recap at the end of chapter 1 said things had been so "since the Machine
    /// stopped": not in the text heard, and false at that point in the story. The title is the
    /// one piece of the future every book carries.
    public static func prompt(book: PreparedBook, heard: HeardText, earlierNotes: [Int: String] = [:]) -> String {
        let recent = heard.tail(window)
        let firstRecent = recent.first?.chapter ?? 0
        var out = ""
        let notes = earlierNotes.filter { $0.key < firstRecent }.sorted { $0.key < $1.key }
        if !notes.isEmpty {
            out += "\nEarlier chapters:\n"
            for (index, note) in notes {
                out += "- \(book.chapters.indices.contains(index) ? book.chapters[index].title : "Chapter \(index + 1)"): \(note)\n"
            }
        }
        out += "The most recent text heard, ending where the listener stopped:\n"
        var lastChapter = -1
        for p in recent {
            if p.chapter != lastChapter {
                out += "\n[\(p.chapterTitle)]\n"
                lastChapter = p.chapter
            }
            out += p.text + "\n"
        }
        return out
    }

    /// A finished chapter in one line, kept so a later recap can mention it without sending
    /// the chapter again. Long chapters are sampled at their start, middle and end.
    public static func chapterNotePrompt(_ chapter: PreparedChapter) -> String {
        let text = chapter.segments.filter { $0.kind != .heading }.map(\.text).joined(separator: " ")
        let sample: String
        if text.count <= window {
            sample = text
        } else {
            let third = window / 3
            let middle = text.index(text.startIndex, offsetBy: text.count / 2 - third / 2)
            sample = String(text.prefix(third)) + " [...] " + String(text[middle...].prefix(third)) + " [...] " + String(text.suffix(third))
        }
        return "Summarise this chapter, \"\(chapter.title)\", in one sentence of at most 30 words: who, and what happened. Plain text.\n\n\(sample)"
    }

    /// The reply as it will be spoken: markup and quotation marks gone, cut at a sentence end
    /// within `maximumWords`, and refused (nil) when the model wrote nothing usable.
    public static func clean(_ reply: String) -> String? {
        var text = ModelReply.stripThinking(reply)
        // A heading the model added ("## Recap") is dropped whole; list markers are dropped.
        text = text.replacingOccurrences(of: #"(?m)^\s*#+[^\n]*\n?"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*([-*\u2022]|\d+\.)\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_`#]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"["“”]"#, with: "", options: .regularExpression)
        text = LayoutTextImporter.collapse(text)
        guard text.split(separator: " ").count >= 5 else { return nil }
        let words = text.split(separator: " ")
        if words.count > maximumWords {
            let cut = words.prefix(maximumWords).joined(separator: " ")
            if let end = cut.range(of: #"[.!?](?=[^.!?]*$)"#, options: .regularExpression), cut.distance(from: cut.startIndex, to: end.lowerBound) > 40 {
                text = String(cut[...end.lowerBound])
            } else {
                text = cut + "."
            }
        }
        if !text.lowercased().hasPrefix("previously") { text = "Previously: " + text }
        return text
    }

    /// One call through the app's router (`ModelTask.recap`); nil when no model answered
    /// usefully, so the app simply does not offer a recap.
    public static func make(book: PreparedBook, position: BookPosition, earlierNotes: [Int: String] = [:],
                            complete: VoiceCaster.Complete) async -> (text: String, source: String)? {
        let heard = HeardText(book, upTo: position)
        guard heard.characterCount >= minimumHeardCharacters,
              let reply = try? await complete(system, prompt(book: book, heard: heard, earlierNotes: earlierNotes)),
              let text = clean(reply.text) else { return nil }
        return (text, reply.source)
    }
}

// MARK: - Ask the book

/// What the agent's `document_context` tool returns: the heard passages most relevant to a
/// question, plus the most recent one, never anything past the listener's position.
public enum BookContext {
    public static let defaultBudget = 4_000

    public static let toolDescription = """
        Look up the book the listener is hearing, to answer a question about it ("who is Kuno \
        again?"). Returns passages from the part already heard, most relevant first, and where \
        the listener is. Nothing after their position is included: answer only from these \
        passages, and if they do not hold the answer, say the book has not said yet rather than \
        guessing. Never reveal or hint at later events.
        """

    public struct Result: Sendable, Equatable {
        public var passages: [HeardText.Passage]
        /// "Chapter 2, The Mending Apparatus, about a third of the way in."
        public var position: String

        public init(passages: [HeardText.Passage], position: String) {
            self.passages = passages
            self.position = position
        }
    }

    /// Up to `budget` characters: the passages that share the most of the question's rarer
    /// words (scored like BM25 over the heard text), then the most recent passage, so "what
    /// just happened?" works too. Returned in reading order.
    public static func lookUp(_ question: String, in book: PreparedBook, at position: BookPosition,
                              budget: Int = defaultBudget) -> Result {
        let heard = HeardText(book, upTo: position)
        let passages = heard.passages
        let where_ = describe(position, in: book)
        guard !passages.isEmpty else { return Result(passages: [], position: where_) }

        let terms = Set(words(question).filter { !stopwords.contains($0) })
        let docs = passages.map { words($0.text) }
        let averageLength = Double(docs.reduce(0) { $0 + $1.count }) / Double(docs.count)
        var documentFrequency: [String: Int] = [:]
        for d in docs { for t in Set(d) where terms.contains(t) { documentFrequency[t, default: 0] += 1 } }
        let n = Double(docs.count)
        var scores: [(index: Int, score: Double)] = []
        for (i, d) in docs.enumerated() {
            var score = 0.0
            var tf: [String: Int] = [:]
            for t in d where terms.contains(t) { tf[t, default: 0] += 1 }
            for (t, f) in tf {
                let df = Double(documentFrequency[t] ?? 0)
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                let freq = Double(f)
                score += idf * freq * 2.2 / (freq + 1.2 * (0.25 + 0.75 * Double(d.count) / averageLength))
            }
            if score > 0 { scores.append((i, score)) }
        }
        scores.sort { $0.score > $1.score || ($0.score == $1.score && $0.index > $1.index) }

        var chosen = Set<Int>()
        var used = 0
        let latest = passages.count - 1
        // The latest passage always comes, trimmed to a quarter of the budget.
        chosen.insert(latest)
        used += min(passages[latest].text.count, budget / 4)
        // Where a name in the question first appears (its first three mentions), each with a
        // paragraph either side: books introduce people around their first mentions, and the
        // sentence that says who someone is often does not carry the name. In the sample Kuno
        // is first named in his mother's speech, and "the image of her son" comes three
        // paragraphs later, just before his third mention. Without this, "Who is Kuno?" got
        // his lines alone and a 4B model called him her husband.
        let names = terms.filter { term in passages.contains { $0.text.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: term.prefix(1).uppercased() + term.dropFirst()) + #"\b"#, options: .regularExpression) != nil } }
        for name in names.sorted() {
            let mentions = docs.indices.filter { docs[$0].contains(name) }.prefix(3)
            for i in mentions.flatMap({ [$0, $0 - 1, $0 + 1] }) where passages.indices.contains(i) && !chosen.contains(i) {
                let length = passages[i].text.count
                if used + length > budget { continue }
                chosen.insert(i)
                used += length
            }
        }
        for (i, _) in scores where !chosen.contains(i) {
            let length = passages[i].text.count
            if used + length > budget { continue }
            chosen.insert(i)
            used += length
        }
        let ordered = chosen.sorted().map { i -> HeardText.Passage in
            var p = passages[i]
            if i == latest, p.text.count > budget / 4 { p.text = String(p.text.suffix(budget / 4)) }
            return p
        }
        return Result(passages: ordered, position: where_)
    }

    /// The tool's text, as the agent reads it.
    public static func toolText(_ result: Result) -> String {
        guard !result.passages.isEmpty else { return "The listener has not heard any of the book yet. \(result.position)" }
        var out = "Listener's position: \(result.position) Only text up to there is below.\n"
        var last = -1
        for p in result.passages {
            if p.chapter != last { out += "\n[\(p.chapterTitle)]\n"; last = p.chapter }
            out += p.text + "\n"
        }
        return out
    }

    public static func describe(_ position: BookPosition, in book: PreparedBook) -> String {
        guard book.chapters.indices.contains(position.chapter) else { return "The start of the book." }
        let chapter = book.chapters[position.chapter]
        let share = chapter.segments.isEmpty ? 0 : Double(position.segment) / Double(chapter.segments.count)
        let how: String
        switch share {
        case ..<0.05: how = "at its start"
        case ..<0.2: how = "near its start"
        case ..<0.4: how = "about a third of the way in"
        case ..<0.6: how = "about halfway through"
        case ..<0.8: how = "about two thirds of the way in"
        case ..<0.97: how = "near its end"
        default: how = "at its end"
        }
        return "Chapter \(position.chapter + 1) of \(book.chapters.count), \(chapter.title), \(how)."
    }

    static func words(_ text: String) -> [String] {
        LayoutTextImporter.words(in: text).map { word in
            var w = word
            if w.hasSuffix("'s") || w.hasSuffix("\u{2019}s") { w.removeLast(2) }
            if w.count > 4, w.hasSuffix("s"), !w.hasSuffix("ss") { w.removeLast() }
            return w
        }.filter { $0.count >= 2 }
    }

    static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "by", "for", "with", "from", "as",
        "is", "was", "are", "were", "be", "been", "it", "its", "this", "that", "these", "those", "he", "she",
        "they", "him", "her", "them", "his", "hers", "their", "who", "whom", "what", "which", "when", "where",
        "why", "how", "do", "doe", "did", "does", "again", "about", "there", "here", "has", "have", "had", "me",
        "my", "we", "us", "our", "you", "your", "i", "so", "not", "no", "can", "could", "would", "should",
        "will", "just", "tell", "remind", "book", "story", "chapter", "happen", "happened", "said", "say",
    ]
}

/// Model replies, cleaned the same way wherever they are read.
enum ModelReply {
    /// Reasoning models may wrap their working in `<think>` tags even when asked not to.
    static func stripThinking(_ reply: String) -> String {
        reply.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
