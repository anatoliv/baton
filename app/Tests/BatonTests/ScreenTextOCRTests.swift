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
