import XCTest
@testable import Baton

/// Unit tests for the pure mix-selection core (`MixBuilder`) — no network, no player.
final class MixBuilderTests: XCTestCase {
    // A deterministic pool of 200s tracks (~3:20 each).
    private func songs(_ count: Int, durations: [Int]? = nil, artist: String = "Various") -> [NavidromeSong] {
        (0 ..< count).map { i in
            NavidromeSong(
                id: "s\(i)",
                title: "Track \(i)",
                artist: artist,
                album: "Album",
                duration: durations?[i % (durations!.count)] ?? 200,
                coverArtID: nil
            )
        }
    }

    private func total(_ songs: [NavidromeSong]) -> Int {
        songs.reduce(0) { $0 + ($1.duration ?? 0) }
    }

    // MARK: - Duration targeting

    func testLandsNearTarget() {
        let pool = songs(100, durations: [180, 210, 240, 200, 260])
        let target = 45 * 60 // 2700s
        let mix = MixBuilder.buildMix(candidates: pool, targetSeconds: target, seed: .init())

        // Should land within one average-track-length of the target, and not fall short by
        // more than a track either.
        let t = total(mix)
        XCTAssertGreaterThan(mix.count, 0)
        XCTAssertLessThanOrEqual(abs(t - target), 300, "total \(t) too far from target \(target)")
    }

    func testShortTargetPicksFewTracks() {
        let pool = songs(50)
        let target = 10 * 60 // 600s → ~3 tracks of 200s
        let mix = MixBuilder.buildMix(candidates: pool, targetSeconds: target, seed: .init())
        XCTAssertEqual(mix.count, 3, "10 min / 200s tracks ≈ 3 tracks, got \(mix.count) (\(total(mix))s)")
        XCTAssertLessThanOrEqual(total(mix), target + 200)
    }

    func testDoesNotWildlyOvershoot() {
        let pool = songs(200)
        let target = 30 * 60
        let mix = MixBuilder.buildMix(candidates: pool, targetSeconds: target, seed: .init())
        // Overshoot bounded by roughly one average track.
        XCTAssertLessThanOrEqual(total(mix), target + 240)
    }

    func testTargetSmallerThanAnySongReturnsOne() {
        let pool = songs(5, durations: [200])
        let mix = MixBuilder.buildMix(candidates: pool, targetSeconds: 30, seed: .init())
        XCTAssertEqual(mix.count, 1)
    }

    func testEmptyCandidatesReturnsEmpty() {
        XCTAssertTrue(MixBuilder.buildMix(candidates: [], targetSeconds: 1800, seed: .init()).isEmpty)
    }

    func testSongsWithoutDurationAreIgnored() {
        var pool = songs(3)
        pool.append(NavidromeSong(id: "x", title: "No Dur", artist: "A", album: nil, duration: nil, coverArtID: nil))
        let mix = MixBuilder.buildMix(candidates: pool, targetSeconds: 3000, seed: .init())
        XCTAssertFalse(mix.contains { $0.id == "x" })
    }

    // MARK: - Seed filtering

    func testArtistSeedFiltersPool() {
        let target = songs(10, artist: "Miles Davis")
        let noise = songs(10, artist: "Metallica").map {
            NavidromeSong(id: "n\($0.id)", title: $0.title, artist: "Metallica", album: nil, duration: 200, coverArtID: nil)
        }
        let mix = MixBuilder.buildMix(
            candidates: target + noise,
            targetSeconds: 20 * 60,
            seed: .init(artist: "Miles Davis")
        )
        XCTAssertFalse(mix.isEmpty)
        XCTAssertTrue(mix.allSatisfy { ($0.artist ?? "").lowercased().contains("miles davis") },
                      "artist seed leaked non-matching tracks")
    }

    func testArtistSeedNoMatchFallsBackToFullPool() {
        let pool = songs(20, artist: "Someone")
        let mix = MixBuilder.buildMix(candidates: pool, targetSeconds: 20 * 60, seed: .init(artist: "Nobody Here"))
        // No candidate matches → fall back to the full pool rather than returning empty.
        XCTAssertFalse(mix.isEmpty)
    }

    // MARK: - W-42 / MIX-02: shuffle

    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func testShuffleIsDeterministicForSameSeed() {
        let pool = songs(50)
        var r1 = SeededRNG(42); var r2 = SeededRNG(42)
        let a = MixBuilder.buildMix(candidates: pool, targetSeconds: 1800, seed: .init(), using: &r1)
        let b = MixBuilder.buildMix(candidates: pool, targetSeconds: 1800, seed: .init(), using: &r2)
        XCTAssertEqual(a.map(\.id), b.map(\.id))
    }

    func testDifferentSeedsVaryTheMix() {
        let pool = songs(50)
        var r1 = SeededRNG(1); var r2 = SeededRNG(2)
        let a = MixBuilder.buildMix(candidates: pool, targetSeconds: 1800, seed: .init(), using: &r1)
        let b = MixBuilder.buildMix(candidates: pool, targetSeconds: 1800, seed: .init(), using: &r2)
        XCTAssertNotEqual(a.map(\.id), b.map(\.id), "different seeds should produce a different mix")
    }

    // MARK: - Prompt parsing

    func testParsePromptMinutes() {
        XCTAssertEqual(MixBuilder.parsePrompt("build me a 40 minute focus mix").minutes, 40)
        XCTAssertEqual(MixBuilder.parsePrompt("40-minute jazz").minutes, 40)
        XCTAssertEqual(MixBuilder.parsePrompt("a 90 min drive playlist").minutes, 90)
        XCTAssertEqual(MixBuilder.parsePrompt("chill mix, 25m").minutes, 25)
    }

    func testParsePromptPrefersMinuteTaggedNumber() {
        // The genre "hip hop" carries no number; the "2 hours"→ not a min token, but "45 min" is.
        let parsed = MixBuilder.parsePrompt("play 5 star songs for 45 minutes")
        XCTAssertEqual(parsed.minutes, 45)
    }

    func testParsePromptGenre() {
        XCTAssertEqual(MixBuilder.parsePrompt("mellow jazz mix").genre, "jazz")
        XCTAssertEqual(MixBuilder.parsePrompt("some upbeat techno for 30 min").genre, "techno")
        XCTAssertNil(MixBuilder.parsePrompt("something for the evening").genre)
    }

    func testParsePromptNoMinutes() {
        XCTAssertNil(MixBuilder.parsePrompt("just a focus mix").minutes)
    }
}
