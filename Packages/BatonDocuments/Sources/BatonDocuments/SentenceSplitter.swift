import Foundation

/// Sentences and speakable chunks, without `NSString.enumerateSubstrings(.bySentences)`.
///
/// That API is what read-aloud uses on the Mac (`SpeakableText.chunks`), but it is not
/// implemented in Linux Foundation, and the gateway must chunk a book exactly as the device
/// that prepared it would have. So this splitter is rule-based and identical everywhere:
/// split after `.`, `!`, `?` or `…` (with any closing quotes or brackets) when the next word
/// starts a sentence, except after an abbreviation or an initial.
public enum SentenceSplitter {
    /// Never emit a one-word utterance: below this a chunk is merged into its neighbour.
    public static let minChunkCharacters = 40
    /// Never emit a chunk that takes most of a minute to speak (about 25 seconds of audio).
    /// Kokoro's own guidance is 100–200 tokens per request; 320 characters sits inside it.
    public static let maxChunkCharacters = 320

    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "sr", "jr", "prof", "rev", "gen", "col", "capt", "lt", "sgt",
        "mt", "ft", "no", "nos", "vol", "vols", "pp", "p", "ch", "fig", "figs", "ed", "eds", "etc",
        "e.g", "i.e", "cf", "vs", "viz", "al", "approx", "dept", "est", "inc", "ltd", "co", "corp",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]
    private static let closers: Set<Character> = ["\u{201D}", "\u{2019}", "\"", "'", ")", "]", "»"]
    private static let openers: Set<Character> = ["\u{201C}", "\u{2018}", "\"", "'", "(", "[", "«"]

    /// Split prose into sentences. Whitespace inside a sentence is preserved as given.
    public static func sentences(_ text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        var start = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "." || c == "!" || c == "?" || c == "…" else { i += 1; continue }
            // Run of terminal punctuation ("?!", "...") then closing quotes/brackets.
            var end = i + 1
            while end < chars.count, chars[end] == "." || chars[end] == "!" || chars[end] == "?" || chars[end] == "…" { end += 1 }
            while end < chars.count, closers.contains(chars[end]) { end += 1 }
            // A sentence break needs whitespace and then something that starts a sentence.
            guard end < chars.count, chars[end].isWhitespace else { i = end; continue }
            var next = end
            while next < chars.count, chars[next].isWhitespace { next += 1 }
            guard next < chars.count else { i = end; continue }
            let first = chars[next]
            let startsSentence = first.isUppercase || first.isNumber || openers.contains(first)
                || first == Typography.emDash
            if c == ".", startsSentence, isAbbreviationOrInitial(chars, dotAt: i) {
                i = end
                continue
            }
            if startsSentence {
                let sentence = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { out.append(sentence) }
                start = next
            }
            i = end
        }
        let tail = String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    private static func isAbbreviationOrInitial(_ chars: [Character], dotAt index: Int) -> Bool {
        var j = index - 1
        while j >= 0, chars[j].isLetter || chars[j] == "." { j -= 1 }
        let word = String(chars[(j + 1)..<index])
        if word.isEmpty { return false }
        // An initial: "E. M. Forster", "J. Smith". A single capital letter.
        if word.count == 1, word.first?.isUppercase == true { return true }
        return abbreviations.contains(word.lowercased())
    }

    /// Sentences sized for a TTS request: long ones split at clause boundaries (keeping their
    /// punctuation, unlike `SpeakableText.split`, which rejoins clauses with commas), then at
    /// words; short ones merged forward while they fit.
    ///
    /// `target` packs whole sentences together up to that length. Read-aloud speaks one
    /// sentence per request so its highlight can follow; a book has no live highlight, and
    /// one-sentence requests cost twice the round trips and put a seam in the voice's
    /// intonation at every full stop. Measured on the sample: 733 requests averaging 91
    /// characters as sentences, 481 averaging 140 packed to 280 (short lines of dialogue stay
    /// their own paragraphs).
    public static func chunks(_ text: String,
                              min minCharacters: Int = minChunkCharacters,
                              max maxCharacters: Int = maxChunkCharacters,
                              target: Int? = nil) -> [String] {
        let sized = sentences(text).flatMap { split($0, max: maxCharacters) }
        let packTo = Swift.min(target ?? 0, maxCharacters)
        var merged: [String] = []
        for piece in sized {
            if let last = merged.last,
               last.count < minCharacters || last.count + 1 + piece.count <= packTo,
               last.count + 1 + piece.count <= maxCharacters {
                merged[merged.count - 1] = last + " " + piece
            } else {
                merged.append(piece)
            }
        }
        // A short tail merges backwards, so a paragraph never ends on a stray "Yes."
        if merged.count >= 2, let last = merged.last, last.count < minCharacters,
           merged[merged.count - 2].count + 1 + last.count <= maxCharacters {
            merged[merged.count - 2] += " " + last
            merged.removeLast()
        }
        return merged
    }

    static func split(_ sentence: String, max: Int) -> [String] {
        guard sentence.count > max else { return [sentence] }
        // Clause boundaries: after ; : , or a spaced dash, keeping the punctuation with the
        // clause it ends, so the TTS still hears the pause.
        var clauses: [String] = []
        var current = ""
        let chars = Array(sentence)
        var i = 0
        while i < chars.count {
            current.append(chars[i])
            let isBoundary = (chars[i] == ";" || chars[i] == ":" || chars[i] == ",")
                && i + 1 < chars.count && chars[i + 1] == " "
                || (chars[i] == Typography.emDash && i + 1 < chars.count && chars[i + 1] == " ")
            if isBoundary {
                clauses.append(current)
                current = ""
            }
            i += 1
        }
        if !current.isEmpty { clauses.append(current) }

        var pieces: [String] = []
        var piece = ""
        for clause in clauses {
            if !piece.isEmpty, piece.count + clause.count > max {
                pieces.append(piece.trimmingCharacters(in: .whitespaces))
                piece = clause
            } else {
                piece += clause
            }
        }
        if !piece.trimmingCharacters(in: .whitespaces).isEmpty {
            pieces.append(piece.trimmingCharacters(in: .whitespaces))
        }
        return pieces.flatMap { $0.count > max ? hardSplit($0, max: max) : [$0] }
    }

    static func hardSplit(_ text: String, max: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if !current.isEmpty, current.count + 1 + word.count > max {
                pieces.append(current)
                current = String(word)
            } else {
                current = current.isEmpty ? String(word) : current + " " + word
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
