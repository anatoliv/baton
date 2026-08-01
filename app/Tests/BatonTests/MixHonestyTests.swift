import XCTest
@testable import Baton

/// Regression tests for the `music_build_mix` silent seed-drop (observed 2026-08-01).
///
/// On a library whose genre tags are junk — every track tagged "Music" or "People &
/// Blogs", as happens with YouTube-sourced collections — `getSongsByGenre` and a
/// natural-language prompt search both return nothing, the candidate pool collapses to
/// starred songs, and `buildMix`'s `filtered.isEmpty ? usable : filtered` fallback
/// quietly serves those instead. The result looked like a confident 94-minute ambient
/// mix and was in fact the user's liked eurodance, twice, in a different order.
///
/// The tool is allowed to fall back. It is not allowed to do so silently.
final class MixHonestyTests: XCTestCase {
    private func pool(
        genre: Int = 0, artist: Int = 0, prompt: Int = 0, liked: Int = 0
    ) -> BatonMCPMixTools.CandidatePool {
        var p = BatonMCPMixTools.CandidatePool()
        p.genreMatches = genre
        p.artistMatches = artist
        p.promptMatches = prompt
        p.likedMatches = liked
        return p
    }

    private func seed(genre: String? = nil, artist: String? = nil) -> MixBuilder.Seed {
        MixBuilder.Seed(artist: artist, genre: genre, keywords: [])
    }

    // MARK: - The reported failure

    func testGenreSeedThatMatchesNothingIsReportedNotSwallowed() {
        let warnings = BatonMCPMixTools.mixWarnings(
            pool: pool(liked: 18),
            seed: seed(genre: "Ambient"),
            prompt: "deep focus ambient"
        )
        XCTAssertTrue(
            warnings.contains { $0.contains("Ambient") },
            "a genre seed matching zero tracks must be reported, not silently dropped"
        )
    }

    func testPoolCollapsedToLikedSongsSaysTheMixIgnoredThePrompt() {
        let p = pool(liked: 18)
        XCTAssertTrue(p.collapsedToLiked)
        let warnings = BatonMCPMixTools.mixWarnings(
            pool: p,
            seed: seed(genre: "Ambient"),
            prompt: "calm instrumental ambient for concentration"
        )
        XCTAssertTrue(
            warnings.contains { $0.contains("does NOT reflect the prompt") },
            "the caller must be told the mix is unrelated to what it asked for"
        )
    }

    // MARK: - Individual signals

    func testUnmatchedSeedArtistIsReported() {
        let warnings = BatonMCPMixTools.mixWarnings(
            pool: pool(prompt: 5), seed: seed(artist: "Nonexistent"), prompt: "x"
        )
        XCTAssertTrue(warnings.contains { $0.contains("Nonexistent") })
    }

    func testPromptMatchingNothingIsReportedEvenWhenTheGenreSeedWorked() {
        let warnings = BatonMCPMixTools.mixWarnings(
            pool: pool(genre: 40, liked: 18),
            seed: seed(genre: "Jazz"),
            prompt: "something mellow for the evening"
        )
        XCTAssertTrue(warnings.contains { $0.contains("matched no track") })
        XCTAssertFalse(
            warnings.contains { $0.contains("Jazz") },
            "a genre seed that DID match must not be warned about"
        )
    }

    // MARK: - Silence when everything worked

    func testHealthyPoolProducesNoWarnings() {
        let warnings = BatonMCPMixTools.mixWarnings(
            pool: pool(genre: 40, prompt: 12, liked: 18),
            seed: seed(genre: "Jazz"),
            prompt: "jazz"
        )
        XCTAssertTrue(warnings.isEmpty, "a fully-honoured request must stay quiet: \(warnings)")
    }

    func testCollapsedToLikedIsFalseWhenAnySpecificSignalContributed() {
        XCTAssertFalse(pool(genre: 1, liked: 18).collapsedToLiked)
        XCTAssertFalse(pool(prompt: 1, liked: 18).collapsedToLiked)
        XCTAssertFalse(pool().collapsedToLiked, "an empty pool is a hard error, not a collapse")
    }

    func testSourceCountsAreEchoedForEverySignal() {
        let counts = pool(genre: 1, artist: 2, prompt: 3, liked: 4).sourceCounts
        XCTAssertEqual(counts["genre"], 1)
        XCTAssertEqual(counts["artist"], 2)
        XCTAssertEqual(counts["prompt"], 3)
        XCTAssertEqual(counts["liked"], 4)
    }
}
