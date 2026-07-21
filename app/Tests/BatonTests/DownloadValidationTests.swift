import XCTest
@testable import Baton

/// W-05 + W-06: never adopt an HTTP error page as audio; never adopt (and thus never
/// let Remove delete) a user's own music files that happen to be in the download folder.
@MainActor
final class DownloadValidationTests: XCTestCase {
    private func tempFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        try Data(repeating: 0, count: bytes).write(to: url)
        return url
    }
    private func http(_ status: Int, type: String? = nil) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let type { headers["Content-Type"] = type }
        return HTTPURLResponse(url: URL(string: "https://s/x")!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    // MARK: W-05 — download response validation

    func testRejects404() throws {
        let f = try tempFile(bytes: 4096); defer { try? FileManager.default.removeItem(at: f) }
        XCTAssertThrowsError(try MusicDownloadStore.validateDownloadResponse(http(404), fileURL: f))
    }
    func testRejects500() throws {
        let f = try tempFile(bytes: 4096); defer { try? FileManager.default.removeItem(at: f) }
        XCTAssertThrowsError(try MusicDownloadStore.validateDownloadResponse(http(500), fileURL: f))
    }
    func testRejectsHTMLBody() throws {
        let f = try tempFile(bytes: 4096); defer { try? FileManager.default.removeItem(at: f) }
        XCTAssertThrowsError(try MusicDownloadStore.validateDownloadResponse(http(200, type: "text/html; charset=utf-8"), fileURL: f))
    }
    func testRejectsTinyBody() throws {
        let f = try tempFile(bytes: 100); defer { try? FileManager.default.removeItem(at: f) }
        XCTAssertThrowsError(try MusicDownloadStore.validateDownloadResponse(http(200, type: "audio/mpeg"), fileURL: f))
    }
    func testAccepts200Audio() throws {
        let f = try tempFile(bytes: 4096); defer { try? FileManager.default.removeItem(at: f) }
        XCTAssertNoThrow(try MusicDownloadStore.validateDownloadResponse(http(200, type: "audio/mpeg"), fileURL: f))
    }

    // MARK: W-06 — foreign-file adoption guard

    func testForeignMusicFilenamesNotAdopted() {
        XCTAssertFalse(MusicDownloadStore.isPlausibleSubsonicID("01 - Song"))
        XCTAssertFalse(MusicDownloadStore.isPlausibleSubsonicID("Artist - Title"))
        XCTAssertFalse(MusicDownloadStore.isPlausibleSubsonicID("track1")) // too short
        XCTAssertFalse(MusicDownloadStore.isPlausibleSubsonicID("My Favourite Song"))
    }
    func testSubsonicIdsAdopted() {
        XCTAssertTrue(MusicDownloadStore.isPlausibleSubsonicID("e8f5c2a1b3d4e6f7a8b9c0d1e2f3a4b5")) // 32-char hex
        XCTAssertTrue(MusicDownloadStore.isPlausibleSubsonicID("al-1234567890abcdef"))
    }

    // MARK: W-34 — original-quality downloads + honest extensions

    func testFileExtensionFromContentType() {
        XCTAssertEqual(MusicDownloadStore.fileExtension(forContentType: "audio/flac"), "flac")
        XCTAssertEqual(MusicDownloadStore.fileExtension(forContentType: "audio/x-m4a"), "m4a")
        XCTAssertEqual(MusicDownloadStore.fileExtension(forContentType: "audio/mpeg"), "mp3")
        XCTAssertEqual(MusicDownloadStore.fileExtension(forContentType: nil), "mp3")
    }

    func testPodcastDownloadUsesEnclosureURL() throws {
        let u = try StreamingPlaybackController.resolveDownloadURL(songID: "https://cdn.example.com/ep.m4a")
        XCTAssertEqual(u.absoluteString, "https://cdn.example.com/ep.m4a")
    }

    // MARK: W-33 — batch failure tracking + cooperative cancellation

    override func tearDown() {
        NavidromeMockURLProtocol.handler = nil
        super.tearDown()
    }

    /// A podcast episode's id is its enclosure URL, so `download` streams it directly with no
    /// Navidrome credentials — letting us drive the real download path against a stubbed server.
    private func podcastSong(_ url: String) -> NavidromeSong {
        NavidromeSong(id: url, title: "Ep", artist: "Pod", album: nil, duration: 100, coverArtID: nil)
    }

    private func stubStore(status: Int, contentType: String = "audio/mpeg", bytes: Int = 4096) -> MusicDownloadStore {
        NavidromeMockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": contentType]
            )!
            return (resp, Data(repeating: 0x42, count: bytes))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NavidromeMockURLProtocol.self]
        let store = MusicDownloadStore()
        store.setDownloadFolder(FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)"))
        store.urlSession = URLSession(configuration: config)
        return store
    }

    func testFailedDownloadIsTrackedAndClearedOnRetrySuccess() async {
        let id = "https://feeds.example.com/fail.mp3"
        // A 500 must not be adopted as audio; the failure is tracked (not just logged). (DL-02)
        let store = stubStore(status: 500)
        let failed = await store.download(podcastSong(id))
        XCTAssertFalse(failed, "a 500 is a failed download")
        XCTAssertTrue(store.failedIDs.contains(id), "the failure must be visible to the UI")

        // A subsequent successful download of the same id clears the failure.
        NavidromeMockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "audio/mpeg"])!
            return (resp, Data(repeating: 0x42, count: 8192))
        }
        let ok = await store.download(podcastSong(id))
        XCTAssertTrue(ok, "the retry succeeds")
        XCTAssertFalse(store.failedIDs.contains(id), "a successful retry clears the failure")
    }

    // MARK: W-33 / DL-09 — LRU storage-cap eviction planner

    func testEvictionPlanIsNoOpWhenUnderCapOrUnlimited() {
        let items = [(id: "a", bytes: Int64(100)), (id: "b", bytes: Int64(100))]
        XCTAssertEqual(MusicDownloadStore.evictionPlan(items: items, lastPlayed: [:], capBytes: 0), [], "unlimited cap evicts nothing")
        XCTAssertEqual(MusicDownloadStore.evictionPlan(items: items, lastPlayed: [:], capBytes: 500), [], "fits → evicts nothing")
    }

    func testEvictionPlanDropsLeastRecentlyPlayedFirstUntilUnderCap() {
        let items = [(id: "old", bytes: Int64(100)), (id: "mid", bytes: Int64(100)), (id: "new", bytes: Int64(100))]
        let lastPlayed = [
            "old": Date(timeIntervalSince1970: 1_000),
            "mid": Date(timeIntervalSince1970: 2_000),
            "new": Date(timeIntervalSince1970: 3_000),
        ]
        // Total 300, cap 150 → must drop to ≤150, evicting the two oldest (old, then mid).
        XCTAssertEqual(MusicDownloadStore.evictionPlan(items: items, lastPlayed: lastPlayed, capBytes: 150), ["old", "mid"])
        // Cap 250 → drop just the single oldest.
        XCTAssertEqual(MusicDownloadStore.evictionPlan(items: items, lastPlayed: lastPlayed, capBytes: 250), ["old"])
    }

    func testEvictionPlanTreatsNeverPlayedAsOldest() {
        let items = [(id: "played", bytes: Int64(100)), (id: "never", bytes: Int64(100))]
        let lastPlayed = ["played": Date(timeIntervalSince1970: 5_000)] // "never" absent
        XCTAssertEqual(MusicDownloadStore.evictionPlan(items: items, lastPlayed: lastPlayed, capBytes: 100), ["never"])
    }

    func testDownloadProgressIsClearedAfterCompletion() async {
        let store = stubStore(status: 200)
        let id = "https://feeds.example.com/prog.mp3"
        _ = await store.download(podcastSong(id))
        XCTAssertNil(store.downloadProgress[id], "progress must be cleared once a download finishes")
    }

    func testDownloadProgressIsClearedAfterFailure() async {
        let store = stubStore(status: 500)
        let id = "https://feeds.example.com/progfail.mp3"
        _ = await store.download(podcastSong(id))
        XCTAssertNil(store.downloadProgress[id], "progress must be cleared even when a download fails")
    }

    func testCancelledBatchStopsEarly() async {
        let store = stubStore(status: 200)
        let songs = (0 ..< 3).map { podcastSong("https://feeds.example.com/ok\($0).mp3") }
        // The batch runs on the main actor and can't start until we await, by which point the
        // cancel has already landed — so it stops before completing all three. (DL-07)
        let task = Task { await store.download(songs) }
        task.cancel()
        let completed = await task.value
        XCTAssertLessThan(completed, 3, "a cancelled batch must not plow through the whole album")
    }
}
