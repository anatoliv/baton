import XCTest
@testable import BatonPlaybackKit

/// Looking outside the library.
///
/// The interesting behaviour here is not "does it parse JSON" but the two rules that make
/// the feature safe to ship: it makes **no request at all** until it is switched on, and a
/// source with no key is **off**, not broken.
final class ExternalDiscoveryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        for key in [ExternalDiscovery.enabledKey,
                    ExternalDiscovery.lastFMKeyKey,
                    ExternalDiscovery.youTubeKeyKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in [ExternalDiscovery.enabledKey,
                    ExternalDiscovery.lastFMKeyKey,
                    ExternalDiscovery.youTubeKeyKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    // MARK: The opt-in

    /// This is the one feature that talks to someone other than your own server and your
    /// own model provider. It is off.
    func testItIsOffUntilAskedFor() async {
        XCTAssertFalse(ExternalDiscovery.isEnabled)
        do {
            _ = try await ExternalDiscovery.similar(toTitle: "Anything", artist: "Anyone")
            XCTFail("a disabled feature answered")
        } catch {
            XCTAssertEqual(error as? ExternalDiscovery.Failure, .notEnabled)
        }
    }

    /// Nothing to look up with is a refusal, not an empty page of results.
    func testAnAbsentArtistIsRefusedRatherThanGuessedAt() async {
        UserDefaults.standard.set(true, forKey: ExternalDiscovery.enabledKey)
        do {
            _ = try await ExternalDiscovery.similar(toTitle: "Song", artist: "   ")
            XCTFail("looked up nothing")
        } catch {
            XCTAssertEqual(error as? ExternalDiscovery.Failure, .noArtist)
        }
    }

    // MARK: A missing key is a state, not a failure

    func testTheKeylessSourcesAreAlwaysAvailable() {
        let status = ExternalDiscovery.sourceStatus()
        let keyless = status.filter { [.musicBrainz, .listenBrainz].contains($0.source) }
        XCTAssertEqual(keyless.count, 2)
        XCTAssertTrue(keyless.allSatisfy(\.isAvailable),
                      "the sources that need no account must work out of the box")
    }

    func testAnUnconfiguredSourceReadsAsOffRatherThanBroken() throws {
        let youTube = try XCTUnwrap(ExternalDiscovery.sourceStatus()
            .first { $0.source == .youTube })
        XCTAssertFalse(youTube.isAvailable)
        XCTAssertTrue(youTube.detail.lowercased().contains("off"),
                      "an absent key should say the source is off: \(youTube.detail)")
        // The word that must NOT appear.
        XCTAssertFalse(youTube.detail.lowercased().contains("error"))
    }

    func testConfiguringAKeySwitchesItsSourceOn() throws {
        UserDefaults.standard.set("a-key", forKey: ExternalDiscovery.youTubeKeyKey)
        let youTube = try XCTUnwrap(ExternalDiscovery.sourceStatus()
            .first { $0.source == .youTube })
        XCTAssertTrue(youTube.isAvailable)
    }

    /// Whitespace is not a key. Somebody will paste one badly.
    func testABlankKeyIsNoKey() {
        UserDefaults.standard.set("   ", forKey: ExternalDiscovery.lastFMKeyKey)
        XCTAssertNil(ExternalDiscovery.configuredKey(ExternalDiscovery.lastFMKeyKey))
    }

    // MARK: Reading what the catalogues say

    func testMusicBrainzIdentityIsTakenOnlyOnAStrongMatch() {
        let strong = Data(#"{"artists":[{"id":"abc-123","score":100}]}"#.utf8)
        XCTAssertEqual(ExternalDiscovery.parseArtistMBID(strong), "abc-123")

        // A weak match sends the whole lookup after somebody else's discography.
        let weak = Data(#"{"artists":[{"id":"def-456","score":42}]}"#.utf8)
        XCTAssertNil(ExternalDiscovery.parseArtistMBID(weak))

        XCTAssertNil(ExternalDiscovery.parseArtistMBID(Data(#"{"artists":[]}"#.utf8)))
        XCTAssertNil(ExternalDiscovery.parseArtistMBID(Data("not json".utf8)))
    }

    /// ListenBrainz reports raw listener counts in the thousands. Left alone they would
    /// swamp Last.fm's 0…1 match values when the two lists are ranked together.
    func testListenBrainzScoresAreNormalisedForRankingAgainstOtherSources() throws {
        let data = Data("""
        [{"artist_mbid":"m1","name":"Nirvana","score":11156},
         {"artist_mbid":"m2","name":"Red Hot Chili Peppers","score":10587},
         {"artist_mbid":"m3","name":"Someone Else","score":1000}]
        """.utf8)
        let parsed = ExternalDiscovery.parseSimilarArtists(data)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].score, 1.0, accuracy: 0.0001)
        XCTAssertLessThan(parsed[2].score, 0.2)
        XCTAssertTrue(parsed.allSatisfy { $0.score <= 1.0 })
        XCTAssertEqual(parsed[0].url?.absoluteString, "https://musicbrainz.org/artist/m1")
    }

    func testListenBrainzRowsWithoutANameAreDropped() {
        let data = Data(#"[{"artist_mbid":"m1","score":10},{"name":"","score":5}]"#.utf8)
        XCTAssertTrue(ExternalDiscovery.parseSimilarArtists(data).isEmpty)
    }

    func testLastFMTracksKeepTheirArtistAndLink() throws {
        let data = Data("""
        {"similartracks":{"track":[
          {"name":"Paranoid Android","match":0.9,"url":"https://last.fm/x",
           "artist":{"name":"Radiohead"}}]}}
        """.utf8)
        let parsed = ExternalDiscovery.parseLastFM(data)
        let first = try XCTUnwrap(parsed.first)
        XCTAssertEqual(first.title, "Paranoid Android")
        XCTAssertEqual(first.artist, "Radiohead")
        XCTAssertEqual(first.url?.absoluteString, "https://last.fm/x")
    }

    /// A result you can't open is only half a result, so the video id has to survive.
    func testYouTubeResultsBecomeSomethingYouCanPress() throws {
        let data = Data("""
        {"items":[
          {"id":{"videoId":"abc123"},"snippet":{"title":"A Song","channelTitle":"A Channel"}},
          {"id":{"kind":"playlist"},"snippet":{"title":"No id here"}}]}
        """.utf8)
        let parsed = ExternalDiscovery.parseYouTube(data)
        XCTAssertEqual(parsed.count, 1, "an item with no video id cannot be opened")
        XCTAssertEqual(parsed[0].url?.absoluteString, "https://www.youtube.com/watch?v=abc123")
        XCTAssertEqual(parsed[0].artist, "A Channel")
    }

    func testYouTubeRelevanceOrderBecomesADescendingScore() {
        let items = (0 ..< 3).map {
            #"{"id":{"videoId":"v\#($0)"},"snippet":{"title":"T\#($0)"}}"#
        }.joined(separator: ",")
        let parsed = ExternalDiscovery.parseYouTube(Data("{\"items\":[\(items)]}".utf8))
        XCTAssertEqual(parsed.count, 3)
        XCTAssertGreaterThan(parsed[0].score, parsed[1].score)
        XCTAssertGreaterThan(parsed[1].score, parsed[2].score)
    }

    // MARK: Merging what several catalogues say

    func testTheSameSuggestionFromTwoSourcesIsOneSuggestion() {
        let merged = ExternalDiscovery.deduplicated([
            .init(title: "Karma Police", artist: "Radiohead", source: .lastFM, url: nil, score: 0.5),
            .init(title: "karma police", artist: "radiohead", source: .youTube,
                  url: URL(string: "https://youtube.com/watch?v=1"), score: 0.4),
        ])
        XCTAssertEqual(merged.count, 1)
        // The one you can actually open wins, even on the lower score.
        XCTAssertNotNil(merged[0].url)
    }

    func testDifferentSuggestionsSurviveDeduplication() {
        let merged = ExternalDiscovery.deduplicated([
            .init(title: "A", artist: "One", source: .lastFM, url: nil, score: 0.5),
            .init(title: "B", artist: "Two", source: .lastFM, url: nil, score: 0.4),
        ])
        XCTAssertEqual(merged.count, 2)
    }

    func testTheBetterScoreWinsWhenNeitherCanBeOpened() {
        let merged = ExternalDiscovery.deduplicated([
            .init(title: "A", artist: "One", source: .listenBrainz, url: nil, score: 0.2),
            .init(title: "A", artist: "One", source: .lastFM, url: nil, score: 0.8),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].score, 0.8, accuracy: 0.0001)
    }
}

/// The live half. Off unless asked for, on the same judgement as the lyrics lookup: an
/// environment that cannot give a measurement is not a failing measurement.
///
/// ```sh
/// BATON_LIVE_DISCOVERY=1 swift test --filter ExternalDiscoveryLive
/// ```
final class ExternalDiscoveryLiveTests: XCTestCase {
    private func requireLiveRun() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BATON_LIVE_DISCOVERY"] == "1",
                          "Set BATON_LIVE_DISCOVERY=1 to run the live catalogue lookups.")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: ExternalDiscovery.enabledKey)
        super.tearDown()
    }

    /// The keyless spine has to work on its own, or the feature ships as a settings screen
    /// asking for keys nobody has.
    func testTheKeylessPathFindsRelatedArtists() async throws {
        try requireLiveRun()
        UserDefaults.standard.set(true, forKey: ExternalDiscovery.enabledKey)
        let findings = try await ExternalDiscovery.similar(toTitle: "Karma Police",
                                                          artist: "Radiohead")
        XCTAssertFalse(findings.suggestions.isEmpty,
                       "MusicBrainz + ListenBrainz returned nothing without a key")
        XCTAssertTrue(findings.suggestions.allSatisfy { $0.score <= 1.0 })
        // And it should be honest about what it didn't ask.
        XCTAssertTrue(findings.quietSources.contains { $0.source == .youTube })
    }

    func testAnArtistNobodyHasHeardOfComesBackEmptyRatherThanWrong() async throws {
        try requireLiveRun()
        UserDefaults.standard.set(true, forKey: ExternalDiscovery.enabledKey)
        let findings = try await ExternalDiscovery.similar(
            toTitle: nil, artist: "Zzqq Xwv Nonexistent Band 90210")
        XCTAssertTrue(findings.suggestions.isEmpty)
    }
}
