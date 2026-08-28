import XCTest
@testable import Baton

/// The `read_aloud` MCP tool: an agent hands over text it already extracted.
///
/// What these pin is that the tool is a **door into the existing pipeline**, not a pipeline of
/// its own. Every assertion is about what reached `ScreenTextReader` — because the moment this
/// path starts constructing its own capture, or defaulting the profile differently, an agent's
/// terminal output starts being read with its escape codes pronounced while a selection of the
/// same text is read cleanly.
@MainActor
final class ReadAloudMCPToolTests: XCTestCase {

    private var captured: [ScreenTextReader.Capture] = []

    override func setUp() {
        captured = []
        ScreenTextReader.shared.onCapture = { [weak self] in self?.captured.append($0) }
    }

    override func tearDown() {
        ScreenTextReader.shared.onCapture = nil
    }

    // MARK: - What reaches the reading pipeline

    func testTextReachesTheCapturePathWithItsSourceAndKind() throws {
        _ = try BatonMCPReadTools.run([
            "text": "The article body, long enough to be worth listening to.",
            "source": "arstechnica.com",
            "kind": "browser",
        ])

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.profile, .browser)
        XCTAssertEqual(captured.first?.sourceName, "arstechnica.com")
        XCTAssertEqual(captured.first?.gist, false)
    }

    /// The default is the conservative one. A caller that says nothing about where the text came
    /// from should not have it treated as terminal output (which drops everything before the last
    /// prompt) or as a web page (which drops navigation-shaped lines).
    func testKindDefaultsToGeneric() throws {
        _ = try BatonMCPReadTools.run(["text": "Some prose with no stated origin at all."])
        XCTAssertEqual(captured.first?.profile, .generic)
        XCTAssertNil(captured.first?.sourceName)
    }

    func testGistIsPassedThrough() throws {
        _ = try BatonMCPReadTools.run(["text": "A long article to summarize.", "gist": true])
        XCTAssertEqual(captured.first?.gist, true)
    }

    /// A blank `source` must arrive as "unknown" rather than as an empty name, which would show
    /// as a reading from "" and, with per-app voices on, resolve a voice for nothing.
    func testBlankSourceIsTreatedAsUnknown() throws {
        _ = try BatonMCPReadTools.run(["text": "Text with a blank source.", "source": "   "])
        XCTAssertNil(captured.first?.sourceName)
    }

    // MARK: - Refusals

    func testMissingOrEmptyTextIsRefused() {
        for args in [[:], ["text": ""], ["text": "   \n "]] as [[String: Any]] {
            XCTAssertThrowsError(try BatonMCPReadTools.run(args))
        }
        XCTAssertTrue(captured.isEmpty, "a refused call must not start a reading")
    }

    /// An unknown `kind` is refused rather than quietly read as generic prose. Silently
    /// downgrading would mean an agent passing "shell" gets its escape codes pronounced and no
    /// indication of why.
    func testUnknownKindIsRefusedRatherThanDowngraded() {
        XCTAssertThrowsError(try BatonMCPReadTools.run(["text": "ls -la output", "kind": "shell"]))
        XCTAssertTrue(captured.isEmpty)
    }

    func testTextBeyondTheCapIsRefused() {
        let huge = String(repeating: "a", count: BatonMCPReadTools.maxCharacters + 1)
        XCTAssertThrowsError(try BatonMCPReadTools.run(["text": huge]))
        XCTAssertTrue(captured.isEmpty)
    }

    // MARK: - What the agent gets back

    func testTheReplySaysWhatHappened() throws {
        let json = try BatonMCPReadTools.run([
            "text": "Twelve chars", "kind": "terminal", "source": "Ghostty",
        ])
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(parsed["status"] as? String, "reading")
        XCTAssertEqual(parsed["kind"] as? String, "terminal")
        XCTAssertEqual(parsed["source"] as? String, "Ghostty")
        XCTAssertEqual(parsed["chars"] as? Int, 12)
    }

    /// A gist is a different promise from a reading — it needs a model, and it may fail after
    /// this call returns. The status says which one is under way so the agent does not report
    /// "reading it now" for something that is still being summarized.
    func testAGistSaysSoRatherThanClaimingToBeReading() throws {
        let json = try BatonMCPReadTools.run(["text": "A long article.", "gist": true])
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(parsed["status"] as? String, "summarizing")
    }
}
