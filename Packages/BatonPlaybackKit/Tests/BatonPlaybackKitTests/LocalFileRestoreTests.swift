import XCTest
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// A book chapter restored at launch plays from where it was left.
///
/// Found on a Mac probe: Baton relaunched with chapter 2 of a book paused at 0:13 in the player.
/// Resume played the chapter from 0:00 while the scrubber, the book's "% heard" and Read Along
/// counted from 0:13, so the highlight ran 13 s ahead of the voice, and the playhead went on past
/// the chapter's 0:18 end without ever moving to chapter 3. The saved place had been handed to
/// the AVPlayer deck as a server `timeOffset`, which a file on this device does not have.
@MainActor
final class LocalFileRestoreTests: XCTestCase {
    private let suiteName = "io.tonebox.tests.localfilerestore"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()
    private var files: [String: URL] = [:]

    override func tearDown() {
        for url in files.values { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    private func makeController() -> StreamingPlaybackController {
        if files.isEmpty {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("restore-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (n, id) in ["ch1", "ch2"].enumerated() {
                let url = dir.appendingPathComponent("\(id).wav")
                try? EngineTestSignals.sineWAV(frequency: 220 * Double(n + 1), seconds: 20).write(to: url)
                files[id] = url
            }
        }
        let c = StreamingPlaybackController(streamURLProvider: { URL(string: $0)! }, defaults: suite, systemNowPlaying: false)
        c.gaplessEnabled = true
        c.crossfadeSeconds = 0
        c.setVolume(percent: 0)
        return c
    }

    /// Book chapters, as `ClippingStore.Item.asSong` makes them: their id is their file URL and
    /// their genre says they are a chapter.
    private func chapters() -> [NavidromeSong] {
        ["ch1", "ch2"].map { id in
            var song = NavidromeSong(id: files[id]!.absoluteString, title: id, artist: "Reader", album: nil,
                                     duration: 20, coverArtID: nil)
            song.genre = ClippingStore.bookChapterGenre
            return song
        }
    }

    /// The same files as plain local tracks, not chapters.
    private func plainFiles() -> [NavidromeSong] {
        ["ch1", "ch2"].map { NavidromeSong(id: files[$0]!.absoluteString, title: $0, artist: "Reader", album: nil,
                                           duration: 20, coverArtID: nil) }
    }

    private func wait(_ seconds: Double, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    func testAChapterRestoredAtLaunchResumesWhereItWasLeft() async throws {
        // The session before: chapter 1 paused at 12 s, and the queue kept.
        let before = makeController()
        before.play(chapters(), startAt: 0)
        try await wait(8) { before.duration > 1 }
        before.seek(to: 12)
        try await wait(5) { before.currentTime >= 12.2 }
        before.pause()
        before.persistQueueForTesting()
        let left = before.currentTime
        // Left paused, as at quit: Stop would rewind and save 0:00.

        // The next launch: restored paused at that place, then Resume.
        let after = makeController()
        after.restoreQueue()
        XCTAssertEqual(after.currentTime, left, accuracy: 0.05, "restored at the place it was left")
        XCTAssertEqual(after.streamStartOffsetForTesting, 0, "a file on this device is opened at its start, not as a stream from the place")
        XCTAssertFalse(after.lastStreamURLForTesting?.query?.contains("timeOffset") ?? false,
                       "no server offset on a file: \(String(describing: after.lastStreamURLForTesting))")
        try await wait(5) { after.duration > 1 }
        try await Task.sleep(for: .milliseconds(500))   // the item ready, and the seek to the place applied
        after.resume()
        try await Task.sleep(for: .milliseconds(1_500))
        defer { after.stop() }
        // With no stream offset the playhead is the item's own clock, so this is where the audio is.
        XCTAssertEqual(after.currentTime, left + 1.5, accuracy: 0.6, "the chapter plays on from \(left) s")
        XCTAssertEqual(after.nowPlaying?.title, "ch1")
    }

    /// Every file on this device opens at its start, not only a book chapter.
    ///
    /// A download is always a `file://` URL and has no server behind it to honour `timeOffset`.
    /// Handed the saved place as one, the AVPlayer deck played the file from 0:00 while counting
    /// the playhead from the place: restored at 8 s of a 12 s track, seven seconds after Resume
    /// the clock read 15 s on a 12 s track, still on the first track and still playing.
    func testAPlainFileRestoredAtLaunchResumesWhereItWasLeftAndMovesOn() async throws {
        let tracks = try shortFiles(seconds: 12)
        let before = makeController()
        before.play(tracks, startAt: 0)
        try await wait(8) { before.duration > 1 }
        before.seek(to: 8)
        try await wait(5) { before.currentTime >= 8.1 }
        before.pause()
        before.persistQueueForTesting()

        let after = makeController()
        after.restoreQueue()
        defer { after.stop() }
        XCTAssertEqual(after.currentTime, 8, accuracy: 0.6, "restored at the place it was left")
        XCTAssertEqual(after.streamStartOffsetForTesting, 0, "a file is opened at its start, not as a stream from the place")
        XCTAssertFalse(after.lastStreamURLForTesting?.query?.contains("timeOffset") ?? false,
                       "no server offset on a file: \(String(describing: after.lastStreamURLForTesting))")
        try await wait(5) { after.duration > 1 }
        try await Task.sleep(for: .milliseconds(500))   // the item ready, and the seek to the place applied
        after.resume()
        try await Task.sleep(for: .seconds(7))
        XCTAssertEqual(after.nowPlaying?.title, "b", "4 s were left of the first track; 7 s after Resume the second plays")
        XCTAssertLessThan(after.currentTime, 6, "the playhead is the second track's own clock")
    }

    /// The inverse of what 98b43e73 asserted: a plain file restored at a place keeps no stream
    /// offset and asks for no `timeOffset`, exactly like a book chapter.
    func testAPlainFileOpensAtItsStartLikeABookChapter() async throws {
        _ = makeController()   // writes the files
        XCTAssertFalse(plainFiles()[0].isBookChapterFile)
        let before = makeController()
        before.play(plainFiles(), startAt: 0)
        try await wait(8) { before.duration > 1 }
        before.seek(to: 12)
        try await wait(5) { before.currentTime >= 12.2 }
        before.pause()
        before.persistQueueForTesting()

        let after = makeController()
        after.restoreQueue()
        defer { after.stop() }
        XCTAssertEqual(after.streamStartOffsetForTesting, 0, "a plain file keeps no stream offset")
        XCTAssertFalse(after.lastStreamURLForTesting?.query?.contains("timeOffset") ?? false,
                       "and asks for no timeOffset: \(String(describing: after.lastStreamURLForTesting))")
        XCTAssertEqual(after.currentTime, 12, accuracy: 0.6, "while the clock shows the place")
    }

    /// A client-side podcast episode is a third-party enclosure URL. Its host has never heard of
    /// `timeOffset`, so a restored episode opens at its start and seeks to the place, the same as
    /// a file. The fixture serves a real MP3 with byte ranges, as a static enclosure host does.
    func testARestoredPodcastEpisodeOpensAtItsStartAndSeeksToThePlace() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/stream-fixture.mp3", withExtension: nil))
        let server = try EngineHTTPServer(payload: try Data(contentsOf: fixture),
                                          delivery: .rangeCapable(bytesPerSecond: 8_000_000))
        defer { server.stop() }
        let episodeURL = server.url.absoluteString + "/episode.mp3"
        let episode = NavidromeSong(id: episodeURL, title: "Episode", artist: "Show", album: nil,
                                    duration: 68, coverArtID: nil)
        let before = makeController()
        before.play([episode], startAt: 0)
        try await wait(8) { before.duration > 1 && before.currentTime > 0.2 }
        before.seek(to: 30)
        try await wait(5) { before.currentTime >= 30.1 }
        XCTAssertGreaterThanOrEqual(before.currentTime, 30, "the episode played and reached the place")
        before.pause()
        before.persistQueueForTesting()

        let after = makeController()
        after.restoreQueue()
        defer { after.stop() }
        XCTAssertEqual(after.currentTime, 30, accuracy: 0.6, "restored at the place it was left")
        XCTAssertEqual(after.streamStartOffsetForTesting, 0, "an enclosure is opened at its start")
        XCTAssertEqual(after.lastStreamURLForTesting?.absoluteString, episodeURL,
                       "the enclosure URL is fetched as it is, with no timeOffset added")
        try await wait(5) { after.duration > 1 }
        try await Task.sleep(for: .milliseconds(800))   // ready, paused, and the seek to the place asked for
        after.resume()
        // The seek over HTTP re-buffers from the place, so wait for the clock to move rather
        // than for a fixed time, and watch that it never falls back to the top on the way.
        var lowest = after.currentTime
        try await wait(8) {
            lowest = min(lowest, after.currentTime)
            return after.currentTime > 31
        }
        XCTAssertGreaterThan(after.currentTime, 31, "the episode plays on")
        XCTAssertLessThan(after.currentTime, 38, "from the place, not with an offset added")
        XCTAssertGreaterThan(lowest, 29, "the clock went back to the top: the audio played from 0:00")
        XCTAssertEqual(after.nowPlaying?.title, "Episode")
    }

    /// A file shorter than its metadata ends early. The early-end guard reloads it at the
    /// playhead, which for a file means opening at 0 and seeking there: past its real end, so
    /// it ends again. The seek restoring that place refilled the guard's budget, and the track
    /// reloaded for good instead of moving on.
    func testAFileShorterThanItsMetadataMovesOnInsteadOfReloadingForever() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("short-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        files["short-dir"] = dir
        let short = dir.appendingPathComponent("short.wav"), next = dir.appendingPathComponent("next.wav")
        try EngineTestSignals.sineWAV(frequency: 440, seconds: 1).write(to: short)
        try EngineTestSignals.sineWAV(frequency: 660, seconds: 10).write(to: next)
        let songs = [NavidromeSong(id: short.absoluteString, title: "short", artist: "A", album: nil, duration: 30, coverArtID: nil),
                     NavidromeSong(id: next.absoluteString, title: "next", artist: "A", album: nil, duration: 10, coverArtID: nil)]
        let c = makeController()
        c.gaplessEnabled = false
        defer { c.stop() }
        c.play(songs)
        try await wait(15) { c.nowPlaying?.title == "next" }
        XCTAssertEqual(c.nowPlaying?.title, "next", "the short file reloaded \(c.loadCurrentCountForTesting) times instead of moving on")
        XCTAssertLessThan(c.loadCurrentCountForTesting, 10)
    }

    /// Two plain local tracks, "a" and "b", of `seconds` each.
    private func shortFiles(seconds: Double) throws -> [NavidromeSong] {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try ["a", "b"].enumerated().map { n, id in
            let url = dir.appendingPathComponent("\(id).wav")
            try EngineTestSignals.sineWAV(frequency: 220 * Double(n + 1), seconds: seconds).write(to: url)
            files["short-\(id)"] = url
            return NavidromeSong(id: url.absoluteString, title: id, artist: "Artist", album: nil,
                                 duration: Int(seconds), coverArtID: nil)
        }
    }
}
