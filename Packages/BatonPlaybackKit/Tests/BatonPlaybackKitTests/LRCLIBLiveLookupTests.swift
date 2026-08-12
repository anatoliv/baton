import XCTest
@testable import BatonPlaybackKit

/// The one test that talks to LRCLIB for real.
///
/// Everything else about the lookup is pinned offline, which is right — a gate that needs
/// the internet is a gate that goes red for reasons that have nothing to do with the code.
/// But the bug this fixes was invisible offline: the request shapes were all perfectly
/// well-formed, and the service simply had no record under the name being asked for. Only a
/// live call can tell those apart, so there is a live call, and it is opt-in:
///
/// ```sh
/// BATON_LIVE_LYRICS=1 swift test --filter LRCLIBLive
/// ```
///
/// Skipped otherwise, on the same judgement as the conversation eval: an environment that
/// cannot give a measurement is not a failing measurement.
final class LRCLIBLiveLookupTests: XCTestCase {
    private func requireLiveRun() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BATON_LIVE_LYRICS"] == "1",
                          "Set BATON_LIVE_LYRICS=1 to run the live LRCLIB lookup.")
    }

    /// The reported track, with the tags exactly as the library holds them. This 404s on
    /// `/api/get` — that is the bug — and resolves through the search hop.
    func testTheReportedTrackResolves() async throws {
        try requireLiveRun()
        let lyrics = await LRCLIBLyrics.lyrics(
            title: "Wearing My Shoes (Louis Bailar's radio Chillout)",
            artist: "Aura feat. Dani Senior",
            album: nil,
            durationSeconds: 205
        )
        let found = try XCTUnwrap(lyrics, "the search hop should find what /api/get cannot")
        XCTAssertFalse(found.lines.isEmpty)
    }

    /// The same title at the wrong length is a different recording, and must come back
    /// empty rather than confidently wrong.
    func testAWrongDurationFindsNothingRatherThanTheWrongSheet() async throws {
        try requireLiveRun()
        let lyrics = await LRCLIBLyrics.lyrics(
            title: "Wearing My Shoes (Louis Bailar's radio Chillout)",
            artist: "Aura feat. Dani Senior",
            album: nil,
            durationSeconds: 600
        )
        XCTAssertNil(lyrics)
    }

    /// A track whose tags are clean enough for the exact hop still works — the fallback is
    /// additive, not a replacement.
    func testAnExactMatchStillResolves() async throws {
        try requireLiveRun()
        let lyrics = await LRCLIBLyrics.lyrics(title: "Bohemian Rhapsody", artist: "Queen",
                                               album: nil, durationSeconds: 354)
        XCTAssertNotNil(lyrics)
    }
}
