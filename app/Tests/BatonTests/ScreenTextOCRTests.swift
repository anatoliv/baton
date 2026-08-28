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
}
