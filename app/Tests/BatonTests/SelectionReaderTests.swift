import AppKit
import XCTest
@testable import Baton

/// Read aloud, Phase 5: the clipboard fallback's save-and-restore.
///
/// This is the riskiest code in the feature. Phase 0 proved Chrome vends no `AXSelectedText`,
/// so the ⌘C fallback is the hotkey's real path in the most common source app — which means it
/// runs often, on a clipboard holding whatever the user last copied. Getting the restore wrong
/// does not fail a reading; it destroys something of theirs.
///
/// The accessibility read itself cannot be tested here: it needs another application, a real
/// selection, and the grant. Phase 0 measured it directly instead.
@MainActor
final class SelectionReaderTests: XCTestCase {

    /// A private pasteboard, so a test run never touches the developer's own clipboard.
    private var pasteboard: NSPasteboard!

    override func setUp() {
        pasteboard = NSPasteboard(name: .init("baton-read-aloud-test-\(UUID().uuidString)"))
    }
    override func tearDown() { pasteboard.releaseGlobally() }

    func testPlainStringSurvivesTheRoundTrip() {
        pasteboard.clearContents()
        pasteboard.setString("something the user copied earlier", forType: .string)

        let saved = SelectionReader.snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("the selection we grabbed", forType: .string)
        SelectionReader.restore(saved, to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "something the user copied earlier")
    }

    /// The snapshot keeps *every* type, not just the string. Saving only the string would
    /// silently turn a copied image into nothing — a far worse outcome than failing to read a
    /// selection, and one the user would not connect to having pressed a hotkey.
    func testEveryTypeOnTheItemSurvives() throws {
        // Built directly from a bitmap rep: an `NSImage` with no representations has no TIFF
        // data at all, which makes the fixture nil rather than the behaviour wrong.
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("caption text", forType: .string)
        item.setData(png, forType: .png)
        pasteboard.writeObjects([item])

        let saved = SelectionReader.snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("clobbered", forType: .string)
        SelectionReader.restore(saved, to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "caption text")
        XCTAssertEqual(pasteboard.data(forType: .png), png, "a copied image must survive the fallback")
    }

    /// An empty clipboard must come back empty rather than holding what we copied — otherwise
    /// the fallback quietly leaves the selection behind on a clipboard that had nothing in it.
    func testAnEmptyClipboardIsRestoredEmpty() {
        pasteboard.clearContents()
        let saved = SelectionReader.snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("the selection we grabbed", forType: .string)
        SelectionReader.restore(saved, to: pasteboard)

        XCTAssertNil(pasteboard.string(forType: .string))
    }

    /// A copy that never lands must leave the pasteboard exactly as it was. The fallback put the
    /// saved contents back regardless, which rewrote a clipboard nothing had touched: it bumped
    /// the change count (so a password manager's clear-after-a-minute saw "the user copied
    /// something else" and stood down) and replaced promised types with plain data
    ///
    func testACopyThatNeverLandsLeavesThePasteboardUntouched() {
        pasteboard.clearContents()
        pasteboard.setString("a password the manager will clear", forType: .string)
        let before = pasteboard.changeCount

        let copied = SelectionReader.clipboardSelection(pasteboard: pasteboard, copy: {})

        XCTAssertNil(copied)
        XCTAssertEqual(pasteboard.changeCount, before, "the pasteboard was rewritten though nothing was copied")
        XCTAssertEqual(pasteboard.string(forType: .string), "a password the manager will clear")
    }

    /// A copy that lands is read and the earlier contents go back.
    func testACopyThatLandsIsReadAndTheEarlierContentsRestored() {
        pasteboard.clearContents()
        pasteboard.setString("something copied earlier", forType: .string)

        let board: NSPasteboard = pasteboard
        let copied = SelectionReader.clipboardSelection(pasteboard: board) {
            board.clearContents()
            board.setString("the selected words", forType: .string)
        }

        XCTAssertEqual(copied, "the selected words")
        XCTAssertEqual(pasteboard.string(forType: .string), "something copied earlier")
    }
}
