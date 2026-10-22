import Foundation
import XCTest
@testable import BatonPlaybackKit

/// The Clippings search index (M8.9).
///
/// Three things are worth proving. The index answers what it is asked (add, change, remove, case,
/// accents, substrings anywhere in a word). It never loses a result the old filter gave: the old
/// filters are kept below, verbatim, as the oracle, and the only differences allowed are the
/// accent and case matches listed by hand. And it is fast where the old filter was not: a keystroke
/// over 300 chapters of 70,000 characters.
final class TextSearchIndexTests: XCTestCase {

    private func index(_ docs: [String: [String]]) -> TextSearchIndex {
        var index = TextSearchIndex()
        index.sync(docs.map { TextSearchIndex.Document(id: $0.key, fields: $0.value) })
        return index
    }

    // MARK: - Correctness

    func testAnEmptyQueryMatchesNothingInTheIndex() {
        let index = index(["a": ["Anything"]])
        XCTAssertEqual(index.search(""), [], "the views show everything for an empty query without asking")
        XCTAssertTrue(TextSearchIndex.matches("Anything", query: ""))
    }

    func testCaseAndAccentsAreIgnoredBothWays() {
        let index = index(["cafe": ["Notes from the Café de Flore"], "plain": ["A cafe on the corner"],
                           "upper": ["THE CAFÉ"], "other": ["Nothing here"]])
        let all: Set = ["cafe", "plain", "upper"]
        XCTAssertEqual(index.search("cafe"), all)
        XCTAssertEqual(index.search("café"), all)
        XCTAssertEqual(index.search("CAFÉ"), all)
        XCTAssertEqual(index.search("Cafe\u{301}"), all, "a decomposed é is the same letter")
        XCTAssertEqual(index.search("naïve"), [])
    }

    func testPrefixAndMidWordSubstrings() {
        let index = index(["n": ["How notarization works"], "s": ["Sparkle appcasts"]])
        XCTAssertEqual(index.search("notar"), ["n"], "prefix")
        XCTAssertEqual(index.search("tarizat"), ["n"], "inside a word")
        XCTAssertEqual(index.search("ation wo"), ["n"], "across a word break")
        XCTAssertEqual(index.search("casts"), ["s"], "suffix")
        XCTAssertEqual(index.search("k"), ["n", "s"], "one character")
        XCTAssertEqual(index.search("pp"), ["s"], "two characters")
        XCTAssertEqual(index.search("works appcasts"), [], "a match never spans two documents or fields")
    }

    func testFieldsMatchSeparately() {
        let index = index(["a": ["Title", "Source"]])
        XCTAssertEqual(index.search("title"), ["a"])
        XCTAssertEqual(index.search("source"), ["a"])
        XCTAssertEqual(index.search("titlesource"), [], "fields are not run together")
    }

    func testAddChangeAndRemove() {
        var index = TextSearchIndex()
        XCTAssertEqual(index.sync([.init(id: "a", fields: ["first words"])]).added, 1)
        XCTAssertEqual(index.search("first"), ["a"])

        // Added beside it.
        var counts = index.sync([.init(id: "a", fields: ["first words"]), .init(id: "b", fields: ["second words"])])
        XCTAssertEqual(counts.added, 1)
        XCTAssertEqual(counts.changed, 0, "an unchanged document is not folded again")
        XCTAssertEqual(index.search("words"), ["a", "b"])

        // Changed: the old words go, the new ones come.
        counts = index.sync([.init(id: "a", fields: ["renamed"]), .init(id: "b", fields: ["second words"])])
        XCTAssertEqual(counts.changed, 1)
        XCTAssertEqual(index.search("first"), [])
        XCTAssertEqual(index.search("renamed"), ["a"])

        // Removed by leaving it out.
        counts = index.sync([.init(id: "a", fields: ["renamed"])])
        XCTAssertEqual(counts.removed, 1)
        XCTAssertEqual(index.search("second"), [])
        XCTAssertFalse(index.contains(id: "b"))

        index.update(.init(id: "c", fields: ["third"]))
        XCTAssertEqual(index.search("third"), ["c"])
        index.remove(id: "c")
        XCTAssertEqual(index.search("third"), [])
        XCTAssertEqual(index.count, 1)
    }

    /// Accented and not, and also text the old filter handled in its own way.
    func testFoldingAwkwardText() {
        XCTAssertEqual(TextSearchIndex.fold("Ünïcödé"), Array("unicode".utf8))
        XCTAssertEqual(TextSearchIndex.fold("ABC xyz"), Array("abc xyz".utf8))
        XCTAssertTrue(TextSearchIndex.matches("İstanbul", query: "istanbul"))
        XCTAssertTrue(TextSearchIndex.matches("ΣΟΦΊΑ", query: "σοφια"))
        XCTAssertTrue(TextSearchIndex.matches("Listening 🎧 now", query: "🎧"))
        XCTAssertFalse(TextSearchIndex.matches("Straße", query: "strasse"), "ß is a letter, not an accent")
        // A query that is only a mark folds to nothing and is answered the old way.
        XCTAssertFalse(TextSearchIndex.matches("plain", query: "\u{301}"))
    }

    // MARK: - Parity with the old filters

    /// Varied clippings: readings, book chapters, accents, curly quotes, emoji, other scripts.
    private let fixture: [ClippingStore.Item] = {
        func item(_ id: String, _ title: String, source: String? = nil, text: String? = nil,
                  book: String? = nil) -> ClippingStore.Item {
            var clipping = ClippingStore.Clipping(id: id, title: title, source: source, createdAt: Date(), text: text)
            if let book {
                clipping.documentID = "doc-\(book)"
                clipping.documentTitle = book
                clipping.chapterIndex = 0
                clipping.chapterTitle = title
            }
            return ClippingStore.Item(clipping: clipping, url: URL(fileURLWithPath: "/tmp/\(id).m4a"))
        }
        return [
            item("r1", "Google Chrome 09.15", source: "Google Chrome",
                 text: "The bit about notarization: Apple checks the signature before Gatekeeper lets it run."),
            item("r2", "Ghostty 10.02", source: "Ghostty", text: "swift test --filter ClippingSearchTests passed."),
            item("r3", "Le café du coin", source: "Safari",
                 text: "Nous avons pris un café crème au comptoir, puis un résumé de la réunion."),
            item("r4", "A cafe in Brooklyn", source: nil, text: "The cafe had naive art on every wall."),
            item("r5", "Naïve questions", source: "Notes", text: "Is a naïve résumé still a resume?"),
            item("r6", "Quotes", source: "Books", text: "“I’m not sure,” she said. It’s the author’s choice…"),
            item("r7", "İstanbul notes", source: "Maps", text: "Istanbul, İzmir and ΣΟΦΊΑ, Σοφία."),
            item("r8", "Emoji", source: nil, text: "Listening 🎧 to the café playlist ☕️."),
            item("r9", "Empty", source: nil, text: nil),
            item("r10", "Decomposed", source: "Cafe\u{301} Society", text: "re\u{301}sume\u{301} with combining marks"),
            item("c1", "Chapter 1", source: "Kokoro", text: "Imagine, if you can, a small room, hexagonal in shape.",
                 book: "The Machine Stops"),
            item("c2", "Chapter 2: The Mending Apparatus", source: "Kokoro",
                 text: "Vashti’s next move was to turn off the isolation switch.", book: "The Machine Stops"),
            item("c3", "Chapter I", source: "Kokoro", text: "It is a truth universally acknowledged.",
                 book: "Pride and Prejudice"),
            item("r11", "Straße", source: "Maps", text: "Die Hauptstraße ist lang. STRASSE in capitals."),
        ]
    }()

    /// The Mac's filter before M8.9, from MusicClippingsView.swift, verbatim.
    private func oldMacFilter(_ items: [ClippingStore.Item], _ filterText: String) -> [ClippingStore.Item] {
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.clipping.title.lowercased().contains(query)
                || ($0.clipping.source?.lowercased().contains(query) ?? false)
                || ($0.clipping.text?.lowercased().contains(query) ?? false)
        }
    }

    /// The iPhone's filter before M8.9, from ClippingsView.swift, verbatim.
    private func oldPhoneFilter(_ items: [ClippingStore.Item], _ filter: String) -> [ClippingStore.Item] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return items }
        return items.filter {
            $0.clipping.title.lowercased().contains(needle)
                || ($0.clipping.documentTitle?.lowercased().contains(needle) ?? false)
                || ($0.clipping.source?.lowercased().contains(needle) ?? false)
                || ($0.clipping.text?.lowercased().contains(needle) ?? false)
        }
    }

    private static let macFields: ClippingSearch.Fields = [.title, .source, .text]
    private static let phoneFields: ClippingSearch.Fields = [.title, .documentTitle, .source, .text]

    /// Every query, and what folding adds to the old result (empty unless listed).
    private let queries: [(String, mac: Set<String>, phone: Set<String>)] = [
        ("the", [], []), ("The", [], []), ("THE", [], []), ("e", [], []), ("x", [], []), ("ch", [], []),
        ("notar", [], []), ("notarization", [], []), ("bit about", [], []), ("about notar", [], []),
        ("  notarization  ", [], []), ("google", [], []), ("CHROME", [], []), ("chapter", [], []),
        ("chapter 2", [], []), ("machine stops", [], []), ("machine", [], []), ("pride", [], []),
        ("café", ["r4"], ["r4"]), ("CAFÉ", ["r4"], ["r4"]), ("cafe\u{301}", ["r4"], ["r4"]),
        ("cafe", ["r3", "r8", "r10"], ["r3", "r8", "r10"]),
        ("naïve", ["r4"], ["r4"]), ("naive", ["r5"], ["r5"]), ("résumé", [], []),
        ("resume", ["r3", "r10"], ["r3", "r10"]), ("istanbul", [], []), ("İstanbul", [], []),
        ("izmir", ["r7"], ["r7"]), ("σοφια", ["r7"], ["r7"]), ("ΣΟΦΊΑ", [], []),
        ("straße", [], []), ("strasse", [], []), ("🎧", [], []), ("☕️", [], []), ("’s", [], []),
        ("“i’m", [], []), ("…", [], []), ("10.02", [], []), ("--filter", [], []), ("zzz", [], []),
        ("a", [], []), ("qu", [], []), ("hexagonal in shape.", [], []), ("vashti’s", [], []),
        ("isolation switch", [], []), ("universally", [], []),
    ]

    func testTheIndexReturnsWhatTheOldFiltersReturnedPlusAccentMatches() {
        for (fields, oracle, platform) in [(Self.macFields, oldMacFilter, "Mac"), (Self.phoneFields, oldPhoneFilter, "iPhone")] {
            var index = TextSearchIndex()
            index.sync(fixture.map { .init(id: $0.id, fields: fields.values(of: $0.clipping)) })
            for (query, macAdded, phoneAdded) in queries {
                let old = Set(oracle(fixture, query).map(\.id))
                let new = index.search(query.trimmingCharacters(in: .whitespaces))
                XCTAssertTrue(new.isSuperset(of: old), "\(platform) \"\(query)\": lost \(old.subtracting(new).sorted())")
                let added = platform == "Mac" ? macAdded : phoneAdded
                XCTAssertEqual(new.subtracting(old), added, "\(platform) \"\(query)\": only accent and case matches are new")
            }
        }
        // The two apps still differ where they always did: only the iPhone looks at the book title.
        XCTAssertEqual(Set(oldPhoneFilter(fixture, "machine stops").map(\.id)), ["c1", "c2"])
        XCTAssertEqual(Set(oldMacFilter(fixture, "machine stops").map(\.id)), [])
    }

    // MARK: - Speed

    /// 300 chapters of 70,000 characters: what a few books add. Half are plain ASCII and half
    /// have the curly quotes and accents real books have, which take the slower folding path.
    func testAKeystrokeOverThreeHundredLongChaptersIsWellUnderAFrame() throws {
        let words = ["the", "and", "of", "machine", "said", "she", "room", "light", "was", "in", "that",
                     "her", "it", "to", "a", "with", "for", "had", "not", "but", "voice", "button",
                     "chair", "speaking", "tube", "lecture", "music", "airship", "earth", "surface"]
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func next() -> Int { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return Int(seed % 1_000_000) }
        var items: [ClippingStore.Item] = []
        for n in 0..<300 {
            var text = ""
            text.reserveCapacity(71_000)
            while text.utf8.count < 70_000 {
                text += words[next() % words.count]
                if n.isMultiple(of: 2), next() % 50 == 0 { text += "’s café" }
                text += next() % 12 == 0 ? ". " : " "
            }
            if n % 100 == 7 { text += " the notarization of Vashti " }
            let clipping = ClippingStore.Clipping(id: "ch\(n)", title: "Chapter \(n + 1)", source: "Kokoro",
                                                  createdAt: Date(), text: text)
            items.append(.init(clipping: clipping, url: URL(fileURLWithPath: "/tmp/ch\(n).m4a")))
        }

        let clock = ContinuousClock()
        var index = TextSearchIndex()
        let build = clock.measure {
            index.sync(items.map { .init(id: $0.id, fields: Self.macFields.values(of: $0.clipping)) })
        }

        // A rare word, a common word, one and two letters, a phrase that is not there although
        // every three letters of it are (the worst case: every chapter is read to the end), and
        // an accented query.
        let queries = ["notarization", "the", "e", "qz", "machine airship tube voice surface earth", "cafe", "zebra"]
        var worst: Duration = .zero
        var lines: [String] = []
        for query in queries {
            var result = Set<String>()
            var samples: [Duration] = []
            for _ in 0..<5 { samples.append(clock.measure { result = index.search(query) }) }
            let median = samples.sorted()[2]
            worst = max(worst, median)
            let old = Set(oldMacFilter(items, query).map(\.id))
            XCTAssertTrue(result.isSuperset(of: old), "\"\(query)\"")
            lines.append("\"\(query)\": \(result.count) matches, \(Self.ms(median))")
        }
        XCTAssertEqual(index.search("notarization"), ["ch7", "ch107", "ch207"])

        var oldResult: [ClippingStore.Item] = []
        let oldRare = clock.measure { oldResult = oldMacFilter(items, "notarization") }
        let oldMiss = clock.measure { oldResult = oldMacFilter(items, "machine airship tube voice surface earth") }
        XCTAssertEqual(Set(oldResult.map(\.id)), [])

        let report = "TIMING 300x70k: build \(Self.ms(build)); new worst median \(Self.ms(worst)); "
            + lines.joined(separator: "; ")
            + "; old filter \"notarization\" \(Self.ms(oldRare)), old near-miss \(Self.ms(oldMiss))"
        print(report)
        XCTAssertLessThan(worst, .milliseconds(16), report)
    }

    private static func ms(_ d: Duration) -> String {
        let c = d.components
        return String(format: "%.2f ms", Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
    }
}

/// The model the views use: it follows the store, debounces typing and keeps up with changes.
@MainActor
final class ClippingSearchTests: XCTestCase {

    private var dir: URL!
    private var store: ClippingStore!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("baton-search-\(UUID().uuidString)")
        store = ClippingStore(directory: dir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func adopt(_ title: String, text: String) throws -> ClippingStore.Item {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).m4a")
        try Data(repeating: 0x41, count: 64).write(to: url)
        return try store.adopt(url, title: title, durationSeconds: 1, text: text)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    func testTypingIsAnsweredForTheLastKeystrokeOnly() async throws {
        let cafe = try adopt("Café notes", text: "an espresso")
        try adopt("Elsewhere", text: "nothing to see")
        let search = ClippingSearch(fields: [.title, .text], debounce: .milliseconds(150))
        search.follow(store)

        let clock = ContinuousClock()
        let start = clock.now
        for prefix in ["c", "ca", "caf", "cafe"] { search.setQuery(prefix) }
        XCTAssertFalse(search.isFiltering, "nothing is answered before the pause")
        XCTAssertEqual(search.filter(store.items).count, 2, "the list stays as it was meanwhile")
        await search.settle()
        let elapsed = clock.now - start
        XCTAssertEqual(search.answeredQuery, "cafe", "the answer is for the final keystroke")
        XCTAssertEqual(search.filter(store.items).map(\.id), [cafe.id])
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(150))
        XCTAssertLessThan(elapsed, .milliseconds(400), "the answer follows the pause, not later")

        search.setQuery("  ")
        XCTAssertFalse(search.isFiltering, "clearing shows everything at once")
        XCTAssertEqual(search.filter(store.items).count, 2)
    }

    func testTheIndexFollowsAddsRenamesAndRemovals() async throws {
        let first = try adopt("Morning reading", text: "the lighthouse keeper")
        let search = ClippingSearch(fields: [.title, .source, .text], debounce: .milliseconds(10))
        search.follow(store)
        search.setQuery("LIGHTHOUSE")
        await search.settle()
        XCTAssertEqual(search.matches, [first.id])

        // Added while the query stands: it appears without typing again.
        let second = try adopt("Evening reading", text: "another lighthouse")
        await waitUntil { search.matches == [first.id, second.id] }

        // Renamed: the new title is searchable, the old one is not.
        store.rename(id: second.id, to: "Phare")
        search.setQuery("phare")
        await waitUntil { search.matches == [second.id] }
        search.setQuery("evening")
        await waitUntil { search.answeredQuery == "evening" && search.matches == [] }

        // Removed: gone from the answer.
        search.setQuery("lighthouse")
        await waitUntil { search.matches == [first.id, second.id] }
        store.remove(id: first.id)
        await waitUntil { search.matches == [second.id] }
    }

    func testABookTitleIsMatchedWithTheSameRules() async throws {
        try adopt("Reading", text: "words")
        let search = ClippingSearch(fields: [.title], debounce: .milliseconds(10))
        search.follow(store)
        XCTAssertTrue(search.matches(title: "Anything"), "everything matches with no query")
        search.setQuery("ecole")
        await search.settle()
        XCTAssertTrue(search.matches(title: "L’École des femmes"))
        XCTAssertFalse(search.matches(title: "Pride and Prejudice"))
    }
}
