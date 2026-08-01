import XCTest
@testable import Baton

/// `MixBuilder.searchProbes` — the fallback that stops a descriptive prompt from
/// matching nothing. `search3` searches metadata with AND-ish semantics, so
/// "calm instrumental ambient for concentration" returns zero rows and the mix pool
/// collapses to liked songs.
final class SearchProbeTests: XCTestCase {
    func testFullPromptIsAlwaysTriedFirst() {
        let probes = MixBuilder.searchProbes(for: "deep focus ambient")
        XCTAssertEqual(probes.first, "deep focus ambient", "an exact title match must get first chance")
    }

    func testDescriptivePromptFallsBackToDistinctiveWords() {
        let probes = MixBuilder.searchProbes(for: "calm instrumental ambient for concentration")
        XCTAssertGreaterThan(probes.count, 1, "a prompt that matches nothing needs fallbacks")
        XCTAssertTrue(probes.contains("concentration"))
        XCTAssertTrue(probes.contains("instrumental"))
    }

    func testLongestWordsAreProbedFirst() {
        let probes = Array(MixBuilder.searchProbes(for: "some mellow evening jazz").dropFirst())
        let lengths = probes.map(\.count)
        XCTAssertEqual(lengths, lengths.sorted(by: >), "longest-first: \(probes)")
    }

    func testStopwordsAndFillerAreNotProbed() {
        let probes = MixBuilder.searchProbes(for: "please build me a 40 minute playlist that I would like")
        for junk in ["please", "build", "playlist", "minute", "would", "like", "that"] {
            XCTAssertFalse(probes.dropFirst().contains(junk), "\(junk) is not a search term")
        }
    }

    func testProbeCountIsBounded() {
        let probes = MixBuilder.searchProbes(
            for: "atmospheric hypnotic progressive melodic downtempo instrumental electronic",
            limit: 3
        )
        XCTAssertLessThanOrEqual(probes.count, 4, "full prompt + at most `limit` words")
    }

    func testNoDuplicateProbes() {
        let probes = MixBuilder.searchProbes(for: "ambient ambient ambient")
        XCTAssertEqual(Set(probes).count, probes.count, "\(probes)")
    }

    func testEmptyPromptYieldsNoProbes() {
        XCTAssertTrue(MixBuilder.searchProbes(for: "   ").isEmpty)
    }

    func testSingleWordPromptIsJustThatWord() {
        XCTAssertEqual(MixBuilder.searchProbes(for: "jazz"), ["jazz"])
    }
}
