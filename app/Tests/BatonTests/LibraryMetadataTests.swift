import XCTest
@testable import Baton

/// Coverage for the extended Subsonic/OpenSubsonic metadata added to the domain models:
/// wire decoding of the new fields, the quality/format helper, release-type + multi-artist
/// helpers, and the RFC3339 date parser. All decode paths run against a stubbed URLProtocol.
final class LibraryMetadataTests: XCTestCase {
    override func tearDown() {
        NavidromeMockURLProtocol.handler = nil
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
            username: "joe", secret: "sesame", authMode: .tokenSalt
        )
    }

    // MARK: - Wire decoding of the new fields

    func testRichSongDecodesExtendedMetadata() async throws {
        NavidromeMockURLProtocol.handler = { request in
            let json = """
            {"subsonic-response":{"status":"ok","searchResult3":{"song":[{
              "id":"s1","title":"So What","artist":"Miles Davis","album":"Kind of Blue",
              "albumId":"al1","duration":545,"coverArt":"c1","track":1,"year":1959,
              "discNumber":1,"genre":"Jazz","genres":[{"name":"Jazz"},{"name":"Bebop"}],
              "bitRate":1411,"suffix":"flac","contentType":"audio/flac","size":32000000,
              "samplingRate":96000,"bitDepth":24,"channelCount":2,"playCount":7,
              "played":"2024-01-15T10:30:00.000Z","bpm":132,"comment":"remaster",
              "musicBrainzId":"mbid-1","displayArtist":"Miles Davis feat. Coltrane",
              "starred":"2023-05-01T00:00:00Z","userRating":5
            }]}}}
            """
            return navidromeOK(json, request)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let song = try await client.search3(query: "miles").songs.first
        let s = try XCTUnwrap(song)
        XCTAssertEqual(s.year, 1959)
        XCTAssertEqual(s.discNumber, 1)
        XCTAssertEqual(s.genre, "Jazz")
        XCTAssertEqual(s.genres, ["Jazz", "Bebop"])
        XCTAssertEqual(s.bitRate, 1411)
        XCTAssertEqual(s.suffix, "flac")
        XCTAssertEqual(s.contentType, "audio/flac")
        XCTAssertEqual(s.size, 32_000_000)
        XCTAssertEqual(s.samplingRate, 96000)
        XCTAssertEqual(s.bitDepth, 24)
        XCTAssertEqual(s.channelCount, 2)
        XCTAssertEqual(s.playCount, 7)
        XCTAssertNotNil(s.played)
        XCTAssertEqual(s.bpm, 132)
        XCTAssertEqual(s.comment, "remaster")
        XCTAssertEqual(s.musicBrainzID, "mbid-1")
        XCTAssertEqual(s.displayArtist, "Miles Davis feat. Coltrane")
        XCTAssertTrue(s.isLiked)
        XCTAssertEqual(s.userRating, 5)
    }

    func testRichAlbumDecodesExtendedMetadata() async throws {
        NavidromeMockURLProtocol.handler = { request in
            let json = """
            {"subsonic-response":{"status":"ok","searchResult3":{"album":[{
              "id":"al1","name":"Kind of Blue","artist":"Miles Davis","artistId":"ar1",
              "songCount":5,"duration":2600,"coverArt":"c1","year":1959,"genre":"Jazz",
              "genres":[{"name":"Jazz"}],"playCount":42,"played":"2024-02-01T00:00:00Z",
              "created":"2020-06-01T00:00:00Z","releaseTypes":["ep"],"isCompilation":true,
              "originalReleaseDate":{"year":1959,"month":8,"day":17},
              "musicBrainzId":"mbid-al","displayArtist":"Miles Davis & Friends","userRating":4
            }]}}}
            """
            return navidromeOK(json, request)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let album = try await client.search3(query: "blue").albums.first
        let a = try XCTUnwrap(album)
        XCTAssertEqual(a.genre, "Jazz")
        XCTAssertEqual(a.genres, ["Jazz"])
        XCTAssertEqual(a.playCount, 42)
        XCTAssertNotNil(a.played)
        XCTAssertNotNil(a.created)
        XCTAssertEqual(a.releaseTypes, ["ep"])
        XCTAssertTrue(a.isCompilation)
        XCTAssertEqual(a.originalReleaseDate, "1959-08-17")
        XCTAssertEqual(a.musicBrainzID, "mbid-al")
        XCTAssertEqual(a.displayArtist, "Miles Davis & Friends")
    }

    func testPlaylistDecodesOwnerAndComment() async throws {
        NavidromeMockURLProtocol.handler = { request in
            let json = """
            {"subsonic-response":{"status":"ok","playlist":{
              "id":"p1","name":"Focus","songCount":1,"owner":"alice","comment":"deep work",
              "created":"2021-01-01T00:00:00Z","changed":"2024-03-01T00:00:00Z",
              "entry":[{"id":"a","title":"One"}]}}}
            """
            return navidromeOK(json, request)
        }
        let client = NavidromeClient(credentials: creds(), session: mockSession())
        let p = try await client.getPlaylist(id: "p1")
        XCTAssertEqual(p.owner, "alice")
        XCTAssertEqual(p.comment, "deep work")
        XCTAssertNotNil(p.created)
        XCTAssertNotNil(p.changed)
    }

    // MARK: - Computed helpers (pure)

    func testQualityLabelLossless() {
        let flac = NavidromeSong(id: "1", title: "t", suffix: "flac", samplingRate: 96000, bitDepth: 24)
        XCTAssertEqual(flac.qualityLabel, "FLAC · 24/96")

        let flacNoDepth = NavidromeSong(id: "2", title: "t", suffix: "flac", samplingRate: 44100)
        XCTAssertEqual(flacNoDepth.qualityLabel, "FLAC · 44kHz")

        let flacBare = NavidromeSong(id: "3", title: "t", suffix: "flac")
        XCTAssertEqual(flacBare.qualityLabel, "FLAC")
    }

    func testQualityLabelLossy() {
        let mp3 = NavidromeSong(id: "1", title: "t", bitRate: 320, suffix: "mp3")
        XCTAssertEqual(mp3.qualityLabel, "MP3 320")

        let noSuffix = NavidromeSong(id: "2", title: "t", bitRate: 128)
        XCTAssertEqual(noSuffix.qualityLabel, "128 kbps")

        let nothing = NavidromeSong(id: "3", title: "t")
        XCTAssertNil(nothing.qualityLabel)
    }

    func testReleaseTypeLabel() {
        XCTAssertEqual(NavidromeAlbum(id: "1", name: "a", releaseTypes: ["ep"]).releaseTypeLabel, "EP")
        XCTAssertEqual(NavidromeAlbum(id: "2", name: "a", releaseTypes: ["single"]).releaseTypeLabel, "Single")
        XCTAssertNil(NavidromeAlbum(id: "3", name: "a", releaseTypes: ["album"]).releaseTypeLabel)
        XCTAssertEqual(NavidromeAlbum(id: "4", name: "a", isCompilation: true).releaseTypeLabel, "Compilation")
        XCTAssertNil(NavidromeAlbum(id: "5", name: "a").releaseTypeLabel)
    }

    func testDisplayArtistNameFallsBackToArtist() {
        XCTAssertEqual(NavidromeSong(id: "1", title: "t", artist: "A", displayArtist: "A feat. B").displayArtistName, "A feat. B")
        XCTAssertEqual(NavidromeSong(id: "2", title: "t", artist: "A").displayArtistName, "A")
        XCTAssertEqual(NavidromeSong(id: "3", title: "t", artist: "A", displayArtist: "").displayArtistName, "A")
    }

    func testGenresFallBackToSingleGenre() {
        // A song given only `genre` exposes it through `genres` too.
        let s = NavidromeSong(id: "1", title: "t", genre: "Rock")
        XCTAssertEqual(s.genres, ["Rock"])
    }

    // MARK: - Agent-facing MCP JSON exposure

    @MainActor
    func testSongJSONExposesExtendedMetadata() {
        let song = NavidromeSong(
            id: "s1", title: "T", artist: "A", album: "Al", duration: 100,
            isLiked: true, userRating: 4, track: 3, year: 1990, discNumber: 2,
            genre: "Jazz", genres: ["Jazz", "Bebop"], bitRate: 320, suffix: "flac",
            contentType: "audio/flac", size: 1000, samplingRate: 96000, bitDepth: 24,
            channelCount: 2, playCount: 5, bpm: 120, comment: "note",
            musicBrainzID: "mb", displayArtist: "A feat. B"
        )
        let json = BatonMCPToolCatalog.songJSON(song)
        XCTAssertEqual(json["year"] as? Int, 1990)
        XCTAssertEqual(json["disc"] as? Int, 2)
        XCTAssertEqual(json["genres"] as? [String], ["Jazz", "Bebop"])
        XCTAssertEqual(json["quality"] as? String, "FLAC · 24/96")
        XCTAssertEqual(json["play_count"] as? Int, 5)
        XCTAssertEqual(json["rating"] as? Int, 4)
        XCTAssertEqual(json["liked"] as? Bool, true)
        XCTAssertEqual(json["display_artist"] as? String, "A feat. B")
        XCTAssertEqual(json["bpm"] as? Int, 120)
        XCTAssertEqual(json["content_type"] as? String, "audio/flac")
        XCTAssertEqual(json["channels"] as? Int, 2)
        XCTAssertEqual(json["comment"] as? String, "note")
    }

    // MARK: - Date parsing

    func testSubsonicDateParse() {
        XCTAssertNotNil(SubsonicDate.parse("2024-01-15T10:30:00.000Z"))
        XCTAssertNotNil(SubsonicDate.parse("2024-01-15T10:30:00Z"))
        XCTAssertNil(SubsonicDate.parse(nil))
        XCTAssertNil(SubsonicDate.parse(""))
        XCTAssertNil(SubsonicDate.parse("not-a-date"))
    }
}
