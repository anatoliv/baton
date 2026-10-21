@testable import BatonShareKit
import XCTest

/// Routing picked songs to a song, mixtape or collection link (specs/collection-sharing.md, decision 7).
final class ShareCollectionPlanTests: XCTestCase {
    private let books = ShareBookLimits(limits: .standard)
    private var withCollections: ShareCollectionPlan.Service { .init(collection: books) }
    private let withoutCollections = ShareCollectionPlan.Service()

    private func tracks(_ seconds: [Int?], onServer: Bool = true) -> [ShareCollectionPlan.Track] {
        seconds.enumerated().map { .init(id: "id-\($0.offset)", title: "Song \($0.offset + 1)", seconds: $0.element, onServer: onServer) }
    }

    private func route(_ seconds: [Int?], service: ShareCollectionPlan.Service, kind: ShareCollectionKind = .album)
        -> Result<ShareCollectionPlan.Route, ShareCollectionPlan.Refusal> {
        ShareCollectionPlan.route(tracks(seconds), kind: kind, service: service)
    }

    func testOneShortSongIsASongLink() {
        XCTAssertEqual(route([240], service: withCollections), .success(.song))
        XCTAssertEqual(route([240], service: withoutCollections), .success(.song))
    }

    func testTwoToTwelveWithinTheMixtapeLimitsAreAMixtape() {
        XCTAssertEqual(route([200, 200], service: withCollections), .success(.mixtape))
        // 12 songs of 50 s: 600 s and 12 × (2 MB + tags) of MP3, inside 20 minutes and 25 MiB.
        XCTAssertEqual(route(Array(repeating: 50, count: 12), service: withoutCollections), .success(.mixtape))
    }

    func testThirteenSongsAreACollectionWhenAdvertised() throws {
        let result = try route(Array(repeating: 60, count: 13), service: withCollections).get()
        guard case let .collection(link) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(link.kind, .album)
        XCTAssertEqual(link.seconds, 780)
        XCTAssertEqual(link.bitRates, Array(repeating: 128_000, count: 13))
    }

    func testTheMixtapeByteCapIsJudgedAtThreeHundredTwentyKilobits() throws {
        // Four 4-minute songs: 16 minutes fits the duration cap, but 4 × 240 s at 320 kbps is
        // about 38 MB of MP3, past the mixtape's 25 MiB, so the mixtape path would refuse it.
        let result = try route([240, 240, 240, 240], service: withCollections).get()
        guard case .collection = result else { return XCTFail("expected a collection, got \(result)") }
        // An MP3 library at 192 kbps the server hands over untouched does fit: its sizes are known.
        let small = (0 ..< 4).map {
            ShareCollectionPlan.Track(id: "m\($0)", title: "M\($0)", seconds: 240,
                                      mp3Bytes: ShareCollectionPlan.mp3Bytes(seconds: 240, suffix: "mp3", bitRate: 192, size: 5_800_000))
        }
        XCTAssertEqual(ShareCollectionPlan.route(small, kind: .playlist, service: withCollections), .success(.mixtape))
    }

    func testAMixtapeOverTwentyMinutesIsACollection() throws {
        let result = try route([700, 700], service: withCollections).get()
        guard case .collection = result else { return XCTFail("\(result)") }
        XCTAssertEqual(route([700, 700], service: withoutCollections),
                       .failure(.needsCollection(kind: .album, maxTracks: 12, maxSeconds: 1200, onlyHere: false)))
    }

    func testTheAdvertisedMixtapeDurationBindsWhenLower() {
        let service = ShareCollectionPlan.Service(maxSeconds: 300)
        XCTAssertEqual(route([200, 200], service: service),
                       .failure(.needsCollection(kind: .album, maxTracks: 12, maxSeconds: 300, onlyHere: false)))
    }

    func testOneLongSongIsAOneTrackCollectionOrTooLong() throws {
        guard case .collection = try route([1800], service: withCollections).get() else { return XCTFail() }
        XCTAssertEqual(route([1800], service: withoutCollections), .failure(.trackTooLong("Song 1", maxSeconds: 1200)))
    }

    func testASongOnlyOnThisDeviceNeedsACollection() throws {
        let local = tracks([200, 200], onServer: false)
        guard case .collection = try ShareCollectionPlan.route(local, kind: .playlist, service: withCollections).get() else {
            return XCTFail()
        }
        XCTAssertEqual(ShareCollectionPlan.route(local, kind: .playlist, service: withoutCollections),
                       .failure(.needsCollection(kind: .playlist, maxTracks: 12, maxSeconds: 1200, onlyHere: true)))
    }

    func testRefusals() {
        XCTAssertEqual(route([], service: withCollections), .failure(.nothingPicked))
        XCTAssertEqual(route([200, nil], service: withCollections), .failure(.unknownLength("Song 2")))
        XCTAssertEqual(route([200, 0], service: withCollections), .failure(.unknownLength("Song 2")))
        XCTAssertEqual(route([200], service: .init(enabled: false)), .failure(.paused))
        XCTAssertEqual(route(Array(repeating: 60, count: 201), service: withCollections), .failure(.tooManyTracks(max: 200)))
        let longest = ShareCollectionPlan.longestTrack(books)
        XCTAssertEqual(route([200, longest + 1], service: withCollections),
                       .failure(.trackTooLong("Song 2", maxSeconds: longest)))
        // Forty 68-minute tracks: each fits at 48 kbps, together within 48 hours but far past 256 MiB.
        guard case .failure(.tooLarge) = route(Array(repeating: longest, count: 40), service: withCollections) else {
            return XCTFail("expected too large")
        }
    }

    func testAnyDeclaredLengthRefusesRatherThanOverflows() {
        // A server can declare anything; Int.max must refuse, never trap (as the mixtape path's own test).
        let huge = [Int.max, 1]
        XCTAssertEqual(route(huge, service: withoutCollections),
                       .failure(.needsCollection(kind: .album, maxTracks: 12, maxSeconds: 1200, onlyHere: false)))
        XCTAssertEqual(route(huge, service: withCollections), .failure(.trackTooLong("Song 1", maxSeconds: ShareCollectionPlan.longestTrack(books))))
        XCTAssertEqual(route([Int.max], service: withoutCollections), .failure(.trackTooLong("Song 1", maxSeconds: 1200)))
        XCTAssertNotNil(ShareCollectionPlan.unavailableReason(.init(id: "a", title: "A", seconds: .max), service: withCollections))
        XCTAssertFalse(ShareCollectionPlan.line(.mixtape, tracks: tracks(huge)).isEmpty)
    }

    func testACollectionKindTheServiceDoesNotTakeIsNotOffered() {
        var config = ShareConfig(enabled: true, limits: .standard)
        config.mixtapes = 1; config.books = 1; config.book = books
        XCTAssertNil(ShareCollectionPlan.Service(config: config, kind: .album).collection, "no collections: 1")
        config.collections = 1
        config.collection = ShareCollectionLimits(kinds: [.album])
        XCTAssertNotNil(ShareCollectionPlan.Service(config: config, kind: .album).collection)
        XCTAssertNil(ShareCollectionPlan.Service(config: config, kind: .playlist).collection)
        config.books = nil
        XCTAssertNil(ShareCollectionPlan.Service(config: config, kind: .album).collection, "collections ride on books")
    }

    func testTheBitRateFallsBackForLongTracksAndStopsAtFortyEight() {
        let cap = books.maxChapterBytes
        XCTAssertEqual(ShareCollectionLimits.bitRate(forSeconds: 241, maxTrackBytes: cap), 128_000)
        // 25 MiB × 0.94 holds about 1,540 s at 128 kbps.
        XCTAssertEqual(ShareCollectionLimits.bitRate(forSeconds: 1500, maxTrackBytes: cap), 128_000)
        XCTAssertEqual(ShareCollectionLimits.bitRate(forSeconds: 1800, maxTrackBytes: cap), 96_000)
        XCTAssertEqual(ShareCollectionLimits.bitRate(forSeconds: 3000, maxTrackBytes: cap), 64_000)
        XCTAssertEqual(ShareCollectionLimits.bitRate(forSeconds: 4000, maxTrackBytes: cap), 48_000)
        XCTAssertNil(ShareCollectionLimits.bitRate(forSeconds: 4200, maxTrackBytes: cap))
        let longest = ShareCollectionPlan.longestTrack(books)
        XCTAssertEqual(ShareCollectionLimits.bitRate(forSeconds: longest, maxTrackBytes: cap), 48_000)
        XCTAssertNil(ShareCollectionLimits.bitRate(forSeconds: longest + 1, maxTrackBytes: cap))
        XCTAssertEqual(longest / 60, 68, "about 68 minutes, as the spec says")
        guard case let .collection(link) = try? route([300, 1800, 3000, 4000], service: withCollections).get() else { return XCTFail() }
        XCTAssertEqual(link.bitRates, [128_000, 96_000, 64_000, 48_000])
    }

    func testThePickerMarksOnlyTracksThatCanNeverGo() {
        XCTAssertEqual(ShareCollectionPlan.unavailableReason(.init(id: "a", title: "A", seconds: nil), service: nil), "Length unknown")
        XCTAssertNil(ShareCollectionPlan.unavailableReason(.init(id: "a", title: "A", seconds: 5000), service: withoutCollections))
        XCTAssertEqual(ShareCollectionPlan.unavailableReason(.init(id: "a", title: "A", seconds: 5000), service: withCollections),
                       "Too long to share (over 1 h 8 m)")
        XCTAssertNil(ShareCollectionPlan.unavailableReason(.init(id: "a", title: "A", seconds: 241), service: withCollections))
    }

    func testTheComposerLine() throws {
        let album = tracks(Array(repeating: 223, count: 14))
        let route = try ShareCollectionPlan.route(album, kind: .album, service: withCollections).get()
        XCTAssertEqual(ShareCollectionPlan.line(route, tracks: album), "14 songs · 52 m · about 50 MB · one album link")
        let mix = tracks(Array(repeating: 135, count: 8))
        XCTAssertEqual(ShareCollectionPlan.line(.mixtape, tracks: mix), "8 songs · 18 m · a mixtape link")
        XCTAssertEqual(ShareCollectionPlan.line(.song, tracks: tracks([45])), "1 song · 45 s · a song link")
        XCTAssertEqual(ShareCollectionPlan.duration(4320), "1 h 12 m")
    }

    func testTheRefusalsSayWhatToDo() {
        XCTAssertEqual(ShareCollectionPlan.Refusal.needsCollection(kind: .album, maxTracks: 12, maxSeconds: 1200, onlyHere: false).message,
                       "Album links aren't available on the share service yet. Pick up to 12 songs and 20 m for a mixtape link.")
        XCTAssertTrue(ShareCollectionPlan.Refusal.unknownLength("X").message.contains("Turn it off"))
    }

    func testASelectionsSuggestedTitle() {
        XCTAssertEqual(ShareCollectionPlan.suggestedTitle(albums: ["Blue", "Blue"], artists: ["Joni", "Joni"]), "Blue")
        XCTAssertEqual(ShareCollectionPlan.suggestedTitle(albums: ["Blue", "Court and Spark"], artists: ["Joni", "Joni"]),
                       "Songs by Joni")
        XCTAssertEqual(ShareCollectionPlan.suggestedTitle(albums: ["A", nil], artists: ["X", "Y"]), "Mixtape")
        XCTAssertEqual(ShareCollectionPlan.suggestedTitle(albums: [nil, nil], artists: [nil, nil]), "Mixtape")
        XCTAssertEqual(ShareCollectionPlan.wireText("  Tab\there  "), "Tab here")
        XCTAssertNil(ShareCollectionPlan.wireText("   "))
    }
}
