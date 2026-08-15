import XCTest
import BatonSubsonicKit
@testable import Baton

/// Coverage for internet-radio: station-list decoding, the CRUD request shapes,
/// and the add/edit URL-validation helper. Network is stubbed via the shared
/// `NavidromeMockURLProtocol` (see NavidromeClientTests.swift).
final class RadioTests: XCTestCase {
    override func tearDown() {
        NavidromeMockURLProtocol.handler = nil
        NavidromeMockURLProtocol.lastRequestURL = nil
        super.tearDown()
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NavidromeMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func creds() -> NavidromeCredentials {
        NavidromeCredentials(
            baseURL: URL(string: "https://music.example.com")!,
            username: "joe",
            secret: "sesame",
            authMode: .tokenSalt
        )
    }

    // MARK: - Decoding

    func testGetInternetRadioStationsDecodes() async throws {
        NavidromeMockURLProtocol.handler = { req in
            let json = """
            {"subsonic-response":{"status":"ok","version":"1.16.1","internetRadioStations":{
              "internetRadioStation":[
                {"id":"1","name":"Jazz FM","streamUrl":"https://stream.example.com/jazz.mp3","homePageUrl":"https://jazz.example.com"},
                {"id":"2","name":"Ambient","streamUrl":"https://stream.example.com/ambient.aac"}
              ]}}}
            """
            return navidromeOK(json, req)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let stations = try await client.getInternetRadioStations()
        XCTAssertEqual(stations.count, 2)
        XCTAssertEqual(stations[0].id, "1")
        XCTAssertEqual(stations[0].name, "Jazz FM")
        XCTAssertEqual(stations[0].streamUrl, "https://stream.example.com/jazz.mp3")
        XCTAssertEqual(stations[0].homepageUrl, "https://jazz.example.com")
        XCTAssertNotNil(stations[0].streamURL)
        // Second station has no homepage → nil.
        XCTAssertNil(stations[1].homepageUrl)
    }

    /// Some servers spell the homepage `homepageUrl` (lowercase p) rather than the
    /// spec's `homePageUrl`; both must survive the round-trip.
    func testHomepageAlternateSpellingDecodes() async throws {
        NavidromeMockURLProtocol.handler = { req in
            let json = """
            {"subsonic-response":{"status":"ok","internetRadioStations":{
              "internetRadioStation":[
                {"id":"9","name":"Alt","streamUrl":"https://s.example.com/x","homepageUrl":"https://alt.example.com"}]}}}
            """
            return navidromeOK(json, req)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let stations = try await client.getInternetRadioStations()
        XCTAssertEqual(stations.first?.homepageUrl, "https://alt.example.com")
    }

    func testEmptyStationListDecodes() async throws {
        NavidromeMockURLProtocol.handler = { req in
            navidromeOK(#"{"subsonic-response":{"status":"ok","internetRadioStations":{}}}"#, req)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let stations = try await client.getInternetRadioStations()
        XCTAssertTrue(stations.isEmpty)
    }

    // MARK: - CRUD request shapes

    func testCreateStationSendsNameStreamAndHomepage() async throws {
        NavidromeMockURLProtocol.handler = { req in navidromeOK(#"{"subsonic-response":{"status":"ok"}}"#, req) }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        try await client.createInternetRadioStation(
            name: "Jazz FM", streamUrl: "https://s.example.com/jazz", homepageUrl: "https://jazz.example.com"
        )
        let url = try XCTUnwrap(NavidromeMockURLProtocol.lastRequestURL?.absoluteString)
        XCTAssertTrue(url.contains("createInternetRadioStation.view"))
        XCTAssertTrue(url.contains("name=Jazz%20FM"))
        XCTAssertTrue(url.contains("streamUrl=https"))
        XCTAssertTrue(url.contains("homepageUrl=https"))
    }

    func testCreateStationOmitsEmptyHomepage() async throws {
        NavidromeMockURLProtocol.handler = { req in navidromeOK(#"{"subsonic-response":{"status":"ok"}}"#, req) }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        try await client.createInternetRadioStation(name: "Ambient", streamUrl: "https://s.example.com/a")
        let url = try XCTUnwrap(NavidromeMockURLProtocol.lastRequestURL?.absoluteString)
        XCTAssertFalse(url.contains("homepageUrl="))
    }

    func testUpdateStationSendsId() async throws {
        NavidromeMockURLProtocol.handler = { req in navidromeOK(#"{"subsonic-response":{"status":"ok"}}"#, req) }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        try await client.updateInternetRadioStation(id: "7", name: "Renamed", streamUrl: "https://s.example.com/z")
        let url = try XCTUnwrap(NavidromeMockURLProtocol.lastRequestURL?.absoluteString)
        XCTAssertTrue(url.contains("updateInternetRadioStation.view"))
        XCTAssertTrue(url.contains("id=7"))
        XCTAssertTrue(url.contains("name=Renamed"))
    }

    func testDeleteStationSendsId() async throws {
        NavidromeMockURLProtocol.handler = { req in navidromeOK(#"{"subsonic-response":{"status":"ok"}}"#, req) }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        try await client.deleteInternetRadioStation(id: "3")
        let url = try XCTUnwrap(NavidromeMockURLProtocol.lastRequestURL?.absoluteString)
        XCTAssertTrue(url.contains("deleteInternetRadioStation.view"))
        XCTAssertTrue(url.contains("id=3"))
    }

    // MARK: - Error mapping (shares the base client's mapping)

    func testUnauthorizedMaps() async {
        NavidromeMockURLProtocol.handler = { req in
            navidromeOK(
                #"{"subsonic-response":{"status":"failed","error":{"code":40,"message":"Wrong"}}}"#,
                req
            )
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        do {
            _ = try await client.getInternetRadioStations()
            XCTFail("Expected unauthorized")
        } catch let error as NavidromeError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("Threw unexpected \(error)")
        }
    }

    // MARK: - URL validation helper

    func testValidStationPasses() {
        XCTAssertTrue(RadioStationEditor.isValid(name: "Jazz", streamURL: "https://stream.example.com/live.mp3"))
        XCTAssertTrue(RadioStationEditor.isValid(name: "HTTP OK", streamURL: "http://stream.example.com/live"))
    }

    func testInvalidStationRejected() {
        XCTAssertFalse(RadioStationEditor.isValid(name: "", streamURL: "https://s.example.com/x"))
        XCTAssertFalse(RadioStationEditor.isValid(name: "No URL", streamURL: ""))
        XCTAssertFalse(RadioStationEditor.isValid(name: "Bad scheme", streamURL: "ftp://s.example.com/x"))
        XCTAssertFalse(RadioStationEditor.isValid(name: "No host", streamURL: "https://"))
        XCTAssertFalse(RadioStationEditor.isValid(name: "Not a URL", streamURL: "just some text"))
    }

    /// A decoded station's `streamURL` is nil for a non-URL string (the row uses this
    /// to decide a station is playable).
    func testStreamURLNilForGarbage() {
        let station = NavidromeRadioStation(id: "x", name: "X", streamUrl: "   ", homepageUrl: nil)
        XCTAssertNil(station.streamURL)
    }
}

/// The rule that a station and the library queue are one pair of speakers, not two.
///
/// Both halves used to be written per-app: the Mac wired the duck, the media-key routing and
/// "a track start ends the broadcast"; the phone wired only the duck, and would play a station
/// and a library track at the same time. `InternetRadioStore.bind(to:)` plus the transport's own
/// `stopOnAirStation()` are now the single copy, so these tests exercise what both apps run.
@MainActor
final class RadioLibraryExclusionTests: XCTestCase {
    private let suiteName = "io.tonebox.tests.radioexclusion"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()

    private func makeController() -> StreamingPlaybackController {
        StreamingPlaybackController(
            streamURLProvider: { _ in URL(string: "file:///dev/null")! },
            defaults: suite,
            systemNowPlaying: false
        )
    }

    private func song(_ id: String) -> NavidromeSong {
        NavidromeSong(id: id, title: "Song \(id)", artist: "Artist", album: nil, duration: nil, coverArtID: nil)
    }

    /// Never resolves — the point is the station being *on air*, not audio arriving.
    private func station(_ id: String = "s1") -> NavidromeRadioStation {
        NavidromeRadioStation(id: id, name: "Station \(id)", streamUrl: "https://stream.invalid/\(id).mp3")
    }

    private func bound() -> (StreamingPlaybackController, InternetRadioStore) {
        let controller = makeController()
        let radio = InternetRadioStore()
        radio.bind(to: controller)
        return (controller, radio)
    }

    func testTuningAStationSuspendsTheLibrary() {
        let (c, radio) = bound()
        c.play([song("a")])
        XCTAssertEqual(c.state, .playing)
        radio.play(station())
        XCTAssertEqual(c.state, .paused, "the library must give the output up to the station")
        XCTAssertNotNil(radio.onAirStation)
    }

    /// The half the phone was missing: a library track starting must end the broadcast,
    /// not play over it.
    func testStartingALibraryTrackTakesTheOutputBack() {
        let (c, radio) = bound()
        radio.play(station())
        XCTAssertNotNil(radio.onAirStation)
        c.play([song("a")])
        XCTAssertNil(radio.onAirStation, "a library track start must leave the station off air")
        XCTAssertEqual(c.state, .playing)
    }

    /// Resuming mid-track never reaches the track-start path, and the phone's mini player
    /// (like `music_resume` over MCP) is not radio-aware — so the rule has to hold here too.
    func testResumingTheLibraryTakesTheOutputBack() {
        let (c, radio) = bound()
        c.play([song("a")])
        radio.play(station())
        XCTAssertEqual(c.state, .paused)
        c.resume()
        XCTAssertNil(radio.onAirStation)
        XCTAssertEqual(c.state, .playing)
    }

    /// A media key during a broadcast drives the *station*. Without the binding the phone
    /// resumed the library underneath the stream — two things playing from one button.
    func testMediaKeyPlayDrivesTheStationWhileOnAir() {
        let (c, radio) = bound()
        c.play([song("a")])
        radio.play(station())
        XCTAssertEqual(c.state, .paused)
        c.handleRemotePlay()
        XCTAssertNotNil(radio.onAirStation, "the play key belongs to the station while it holds the output")
        XCTAssertEqual(c.state, .paused, "the library must not resume under the stream")
    }

    /// And a next key walks the station list rather than the queue.
    func testMediaKeyNextWalksStationsWhileOnAir() {
        let (c, radio) = bound()
        c.play([song("a"), song("b")])
        radio.orderedStations = [station("s1"), station("s2")]
        radio.play(station("s1"))
        c.handleRemoteNext()
        XCTAssertEqual(radio.onAirStation?.id, "s2")
        XCTAssertEqual(c.nowPlaying?.id, "a", "the queue must not advance while a station is on air")
    }

    /// With nothing on air the transport is untouched by any of this.
    func testNoStationLeavesTheLibraryAlone() {
        let (c, radio) = bound()
        c.play([song("a")])
        c.pause()
        XCTAssertNil(radio.onAirStation)
        c.handleRemotePlay()
        XCTAssertEqual(c.state, .playing)
    }
}
