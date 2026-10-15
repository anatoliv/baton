import Foundation
import XCTest
@testable import BatonDocuments

/// The layout importer against page shapes taken from the sample (`The Machine Stops`, as
/// `pdftotext -layout` prints it), reproduced with invented text: the book is not checked in.
/// The sample's own numbers (24 page numbers, 22 hyphen breaks, 3 chapters, 294 paragraphs)
/// are pinned by `testTheSampleBook`, which runs when `BATON_DOCS_SAMPLE` points at the PDF
/// (read through PDFKit) or at its layout text (`pdftotext -layout book.pdf book.txt`).
final class LayoutTextImporterTests: XCTestCase {

    /// Three pages with the sample's furniture: a title page, a numbered chapter heading, an
    /// indented first line per paragraph, a centred page number at each page's foot, and words
    /// broken across lines.
    private let pages = [
        """
                              A Small Room
                              by A. N. Author
                First published in the Example Review, 1909

        1 The Cell
        Imagine a small room, shaped like the cell of a bee. It is lit by neither window
        nor lamp, and yet it is bright. There is a reading-desk and a chair, and some-
        thing like music fills the air.
            An electric bell rang.
            \u{201C}Who is it?\u{201D} she called. Something in her voice was irritable.

                                                     2
        """,
        """
            \u{201C}It is me, mother,\u{201D} said Tom. \u{201C}I want you to come to the is-
        lands with me.\u{201D}
            She said that the islands were no place for anyone.

                                                     3
        """,
        """
        2 The Surface
        He went to the surface. The well-known stairway was long, and the light at the top
        was a well-
        known kind of grey.

                                                     4
        """,
    ]

    func testTitlePageBylineAndFrontMatter() {
        let r = LayoutTextImporter().extract(pages: pages)
        XCTAssertEqual(r.title, "A Small Room")
        XCTAssertEqual(r.author, "A. N. Author")
        XCTAssertEqual(r.frontMatter, ["First published in the Example Review, 1909"])
    }

    func testNumberedHeadingsBecomeChapters() {
        let r = LayoutTextImporter().extract(pages: pages)
        XCTAssertEqual(r.chapters.map(\.title), ["The Cell", "The Surface"])
        XCTAssertEqual(r.chapters.map(\.label), ["1", "2"])
        XCTAssertEqual(r.chapters[0].spokenHeading, "Chapter 1. The Cell")
        XCTAssertTrue(r.foundHeadings)
    }

    func testPageNumbersAreRemovedAndCounted() {
        let r = LayoutTextImporter().extract(pages: pages)
        XCTAssertEqual(r.stats.removedPageNumbers, 3)
        XCTAssertFalse(r.chapters.flatMap(\.paragraphs).contains { $0.contains(" 3 ") || $0.hasSuffix(" 2") })
    }

    func testIndentationStartsParagraphsAndAParagraphRunsAcrossAPageBreak() {
        let r = LayoutTextImporter().extract(pages: pages)
        XCTAssertEqual(r.stats.paragraphRule, .indentation)
        let first = r.chapters[0].paragraphs
        XCTAssertEqual(first.count, 5)
        XCTAssertTrue(first[0].hasPrefix("Imagine a small room"))
        XCTAssertTrue(first[0].hasSuffix("fills the air."))
        XCTAssertEqual(first[1], "An electric bell rang.")
        // The quote that starts on page 2 is its own paragraph, and its hyphen break joins.
        XCTAssertEqual(first[3], "\u{201C}It is me, mother,\u{201D} said Tom. \u{201C}I want you to come to the islands with me.\u{201D}")
    }

    func testHyphenBreaksJoinByTheDocumentsOwnVocabulary() {
        let r = LayoutTextImporter().extract(pages: pages)
        let text = r.chapters.flatMap(\.paragraphs).joined(separator: "\n")
        XCTAssertTrue(text.contains("and something like music"), text)       // "something" occurs elsewhere
        XCTAssertTrue(text.contains("the islands with me"))                    // "islands" occurs elsewhere
        XCTAssertTrue(text.contains("was a well-known kind of grey"), text)    // "well-known" is printed whole
        XCTAssertTrue(text.contains("reading-desk"))                           // mid-line compounds untouched
        XCTAssertEqual(r.stats.joinedHyphens, 2)
        XCTAssertEqual(r.stats.keptHyphens, 1)
    }

    func testSpellCheckerBreaksAVocabularyTie() {
        // Neither "sunbeam" nor "sun-beam" appears elsewhere. With no oracle the break joins;
        // an oracle that knows both halves but not the joined form keeps the hyphen.
        let page = ["1 One\nIt was a sun-\nbeam in a jar.\n2 Two\nMore text here, quite a lot of it."]
        XCTAssertTrue(LayoutTextImporter().extract(pages: page).chapters[0].paragraphs[0].contains("sunbeam"))
        let oracle = LayoutTextImporter(isWord: { ["sun": true, "beam": true, "sunbeam": false][$0] })
        XCTAssertTrue(oracle.extract(pages: page).chapters[0].paragraphs[0].contains("sun-beam"))
    }

    func testRunningHeadsAreRemovedOnlyWhereTheyRepeat() {
        let openings = ["The road went north", "Rain came at noon", "They slept in a barn",
                        "A dog followed them", "The bridge was out", "At last the town"]
        let pages = openings.enumerated().map { n, opening in
            """
            THE LONG ROAD                                         \(n + 1)
                \(opening), and the page carries on for a while, as text does on any page.
            The \(opening.lowercased()) line ends here, after more words than before.
            """
        }
        let r = LayoutTextImporter().extract(pages: pages)
        XCTAssertEqual(r.stats.removedRunningLines, 6)
        XCTAssertFalse(r.chapters.flatMap(\.paragraphs).contains { $0.contains("LONG ROAD") })
    }

    func testChapterWordsAndRomanNumerals() {
        let pages = ["""
        CHAPTER IV
        The Storm
        The wind rose in the night and did not stop until the morning came again.

        CHAPTER V: The Calm
        In the morning everything was still and the sea lay flat under a white sky.

        VI.
        The Harbour
        They came into harbour at noon, and nobody on the quay said a single word.
        """]
        let r = LayoutTextImporter().extract(pages: pages)
        XCTAssertEqual(r.chapters.map(\.title), ["The Storm", "The Calm", "The Harbour"])
        XCTAssertEqual(r.chapters.map(\.label), ["Chapter IV", "Chapter V", "VI"])
        XCTAssertEqual(r.chapters[0].spokenHeading, "Chapter IV. The Storm")
        XCTAssertEqual(r.chapters[2].spokenHeading, "Chapter VI. The Harbour")
    }

    func testALoneNumberedLineIsTextNotAHeading() {
        // A numbered list item looks like "1 The Air-Ship". One on its own is not a chapter.
        let pages = ["Shopping\n\nYou will need the following, from the shop on the corner.\n\n3 Eggs\n\nBeat them well."]
        let r = LayoutTextImporter().extract(pages: pages)
        XCTAssertFalse(r.foundHeadings)
        XCTAssertEqual(r.chapters.count, 1)
        XCTAssertTrue(r.chapters[0].paragraphs.contains("3 Eggs"))
    }

    func testDeclaredHeadingsFromAnOutlineWin() {
        let pages = ["Preface\nA few words first, before the story starts.\nThe Story Proper\nOnce upon a time there was a room."]
        let r = LayoutTextImporter(declaredHeadings: ["Preface", "The Story Proper"]).extract(pages: pages)
        XCTAssertEqual(r.chapters.map(\.title), ["Preface", "The Story Proper"])
    }

    func testShortLastLineRuleWhenThereIsNoIndentationOrBlankLine() {
        // PDFKit-like: no indentation, no blank lines. A line well short of the measure that
        // ends a sentence closes its paragraph.
        let pages = ["""
        The first paragraph runs across several lines of text that reach the right margin
        and keep going along the line until it finally comes to a stop near the edge, then
        ends here.
        Then the second paragraph begins, and it too runs on to the margin and further
        before it stops short.
        """]
        let r = LayoutTextImporter().extract(pages: pages)
        XCTAssertEqual(r.stats.paragraphRule, .shortLastLine)
        XCTAssertEqual(r.chapters[0].paragraphs.count, 2)
    }

    func testBlankLineParagraphsDoNotBreakAtAPageBoundary() {
        let pages = [
            "Title Line\n\nThe first paragraph starts here and\n\nA second paragraph that is separate.\n\nA third that runs over the",
            "page boundary without stopping.\n\nAnd a fourth.",
        ]
        let r = LayoutTextImporter().extract(pages: pages)
        XCTAssertEqual(r.stats.paragraphRule, .blankLines)
        XCTAssertTrue(r.chapters[0].paragraphs.contains("A third that runs over the page boundary without stopping."),
                      "\(r.chapters[0].paragraphs)")
    }

    func testLigaturesAndInvisibleMarksAreCleaned() {
        let r = LayoutTextImporter().extract(pages: ["Title\n\nThe \u{FB01}eld was \u{FB02}at\u{200B} and wide, and the o\u{FB03}ce was closed."])
        XCTAssertEqual(r.chapters[0].paragraphs, ["The field was flat and wide, and the office was closed."])
    }

    // MARK: - PDF line geometry

    /// A line placed as PDFKit reports it: 6 points a character, 14.4 points a line, the
    /// margin at 90 and a paragraph indent of 17.5, which are the sample's own measurements.
    private func placed(_ text: String, x: Double = 90, line: Int) -> LayoutTextImporter.PlacedLine {
        .init(text: text, minX: x, minY: 700 - Double(line) * 14.4, width: Double(text.count) * 6)
    }

    func testPlacedLinesGetTheIndentationThatMarksParagraphs() {
        // PDFKit's `page.string` drops indentation, and with it most paragraph breaks: on the
        // sample, 60 of 294 paragraphs merged into their neighbours, because a paragraph whose
        // last line reaches the margin has no short last line to give it away.
        let pages = LayoutTextImporter.layoutText(ofPages: [[
            placed("A Small Room", x: 270, line: 0),
            placed("The first paragraph runs right across the page to the margin", line: 2),
            placed("and its last line also reaches the margin, as last lines can do.", line: 3),
            placed("A second paragraph starts here, indented like every other one", x: 107.5, line: 4),
            placed("and runs on.", line: 5),
            placed("12", x: 300, line: 7),
        ]])
        XCTAssertEqual(pages[0].components(separatedBy: "\n"), [
            String(repeating: " ", count: 30) + "A Small Room",
            "",
            "The first paragraph runs right across the page to the margin",
            "and its last line also reaches the margin, as last lines can do.",
            "   A second paragraph starts here, indented like every other one",
            "and runs on.",
            "",
            String(repeating: " ", count: 35) + "12",
        ])
        let r = LayoutTextImporter().extract(pages: pages)
        XCTAssertEqual(r.title, "A Small Room")
        XCTAssertEqual(r.stats.paragraphRule, .indentation)
        XCTAssertEqual(r.stats.removedPageNumbers, 1)
        XCTAssertEqual(r.chapters.flatMap(\.paragraphs), [
            "The first paragraph runs right across the page to the margin and its last line also reaches the margin, as last lines can do.",
            "A second paragraph starts here, indented like every other one and runs on.",
        ])
    }

    func testTheMarginComesFromTheWholeDocumentNotThePage() {
        // A page of short dialogue is all paragraph starts. Measured on that page alone, the
        // indent looks like the margin and every break on it disappears.
        let prose = (0..<10).map { placed("A long line of narration that runs all the way to the margin", line: $0) }
        let dialogue = ["\u{201C}Why not?\u{201D}", "\u{201C}One mustn\u{2019}t.\u{201D}", "\u{201C}Well?\u{201D}"]
            .enumerated().map { placed($1, x: 107.5, line: $0) }
        let pages = LayoutTextImporter.layoutText(ofPages: [prose, dialogue])
        XCTAssertEqual(pages[1].components(separatedBy: "\n").map { $0.prefix { $0 == " " }.count }, [3, 3, 3])
    }

    func testTwoStrayLinesInAShortDocumentDoNotMoveTheMargin() {
        // Under 60 lines, 5% is two lines: two hanging numbers at x = 60 used to become the
        // margin, which indented every body line into a paragraph start.
        var lines = (0..<12).map { placed("A long line of narration that runs all the way to the margin", line: $0) }
        lines.append(placed("1", x: 60, line: 13))
        lines.append(placed("2", x: 60, line: 14))
        let text = LayoutTextImporter.layoutText(ofPages: [lines])[0]
        XCTAssertTrue(text.components(separatedBy: "\n").prefix(12).allSatisfy { $0.hasPrefix("A long line") }, text)
    }

    func testAStrayLineLeftOfTheMarginDoesNotMoveIt() {
        var lines = (0..<30).map { placed("A long line of narration that runs all the way to the margin", line: $0) }
        lines.append(placed("*", x: 60, line: 31))
        let text = LayoutTextImporter.layoutText(ofPages: [lines])[0]
        XCTAssertTrue(text.hasPrefix("A long line"), text)
    }

    func testTheSampleBook() throws {
        guard let path = ProcessInfo.processInfo.environment["BATON_DOCS_SAMPLE"] else {
            throw XCTSkip("set BATON_DOCS_SAMPLE to the Machine Stops PDF, or to its `pdftotext -layout` text")
        }
        let r: LayoutTextImporter.Result
        if path.lowercased().hasSuffix(".pdf") {
            // Through PDFKit, as the app reads it. Phase 0 found PDFKit gives the same 294
            // paragraphs as `pdftotext` only once its line positions are laid out as text.
            #if canImport(PDFKit)
            var warnings: [ImportWarning] = []
            r = try DocumentImporter.readPDF(data: Data(contentsOf: URL(fileURLWithPath: path)), isWord: nil,
                                             warnings: &warnings)
            #else
            throw XCTSkip("PDFKit is not available here; pass the `pdftotext -layout` text instead")
            #endif
        } else {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            r = LayoutTextImporter().extract(pages: text.components(separatedBy: "\u{0C}"))
        }
        XCTAssertEqual(r.title, "The Machine Stops")
        XCTAssertEqual(r.author, "E. M. Forster")
        XCTAssertEqual(r.chapters.map(\.title), ["The Air-Ship", "The Mending Apparatus", "The Homeless"])
        XCTAssertEqual(r.stats.removedPageNumbers, 24)
        XCTAssertEqual(r.stats.joinedHyphens + r.stats.keptHyphens, 22)
        XCTAssertEqual(r.stats.keptHyphens, 0)
        // 294, where the POC counted 296: two lines of verse quoted mid-sentence, centred in
        // the layout, stay inside their sentence here instead of becoming paragraphs of their
        // own, which is what the ear wants.
        XCTAssertEqual(r.chapters.reduce(0) { $0 + $1.paragraphs.count }, 294)
        let all = r.chapters.flatMap(\.paragraphs).joined(separator: " ")
        XCTAssertTrue(all.contains("a generation \u{2018}seraphically free From taint of personality,\u{2019} which will see"))
        XCTAssertTrue(all.contains("communication-system"))
        XCTAssertFalse(all.contains("some- thing"))
    }
}
