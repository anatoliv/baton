import Foundation
import Testing
@testable import Baton

@MainActor
private func song(_ id: String, artist: String? = "Artist", album: String? = nil) -> NavidromeSong {
    NavidromeSong(id: id, title: "T\(id)", artist: artist, album: album,
                  albumID: nil, duration: 200, coverArtID: nil)
}

@MainActor
private func freshHistory() -> MusicPlayHistory {
    // Inject a unique directory: the archive is an on-disk JSONL (W-32), so without this every
    // test would share ~/Library/Application Support/Baton/play-history.jsonl and see each other's
    // entries. (W-49 hygiene)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID())", isDirectory: true)
    return MusicPlayHistory(defaults: UserDefaults(suiteName: "hist-\(UUID())")!,
                            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
                            directory: dir)
}

// MARK: - Archive

@MainActor
@Suite("Local listen archive")
struct LocalArchiveTests {
    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("record(_:playedAt:) stamps the given start time, not now")
    func recordsGivenTime() {
        let h = freshHistory()
        h.record(song("a"), playedAt: Date(timeIntervalSince1970: 1_000))
        #expect(h.entries.first?.playedAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test("disabling local logging stops new recordings")
    func togglesOff() {
        let h = freshHistory()
        h.isEnabled = false
        h.record(song("a"), playedAt: t)
        #expect(h.entries.isEmpty)
        h.isEnabled = true
        h.record(song("a"), playedAt: t)
        #expect(h.entries.count == 1)
    }

    @Test("top albums ranks by plays and skips blank album names")
    func topAlbums() {
        let h = freshHistory()
        h.record(song("a1", album: "X"), playedAt: t)
        h.record(song("a2", album: "X"), playedAt: t.addingTimeInterval(120))
        h.record(song("b1", album: "Y"), playedAt: t.addingTimeInterval(240))
        h.record(song("c1", album: nil), playedAt: t.addingTimeInterval(360)) // no album — excluded
        let albums = h.topAlbums(since: .distantPast)
        #expect(albums.first?.album == "X")
        #expect(albums.first?.count == 2)
        #expect(albums.contains { $0.album.isEmpty } == false)
    }

    @Test("lifetime total and first-listen date")
    func lifetime() {
        let h = freshHistory()
        h.record(song("a"), playedAt: t)
        h.record(song("b"), playedAt: t.addingTimeInterval(120))
        h.record(song("c"), playedAt: t.addingTimeInterval(240))
        #expect(h.lifetimeCount == 3)
        #expect(h.firstListenDate == t)
    }

    @Test("dailyCounts is bounded even for an unbounded start (no runaway)")
    func dailyBounded() {
        let h = freshHistory()
        h.record(song("a"), playedAt: t)
        let daily = h.dailyCounts(since: .distantPast)
        #expect(daily.count <= 400)
        #expect(daily.count >= 1)
    }

    @Test("import merges new listens and dedups on re-import")
    func importRoundTrip() {
        let h = freshHistory()
        let listens = [
            PortableListen(listened_at: 100, track_metadata: .init(artist_name: "A", track_name: "One", release_name: "Alb")),
            PortableListen(listened_at: 200, track_metadata: .init(artist_name: "B", track_name: "Two", release_name: nil)),
        ]
        #expect(h.ingest(listens) == 2)
        #expect(h.ingest(listens) == 0)          // already present
        #expect(h.lifetimeCount == 2)
        #expect(h.topArtists(since: .distantPast).contains { $0.artist == "A" })
    }
}

// MARK: - Portable IO

@MainActor
@Suite("Listen archive export/import format")
struct ListenArchiveIOTests {
    private func listen(_ at: Int, _ artist: String, _ track: String, _ album: String? = nil) -> PortableListen {
        PortableListen(listened_at: at, track_metadata: .init(artist_name: artist, track_name: track, release_name: album))
    }

    @Test("JSON export is ListenBrainz-shaped and round-trips")
    func jsonRoundTrip() {
        let listens = [listen(100, "A", "One", "Alb"), listen(200, "B", "Two")]
        let data = ListenArchiveIO.exportJSON(listens)
        let text = String(data: data, encoding: .utf8)!
        #expect(text.contains("listened_at"))
        #expect(text.contains("track_metadata"))
        #expect(text.contains("artist_name"))
        #expect(ListenArchiveIO.parse(data) == listens)
    }

    @Test("CSV quotes fields containing commas")
    func csvEscaping() {
        let csv = ListenArchiveIO.exportCSV([listen(0, "Tyler, the Creator", "IFHY")])
        #expect(csv.contains("\"Tyler, the Creator\""))
        #expect(csv.hasPrefix("artist,track,album,listened_at"))
    }

    @Test("parse accepts JSONL and skips entries missing artist/track")
    func parseJSONL() {
        let jsonl = """
        {"listened_at":1,"track_metadata":{"artist_name":"A","track_name":"One"}}
        {"listened_at":2,"track_metadata":{"artist_name":"","track_name":"Bad"}}
        {"listened_at":3,"track_metadata":{"artist_name":"B","track_name":"Two"}}
        """
        let parsed = ListenArchiveIO.parse(Data(jsonl.utf8))
        #expect(parsed.count == 2)
        #expect(parsed.map(\.artist) == ["A", "B"])
    }

    @Test("unrecognised input yields no listens")
    func garbage() {
        #expect(ListenArchiveIO.parse(Data("not json".utf8)).isEmpty)
    }
}

// MARK: - Service → archive wiring

@MainActor
private final class InactiveDestination: ScrobbleDestination {
    let destinationID = "inactive"
    let isActive = false
    let maxBatch = 1
    func sendNowPlaying(_ scrobble: Scrobble) async {}
    func submit(_ batch: [Scrobble]) async throws {}
}

@MainActor
private final class RecordingSpy: LocalListenRecording {
    private(set) var recorded: [(song: NavidromeSong, at: Date)] = []
    func record(_ song: NavidromeSong, playedAt: Date) { recorded.append((song, playedAt)) }
}

@MainActor
@Suite("ScrobbleService → local archive")
struct ScrobbleServiceArchiveTests {
    @Test("a completed library track is logged locally at its start time; podcasts are not")
    func recordsLibraryNotPodcast() {
        let spy = RecordingSpy()
        let suite = UserDefaults(suiteName: "svc-arch-\(UUID())")!
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let service = ScrobbleService(
            listenBrainz: InactiveDestination(), lastfm: InactiveDestination(), navidrome: InactiveDestination(),
            localArchive: spy, queue: ScrobbleQueue(defaults: suite), defaults: suite,
            now: { start }, monitorNetwork: false, autoFlush: false
        )
        let library = NavidromeSong(id: "song1", title: "T", artist: "A", album: "Alb",
                                    albumID: nil, duration: 200, coverArtID: nil)
        let podcast = NavidromeSong(id: "https://x/ep.mp3", title: "Ep", artist: "Show",
                                    album: nil, albumID: nil, duration: 3600, coverArtID: nil)

        service.completed(library, startedAt: start)
        service.completed(podcast, startedAt: start)

        #expect(spy.recorded.count == 1)
        #expect(spy.recorded.first?.song.id == "song1")
        #expect(spy.recorded.first?.at == start)
    }
}
