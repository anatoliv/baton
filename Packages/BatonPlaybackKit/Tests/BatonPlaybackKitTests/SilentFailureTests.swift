import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import XCTest
@testable import BatonPlaybackKit

/// The stores that used to fail without saying so.
///
/// Each of these guards one specific way data went missing or a screen lied: the listening
/// archive erasing lines it could not read, the browse store reporting a refused sign-in as an
/// empty library, and the linked-device log deleting itself on an encode failure.
@MainActor
final class SilentFailureTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-ws3-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "io.tonebox.baton.tests.\(UUID().uuidString)")!
    }

    private func song(_ id: String) -> NavidromeSong {
        NavidromeSong(id: id, title: "Track \(id)", artist: "An Artist", duration: 200)
    }

    // MARK: - S-F11: the lifetime listening archive

    /// `load()` skipped undecodable lines with no log and no count, and `rewriteFile()` then
    /// wrote back only the lines that decoded, destroying the rest for good. This is the free
    /// alternative to Last.fm, and it was the one store that logged no write failure at all.
    func testAGarbageLineSurvivesARewrite() throws {
        let url = dir.appendingPathComponent("play-history.jsonl")
        let good = try JSONEncoder().encode(MusicPlayHistory.Entry(
            song: song("s1"), playedAt: Date(timeIntervalSince1970: 1_000_000)))
        var file = Data()
        file.append(good); file.append(0x0A)
        file.append(Data(#"{"song":{"id":"s2","title":"half a line"#.utf8)); file.append(0x0A)
        try file.write(to: url)

        let history = MusicPlayHistory(defaults: suite(),
                                       clock: { Date(timeIntervalSince1970: 2_000_000) },
                                       directory: dir)
        XCTAssertEqual(history.entries.count, 1, "the readable line loads")

        // An out-of-order insert forces the rewrite that used to erase the other line.
        history.record(song("s3"), playedAt: Date(timeIntervalSince1970: 500_000))

        let corrupt = try Data(contentsOf: url.appendingPathExtension("corrupt"))
        XCTAssertTrue(String(decoding: corrupt, as: UTF8.self).contains("half a line"),
                      "the unreadable line must be kept, not silently destroyed")

        let rewritten = try Data(contentsOf: url)
        XCTAssertTrue(String(decoding: rewritten, as: UTF8.self).contains("s1"),
                      "and the good lines are still there")
    }

    /// One-shot, not a permanent refusal to rewrite: cap compaction runs from `load()` itself,
    /// and a store that will never rewrite grows without bound.
    func testTheQuarantineHappensOnceAndDoesNotBlockLaterRewrites() throws {
        let url = dir.appendingPathComponent("play-history.jsonl")
        var file = Data()
        file.append(Data("not json at all".utf8)); file.append(0x0A)
        try file.write(to: url)

        let history = MusicPlayHistory(defaults: suite(),
                                       clock: { Date(timeIntervalSince1970: 2_000_000) },
                                       directory: dir)
        history.record(song("a"), playedAt: Date(timeIntervalSince1970: 900_000))
        history.record(song("b"), playedAt: Date(timeIntervalSince1970: 800_000))
        history.record(song("c"), playedAt: Date(timeIntervalSince1970: 700_000))

        let corrupt = try Data(contentsOf: url.appendingPathExtension("corrupt"))
        XCTAssertEqual(String(decoding: corrupt, as: UTF8.self), "not json at all\n",
                       "kept exactly once, not appended on every rewrite")
        XCTAssertEqual(history.entries.count, 3, "and the store keeps working")
    }

    func testACleanArchiveWritesNoSidecar() {
        let history = MusicPlayHistory(defaults: suite(), directory: dir)
        history.record(song("s1"), playedAt: Date(timeIntervalSince1970: 1_000))
        history.record(song("s2"), playedAt: Date(timeIntervalSince1970: 500))
        let sidecar = dir.appendingPathComponent("play-history.jsonl.corrupt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }

    // MARK: - S-F9: "signed out" must not read as "your library is empty"

    private func storeThrowing(_ error: NavidromeError) -> MusicLibraryStore {
        MusicLibraryStore(clientProvider: { throw error })
    }

    /// `albumSongs` feeds "Play album", so a failed fetch made the play button do nothing at
    /// all, with no message anywhere.
    func testAnAuthFailureOnAlbumSongsIsReportedRatherThanRenderedAsAnEmptyAlbum() async {
        let store = storeThrowing(.unauthorized)
        let songs = await store.albumSongs(id: "a1")
        XCTAssertTrue(songs.isEmpty, "there is nothing to show")
        XCTAssertNotNil(store.lastError, "but the screen must be told why, not left saying the album is empty")
    }

    func testALockedKeychainIsReportedOnTheLibraryPath() async {
        let store = storeThrowing(.credentialsUnreadable(status: -25308))
        _ = await store.artistAlbums(id: "ar1")
        XCTAssertEqual(store.lastError,
                       NavidromeError.credentialsUnreadable(status: -25308).errorDescription)
    }

    func testASubsonicWrongPasswordIsReported() async {
        let store = storeThrowing(.subsonic(code: 40, message: "Wrong username or password"))
        _ = await store.songsByGenre("Ambient")
        XCTAssertNotNil(store.lastError)
    }

    func testAFolderListingReportsARefusedSignIn() async {
        let store = storeThrowing(.unauthorized)
        let index = await store.folderRootIndex()
        XCTAssertTrue(index.items.isEmpty)
        XCTAssertNotNil(store.lastError, "no folders and no reason is the dead end this closes")
    }

    /// Deliberately not a banner. Several of these run as background prefetches for home
    /// shelves, and raising one from every LAN blip would be worse than the silence.
    func testATransportBlipDoesNotRaiseABannerFromABackgroundPrefetch() async {
        let store = storeThrowing(.transport("The network connection was lost."))
        _ = await store.albums(type: "recent", size: 10)
        XCTAssertNil(store.lastError, "browse rides out a blip by design; only auth is surfaced")
    }

    func testAServerErrorDoesNotRaiseABannerEither() async {
        let store = storeThrowing(.http(status: 500))
        _ = await store.serverRecentAlbums()
        XCTAssertNil(store.lastError)
    }

    // MARK: - S-F27: the linked-device log

    /// `UserDefaults.set(nil:)` removes the key, so `set(try? encode(...))` erased the record
    /// of every device this Mac had handed its credentials to. Security-relevant.
    func testTheLinkedDeviceLogSurvivesAndIsNotClearedByReading() {
        let defaults = suite()
        DevicePairing.LinkedDevices.record(name: "Anatoli's iPhone", defaults: defaults)
        DevicePairing.LinkedDevices.record(name: "Test iPad", defaults: defaults)
        XCTAssertEqual(DevicePairing.LinkedDevices.all(defaults: defaults).count, 2)

        DevicePairing.LinkedDevices.forget(
            DevicePairing.LinkedDevices.all(defaults: defaults)[0].id, defaults: defaults)
        XCTAssertEqual(DevicePairing.LinkedDevices.all(defaults: defaults).count, 1,
                       "forgetting one device must not take the log with it")
    }

    // MARK: - S-F27: disconnecting leaves nothing of the previous account

    /// `clear()` removed the progress file and never the server-episode registry, so up to
    /// 2,000 episode titles from the account being left survived the purge and
    /// `isServerEpisode` kept answering true for ids on a server the device had gone from.
    func testDisconnectingTakesTheServerEpisodeRegistryToo() {
        let store = PodcastProgressStore(directory: dir)
        store.loadIfNeeded()
        store.registerServerEpisodes([
            .init(id: "e1", title: "An episode", channel: "A show"),
            .init(id: "e2", title: "Another", channel: "A show"),
        ])
        XCTAssertTrue(store.isServerEpisode("e1"))

        store.clear()

        XCTAssertFalse(store.isServerEpisode("e1"),
                       "the previous account's episodes must not answer for the next one")
        XCTAssertTrue(store.serverEpisodes.isEmpty)

        let reopened = PodcastProgressStore(directory: dir)
        reopened.loadIfNeeded()
        XCTAssertTrue(reopened.serverEpisodes.isEmpty, "and they must not come back off disk")
    }

    // MARK: - S-F21: the sleep timer's ceiling

    /// `optionalInt` on the MCP surface also accepts a string, so a large number from any local
    /// client (or a model emitting one through the Music Friend tool surface) reached
    /// `minutes * 60` and trapped the whole app.
    func testTheSleepTimerIsBoundedNoMatterWhatTheToolSurfaceSends() {
        let controller = StreamingPlaybackController()
        controller.setSleepTimer(minutes: .max)
        guard let endsAt = controller.sleepTimerEndsAt else {
            return XCTFail("a clamped timer should still be armed")
        }
        let hours = endsAt.timeIntervalSinceNow / 3600
        XCTAssertLessThanOrEqual(hours, 24.1, "clamped to 24 hours")
        XCTAssertGreaterThan(hours, 23.9)
        controller.cancelSleepTimer()
    }

    func testAnOrdinarySleepTimerIsUntouched() {
        let controller = StreamingPlaybackController()
        controller.setSleepTimer(minutes: 30)
        guard let endsAt = controller.sleepTimerEndsAt else {
            return XCTFail("expected an armed timer")
        }
        XCTAssertEqual(endsAt.timeIntervalSinceNow, 1800, accuracy: 5)
        controller.cancelSleepTimer()
    }
}
