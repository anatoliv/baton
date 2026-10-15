import Foundation

/// How a book's names and invented words are said: proposed by a model, corrected by the
/// person, and sent to Kokoro as its own override markup, `[Kuno](/kˈunO/)`
/// (`specs/document-clippings.md`, *Expansions* 3).
///
/// Only Kokoro reads that markup; any other engine would read the brackets aloud, so the
/// renderer applies the lexicon to Kokoro voices alone. Kokoro's phonemizer (misaki) writes
/// English diphthongs as single capital letters (`O` for the vowel of "go", `A` for "day"),
/// so IPA as a model or a dictionary writes it is converted to that on the way in.
public struct PronunciationLexicon: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var word: String
        /// Kokoro (misaki) phonemes, already converted from IPA.
        public var phonemes: String
        /// "model" when proposed and not yet looked at, "person" once corrected or confirmed.
        public var source: String

        public init(word: String, phonemes: String, source: String) {
            self.word = word
            self.phonemes = phonemes
            self.source = source
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    public var isEmpty: Bool { entries.isEmpty }

    /// Add or replace a word's pronunciation; a person's word replaces a model's.
    public mutating func set(_ word: String, ipa: String, source: String = "person") {
        let phonemes = Self.kokoroPhonemes(fromIPA: ipa)
        guard Self.isValid(phonemes) else { return }
        entries.removeAll { $0.word == word }
        entries.append(Entry(word: word, phonemes: phonemes, source: source))
        entries.sort { $0.word < $1.word }
    }

    /// The text with every whole-word occurrence of an entry marked for Kokoro. Longer words
    /// first, so "Vashti" is not marked inside a "Vashtiland" entry's text. Text that already
    /// holds markup is left alone.
    public func apply(to text: String) -> String {
        guard !entries.isEmpty, !text.contains("](/") else { return text }
        var out = text
        for entry in entries.sorted(by: { $0.word.count > $1.word.count }) {
            let pattern = #"(?<![\p{L}\[])"# + NSRegularExpression.escapedPattern(for: entry.word) + #"(?![\p{L}\]])"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let template = NSRegularExpression.escapedTemplate(for: "[\(entry.word)](/\(entry.phonemes)/)")
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    // MARK: - IPA to Kokoro

    /// Standard IPA → misaki's spelling: diphthongs as one letter, affricates as ligatures,
    /// `r` as `ɹ`, `g` as `ɡ`, slashes and brackets dropped.
    public static func kokoroPhonemes(fromIPA ipa: String) -> String {
        var s = ipa.trimmingCharacters(in: CharacterSet(charactersIn: " /[]"))
        for (from, to) in [("eɪ", "A"), ("aɪ", "I"), ("oʊ", "O"), ("əʊ", "Q"), ("aʊ", "W"), ("ɔɪ", "Y"),
                           ("dʒ", "ʤ"), ("d͡ʒ", "ʤ"), ("tʃ", "ʧ"), ("t͡ʃ", "ʧ"), ("ɝ", "ɜɹ"), ("ɚ", "əɹ"),
                           ("r", "ɹ"), ("g", "ɡ"), ("'", "ˈ"), ("\u{2019}", "ˈ"), (".", "")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        return s.replacingOccurrences(of: " ", with: "")
    }

    /// What Kokoro's vocabulary can hold: IPA letters, misaki's capitals, stress and length.
    static let allowed: Set<Character> = Set("abdefhijklmnopstuvwxzæçðŋɐɑɒɔəɛɜɟɡɣɤɥɨɪɬɮɯɰɲɳɴɸɹɻɽɾʀʁʂʃʈʊʋʌʎʏʒʔʝʤʧθχᵊᵻAIOQWYˈˌː")

    public static func isValid(_ phonemes: String) -> Bool {
        !phonemes.isEmpty && phonemes.count <= 40 && phonemes.allSatisfy { allowed.contains($0) }
    }

    // MARK: - Candidates

    public struct Candidate: Sendable, Equatable {
        public var word: String
        public var count: Int
        /// The first sentence it appears in, for the prompt and for the person.
        public var example: String
    }

    /// Words worth a look: names (capitalised away from the start of a sentence) and, when the
    /// app passes a spell checker, words it does not know. Each must occur at least twice: a
    /// word said once is not worth a person's correction. Most frequent first.
    ///
    /// A capitalised word that the book also uses in lower case is an ordinary word given
    /// weight ("the Machine", "the Committee") or opening a quotation ("You"), not a name: on
    /// the sample that rule took the list from 40 words, half of them "Machine", "You", "World",
    /// to the names and places a voice might stumble on. With a spell checker, a capitalised
    /// word it knows ("Brisbane", "Asia") is left out too.
    public static func candidates(in document: ImportedDocument, isWord: ((String) -> Bool?)? = nil,
                                  limit: Int = 25) -> [Candidate] {
        var lowercase = Set<String>()
        for paragraph in document.paragraphs {
            for word in paragraph.split(whereSeparator: { !$0.isLetter }) where word.first?.isLowercase == true {
                lowercase.insert(String(word))
            }
        }
        var counts: [String: Int] = [:]
        var examples: [String: String] = [:]
        var sentenceStartOnly: [String: Bool] = [:]
        for paragraph in document.paragraphs {
            for sentence in SentenceSplitter.sentences(paragraph) {
                let words = sentence.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "\u{2019}" && $0 != "-" })
                for (i, raw) in words.enumerated() {
                    var word = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "'\u{2019}-"))
                    if word.hasSuffix("'s") || word.hasSuffix("\u{2019}s") { word.removeLast(2) }
                    guard word.count >= 3, let first = word.first else { continue }
                    let isName = first.isUppercase && word.dropFirst().contains(where: \.isLowercase)
                    let unknown = !isName && first.isLowercase && isWord?(word) == false
                    guard isName || unknown, !commonCapitalised.contains(word.lowercased()) else { continue }
                    if isName, lowercase.contains(word.lowercased()) || isWord?(word) == true { continue }
                    counts[word, default: 0] += 1
                    if examples[word] == nil { examples[word] = String(sentence.prefix(120)) }
                    sentenceStartOnly[word] = (sentenceStartOnly[word] ?? true) && i == 0
                }
            }
        }
        var found: [Candidate] = []
        for (word, count) in counts where count >= 2 && sentenceStartOnly[word] == false {
            found.append(Candidate(word: word, count: count, example: examples[word] ?? ""))
        }
        found.sort { a, b in a.count != b.count ? a.count > b.count : a.word < b.word }
        return Array(found.prefix(limit))
    }

    /// Capitalised words that are not names, or are names no voice gets wrong.
    static let commonCapitalised: Set<String> = [
        "the", "and", "but", "mr", "mrs", "miss", "sir", "lady", "lord", "dr", "god", "english", "england", "london",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february",
        "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "chapter", "part", "book", "christmas", "heaven", "france", "french", "america", "american", "europe",
    ]

    // MARK: - The model

    public static let system = """
        You help an audiobook narrator. You get words from a book, each with a sentence it \
        appears in. A text-to-speech voice reads standard English well, so leave out every \
        word it would say correctly. For each word it is likely to get wrong (an unusual name, \
        an invented word, a foreign word), give its pronunciation in IPA as the book means it. \
        Answer with JSON only: {"words": [{"word": "...", "ipa": "..."}]}, or {"words": []}.
        """

    public static func prompt(_ candidates: [Candidate], title: String, language: String?) -> String {
        var out = "Book: \(title)\(language.map { " (language: \($0))" } ?? "")\n\nWords:\n"
        for c in candidates { out += "- \(c.word): \(c.example)\n" }
        return out
    }

    /// The model's proposals, kept only for words that were asked about and phonemes Kokoro
    /// can read. Marked "model" until a person looks.
    public static func parse(_ reply: String, candidates: [Candidate]) -> PronunciationLexicon {
        var lexicon = PronunciationLexicon()
        let asked = Set(candidates.map(\.word))
        let text = ModelReply.stripThinking(reply)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let words = object["words"] as? [[String: Any]] else { return lexicon }
        for item in words {
            guard let word = item["word"] as? String, asked.contains(word), let ipa = item["ipa"] as? String else { continue }
            lexicon.set(word, ipa: ipa, source: "model")
        }
        return lexicon
    }

    /// Candidates → one model call → proposals. Empty when no model answered: a book reads
    /// fine without a lexicon, so nothing is in the way.
    public static func propose(for document: ImportedDocument, isWord: ((String) -> Bool?)? = nil,
                               complete: VoiceCaster.Complete) async -> (lexicon: PronunciationLexicon, source: String?) {
        let candidates = candidates(in: document, isWord: isWord)
        guard !candidates.isEmpty,
              let reply = try? await complete(system, prompt(candidates, title: document.title, language: document.language))
        else { return (PronunciationLexicon(), nil) }
        return (parse(reply.text, candidates: candidates), reply.source)
    }
}
