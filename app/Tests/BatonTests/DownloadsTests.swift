import XCTest
@testable import Baton

/// Coverage for the Downloads manager surface on `MusicDownloadStore`: enumerating
/// downloaded items, byte-size accounting, and `remove(id:)` — all against a temp folder
/// (no network). Also covers the static filename parser used for legacy downloads.
@MainActor
final class DownloadsTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-downloads-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Don't leave the temp folder persisted in UserDefaults for other tests / the app.
        UserDefaults.standard.removeObject(forKey: MusicDownloadStore.folderKey)
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    /// Writes a fake audio file of `bytes` bytes and records it in the manifest + meta
    /// sidecars, then returns a store pointed at the temp dir (which rescans on set).
    private func makeStore(_ tracks: [(id: String, name: String, bytes: Int)],
                           meta: [String: [String: Any]] = [:]) -> MusicDownloadStore {
        var manifest: [String: String] = [:]
        for track in tracks {
            let url = tempDir.appendingPathComponent(track.name)
            FileManager.default.createFile(
                atPath: url.path, contents: Data(count: track.bytes)
            )
            manifest[track.id] = track.name
        }
        write(manifest, to: MusicDownloadStore.manifestName)
        if !meta.isEmpty { writeJSON(meta, to: MusicDownloadStore.metaName) }

        let store = MusicDownloadStore()
        store.setDownloadFolder(tempDir)
        return store
    }

    private func write(_ dict: [String: String], to name: String) {
        let data = try! JSONEncoder().encode(dict)
        try! data.write(to: tempDir.appendingPathComponent(name))
    }

    private func writeJSON(_ dict: [String: [String: Any]], to name: String) {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        try! data.write(to: tempDir.appendingPathComponent(name))
    }

    // MARK: - Enumeration

    func testEnumerateReturnsDownloadedItems() {
        let store = makeStore([
            (id: "a", name: "Air - Kelly Watch.mp3", bytes: 100),
            (id: "b", name: "Daft Punk - Aerodynamic.mp3", bytes: 200),
        ])
        let items = store.downloadedItems()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map(\.id)), ["a", "b"])
        // Sorted by artist: Air before Daft Punk.
        XCTAssertEqual(items.first?.id, "a")
    }

    func testEnumerateUsesSidecarMetadataWhenPresent() {
        let store = makeStore(
            [(id: "a", name: "Air - Kelly Watch.mp3", bytes: 100)],
            meta: ["a": ["title": "Kelly Watch the Stars", "artist": "Air",
                         "album": "Moon Safari", "duration": 226]]
        )
        let item = try? XCTUnwrap(store.downloadedItems().first)
        XCTAssertEqual(item?.title, "Kelly Watch the Stars")
        XCTAssertEqual(item?.artist, "Air")
        XCTAssertEqual(item?.album, "Moon Safari")
        XCTAssertEqual(item?.duration, 226)
    }

    func testEnumerateFallsBackToParsedFilenameForLegacyDownloads() {
        // No meta sidecar — title/artist come from the "{artist} - {title}" filename.
        let store = makeStore([(id: "a", name: "Boards of Canada - Roygbiv.mp3", bytes: 100)])
        let item = store.downloadedItems().first
        XCTAssertEqual(item?.artist, "Boards of Canada")
        XCTAssertEqual(item?.title, "Roygbiv")
    }

    func testDownloadItemProducesPlayableSong() {
        let store = makeStore(
            [(id: "a", name: "x.mp3", bytes: 10)],
            meta: ["a": ["title": "T", "artist": "A", "album": "Al", "duration": 42]]
        )
        let song = store.downloadedItems().first!.song
        XCTAssertEqual(song.id, "a")
        XCTAssertEqual(song.title, "T")
        XCTAssertEqual(song.artist, "A")
        XCTAssertEqual(song.duration, 42)
    }

    // MARK: - Size accounting

    func testTotalBytesSumsAllFiles() {
        let store = makeStore([
            (id: "a", name: "a.mp3", bytes: 100),
            (id: "b", name: "b.mp3", bytes: 250),
        ])
        XCTAssertEqual(store.totalBytes(), 350)
    }

    func testItemByteSizeMatchesFile() {
        let store = makeStore([(id: "a", name: "a.mp3", bytes: 512)])
        XCTAssertEqual(store.downloadedItems().first?.byteSize, 512)
    }

    // MARK: - Removal

    func testRemoveDeletesFileAndDropsFromEnumeration() {
        let store = makeStore([
            (id: "a", name: "a.mp3", bytes: 100),
            (id: "b", name: "b.mp3", bytes: 100),
        ])
        XCTAssertTrue(store.isDownloaded("a"))

        store.remove(id: "a")

        XCTAssertFalse(store.isDownloaded("a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("a.mp3").path))
        XCTAssertEqual(store.downloadedItems().map(\.id), ["b"])
        XCTAssertEqual(store.totalBytes(), 100)
    }

    func testRemoveIsIdempotent() {
        let store = makeStore([(id: "a", name: "a.mp3", bytes: 100)])
        store.remove(id: "a")
        store.remove(id: "a") // no crash, still gone
        XCTAssertTrue(store.downloadedItems().isEmpty)
    }

    // MARK: - What a row should offer about the offline copy

    /// The bug: every menu on the phone said "Download", whatever the state, so a track you
    /// already had invited you to fetch it again and offered no way to remove it.
    func testADownloadedTrackOffersToRemoveItRatherThanFetchItAgain() {
        let store = makeStore([(id: "a", name: "Air - Kelly Watch.mp3", bytes: 100)])
        let song = NavidromeSong(id: "a", title: "Kelly Watch", artist: "Air", album: nil)

        XCTAssertEqual(store.offlineAction(for: song), .remove)
    }

    func testATrackThatIsNotDownloadedOffersToDownloadIt() {
        let store = makeStore([])
        let song = NavidromeSong(id: "b", title: "Aerodynamic", artist: "Daft Punk", album: nil)

        XCTAssertEqual(store.offlineAction(for: song), .download)
    }

    /// Removing puts the offer back, which is the half that would make a one-way toggle look
    /// like it worked: deleting and then finding no way to get the track back offline again.
    func testRemovingADownloadOffersToDownloadItAgain() {
        let store = makeStore([(id: "a", name: "Air - Kelly Watch.mp3", bytes: 100)])
        let song = NavidromeSong(id: "a", title: "Kelly Watch", artist: "Air", album: nil)

        store.delete("a")

        XCTAssertEqual(store.offlineAction(for: song), .download)
    }

    /// A clipping or a demo track is already a file here and no server holds a copy. Offering
    /// "Download" is an action that cannot happen; offering "Remove Download" would be worse,
    /// because it reads as evicting a cache and would actually delete the only copy.
    func testAFileAlreadyOnThisDeviceOffersNeither() {
        let store = makeStore([])
        let clipping = NavidromeSong(id: "file:///tmp/deploy-products.m4a",
                                     title: "Deploy products", artist: "Ghostty", album: nil)

        XCTAssertTrue(clipping.isLocalOnly, "precondition: a file:// id is local-only")
        XCTAssertEqual(store.offlineAction(for: clipping), .unavailable)
    }

    // MARK: - Static helpers

    func testParseFilenameSplitsArtistAndTitle() {
        let (artist, title) = MusicDownloadStore.parseFilename("Air - Kelly Watch")
        XCTAssertEqual(artist, "Air")
        XCTAssertEqual(title, "Kelly Watch")
    }

    func testParseFilenameFallsBackToWholeStringAsTitle() {
        let (artist, title) = MusicDownloadStore.parseFilename("SingleName")
        XCTAssertNil(artist)
        XCTAssertEqual(title, "SingleName")
    }

    func testFileByteSizeReadsFromDisk() {
        let url = tempDir.appendingPathComponent("blob.mp3")
        FileManager.default.createFile(atPath: url.path, contents: Data(count: 777))
        XCTAssertEqual(MusicDownloadStore.fileByteSize(at: url), 777)
    }
}
