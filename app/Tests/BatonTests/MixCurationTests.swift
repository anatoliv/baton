import XCTest
@testable import Baton

/// Unit tests for the sonic-aware curation core (`MixBuilder.curate` / `tempoSorted` /
/// `spreadArtists`) — F2, the "discovery is heuristic, not sonic" finding (docs/09 #6).
/// Pure, deterministic, no network / no player.
final class MixCurationTests: XCTestCase {
    private func song(_ id: String, artist: String, bpm: Int? = nil, duration: Int = 200) -> NavidromeSong {
        NavidromeSong(id: id, title: "T\(id)", artist: artist, album: "Album", duration: duration, bpm: bpm)
    }

    private func bpms(_ songs: [NavidromeSong]) -> [Int] { songs.map { $0.bpm ?? -1 } }
    private func ids(_ songs: [NavidromeSong]) -> [String] { songs.map(\.id) }

    private func hasAdjacentSameArtist(_ songs: [NavidromeSong]) -> Bool {
        zip(songs, songs.dropFirst()).contains { $0.artist == $1.artist }
    }

    // MARK: - Artist spreading

    func testSpreadAvoidsAdjacentSameArtistWhenPossible() {
        // A owns 3 of 6 (exactly half) — de-clumping is feasible.
        let pool = [
            song("1", artist: "A"), song("2", artist: "A"), song("3", artist: "A"),
            song("4", artist: "B"), song("5", artist: "C"), song("6", artist: "D"),
        ]
        let out = MixBuilder.spreadArtists(pool)
        XCTAssertEqual(out.count, pool.count)
        XCTAssertEqual(Set(ids(out)), Set(ids(pool)), "must not drop or add tracks")
        XCTAssertFalse(hasAdjacentSameArtist(out), "no two adjacent tracks should share an artist: \(out.map { $0.artist ?? "?" })")
    }

    func testSpreadIsIdentityForAllDistinctArtists() {
        let pool = (0 ..< 8).map { song("\($0)", artist: "artist\($0)") }
        XCTAssertEqual(ids(MixBuilder.spreadArtists(pool)), ids(pool), "already-diverse list must be preserved in order")
    }

    func testSpreadPreservesMultisetEvenWhenOneArtistDominates() {
        // A owns 4 of 5 (> half): some adjacency is unavoidable, but nothing may be lost.
        let pool = [
            song("1", artist: "A"), song("2", artist: "A"), song("3", artist: "A"),
            song("4", artist: "A"), song("5", artist: "B"),
        ]
        let out = MixBuilder.spreadArtists(pool)
        XCTAssertEqual(Set(ids(out)), Set(ids(pool)))
        XCTAssertEqual(out.count, pool.count)
    }

    // MARK: - Tempo shaping (uses server-provided bpm)

    // Distinct artists so spreadArtists is a no-op and the tempo order is observable.
    private func tempoPool() -> [NavidromeSong] {
        [
            song("a", artist: "A", bpm: 130),
            song("b", artist: "B", bpm: 60),
            song("c", artist: "C", bpm: 95),
            song("d", artist: "D", bpm: 101),
        ]
    }

    func testEnergeticOrdersAscendingBPM() {
        let out = MixBuilder.curate(tempoPool(), mood: .energetic)
        XCTAssertEqual(bpms(out), [60, 95, 101, 130], "energetic should build up in tempo")
    }

    func testChillOrdersDescendingBPM() {
        let out = MixBuilder.curate(tempoPool(), mood: .chill)
        XCTAssertEqual(bpms(out), [130, 101, 95, 60], "chill should wind down in tempo")
    }

    func testFocusClustersAroundSteadyTempo() {
        let out = MixBuilder.curate(tempoPool(), mood: .focus)
        // Closest-to-100 first: |101-100|=1, |95-100|=5, |130-100|=30, |60-100|=40.
        XCTAssertEqual(bpms(out), [101, 95, 130, 60], "focus should start nearest the steady target")
    }

    func testNeutralLeavesTempoOrderUntouched() {
        let pool = tempoPool()
        XCTAssertEqual(ids(MixBuilder.curate(pool, mood: .neutral)), ids(pool),
                       "neutral only de-clumps artists; with distinct artists it's the identity")
    }

    func testMissingBPMDegradesGracefully() {
        // No bpm anywhere, distinct artists → curate is the identity (nothing to sort/spread).
        let pool = [song("1", artist: "A"), song("2", artist: "B"), song("3", artist: "C")]
        XCTAssertEqual(ids(MixBuilder.curate(pool, mood: .energetic)), ids(pool))
    }

    func testTracksWithoutBPMSinkAfterTempoShapedOnes() {
        let pool = [
            song("hi", artist: "A", bpm: 140),
            song("none", artist: "B", bpm: nil),
            song("lo", artist: "C", bpm: 70),
        ]
        let out = MixBuilder.tempoSorted(pool, mood: .energetic)
        XCTAssertEqual(ids(out), ["lo", "hi", "none"], "bpm-tagged ascending first, untagged appended in order")
    }

    func testCuratePreservesTheSelectedSet() {
        let pool = [
            song("1", artist: "A", bpm: 120), song("2", artist: "A", bpm: 90),
            song("3", artist: "B", bpm: 100), song("4", artist: "C", bpm: 80),
        ]
        let out = MixBuilder.curate(pool, mood: .energetic)
        XCTAssertEqual(Set(ids(out)), Set(ids(pool)), "curation reorders but never changes the selection")
        XCTAssertEqual(out.count, pool.count)
    }

    // MARK: - Mood detection from the prompt

    func testMoodDetection() {
        XCTAssertEqual(MixBuilder.Mood.detect(["upbeat", "focus", "mix"]), .energetic, "first match wins")
        XCTAssertEqual(MixBuilder.Mood.detect(["mellow", "evening"]), .chill)
        XCTAssertEqual(MixBuilder.Mood.detect(["deep", "study"]), .focus)
        XCTAssertEqual(MixBuilder.Mood.detect(["jazz", "saturday"]), .neutral)
        XCTAssertEqual(MixBuilder.Mood.detect([]), .neutral)
    }
}
