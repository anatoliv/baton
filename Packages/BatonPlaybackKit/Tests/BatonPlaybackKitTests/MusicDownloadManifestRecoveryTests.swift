#if !os(watchOS)
import XCTest
@testable import BatonPlaybackKit
@testable import BatonSubsonicKit
import BatonSubsonicModels

/// What happens to a downloaded library when the manifest that names its files is damaged.
///
/// The manifest is the only record mapping a song id to a templated filename, so a torn write
/// used to take the whole download folder with it: the file is quarantined, the store starts
/// empty, and a folder of audio files reads as "nothing downloaded". These tests pin both
/// halves of the recovery - the damaged bytes are kept aside, and the audio is claimed again
/// from the metadata sidecar rather than treated as missing.
@MainActor
final class MusicDownloadManifestRecoveryTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-download-recovery-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Point the store at the temp folder before it is constructed, so no test ever reads or
        // writes the real music cache.
        BatonStorage.defaults.set(folder.path, forKey: MusicDownloadStore.folderKey)
    }

    override func tearDown() {
        BatonStorage.defaults.removeObject(forKey: MusicDownloadStore.folderKey)
        BatonStorage.defaults.removeObject(forKey: "baton.downloads.purgeGeneration")
        if let folder { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A fake audio file. Only its name matters to the manifest, so the bytes are filler.
    private func writeAudio(_ name: String) -> URL {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(count: 2048))
        return url
    }

    private func write(_ json: String, to name: String) {
        try! Data(json.utf8).write(to: folder.appendingPathComponent(name))
    }

    private func files(matching prefix: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }.sorted()
    }

    private func manifestOnDisk() throws -> [String: String] {
        struct Envelope: Decodable { let version: Int; let payload: [String: String] }
        let data = try Data(contentsOf: folder.appendingPathComponent(MusicDownloadStore.manifestName))
        return try JSONDecoder().decode(Envelope.self, from: data).payload
    }

    // MARK: - Tests

    /// The case the card is about: the manifest is truncated mid-write, and the audio files are
    /// still sitting in the folder.
    func testATruncatedManifestIsQuarantinedAndItsDownloadsAreClaimedAgain() throws {
        _ = writeAudio("Air - Kelly Watch the Stars.mp3")
        _ = writeAudio("Daft Punk - Aerodynamic.flac")
        // A prefix of the envelope the shipping writer produces, as a half-completed write leaves it.
        write(#"{"version":1,"payload":{"a":"Air - Kelly Watch the St"#, to: MusicDownloadStore.manifestName)
        write(#"""
        {"a":{"title":"Kelly Watch the Stars","artist":"Air","album":"Moon Safari"},
         "b":{"title":"Aerodynamic","artist":"Daft Punk","album":"Discovery"}}
        """#, to: MusicDownloadStore.metaName)

        let store = MusicDownloadStore()

        let aside = files(matching: MusicDownloadStore.manifestName + ".corrupt-")
        XCTAssertEqual(aside.count, 1, "the damaged manifest bytes were not kept: \(files(matching: ".tonebox"))")

        XCTAssertEqual(store.downloadedIDs, ["a", "b"],
                       "the audio files are still on disk but the store reports them missing")
        XCTAssertEqual(store.localURL(for: "a")?.lastPathComponent, "Air - Kelly Watch the Stars.mp3")
        XCTAssertEqual(store.localURL(for: "b")?.lastPathComponent, "Daft Punk - Aerodynamic.flac")
        // The rebuild is written back, so the next launch does not have to work it out again.
        XCTAssertEqual(try manifestOnDisk(), ["a": "Air - Kelly Watch the Stars.mp3",
                                              "b": "Daft Punk - Aerodynamic.flac"])
    }

    /// The sidecar records the filename itself for downloads saved by this build and later, so
    /// recovery does not have to guess when the template has changed since the download.
    func testTheFilenameRecordedInTheSidecarSurvivesATemplateChange() throws {
        _ = writeAudio("Air - Kelly Watch the Stars.mp3")
        write("not json at all", to: MusicDownloadStore.manifestName)
        write(#"""
        {"a":{"title":"Kelly Watch the Stars","artist":"Air",
              "file":"Air - Kelly Watch the Stars.mp3"}}
        """#, to: MusicDownloadStore.metaName)
        BatonStorage.defaults.set("{title} ({artist})", forKey: MusicDownloadStore.templateKey)
        defer { BatonStorage.defaults.removeObject(forKey: MusicDownloadStore.templateKey) }

        let store = MusicDownloadStore()

        XCTAssertEqual(store.downloadedIDs, ["a"])
        XCTAssertEqual(store.localURL(for: "a")?.lastPathComponent, "Air - Kelly Watch the Stars.mp3")
    }

    /// The guard that keeps a recovery from adopting the user's own library: a file that
    /// no metadata entry accounts for is left alone, however audio-shaped its name is.
    func testAFileNoMetadataEntryAccountsForIsNotAdopted() throws {
        _ = writeAudio("Air - Kelly Watch the Stars.mp3")
        _ = writeAudio("01 - Some Bootleg.mp3")
        write(#"{"version":1,"payload":{"a":"Air - Kelly"#, to: MusicDownloadStore.manifestName)
        write(#"{"a":{"title":"Kelly Watch the Stars","artist":"Air"}}"#, to: MusicDownloadStore.metaName)

        let store = MusicDownloadStore()

        XCTAssertEqual(store.downloadedIDs, ["a"], "a file Baton has no record of was adopted")
    }

    /// Two downloads that render the same name must not both claim the same file: one takes it
    /// and the other stays unresolved, rather than the two being paired at random.
    func testAnAmbiguousNameIsNotPairedTwice() throws {
        _ = writeAudio("Air - Kelly Watch the Stars.mp3")
        write("{", to: MusicDownloadStore.manifestName)
        write(#"""
        {"a":{"title":"Kelly Watch the Stars","artist":"Air"},
         "b":{"title":"Kelly Watch the Stars","artist":"Air"}}
        """#, to: MusicDownloadStore.metaName)

        let store = MusicDownloadStore()

        XCTAssertEqual(store.downloadedIDs.count, 1)
        XCTAssertEqual(store.downloadedIDs, ["a"], "the lower id claims the one file, deterministically")
    }

    /// A healthy manifest is left exactly as it is: recovery is not a second source of truth.
    func testAHealthyManifestIsNotRewritten() throws {
        _ = writeAudio("Air - Kelly Watch the Stars.mp3")
        write(#"{"version":1,"payload":{"a":"Air - Kelly Watch the Stars.mp3"}}"#,
              to: MusicDownloadStore.manifestName)
        write(#"{"a":{"title":"Kelly Watch the Stars","artist":"Air"}}"#, to: MusicDownloadStore.metaName)
        let before = try Data(contentsOf: folder.appendingPathComponent(MusicDownloadStore.manifestName))

        let store = MusicDownloadStore()

        XCTAssertEqual(store.downloadedIDs, ["a"])
        XCTAssertTrue(files(matching: MusicDownloadStore.manifestName + ".corrupt-").isEmpty)
        let after = try Data(contentsOf: folder.appendingPathComponent(MusicDownloadStore.manifestName))
        XCTAssertEqual(before, after, "an untouched manifest was rewritten on a plain launch")
    }

    // MARK: - Downloading

    /// A store whose downloads are answered by `StubStream` with the MP3 fixture. Server config
    /// reads go to a throwaway suite.
    private func downloadingStore() throws -> MusicDownloadStore {
        StubStream.reset()
        StubStream.body = try Data(contentsOf: XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/stream-fixture.mp3", withExtension: nil)))
        let realDefaults = NavidromeConfig.defaults
        NavidromeConfig.defaults = ThrowawayDefaults.make("download-recovery")
        addTeardownBlock { @MainActor in NavidromeConfig.defaults = realDefaults }
        let store = MusicDownloadStore()
        store.urlSession = StubStream.session()
        return store
    }

    /// The download folder can be the user's own library. A file of theirs with the name
    /// a download renders is not Baton's to delete and take over (C2-5).
    func testADownloadDoesNotReplaceTheUsersOwnFileWithTheSameName() async throws {
        let theirs = folder.appendingPathComponent("A - T.mp3")
        let bytes = Data(repeating: 7, count: 2048)
        try bytes.write(to: theirs)
        let store = try downloadingStore()
        let episode = NavidromeSong(id: "https://cdn.example/t.mp3", title: "T", artist: "A")

        let downloaded = await store.download(episode)

        XCTAssertTrue(downloaded)
        XCTAssertEqual(try? Data(contentsOf: theirs), bytes, "the user's own file was deleted or overwritten")
        let ours = try XCTUnwrap(store.localURL(for: episode.id))
        XCTAssertNotEqual(ours.lastPathComponent, "A - T.mp3")
        XCTAssertTrue(ours.lastPathComponent.hasPrefix("A - T"))
    }

    /// A saved resume blob that no longer works (its partial was purged, or it is damaged) is
    /// dropped after the failed resume, so the next attempt starts fresh instead of repeating
    /// the same failure forever (C2-6).
    func testAResumeBlobThatFailsIsDroppedSoTheNextAttemptStartsFresh() async throws {
        let resume = folder.appendingPathComponent(".resume", isDirectory: true)
        try FileManager.default.createDirectory(at: resume, withIntermediateDirectories: true)
        let blob = resume.appendingPathComponent("https___cdn_example_r_mp3.resume")
        // Bytes URLSession cannot read back as resume data, as a torn or foreign write leaves them.
        try Data("not a resume blob".utf8).write(to: blob)
        let store = try downloadingStore()
        // A damaged blob fails by timing out, so keep the timeout short.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubStream.self]
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 2
        store.urlSession = URLSession(configuration: configuration)
        let episode = NavidromeSong(id: "https://cdn.example/r.mp3", title: "R", artist: "A")

        let first = await store.download(episode)
        XCTAssertFalse(first, "the damaged blob was expected to fail")
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path), "the failing blob was kept")

        let second = await store.download(episode)
        XCTAssertTrue(second, "the retry repeated the failed resume instead of starting fresh")
        XCTAssertTrue(store.isDownloaded(episode.id))
    }

    // MARK: - Session purge

    /// A resume blob holds the authenticated request (the apiKey or token and salt, and the
    /// custom headers), so "Disconnect and delete my data" must not leave one behind (C2-7).
    func testDeleteAllRemovesSavedResumeData() throws {
        let resume = folder.appendingPathComponent(".resume", isDirectory: true)
        try FileManager.default.createDirectory(at: resume, withIntermediateDirectories: true)
        try Data("blob".utf8).write(to: resume.appendingPathComponent("song_1.resume"))
        let store = MusicDownloadStore()

        store.deleteAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: resume.path),
                       "a resume blob with the account's credentials survived the purge")
    }

    /// The purge forgets downloads in flight, failed ones and recorded collections, and a
    /// background download that finishes after it does not bring the old account's file and
    /// manifest row back (C2-11).
    func testDeleteAllForgetsPendingStateAndDropsALateBackgroundCompletion() throws {
        let store = MusicDownloadStore()
        let running = NavidromeSong(id: "song-running", title: "Running", artist: "Artist")
        let failed = NavidromeSong(id: "song-failed", title: "Failed", artist: "Artist")
        store.noteBackgroundRestored(running)
        store.noteBackgroundFailure(failed)
        store.registerCollection(kind: "playlist", id: "p1", trackIDs: [running.id, failed.id])

        store.deleteAll()

        XCTAssertTrue(store.inFlight.isEmpty)
        XCTAssertTrue(store.downloadProgress.isEmpty)
        XCTAssertTrue(store.failedDownloads.isEmpty)
        XCTAssertTrue(store.downloadedCollections.isEmpty)
        XCTAssertTrue(MusicDownloadStore().downloadedCollections.isEmpty, "the collections file survived the purge")

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("late-\(UUID().uuidString)")
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "Fixtures/stream-fixture.mp3", withExtension: nil)))
            .write(to: temp)
        let response = HTTPURLResponse(url: URL(string: "https://music.example/rest/download?id=song-running")!,
                                       statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "audio/mpeg"])!
        store.completeBackgroundDownload(song: running, temp: temp, response: response)

        XCTAssertFalse(store.isDownloaded(running.id), "a download finished after the purge was written back")
        XCTAssertTrue(files(matching: "Artist - Running").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }

    /// The purge cancels the background session's own tasks, so a download that would have
    /// finished after a suspension or a relaunch (which only the session remembers) never runs
    /// to the end, and a task from before the purge cannot finish a later download of the same
    /// song with the old account's bytes (C2-11).
    func testDeleteAllCancelsBackgroundTasksAndAnOldTaskCannotFinishANewDownload() async throws {
        let store = try downloadingStore()
        StubStream.stall = true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubStream.self]
        let engine = BackgroundDownloadEngine(configuration: configuration)
        store.backgroundEngine = engine
        let song = NavidromeSong(id: "https://cdn.example/b.mp3", title: "B", artist: "A")
        let enqueued = await store.download(song)
        XCTAssertTrue(enqueued)
        let running = await engine.unfinishedTasks().count
        XCTAssertEqual(running, 1)

        store.deleteAll()

        var remaining = await engine.unfinishedTasks().count
        for _ in 0 ..< 50 where remaining > 0 {
            try await Task.sleep(nanoseconds: 100_000_000)
            remaining = await engine.unfinishedTasks().count
        }
        XCTAssertEqual(remaining, 0, "the background task outlived the purge")

        // The same song is downloaded again for the next account, and the old task's bytes
        // arrive (its completion was already queued, or it was restored after a relaunch).
        let again = await store.download(song)
        XCTAssertTrue(again)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("old-\(UUID().uuidString)")
        try StubStream.body.write(to: temp)
        let response = HTTPURLResponse(url: URL(string: song.id)!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "audio/mpeg"])!
        store.completeBackgroundDownload(song: song, temp: temp, response: response)
        XCTAssertFalse(store.isDownloaded(song.id), "a task from before the purge finished the new download")
        XCTAssertTrue(store.isDownloading(song.id), "the new download stopped waiting for its own task")
    }
}
#endif
