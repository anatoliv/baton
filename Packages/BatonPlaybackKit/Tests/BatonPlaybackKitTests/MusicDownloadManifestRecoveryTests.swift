#if !os(watchOS)
import XCTest
@testable import BatonPlaybackKit
@testable import BatonSubsonicKit

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
}
#endif
