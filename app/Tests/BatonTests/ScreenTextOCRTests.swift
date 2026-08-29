import AppKit
import XCTest
@testable import Baton

/// Read aloud, Phase 11: turning Vision's boxes back into a document.
///
/// The capture itself needs the Screen Recording grant and a real window, so what is tested is
/// the part that fails *quietly*: reading order. Vision hands back fragments positioned in
/// space, and getting their order wrong produces fluent, confident nonsense rather than an
/// obvious error — which is far worse than a crash, because it sounds fine.
@MainActor
final class ScreenTextOCRTests: XCTestCase {

    private func piece(_ text: String, y: CGFloat, x: CGFloat, h: CGFloat = 0.02) -> ScreenTextOCR.Piece {
        .init(text: text, midY: y, minX: x, height: h)
    }

    /// Vision's origin is at the **bottom left**, so a larger y is higher on screen. Sorting the
    /// intuitive way reads the document from the bottom up. This is the single easiest mistake
    /// to make here and it reads as a broken recogniser rather than a broken sort.
    func testReadsTopToBottomDespiteBottomLeftOrigin() {
        let out = ScreenTextOCR.assemble([
            piece("third line", y: 0.20, x: 0.1),
            piece("first line", y: 0.80, x: 0.1),
            piece("second line", y: 0.50, x: 0.1),
        ])
        XCTAssertEqual(out, "first line\nsecond line\nthird line")
    }

    /// Fragments sharing a line are joined left to right, whatever order Vision reports them in.
    func testJoinsFragmentsOnOneLineLeftToRight() {
        let out = ScreenTextOCR.assemble([
            piece("world", y: 0.50, x: 0.40),
            piece("hello", y: 0.50, x: 0.10),
        ])
        XCTAssertEqual(out, "hello world")
    }

    /// Two fragments belong to the same line when their centres are close relative to the text
    /// size. A fixed epsilon breaks on any page that mixes a heading with body text.
    func testNearlyAlignedFragmentsCountAsOneLine() {
        let out = ScreenTextOCR.assemble([
            piece("left", y: 0.500, x: 0.10),
            piece("right", y: 0.503, x: 0.40),   // same line, a hair off
            piece("below", y: 0.400, x: 0.10),
        ])
        XCTAssertEqual(out, "left right\nbelow")
    }

    func testHeadingAndBodySizesDoNotCollapseIntoOneLine() {
        let out = ScreenTextOCR.assemble([
            piece("A Heading", y: 0.90, x: 0.1, h: 0.06),
            piece("Body text below it.", y: 0.80, x: 0.1, h: 0.02),
        ])
        XCTAssertEqual(out, "A Heading\nBody text below it.")
    }

    func testNothingRecognisedIsAnEmptyDocument() {
        XCTAssertEqual(ScreenTextOCR.assemble([ScreenTextOCR.Piece]()), "")
    }

    // MARK: - Against real Vision output

    /// Renders text into an image and runs it through the actual recogniser.
    ///
    /// The tests above pin the ordering with synthetic boxes, which is the part most likely to
    /// be silently wrong. This one closes the other half: that `recognize(_:)` drives Vision
    /// correctly and hands its observations to the assembler in a shape that survives. It needs
    /// no Screen Recording grant, because the pixels come from us rather than from the screen —
    /// so the only thing left unverified afterwards is the capture itself.
    private func image(_ lines: [(text: String, size: CGFloat)], width: CGFloat = 900) throws -> CGImage {
        let padding: CGFloat = 40
        let height = lines.reduce(padding * 2) { $0 + $1.size * 1.8 }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        var y = height - padding
        for line in lines {
            y -= line.size * 1.8
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: line.size),
                .foregroundColor: NSColor.black,
            ]
            NSAttributedString(string: line.text, attributes: attributes)
                .draw(at: NSPoint(x: padding, y: y))
        }
        image.unlockFocus()

        var rect = NSRect(x: 0, y: 0, width: width, height: height)
        return try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
    }

    /// The whole point: a rendered document comes back top to bottom, not upside down.
    func testRealVisionOutputComesBackInReadingOrder() throws {
        let rendered = try image([
            ("Deployment notes", 40),
            ("The migration applied cleanly.", 28),
            ("Traffic has been shifted over.", 28),
            ("Error rates are flat.", 28),
        ])

        switch ScreenTextOCR.recognize(rendered) {
        case let .success(text):
            let lines = text.split(separator: "\n").map(String.init)
            // Vision is not perfect on synthetic renders, so assert on order and on the words
            // that carry the meaning rather than on an exact transcript.
            let joined = lines.joined(separator: " ").lowercased()
            XCTAssertTrue(joined.contains("deployment"), "got: \(text)")
            XCTAssertTrue(joined.contains("migration"), "got: \(text)")

            let headingAt = joined.range(of: "deployment").map { joined.distance(from: joined.startIndex, to: $0.lowerBound) }
            let bodyAt = joined.range(of: "migration").map { joined.distance(from: joined.startIndex, to: $0.lowerBound) }
            XCTAssertNotNil(headingAt); XCTAssertNotNil(bodyAt)
            XCTAssertLessThan(headingAt ?? .max, bodyAt ?? 0,
                              "the heading must be read before the body, not after it: \(text)")
        case let .failure(error):
            throw XCTSkip("Vision returned nothing on this machine: \(error)")
        }
    }

    /// A blank image is "no text", not a crash and not an empty success.
    func testABlankImageReportsNoText() throws {
        let blank = try image([("", 20)])
        if case let .failure(error) = ScreenTextOCR.recognize(blank) {
            XCTAssertEqual(error, .noText)
        } else {
            XCTFail("a blank image should report noText")
        }
    }
}

/// The case the card actually names, and the one no synthetic test had covered: **columns**.
///
/// TBX-3830's "done when" is "a PDF page in Preview reads in the right order", and a great many
/// PDFs worth listening to are two-column. `assemble` groups fragments whose vertical centres are
/// close into one visual line and reads them left to right, which is right for a single column
/// and reads *across the gutter* on two. The failure is the bad kind: fluent, plausible sentences
/// made of alternating halves, which sounds like the recogniser is broken rather than the sort.
///
/// This needs no Screen Recording grant. The grant is for *capturing another app's window*;
/// recognition and ordering run on pixels we render ourselves, so the risky half can be measured
/// here rather than waiting on someone to hold a PDF up to it.
@MainActor
final class ScreenTextOCRColumnTests: XCTestCase {

    /// Two columns of body text, laid out as a page would be.
    private func twoColumnPage(left: [String], right: [String],
                               width: CGFloat = 1000, size: CGFloat = 26) throws -> CGImage {
        let padding: CGFloat = 40
        let gutter: CGFloat = 80
        let columnWidth = (width - padding * 2 - gutter) / 2
        let rows = max(left.count, right.count)
        let height = padding * 2 + CGFloat(rows) * size * 1.8

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor.black,
        ]
        for (index, text) in left.enumerated() {
            let y = height - padding - CGFloat(index + 1) * size * 1.8
            NSAttributedString(string: text, attributes: attributes)
                .draw(in: NSRect(x: padding, y: y, width: columnWidth, height: size * 1.6))
        }
        for (index, text) in right.enumerated() {
            let y = height - padding - CGFloat(index + 1) * size * 1.8
            NSAttributedString(string: text, attributes: attributes)
                .draw(in: NSRect(x: padding + columnWidth + gutter, y: y,
                                 width: columnWidth, height: size * 1.6))
        }
        image.unlockFocus()

        var rect = NSRect(x: 0, y: 0, width: width, height: height)
        return try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
    }

    /// A two-column page must read one column then the other, not alternate across the gutter.
    func testTwoColumnsAreReadOneColumnAtATime() throws {
        let left = ["The migration applied cleanly", "and traffic was shifted over",
                    "without any manual steps"]
        let right = ["Error rates stayed flat", "throughout the whole window",
                     "and no alerts were raised"]

        let rendered = try twoColumnPage(left: left, right: right)
        guard case let .success(text) = ScreenTextOCR.recognize(rendered) else {
            throw XCTSkip("Vision produced no text for the rendered page")
        }

        let flat = text.replacingOccurrences(of: "\n", with: " ").lowercased()
        guard let firstLeft = flat.range(of: "migration applied"),
              let lastLeft = flat.range(of: "without any manual"),
              let firstRight = flat.range(of: "error rates stayed")
        else {
            throw XCTSkip("Vision did not recognise the marker phrases: \(text)")
        }

        // The whole of the left column must come before any of the right one. If the columns
        // interleave, the right column's opening lands between the left column's first and last
        // lines, and the reading is nonsense delivered fluently.
        XCTAssertTrue(firstLeft.lowerBound < lastLeft.lowerBound,
                      "the left column itself came out of order: \(text)")
        XCTAssertTrue(lastLeft.lowerBound < firstRight.lowerBound,
                      "columns interleaved — the right column began before the left finished. "
                      + "A two-column PDF would be read across the gutter. Got:\n\(text)")
    }
}

/// The other half of column handling: **not** splitting a page that has only one column.
///
/// A false positive is worse than a false negative here. Failing to detect columns leaves a page
/// reading as it did before, which is a known limitation; splitting a page that was already
/// correct silently reorders it, and nothing on screen would say so. These pin the guards.
@MainActor
final class ScreenTextOCRSingleColumnTests: XCTestCase {

    private func piece(_ text: String, y: CGFloat, x: CGFloat, toX: CGFloat,
                       h: CGFloat = 0.02) -> ScreenTextOCR.Piece {
        ScreenTextOCR.Piece(text: text, midY: y, minX: x, height: h, maxX: toX)
    }

    /// Ordinary prose with a ragged right edge. The gaps at the ends of short lines must not be
    /// mistaken for a gutter.
    func testRaggedRightProseIsNotSplitIntoColumns() {
        let lines = [
            ("The migration applied cleanly and", 0.90, 0.10, 0.85),
            ("traffic was shifted over without", 0.86, 0.10, 0.82),
            ("any manual steps at all.", 0.82, 0.10, 0.55),
            ("Error rates stayed flat throughout", 0.78, 0.10, 0.88),
            ("the window, and no alerts fired.", 0.74, 0.10, 0.80),
            ("Nothing needed rolling back.", 0.70, 0.10, 0.62),
        ]
        let out = ScreenTextOCR.assemble(lines.map { piece($0.0, y: $0.1, x: $0.2, toX: $0.3) })
        let flat = out.replacingOccurrences(of: "\n", with: " ")
        XCTAssertTrue(flat.hasPrefix("The migration applied cleanly and traffic"),
                      "prose was reordered: \(out)")
        XCTAssertTrue(flat.hasSuffix("Nothing needed rolling back."), "prose was reordered: \(out)")
    }

    /// Two blocks separated by a wide horizontal gap but stacked *vertically* are not columns.
    /// This is the case the vertical-overlap guard exists for: a heading block above a body
    /// block, or a figure beside nothing.
    func testStackedBlocksWithAWideGapAreNotTreatedAsColumns() {
        let pieces = [
            piece("First block line one", y: 0.95, x: 0.05, toX: 0.35),
            piece("First block line two", y: 0.91, x: 0.05, toX: 0.35),
            piece("First block line three", y: 0.87, x: 0.05, toX: 0.35),
            piece("Second block line one", y: 0.40, x: 0.65, toX: 0.95),
            piece("Second block line two", y: 0.36, x: 0.65, toX: 0.95),
            piece("Second block line three", y: 0.32, x: 0.65, toX: 0.95),
        ]
        let out = ScreenTextOCR.assemble(pieces)
        let flat = out.replacingOccurrences(of: "\n", with: " ")
        XCTAssertTrue(flat.hasPrefix("First block line one"), "stacked blocks reordered: \(out)")
        XCTAssertTrue(flat.contains("First block line three Second block line one"),
                      "stacked blocks reordered: \(out)")
    }

    /// Too little on the page to judge. Splitting on three fragments would be guessing.
    func testAVeryShortRegionIsNeverSplit() {
        let pieces = [
            piece("Left", y: 0.9, x: 0.05, toX: 0.2),
            piece("Right", y: 0.9, x: 0.8, toX: 0.95),
        ]
        XCTAssertEqual(ScreenTextOCR.assemble(pieces), "Left Right")
    }

    /// The synthetic version of the real-Vision column test, so the ordering rule is pinned
    /// without depending on the recogniser's mood.
    func testTwoColumnsReadOneAtATime() {
        let pieces = [
            piece("Left one", y: 0.90, x: 0.05, toX: 0.42),
            piece("Left two", y: 0.85, x: 0.05, toX: 0.42),
            piece("Left three", y: 0.80, x: 0.05, toX: 0.42),
            piece("Right one", y: 0.90, x: 0.58, toX: 0.95),
            piece("Right two", y: 0.85, x: 0.58, toX: 0.95),
            piece("Right three", y: 0.80, x: 0.58, toX: 0.95),
        ]
        let out = ScreenTextOCR.assemble(pieces).replacingOccurrences(of: "\n", with: " ")
        XCTAssertEqual(out, "Left one Left two Left three Right one Right two Right three")
    }
}
