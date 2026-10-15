#if !os(watchOS)
import Foundation
import XCTest
@testable import BatonPlaybackKit
@testable import BatonSubsonicKit

/// Audio Baton can get again stays out of iPhone backups; what it cannot get again stays in
/// (DOC-24, `specs/document-clippings.md`, *Storage → Backups*).
///
/// The production call is iOS-only, but `isExcludedFromBackup` is a real resource value on the
/// Mac too, so every test here sets and reads the flag on real files. The stores take the
/// decision as an init argument so the iPhone's behaviour is exercised on the Mac, and the Mac's
/// own default (nothing excluded, Time Machine keeps the library) is pinned separately.
///
/// The failure this guards against hardest is the opposite of the feature: a sidecar excluded by
/// mistake. A restored phone would then have audio with no title, source or text, which nothing
/// can identify, so every store test asserts the sidecars and manifests are still backed up.
@MainActor
final class BackupExclusionTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        BatonStorage.defaults.removeObject(forKey: MusicDownloadStore.folderKey)
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func file(_ name: String, in folder: URL? = nil, bytes: Int = 2048) -> URL {
        let url = (folder ?? dir).appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x41, count: bytes))
        return url
    }

    private func staged(ext: String = "m4a") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-staged-\(UUID().uuidString).\(ext)")
        try Data(repeating: 0x41, count: 2048).write(to: url)
        return url
    }

    private func excludedNames(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { BackupExclusion.isExcluded(folder.appendingPathComponent($0)) }
            .sorted()
    }

    // MARK: - The decision: which files are audio

    func testAudioIsDecidedByExtensionAndMetadataIsNeverAudio() {
        for name in ["a.m4a", "a.MP3", "a.wav", "a.flac", "a.caf", "a.m4b", "a.aiff", "a.opus"] {
            XCTAssertTrue(BackupExclusion.isAudio(URL(fileURLWithPath: "/x/\(name)")), "\(name) is audio")
        }
        // A sidecar, its quarantined copy, the clippings tombstones, the download manifest and
        // metadata, a resume blob: every one is the only record of something and must stay backed up.
        for name in ["id.json", "id.json.corrupt-1759500000", "dismissed.json",
                     MusicDownloadStore.manifestName, MusicDownloadStore.metaName,
                     MusicDownloadStore.collectionsName, "song.resume", "notes.txt", "noextension"] {
            XCTAssertFalse(BackupExclusion.isAudio(URL(fileURLWithPath: "/x/\(name)")), "\(name) is not audio")
        }
    }

    /// The sweep a store runs over its own directory: top-level audio files only. A directory
    /// that happens to end in `.m4a` is not a file to flag, and a subdirectory is not the store's.
    func testAudioFilesInADirectoryAreItsTopLevelAudioOnly() throws {
        file("abc.m4a")
        file("abc.json")
        file("abc.json.corrupt-1759500000")
        file("dismissed.json")
        file("def.wav")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("odd.m4a"),
                                                withIntermediateDirectories: true)
        let nested = dir.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        file("deep.wav", in: nested)

        XCTAssertEqual(BackupExclusion.audioFiles(in: dir).map(\.lastPathComponent), ["abc.m4a", "def.wav"])
    }

    // MARK: - The flag, on real files

    func testExcludingSetsTheFlagOnceAndReportsIt() {
        let audio = file("a.m4a")
        XCTAssertFalse(BackupExclusion.isExcluded(audio), "a fresh file is backed up")

        XCTAssertTrue(BackupExclusion.exclude(audio), "the first call sets the flag")
        XCTAssertTrue(BackupExclusion.isExcluded(audio))
        XCTAssertFalse(BackupExclusion.exclude(audio), "already excluded: nothing newly set")

        XCTAssertFalse(BackupExclusion.exclude(dir.appendingPathComponent("missing.m4a")),
                       "a missing file is not reported as excluded")
    }

    /// `adopt` and a finished download both move a file into place. The flag is set after the
    /// move, but a clipping renamed or a download re-filed later would lose it if a rename did
    /// not carry it. On one volume it does; pinned so a change of mechanism is noticed.
    func testARenameWithinTheVolumeKeepsTheFlag() throws {
        let audio = file("before.m4a")
        BackupExclusion.exclude(audio)
        let moved = dir.appendingPathComponent("after.m4a")
        try FileManager.default.moveItem(at: audio, to: moved)
        XCTAssertTrue(BackupExclusion.isExcluded(moved))
    }

    /// The Mac keeps everything in Time Machine. If this ever reads true on the Mac, a music
    /// library silently drops out of the owner's backups.
    func testOnlyTheIPhoneExcludesAnything() {
        #if os(iOS)
        XCTAssertTrue(BackupExclusion.appliesOnThisPlatform)
        #else
        XCTAssertFalse(BackupExclusion.appliesOnThisPlatform)
        #endif
    }

    // MARK: - Clippings

    func testAnAdoptedClippingsAudioIsExcludedAndItsSidecarIsNot() throws {
        let store = ClippingStore(directory: dir, excludesAudioFromBackup: true)
        let item = try store.adopt(try staged(), title: "A reading", text: "The words")

        XCTAssertTrue(BackupExclusion.isExcluded(item.url), "the audio can be rendered again")
        XCTAssertFalse(BackupExclusion.isExcluded(dir.appendingPathComponent("\(item.id).json")),
                       "the sidecar holds the title and text: losing it on restore orphans the audio")
        XCTAssertEqual(excludedNames(in: dir), [item.url.lastPathComponent])
    }

    /// A book chapter is a clipping, so book audio on the phone is covered by the same rule.
    func testABookChaptersAudioIsExcluded() throws {
        let store = ClippingStore(directory: dir, excludesAudioFromBackup: true)
        let chapter = ClippingStore.BookChapter(documentID: "doc-1", documentTitle: "The Machine Stops",
                                                author: "E. M. Forster", chapterIndex: 0,
                                                chapterTitle: "The Air-Ship")
        let item = try store.adopt(try staged(ext: "wav"), title: "The Air-Ship", chapter: chapter)
        XCTAssertTrue(BackupExclusion.isExcluded(item.url))
        XCTAssertEqual(excludedNames(in: dir), [item.url.lastPathComponent])
    }

    /// An existing install has clippings that are backed up today. The first launch with this
    /// build marks their audio, and leaves every sidecar and the tombstone file alone.
    func testClippingsAlreadyOnDiskAreExcludedAtLaunch() throws {
        let before = ClippingStore(directory: dir, excludesAudioFromBackup: false)
        let first = try before.adopt(try staged(), title: "Older reading", sha256: "d1")
        let second = try before.adopt(try staged(ext: "wav"), title: "Another")
        before.dismiss(sha256: "gone")
        XCTAssertEqual(excludedNames(in: dir), [], "precondition: nothing excluded yet")

        _ = ClippingStore(directory: dir, excludesAudioFromBackup: true)

        XCTAssertEqual(excludedNames(in: dir),
                       [first.url.lastPathComponent, second.url.lastPathComponent].sorted())
        XCTAssertFalse(BackupExclusion.isExcluded(dir.appendingPathComponent("dismissed.json")))
    }

    func testTheMacExcludesNoClippingAudio() throws {
        #if os(macOS)
        let store = ClippingStore(directory: dir)
        let item = try store.adopt(try staged(), title: "A reading")
        XCTAssertFalse(BackupExclusion.isExcluded(item.url), "Time Machine keeps clippings on the Mac")
        #endif
    }

    // MARK: - Downloads

    private func fixtureMP3() throws -> URL {
        let fixture = try XCTUnwrap(Bundle.module.url(
            forResource: "stream-fixture", withExtension: "mp3", subdirectory: "Fixtures"))
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-download-\(UUID().uuidString).tmp")
        try FileManager.default.copyItem(at: fixture, to: temp)
        return temp
    }

    private func audioResponse() -> URLResponse {
        HTTPURLResponse(url: URL(string: "https://music.example.com/rest/stream.view")!,
                        statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "audio/mpeg"])!
    }

    private func useDownloadFolder() {
        BatonStorage.defaults.set(dir.path, forKey: MusicDownloadStore.folderKey)
    }

    func testAFinishedDownloadIsExcludedAndItsManifestIsNot() throws {
        useDownloadFolder()
        let store = MusicDownloadStore(excludesAudioFromBackup: true)
        let song = NavidromeSong(id: "song-1", title: "Kelly Watch the Stars", artist: "Air",
                                 album: "Moon Safari", duration: 68, coverArtID: nil)

        try store.finalizeDownload(of: song, temp: try fixtureMP3(), response: audioResponse())

        let local = try XCTUnwrap(store.localURL(for: "song-1"))
        XCTAssertTrue(BackupExclusion.isExcluded(local), "a download is a copy of what the server has")
        XCTAssertEqual(excludedNames(in: dir), [local.lastPathComponent],
                       "the manifest and metadata name the files and must stay backed up")
    }

    /// Downloads already on disk are marked at launch, but only the ones Baton can attribute to
    /// itself. A download folder can be pointed at the owner's own music, and those files
    /// are theirs: they must not drop out of the backup because they sit beside Baton's.
    func testDownloadsAlreadyOnDiskAreExcludedAtLaunchAndTheOwnersOwnFilesAreNot() throws {
        useDownloadFolder()
        file("Air - Kelly Watch the Stars.mp3")
        file("My Own Recording.mp3")
        try Data(#"{"version":1,"payload":{"song-1":"Air - Kelly Watch the Stars.mp3"}}"#.utf8)
            .write(to: dir.appendingPathComponent(MusicDownloadStore.manifestName))

        let store = MusicDownloadStore(excludesAudioFromBackup: true)

        XCTAssertEqual(store.downloadedIDs, ["song-1"], "precondition: the manifest was read")
        XCTAssertEqual(excludedNames(in: dir), ["Air - Kelly Watch the Stars.mp3"])
    }

    func testTheMacExcludesNoDownloads() throws {
        #if os(macOS)
        useDownloadFolder()
        let store = MusicDownloadStore()
        let song = NavidromeSong(id: "song-2", title: "Aerodynamic", artist: "Daft Punk",
                                 album: "Discovery", duration: 68, coverArtID: nil)
        try store.finalizeDownload(of: song, temp: try fixtureMP3(), response: audioResponse())
        XCTAssertEqual(excludedNames(in: dir), [], "Time Machine keeps downloads on the Mac")
        #endif
    }
}
#endif
