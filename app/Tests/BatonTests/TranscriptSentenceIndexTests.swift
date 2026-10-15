import Foundation
import XCTest
@testable import Baton

/// The speaking HUD's transcript index (M3.7, "What breaks at book length", item 6).
///
/// The coordinator and the engine describe the spoken position as UTF-16 `NSRange`s. The index
/// has to answer "which sentence is that" in the same units, or the highlight drifts by one
/// position for every emoji and combining mark before it. It also has to answer quickly: the
/// engine publishes progress every 100 ms, and a reading can be a whole book.
@MainActor
final class TranscriptSentenceIndexTests: XCTestCase {

    // MARK: UTF-16 throughout

    /// Three family emoji are 3 characters but 33 UTF-16 units. A `Character`-counting index
    /// reads chunk 1's UTF-16 location as a character offset far past the first sentence and
    /// highlights a later one.
    func testEmojiBeforeTheSpokenRangeDoesNotMoveTheHighlight() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let chunks = [
            "\(family)\(family)\(family) went to the coast \u{1F44B}\u{1F3FD}.",
            "It rained.",
            "Nobody minded at all, because the sea was warm.",
            "The end.",
        ]
        assertEveryChunkMapsToItsOwnSentence(chunks)
    }

    /// The same drift from combining marks: `e` + U+0301 is one character and two UTF-16 units.
    func testCombiningMarksBeforeTheSpokenRangeDoNotMoveTheHighlight() {
        let acute = "e\u{301}"
        let accented = String(repeating: "Caf\(acute) r\(acute)sum\(acute) ", count: 6)
        let chunks = [
            "\(accented)ended there.",
            "Then a short one.",
            "Another short one here.",
            "Last.",
        ]
        assertEveryChunkMapsToItsOwnSentence(chunks)
    }

    /// The index hands back UTF-16 ranges, so the sentence it names is the sentence on screen.
    func testSentenceRangesAreUTF16RangesIntoTheText() {
        let text = "\u{1F44B}\u{1F3FD} Hi there. Caf\u{65}\u{301} next. Done."
        let index = TranscriptSentenceIndex(text: text)
        let ns = text as NSString
        XCTAssertEqual(index.count, 3)
        XCTAssertEqual(index.utf16Length, ns.length)
        for sentence in index.sentences {
            let slice = ns.substring(with: sentence.range)
            XCTAssertEqual(slice.trimmingCharacters(in: .whitespacesAndNewlines), sentence.text)
        }
    }

    // MARK: Edges

    func testFirstSentence() {
        let index = TranscriptSentenceIndex(text: "One. Two. Three.")
        XCTAssertEqual(index.sentenceIndex(containing: 0), 0)
        XCTAssertEqual(index.sentenceIndex(containing: 2), 0)
    }

    func testLastSentenceIncludingTheEndOfTheText() {
        let text = "One. Two. Three."
        let index = TranscriptSentenceIndex(text: text)
        let length = (text as NSString).length
        XCTAssertEqual(index.sentenceIndex(containing: length - 1), 2)
        // A position at (or past) the end, e.g. progress 1.0, stays on the last sentence.
        XCTAssertEqual(index.sentenceIndex(containing: length), 2)
        XCTAssertEqual(index.sentenceIndex(containing: length + 50), 2)
    }

    /// A chunk starts exactly where the previous sentence's trailing space ends. That position
    /// belongs to the new sentence, not the old one; the position just before it, the space,
    /// still belongs to the old one.
    func testARangeExactlyOnABoundaryBelongsToTheSentenceItStarts() {
        let (document, ranges) = ReadAloudCoordinator.layout(["One.", "Two.", "Three."])
        let index = TranscriptSentenceIndex(text: document)
        XCTAssertEqual(index.count, 3)
        for (i, range) in ranges.enumerated() {
            XCTAssertEqual(index.sentenceIndex(containing: range.location), i, "start of chunk \(i)")
            if i > 0 {
                XCTAssertEqual(index.sentenceIndex(containing: range.location - 1), i - 1, "space before chunk \(i)")
            }
        }
    }

    func testEmptyText() {
        let index = TranscriptSentenceIndex(text: "")
        XCTAssertEqual(index.count, 0)
        XCTAssertEqual(index.utf16Length, 0)
        XCTAssertNil(index.sentenceIndex(containing: 0))
    }

    func testTextWithNoSentencePunctuationIsOneSentence() {
        let index = TranscriptSentenceIndex(text: "just a fragment")
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index.sentenceIndex(containing: 5), 0)
    }

    // MARK: Where the spoken position comes from

    /// A word range from the built-in voice (an `NSRange` from the synthesizer) lands in its own
    /// sentence, with emoji earlier in the summary.
    func testAWordRangeMapsToItsSentenceAfterEmoji() {
        let text = "\u{1F44B}\u{1F3FD}\u{1F44B}\u{1F3FD}\u{1F44B}\u{1F3FD} Hello world. Next one here. Last."
        let index = TranscriptSentenceIndex(text: text)
        XCTAssertEqual(index.count, 3)
        let ns = text as NSString
        for (word, sentence) in [("world.", 0), ("Next", 1), ("here.", 1), ("Last.", 2)] {
            let location = TranscriptSentenceIndex.spokenLocation(
                reading: nil, wordRange: ns.range(of: word), progress: nil, utf16Length: index.utf16Length)
            XCTAssertEqual(index.sentenceIndex(containing: location), sentence, word)
        }
    }

    /// With no word timings, progress through the text is estimated in UTF-16 units, the same
    /// units as the index, so 100 % lands on the last sentence rather than short of it.
    func testProgressEstimateUsesUTF16Length() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let text = String(repeating: family, count: 20) + ". Second. Third."
        let index = TranscriptSentenceIndex(text: text)
        let end = TranscriptSentenceIndex.spokenLocation(
            reading: nil, wordRange: nil, progress: 1, utf16Length: index.utf16Length)
        XCTAssertEqual(index.sentenceIndex(containing: end), 2)
        let middle = TranscriptSentenceIndex.spokenLocation(
            reading: nil, wordRange: nil, progress: 0.5, utf16Length: index.utf16Length)
        XCTAssertEqual(index.sentenceIndex(containing: middle), 0, "half the UTF-16 units are still the emoji")
    }

    /// During a reading the position is the current chunk's start, advanced by playback.
    func testReadingPositionAdvancesWithinTheCurrentChunk() {
        let range = NSRange(location: 40, length: 10)
        XCTAssertEqual(TranscriptSentenceIndex.spokenLocation(
            reading: range, wordRange: nil, progress: nil, utf16Length: 100), 40)
        XCTAssertEqual(TranscriptSentenceIndex.spokenLocation(
            reading: range, wordRange: nil, progress: 0.5, utf16Length: 100), 45)
    }

    // MARK: Book length

    /// A 150,000-character book with emoji: built once, and a lookup costs well under a
    /// millisecond. The bounds are deliberately loose (a Debug build on a busy machine) so this
    /// cannot flake: the point is the order of magnitude, a binary search against a scan.
    func testABookLengthTextBuildsOnceAndLooksUpFast() {
        let sentence = "The machine hums \u{1F916} beneath the caf\u{65}\u{301} where Vashti waits. "
        var text = ""
        while text.count < 150_000 { text += sentence }
        let cache = TranscriptSentenceIndex.Cache()

        let clock = ContinuousClock()
        var index = TranscriptSentenceIndex(text: "")
        let build = clock.measure { index = cache.index(for: text) }
        XCTAssertLessThan(build, .seconds(2), "building the index for 150k characters took \(build)")
        XCTAssertGreaterThan(index.count, 2000)

        // Every evaluation asks again; only the first may build.
        for _ in 0 ..< 50 { index = cache.index(for: text) }
        XCTAssertEqual(cache.builds, 1)

        let lookups = 10_000
        let length = index.utf16Length
        var sink = 0
        let elapsed = clock.measure {
            for i in 0 ..< lookups {
                sink &+= index.sentenceIndex(containing: (i &* 7_919) % length) ?? 0
            }
        }
        XCTAssertGreaterThan(sink, 0)
        let perLookup = elapsed / lookups
        XCTAssertLessThan(perLookup, .microseconds(50), "one lookup took \(perLookup)")

        // And the last position is still right at book length.
        XCTAssertEqual(index.sentenceIndex(containing: length - 1), index.count - 1)
    }

    func testTheCacheRebuildsWhenTheTextChanges() {
        let cache = TranscriptSentenceIndex.Cache()
        XCTAssertEqual(cache.index(for: "One. Two.").count, 2)
        XCTAssertEqual(cache.index(for: "One. Two.").count, 2)
        XCTAssertEqual(cache.builds, 1)
        XCTAssertEqual(cache.index(for: "One. Two. Three.").count, 3)
        XCTAssertEqual(cache.builds, 2)
    }

    // MARK: Helpers

    /// Lays the chunks out exactly as the coordinator does, then checks that the start, the
    /// middle and the last unit of every chunk's UTF-16 range map to that chunk's sentence.
    private func assertEveryChunkMapsToItsOwnSentence(_ chunks: [String],
                                                      file: StaticString = #filePath, line: UInt = #line) {
        let (document, ranges) = ReadAloudCoordinator.layout(chunks)
        let index = TranscriptSentenceIndex(text: document)
        XCTAssertEqual(index.count, chunks.count, "one sentence per chunk", file: file, line: line)
        for (i, range) in ranges.enumerated() {
            for location in [range.location, range.location + range.length / 2, NSMaxRange(range) - 1] {
                XCTAssertEqual(index.sentenceIndex(containing: location), i,
                               "chunk \(i) at UTF-16 \(location)", file: file, line: line)
            }
            if index.sentences.indices.contains(i) {
                XCTAssertEqual(index.sentences[i].text, chunks[i], file: file, line: line)
            }
        }
    }

    // MARK: - What VoiceOver hears (F5)

    func testVoiceOverHearsTheSpokenSentenceNotTheWholeBook() {
        let book = String(repeating: "The Machine hums on. Kuno speaks of the surface. ", count: 2_000)
        let index = TranscriptSentenceIndex(text: book)
        let value = SpeakingPlayerView.voiceOverValue(text: book, index: index, active: 3)
        XCTAssertEqual(value, index.sentences[3].text)
        XCTAssertLessThan(value.count, 100)
    }

    func testIdleLongTextSaysHowItStartsAndHowMuchFollows() {
        let book = String(repeating: "The Machine hums on. ", count: 500)
        let index = TranscriptSentenceIndex(text: book)
        let value = SpeakingPlayerView.voiceOverValue(text: book, index: index, active: nil)
        XCTAssertEqual(value, "The Machine hums on. (and \(index.sentences.count - 1) more sentences)")
    }

    func testAShortSummaryIsStillReadWhole() {
        let summary = "Build finished. Two tests failed in the player."
        let index = TranscriptSentenceIndex(text: summary)
        XCTAssertEqual(SpeakingPlayerView.voiceOverValue(text: summary, index: index, active: nil), summary)
    }
}
