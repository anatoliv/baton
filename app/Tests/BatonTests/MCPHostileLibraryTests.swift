import XCTest
@testable import Baton

/// Behavioural tests for the MCP surface against a **deliberately hostile library**.
///
/// Five MCP defects surfaced in one day of an agent genuinely using Baton, and all five
/// were invisible to a suite of 500+ tests:
///
///   1. `build_mix` silently dropped the genre seed and served liked songs instead
///   2. a playlist could be written but never read back
///   3. no way to address a track exactly — a query added five unvetted tracks
///   4. `;` and `+` in a query broke or corrupted the request
///   5. `try?` made a server outage indistinguishable from a missing track
///
/// Defect 5 was introduced *by the fix for defect 1* and caught only by a later audit.
///
/// `MCPSchemaSnapshotTests` pins the *shape* of the contract. This file pins the
/// *behaviour*: given a library that breaks every assumption — junk genre tags, unicode
/// titles, semicolons and pluses, duplicate names, a zero-duration file — the tools must
/// still be honest about what they did.
///
/// The library here is modelled on the real one that exposed the bugs: 6,149 YouTube-
/// sourced tracks where every genre is "Music" or "People & Blogs".
final class MCPHostileLibraryTests: XCTestCase {
    // MARK: - The hostile library

    private func song(
        _ id: String, _ title: String, artist: String? = "Unknown",
        duration: Int? = 240, genre: String? = "Music"
    ) -> NavidromeSong {
        NavidromeSong(id: id, title: title, artist: artist, album: "YT Mix",
                      duration: duration, coverArtID: nil)
    }

    /// Every genre is junk, exactly as a YouTube-ripped library actually is.
    private var hostileLibrary: [NavidromeSong] {
        [
            song("t1", "Space Ambient, Psybient, Psychill Mix", duration: 3952),
            song("t2", "best of øneheart ⧸⧸ ambient mix", duration: 2213),
            song("t3", "Melodic Techno & Deep Progressive", duration: 8207),
            song("t4", "rock; roll classics", duration: 300),
            song("t5", "a+b — plus sign in title", duration: 300),
            song("t6", "Adagio for Strings", artist: "Tiësto", duration: 400),
            song("t7", "Adagio for Strings", artist: "William Orbit", duration: 380),
            song("t8", "Adagio for Strings", artist: "Barber", duration: 480),
            song("t9", "zero length file", duration: 0),
            song("t10", "Untitled", artist: nil, duration: nil),
        ]
    }

    // MARK: - Defect 1: a partly-honoured request must say so

    func testGenreSeedThatMatchesNothingIsReportedNotSilentlyDropped() {
        // The real failure: seed_genre "Ambient" matched zero tracks because every genre
        // is "Music", the pool collapsed to starred songs, and the tool returned a
        // confident 94-minute "ambient" mix of vocal eurodance.
        var pool = BatonMCPMixTools.CandidatePool()
        pool.likedMatches = 18   // only starred songs contributed
        let warnings = BatonMCPMixTools.mixWarnings(
            pool: pool,
            seed: MixBuilder.Seed(artist: nil, genre: "Ambient", keywords: []),
            prompt: "calm instrumental ambient for concentration"
        )
        XCTAssertTrue(warnings.contains { $0.contains("Ambient") },
                      "an unmatched genre seed must be reported")
        XCTAssertTrue(warnings.contains { $0.contains("does NOT reflect the prompt") },
                      "the caller must be told the result is unrelated to the request")
    }

    func testAFullyHonouredRequestStaysQuiet() {
        var pool = BatonMCPMixTools.CandidatePool()
        pool.genreMatches = 40
        pool.promptMatches = 12
        pool.likedMatches = 18
        let warnings = BatonMCPMixTools.mixWarnings(
            pool: pool,
            seed: MixBuilder.Seed(artist: nil, genre: "Jazz", keywords: []),
            prompt: "jazz"
        )
        XCTAssertTrue(warnings.isEmpty, "no warning when nothing degraded: \(warnings)")
    }

    // MARK: - Defect 3: a descriptive prompt must not silently match nothing

    func testDescriptivePromptFallsBackToTermsThatCanActuallyMatch() {
        // Subsonic search is metadata-only and AND-ish, so the whole sentence matches
        // nothing. Falling back to distinctive words is what keeps the pool honest.
        let probes = MixBuilder.searchProbes(for: "calm instrumental ambient for concentration")
        XCTAssertEqual(probes.first, "calm instrumental ambient for concentration",
                       "an exact title match deserves first chance")
        XCTAssertGreaterThan(probes.count, 1, "and then individual terms")
        XCTAssertTrue(probes.contains("concentration"))
        XCTAssertFalse(probes.dropFirst().contains("for"), "stopwords are not search terms")
    }

    // MARK: - Defect 4: hostile characters must survive the round trip

    private func queryURL(_ value: String) throws -> String {
        let creds = NavidromeCredentials(
            baseURL: URL(string: "https://example.test")!,
            username: "u", secret: "p", authMode: .tokenSalt
        )
        return try NavidromeClient(credentials: creds)
            .makeURL("search3.view", query: [URLQueryItem(name: "query", value: value)])
            .absoluteString
    }

    func testSemicolonInATitleDoesNotBreakTheRequest() throws {
        // Go's url.ParseQuery rejects a bare ';' outright — the exact error seen in the field.
        let url = try queryURL("rock; roll classics")
        XCTAssertTrue(url.contains("%3B"))
        XCTAssertFalse(url.contains(";"), "no raw semicolon may reach a Go server: \(url)")
    }

    func testPlusInATitleIsNotDecodedAsASpace() throws {
        let url = try queryURL("a+b")
        XCTAssertTrue(url.contains("%2B"), "unescaped + arrives as a space: \(url)")
    }

    func testUnicodeTitleSurvivesEncoding() throws {
        let url = try queryURL("øneheart")
        XCTAssertTrue(url.contains("%C3%B8"), "UTF-8 percent-encoding expected: \(url)")
    }

    func testAmpersandDoesNotSplitTheQueryString() throws {
        let url = try queryURL("Melodic Techno & Deep Progressive")
        XCTAssertTrue(url.contains("%26"))
        XCTAssertEqual(url.components(separatedBy: "query=").count, 2,
                       "the value must not introduce a second query parameter: \(url)")
    }

    // MARK: - Defect 5: an outage is not a missing track

    func testTransportFailureIsNotReportedAsAMissingTrack() {
        XCTAssertFalse(NavidromeError.transport("offline").isNotFound)
        XCTAssertFalse(NavidromeError.unauthorized.isNotFound)
        XCTAssertFalse(NavidromeError.http(status: 500).isNotFound)
    }

    func testGenuinelyAbsentTrackIsReportedAsMissing() {
        XCTAssertTrue(NavidromeError.subsonic(code: 70, message: "not found").isNotFound)
        XCTAssertTrue(NavidromeError.http(status: 404).isNotFound)
    }

    // MARK: - Defect 2/3: ambiguity must be visible, not silently resolved

    func testDuplicateTitlesAreAllDistinctIdsSoTheCallerMustChoose() {
        // "Adagio for Strings" matched three different recordings; a query-based add took
        // all of them. Exact ids exist precisely so the caller can pick one.
        let adagios = hostileLibrary.filter { $0.title == "Adagio for Strings" }
        XCTAssertEqual(adagios.count, 3)
        XCTAssertEqual(Set(adagios.map(\.id)).count, 3, "each must be separately addressable")
    }

    func testStringArrayArgumentAcceptsARealArrayAndABareString() {
        // song_ids: "abc" is a plausible client mistake and must not silently drop.
        XCTAssertEqual(BatonMCPToolCatalog.optionalStringArray(["song_ids": ["a", "b"]], "song_ids"), ["a", "b"])
        XCTAssertEqual(BatonMCPToolCatalog.optionalStringArray(["song_ids": "a"], "song_ids"), ["a"])
        XCTAssertNil(BatonMCPToolCatalog.optionalStringArray(["song_ids": ["", "  "]], "song_ids"),
                     "an all-blank array reads as absent, not as a request to add nothing")
        XCTAssertNil(BatonMCPToolCatalog.optionalStringArray([:], "song_ids"))
    }

    // MARK: - Degenerate data must not crash selection

    func testZeroAndNilDurationTracksAreExcludedFromMixSelection() {
        let chosen = MixBuilder.buildMix(
            candidates: hostileLibrary,
            targetSeconds: 600,
            seed: MixBuilder.Seed(artist: nil, genre: nil, keywords: [])
        )
        XCTAssertFalse(chosen.contains { ($0.duration ?? 0) <= 0 },
                       "a zero-length file can never contribute to a duration target")
    }

    func testMixSelectionTerminatesOnALibraryOfOnlyUnusableTracks() {
        let unusable = [song("z1", "zero", duration: 0), song("z2", "nil", duration: nil)]
        let chosen = MixBuilder.buildMix(
            candidates: unusable, targetSeconds: 600,
            seed: MixBuilder.Seed(artist: nil, genre: nil, keywords: [])
        )
        XCTAssertTrue(chosen.isEmpty, "must return empty rather than loop or crash")
    }
}
