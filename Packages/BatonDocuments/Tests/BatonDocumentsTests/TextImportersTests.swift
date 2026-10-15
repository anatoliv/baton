import Foundation
import XCTest
@testable import BatonDocuments

final class TextImportersTests: XCTestCase {
    func testGutenbergWrapperIsStrippedAndItsHeaderNamesTheBook() {
        let text = """
        The Project Gutenberg eBook of A Small Room

        This ebook is for the use of anyone anywhere, at no cost and with almost no restrictions.

        Title: A Small Room
        Author: A. N. Author

        *** START OF THE PROJECT GUTENBERG EBOOK A SMALL ROOM ***

        CHAPTER I
        The Cell

        Imagine a small room, shaped like the cell of a bee. It is lit by neither
        window nor lamp.

        It is bright all the same, and very quiet.

        CHAPTER II
        The Bell

        An electric bell rang, and went on ringing for a long while.

        *** END OF THE PROJECT GUTENBERG EBOOK A SMALL ROOM ***

        Section 1. General Terms of Use and Redistributing Project Gutenberg electronic works.
        """
        let r = PlainTextImporter.read(text)
        XCTAssertEqual(r.title, "A Small Room")
        XCTAssertEqual(r.author, "A. N. Author")
        XCTAssertEqual(r.chapters.map(\.title), ["The Cell", "The Bell"])
        XCTAssertEqual(r.chapters[0].paragraphs, [
            "Imagine a small room, shaped like the cell of a bee. It is lit by neither window nor lamp.",
            "It is bright all the same, and very quiet.",
        ])
        let all = r.chapters.flatMap(\.paragraphs).joined()
        XCTAssertFalse(all.contains("Gutenberg"))
        XCTAssertEqual(r.stats.removedPageNumbers, 0)
    }

    func testPlainTextKeepsAFinalNumberLine() {
        // No pages, so no page numbers: a last line of "1984" is text.
        let r = PlainTextImporter.read("Notes\n\nThe year it was published was\n1984")
        XCTAssertTrue(r.chapters.flatMap(\.paragraphs).joined(separator: " ").contains("1984"))
    }

    func testMarkdownSectionsBecomeChaptersAndMarkupGoes() {
        let md = """
        ---
        tags: [notes]
        ---
        # Field Guide

        A short **introduction** with a [link](https://example.com) and `code`.

        ## Birds

        Birds are *mostly* feathered. ![a picture](bird.png)

        - Robins
        - Wrens

        ```swift
        let ignored = true
        ```

        ### Small birds

        Wrens are small.

        ## Insects

        > Insects have six legs.
        """
        let (r, skipped) = MarkdownImporter.read(md, fallbackTitle: "fallback")
        XCTAssertEqual(r.title, "Field Guide")
        XCTAssertEqual(skipped, 1)
        XCTAssertEqual(r.chapters.map(\.title), ["Field Guide", "Birds", "Insects"])
        XCTAssertEqual(r.chapters[0].paragraphs, ["A short introduction with a link and code."])
        XCTAssertEqual(r.chapters[1].paragraphs, ["Birds are mostly feathered.", "Robins", "Wrens", "Small birds.", "Wrens are small."])
        XCTAssertEqual(r.chapters[2].paragraphs, ["Insects have six legs."])
        XCTAssertFalse(r.chapters.flatMap(\.paragraphs).joined().contains("ignored"))
    }

    func testImportFileReadsTextAndMarkdownAndNamesTheSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let txt = dir.appendingPathComponent("a-small_room.txt")
        try "Just one paragraph of prose, with nothing else in the file at all.".write(to: txt, atomically: true, encoding: .utf8)
        let doc = try DocumentImporter.importFile(at: txt)
        XCTAssertEqual(doc.sourceKind, .text)
        XCTAssertEqual(doc.fileName, "a-small_room.txt")
        XCTAssertEqual(doc.sourceSHA256, SHA256Digest.hex(of: try Data(contentsOf: txt)))
        XCTAssertEqual(doc.chapters.count, 1)
        XCTAssertTrue(doc.warnings.contains { $0.kind == .noChapters })

        let md = dir.appendingPathComponent("guide.md")
        try "# Guide\n\n## One\n\nFirst part.\n\n## Two\n\nSecond part.\n".write(to: md, atomically: true, encoding: .utf8)
        let guide = try DocumentImporter.importFile(at: md)
        XCTAssertEqual(guide.title, "Guide")
        XCTAssertEqual(guide.chapters.map(\.title), ["One", "Two"])
        XCTAssertEqual(guide.chapters.map(\.index), [0, 1])
    }

    func testUnsupportedAndEmptyFilesAreRefusedWithAReason() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rtf = dir.appendingPathComponent("book.rtf")
        try Data("{\\rtf1 Hello}".utf8).write(to: rtf)
        XCTAssertThrowsError(try DocumentImporter.importFile(at: rtf)) {
            XCTAssertEqual($0 as? DocumentImporter.Failure, .unsupportedFormat("rtf"))
        }
        // A truncated EPUB is refused with what is wrong, not misread.
        let epub = dir.appendingPathComponent("book.epub")
        try Data([0x50, 0x4B]).write(to: epub)
        XCTAssertThrowsError(try DocumentImporter.importFile(at: epub)) {
            guard case DocumentImporter.Failure.unreadable(let why) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(why.contains("not a zip archive"), why)
        }
        let empty = dir.appendingPathComponent("empty.txt")
        try "   \n\n ".write(to: empty, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try DocumentImporter.importFile(at: empty)) {
            XCTAssertEqual($0 as? DocumentImporter.Failure, .empty)
        }
        XCTAssertThrowsError(try DocumentImporter.importFile(at: dir.appendingPathComponent("x.zip")))
    }

    func testMetadataTitlesThatAreFileNamesAreIgnored() {
        XCTAssertFalse(DocumentImporter.metadataTitleIsUsable("The-Machine-Stops.dvi"))
        XCTAssertFalse(DocumentImporter.metadataTitleIsUsable("Microsoft Word - draft 3.docx"))
        XCTAssertFalse(DocumentImporter.metadataTitleIsUsable("untitled"))
        XCTAssertTrue(DocumentImporter.metadataTitleIsUsable("The Machine Stops"))
        XCTAssertEqual(DocumentImporter.prettyTitle(fromFileName: "the-machine_stops"), "The Machine Stops")
    }
}
