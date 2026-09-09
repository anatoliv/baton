import XCTest
@testable import BatonMobile

/// A palette that could not be extracted is not an answer, and must not be stored as one.
///
/// `ArtworkPaletteLoader` used to write `.neutral` into its cache after any failure, so a
/// single dropped request while a track started left that track's colour-from-artwork
/// backdrop grey for the rest of the session, or until 64 other tracks evicted the entry.
/// Nothing on screen said why, and playing the track again did not fix it. (TBX-5349 / S-F19)
@MainActor
final class PaletteFailureCachingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baton-palette-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    /// One failed fetch followed by a successful one for the same cover: the second wins.
    ///
    /// The cover is a `file://` URL that starts out missing and is then put in place, which
    /// is the same shape as a request that fails and then succeeds without needing a server.
    func testAFailedExtractionIsNotRememberedSoTheNextTryWins() async throws {
        let cover = directory.appendingPathComponent("cover.png")
        let loader = ArtworkPaletteLoader()

        // Nothing at that path yet: the extraction fails.
        loader.update(url: cover)
        await loader.task?.value
        XCTAssertEqual(loader.palette, .neutral, "a failed extraction shows the neutral fallback")

        // The cover arrives. Same URL, so the only thing that can keep the backdrop grey is
        // the loader having remembered the failure.
        let bundled = try XCTUnwrap(
            Bundle.main.url(forResource: "demo-2-cover", withExtension: "png"),
            "the demo covers must be bundled: this test and the demo library both need them"
        )
        try FileManager.default.copyItem(at: bundled, to: cover)

        loader.update(url: nil)
        loader.update(url: cover)
        await loader.task?.value

        XCTAssertNotEqual(loader.palette, .neutral,
                          "the second, successful fetch must win over the first failure")
    }

    /// The other half: a successful extraction is still remembered, so switching back to a
    /// track is instant rather than re-derived. Removing the file after the first read leaves
    /// the cache as the only thing that can answer.
    func testASuccessfulExtractionIsStillRemembered() async throws {
        let cover = directory.appendingPathComponent("cover.png")
        let bundled = try XCTUnwrap(Bundle.main.url(forResource: "demo-2-cover", withExtension: "png"))
        try FileManager.default.copyItem(at: bundled, to: cover)

        let loader = ArtworkPaletteLoader()
        loader.update(url: cover)
        await loader.task?.value
        let first = loader.palette
        XCTAssertNotEqual(first, .neutral)

        try FileManager.default.removeItem(at: cover)
        loader.update(url: nil)
        loader.update(url: cover)
        await loader.task?.value

        XCTAssertEqual(loader.palette, first, "a real palette is cached, and the file is gone")
    }
}
