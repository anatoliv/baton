import Foundation

/// The speaking HUD's transcript, split into sentences once, with a fast answer to "which
/// sentence is being spoken".
///
/// Everything here is **UTF-16**, because that is what the spoken position is: the coordinator
/// lays a reading out as `NSRange`s (`ReadAloudCoordinator.layout`), and the built-in voice
/// reports words as `NSRange`s. The HUD used to count `Character`s against those offsets, which
/// is the same number only in plain ASCII. Every emoji or combining mark before the spoken range
/// pushed the highlight further ahead of the voice.
///
/// It is built **once per text** (see `Cache`), not on every view evaluation. The engine
/// publishes progress every 100 ms, and a reading can be a 70,000-character book: enumerating
/// the sentences of the whole text ten times a second, and then scanning them linearly for the
/// spoken one, is what the old transcript did.
///
/// `Equatable` is cheap where it matters: two copies of the same build share their arrays, and
/// `Array ==` returns at once for shared storage, so the HUD can tell "same transcript" every
/// 100 ms without comparing a book. Only a changed text pays for a full comparison.
struct TranscriptSentenceIndex: Equatable {
    /// One displayed sentence: its text, trimmed for display, and its range in the full text.
    struct Sentence: Equatable {
        let text: String
        /// UTF-16 range in the full text, including any whitespace that follows the sentence,
        /// so the ranges tile the text and every position belongs to exactly one sentence.
        let range: NSRange
    }

    let sentences: [Sentence]
    /// The text's length in UTF-16 units, the same units as every range in and out.
    let utf16Length: Int
    /// `sentences[i].range.location`, ascending, for the binary search.
    private let starts: [Int]

    init(text: String) {
        let ns = text as NSString
        utf16Length = ns.length
        var found: [Sentence] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.bySentences]) { sub, range, enclosing, _ in
            let piece = (sub ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // A run of bare whitespace is not a sentence to show. Its positions fall to the
            // sentence before it, because lookup takes the last start at or before a position.
            guard !piece.isEmpty else { return }
            found.append(Sentence(text: piece, range: NSUnionRange(range, enclosing)))
        }
        if found.isEmpty, utf16Length > 0 {
            // Nothing the sentence enumerator recognised: show the text as it is, as one block.
            found = [Sentence(text: text, range: NSRange(location: 0, length: utf16Length))]
        }
        sentences = found
        starts = found.map(\.range.location)
    }

    var count: Int { sentences.count }

    /// The index of the sentence containing UTF-16 `location`, or nil for an empty text.
    ///
    /// The last sentence that starts at or before `location`, by binary search. A position
    /// before the first sentence (leading whitespace) maps to the first, and one at or past the
    /// end of the text (progress 1.0) to the last, so the highlight never falls off either end.
    func sentenceIndex(containing location: Int) -> Int? {
        guard !starts.isEmpty else { return nil }
        var low = 0
        var high = starts.count // invariant: starts[..<low] <= location < starts[high...]
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= location { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }

    /// Where the voice is, as a UTF-16 position in the displayed text.
    ///
    /// - reading: the range of the sentence being spoken in a reading. The position advances
    ///   through it with playback, so the highlight moves smoothly rather than a chunk at a
    ///   time. `progress` is progress through that one utterance, not the whole reading.
    /// - wordRange: the built-in voice's current word. Placed by where the word *starts*: its
    ///   end is the start of whatever follows it, which may already be the next sentence.
    /// - progress: server audio for a single summary has no word timings, so the position is
    ///   estimated from progress through the clip, in UTF-16 units like everything else.
    static func spokenLocation(reading: NSRange?, wordRange: NSRange?, progress: Double?,
                               utf16Length: Int) -> Int {
        if let reading {
            let within = Double(reading.length) * (progress ?? 0)
            return reading.location + Int(within)
        }
        if let wordRange { return wordRange.location }
        if let progress { return Int(progress * Double(utf16Length)) }
        return 0
    }

    /// Holds the index for the text currently on screen, and rebuilds it only when that text
    /// changes. A reference type so a SwiftUI view can keep one in `@State` and consult it from
    /// `body` without the lookup itself invalidating anything.
    final class Cache {
        /// How many times an index was actually built: the test hook for "once per text".
        private(set) var builds = 0
        private var text: String?
        private var built = TranscriptSentenceIndex(text: "")

        func index(for text: String) -> TranscriptSentenceIndex {
            // The same reading hands back the same string storage on every evaluation, so this
            // comparison is a pointer check in the common case and a memcmp at worst.
            if text == self.text { return built }
            self.text = text
            built = TranscriptSentenceIndex(text: text)
            builds += 1
            return built
        }
    }
}
