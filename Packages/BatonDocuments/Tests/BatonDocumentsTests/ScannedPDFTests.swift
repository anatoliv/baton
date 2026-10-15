import Foundation
import XCTest
@testable import BatonDocuments
#if canImport(PDFKit) && canImport(Vision) && canImport(CoreText)
import CoreGraphics
import CoreText
import PDFKit
#endif

/// Scanned PDFs (M8.3): a page with no text layer is read by text recognition and laid out
/// with the rest of the document.
///
/// The scans are made here, not checked in: text drawn with Core Text into an image, and the
/// image placed on a PDF page that has no text layer, which is what a scanner produces. OCR
/// is deterministic for a given image, but the assertions still ask only for the words that
/// matter and the shape (page order, paragraphs, warnings), not for exact strings.
final class ScannedPDFTests: XCTestCase {

    // MARK: - Placing recognised lines (portable: runs on Linux too)

    func testRecognizedLinesArePlacedInThePagesOwnSpace() {
        let lines = LayoutTextImporter.placedLines(
            recognized: [.init(text: " Second line ", x: 0.1, y: 0.80, width: 0.5, height: 0.02),
                         .init(text: "First line", x: 0.1, y: 0.85, width: 0.6, height: 0.02),
                         .init(text: "   ", x: 0.1, y: 0.5, width: 0.2, height: 0.02)],
            page: (minX: 10, minY: 20, width: 600, height: 800))
        XCTAssertEqual(lines.map(\.text), ["First line", "Second line"], "top first, blanks dropped")
        XCTAssertEqual(lines[0].minX, 10 + 0.1 * 600, accuracy: 0.001)
        XCTAssertEqual(lines[0].minY, 20 + 0.85 * 800, accuracy: 0.001)
        XCTAssertEqual(lines[0].width, 0.6 * 600, accuracy: 0.001)
    }

    func testPiecesOfOnePrintedLineAreJoinedLeftToRight() {
        let lines = LayoutTextImporter.placedLines(
            recognized: [.init(text: "The Surface", x: 0.2, y: 0.801, width: 0.3, height: 0.03),
                         .init(text: "2", x: 0.1, y: 0.800, width: 0.02, height: 0.03),
                         .init(text: "He went to the surface.", x: 0.1, y: 0.75, width: 0.7, height: 0.02)],
            page: (minX: 0, minY: 0, width: 100, height: 100))
        XCTAssertEqual(lines.map(\.text), ["2 The Surface", "He went to the surface."])
        XCTAssertEqual(lines[0].minX, 10, accuracy: 0.001)
        XCTAssertEqual(lines[0].width, 40, accuracy: 0.001)
    }

    func testAPageIsReadInOverlappingBandsThatEachOwnTheirLines() {
        let bands = LayoutTextImporter.RecognitionBand.bands(pageHeight: 792)
        XCTAssertEqual(bands.count, 4)
        XCTAssertEqual(bands.first?.core.lowerBound, 0)
        XCTAssertEqual(bands.first?.regionMinY, 0, "never below the page")
        XCTAssertEqual(bands.last.map { $0.regionMinY + $0.regionHeight } ?? 0, 1, accuracy: 1e-9, "never above it")
        for (low, high) in zip(bands, bands.dropFirst()) {
            XCTAssertEqual(low.core.upperBound, high.core.lowerBound, accuracy: 1e-9, "cores tile the page")
            XCTAssertGreaterThan(low.regionMinY + low.regionHeight, high.core.lowerBound + 30.0 / 792, "overlap wider than a line")
        }
        // A line at the boundary of the first two bands, read whole by both: exactly one keeps it.
        let boundary = bands[0].core.upperBound
        let owners = bands.compactMap { band -> LayoutTextImporter.RecognizedLine? in
            let y = (boundary - 0.004 - band.regionMinY) / band.regionHeight
            guard y > 0, y < 1 else { return nil }
            return band.place(.init(text: "x", x: 0.1, y: y, width: 0.5, height: 0.012 / band.regionHeight))
        }
        XCTAssertEqual(owners.count, 1)
        XCTAssertEqual(owners.first?.y ?? 0, boundary - 0.004, accuracy: 1e-9, "placed back on the whole page")
        XCTAssertEqual(LayoutTextImporter.RecognitionBand.bands(pageHeight: 150).count, 1, "a short page is one band")
    }

    #if canImport(PDFKit) && canImport(Vision) && canImport(CoreText)

    // MARK: - Through the importer

    func testAScannedPageIsReadAndLaidOutLikeText() throws {
        let document = try importPDF([.scanned(Self.story)])
        let text = allText(document)
        for word in ["armchair", "machine", "music", "electric", "mother", "surface", "islands"] {
            XCTAssertTrue(text.lowercased().contains(word), "\(word) missing from: \(text)")
        }
        // The broken word is re-joined and the three indented paragraphs stay three: the
        // recognised lines went through the same layout and re-flow as a text page.
        XCTAssertTrue(text.lowercased().contains("something"), text)
        XCTAssertEqual(document.chapters.flatMap(\.paragraphs).count, 3, "\(document.chapters.flatMap(\.paragraphs))")
        XCTAssertFalse(document.chapters.flatMap(\.paragraphs).contains { $0.trimmingCharacters(in: .whitespaces) == "7" },
                       "the page number is page furniture, as on a text page")
        XCTAssertEqual(document.warnings.first { $0.kind == .pagesRecognized }?.pages, [1])
        XCTAssertNil(document.warnings.first { $0.kind == .pagesWithoutText })
    }

    func testAMixedPDFKeepsTheTextPageAndAddsTheScannedOneInOrder() throws {
        let document = try importPDF([.text(Self.textPage), .scanned(Self.story)])
        let text = allText(document)
        let typed = try XCTUnwrap(text.range(of: "Vashti sat in her chair"), text)
        let scanned = try XCTUnwrap(text.lowercased().range(of: "armchair"), text)
        XCTAssertLessThan(typed.lowerBound, scanned.lowerBound, "page 1 comes before page 2")
        XCTAssertTrue(text.contains("The quiet room was lit by a lamp that never flickered."),
                      "the text page is read from its text layer, word for word")
        XCTAssertEqual(document.warnings.first { $0.kind == .pagesRecognized }?.pages, [2])
        XCTAssertNil(document.warnings.first { $0.kind == .pagesWithoutText })
    }

    func testAPageRecognitionFindsNothingOnIsStillAPageWithoutText() throws {
        let document = try importPDF([.text(Self.textPage), .scanned([]), .scanned(Self.story)])
        XCTAssertEqual(document.warnings.first { $0.kind == .pagesWithoutText }?.pages, [2])
        XCTAssertEqual(document.warnings.first { $0.kind == .pagesRecognized }?.pages, [3])
        XCTAssertTrue(allText(document).contains("Vashti sat in her chair"))
    }

    func testTheLanguagesAskedForAreTheReadersOwn() {
        let supported = ["en-US", "fr-FR", "de-DE", "zh-Hans"]
        XCTAssertEqual(PageRecognizer.recognitionLanguages(preferred: ["en-GB", "fr-FR", "zh-Hans-CN", "ru-RU"],
                                                           supported: supported),
                       ["en-US", "fr-FR", "zh-Hans"])
        XCTAssertEqual(PageRecognizer.recognitionLanguages(preferred: ["en-US", "en-GB"], supported: supported), ["en-US"])
    }

    /// The real check: pages of the sample book, rasterised and wrapped in a PDF with no text
    /// layer, read back through the importer and compared with the same pages read from their
    /// text layer. Runs when `BATON_DOCS_SAMPLE` points at the Machine Stops PDF. Six pages
    /// keep it to a few seconds; the whole book, measured once on 2026-10-03, gave 294
    /// paragraphs, 3 chapters and 9911 of 9911 words, the same as its text layer.
    func testTheSampleBookScanned() throws {
        guard let path = ProcessInfo.processInfo.environment["BATON_DOCS_SAMPLE"], path.lowercased().hasSuffix(".pdf") else {
            throw XCTSkip("set BATON_DOCS_SAMPLE to the Machine Stops PDF")
        }
        let original = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: path)))
        let pageCount = min(6, original.pageCount)
        let textOnly = PDFDocument()
        for i in 0..<pageCount { textOnly.insert(try XCTUnwrap(original.page(at: i)?.copy() as? PDFPage), at: i) }
        let textData = try XCTUnwrap(textOnly.dataRepresentation())
        // 150 dpi, the commonest scanner setting, and a different resolution from the render
        // recognition uses, so this is not the importer reading back its own image.
        let scanData = Self.rasterised(textOnly, dpi: 150)

        var textWarnings: [ImportWarning] = [], scanWarnings: [ImportWarning] = []
        let fromText = try DocumentImporter.readPDF(data: textData, isWord: nil, warnings: &textWarnings)
        let fromScan = try DocumentImporter.readPDF(data: scanData, isWord: nil, warnings: &scanWarnings)
        let textParagraphs = fromText.chapters.flatMap(\.paragraphs)
        let scanParagraphs = fromScan.chapters.flatMap(\.paragraphs)
        print("SCANNED SAMPLE: \(pageCount) pages; warnings \(scanWarnings.map { "\($0.kind.rawValue) \($0.pages)" })")
        print("SCANNED SAMPLE: title \(fromScan.title ?? "-"), chapters \(fromScan.chapters.map(\.title))")
        for p in scanParagraphs.prefix(4) { print("SCANNED SAMPLE: | \(p.prefix(160))") }
        print("SCANNED SAMPLE: paragraphs \(scanParagraphs.count) scanned vs \(textParagraphs.count) from the text layer")

        let textWords = Self.wordList(textParagraphs.joined(separator: " "))
        let scanWords = Set(Self.wordList(scanParagraphs.joined(separator: " ")))
        let found = textWords.filter(scanWords.contains).count
        let share = Double(found) / Double(max(1, textWords.count))
        print("SCANNED SAMPLE: \(found) of \(textWords.count) words of the text layer found in the scan (\(Int(share * 100))%)")
        XCTAssertEqual(scanWarnings.first { $0.kind == .pagesRecognized }?.pages, Array(1...pageCount))
        // Read a whole page at a time, Vision dropped four lines of page 1 and garbled two more:
        // 98% of the words and 90 paragraphs for 89. Read in bands, 100% and 89. The bar sits
        // between the two, so it fails on lost lines and not on a misread letter.
        XCTAssertGreaterThanOrEqual(share, 0.99)
        XCTAssertEqual(scanParagraphs.count, textParagraphs.count)
    }

    // MARK: - Fixtures

    private static let story: [(String, CGFloat)] = [
        ("Imagine a small room, shaped like the cell of a bee. It is lit", 18),
        ("by neither window nor lamp, and yet it is filled with a soft", 0),
        ("radiance. There is an armchair in the centre, and some-", 0),
        ("thing like music fills the air of the room all day long.", 0),
        ("An electric bell rang. The woman in the armchair touched a", 18),
        ("switch and the music was silent, and she turned to the plate", 0),
        ("that showed the face of her son, far away across the world.", 0),
        ("\u{201C}I want you to come and see me, mother,\u{201D} he said. \u{201C}I have", 18),
        ("been to the surface of the earth, and I have seen the islands", 0),
        ("from above, and I want to tell you what the machine hides.\u{201D}", 0),
    ]

    private static let textPage: [(String, CGFloat)] = [
        ("Vashti sat in her chair and waited for the call to come through.", 18),
        ("The quiet room was lit by a lamp that never flickered.", 0),
        ("She had not left the room for many years, and did not wish to.", 18),
    ]

    private enum Page {
        case text([(String, CGFloat)])
        case scanned([(String, CGFloat)])
    }

    private static let pageBox = CGRect(x: 0, y: 0, width: 612, height: 792)

    private func importPDF(_ pages: [Page]) throws -> ImportedDocument {
        let data = NSMutableData()
        var box = Self.pageBox
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let pdf = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in pages {
            pdf.beginPDFPage(nil)
            switch page {
            case .text(let lines):
                Self.draw(lines, pageNumber: nil, in: pdf)
            case .scanned(let lines):
                let image = try XCTUnwrap(Self.scan(lines))
                pdf.draw(image, in: Self.pageBox)
            }
            pdf.endPDFPage()
        }
        pdf.closePDF()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanned-\(UUID().uuidString).pdf")
        try (data as Data).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DocumentImporter.importFile(at: url)
    }

    /// The lines as a scanner would see them: an image at 200 dpi, black on white, page
    /// number at the foot. Empty lines give a blank page.
    private static func scan(_ lines: [(String, CGFloat)]) -> CGImage? {
        let scale: CGFloat = 200 / 72
        let width = Int(pageBox.width * scale), height = Int(pageBox.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        if !lines.isEmpty { draw(lines, pageNumber: "7", in: context) }
        return context.makeImage()
    }

    /// 12-point Times from a one-inch margin, 16 points apart; the number in each pair is the
    /// line's indent.
    private static func draw(_ lines: [(String, CGFloat)], pageNumber: String?, in context: CGContext) {
        let font = CTFontCreateWithName("Times New Roman" as CFString, 12, nil)
        func line(_ text: String, x: CGFloat, y: CGFloat) {
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        var y = pageBox.height - 90
        for (text, indent) in lines {
            line(text, x: 72 + indent, y: y)
            y -= 16
        }
        if let pageNumber { line(pageNumber, x: pageBox.midX - 3, y: 50) }
    }

    /// Every page of `document` as an image at `dpi`, on a PDF page with no text layer.
    private static func rasterised(_ document: PDFDocument, dpi: CGFloat) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: nil, nil) else { return Data() }
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            var box = page.bounds(for: .mediaBox)
            let scale = dpi / 72
            guard let context = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale),
                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            guard let image = context.makeImage() else { continue }
            let boxData = withUnsafeBytes(of: &box) { Data($0) } as CFData
            pdf.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            pdf.draw(image, in: CGRect(origin: .zero, size: box.size))
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return data as Data
    }

    private static func wordList(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 }
    }

    #endif

    private func allText(_ document: ImportedDocument) -> String {
        document.chapters.map { ([$0.title] + $0.paragraphs).joined(separator: "\n") }.joined(separator: "\n\n")
    }
}

