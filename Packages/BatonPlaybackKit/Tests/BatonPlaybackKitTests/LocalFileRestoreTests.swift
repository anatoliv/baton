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

    /// Only a book chapter takes that path: any other file URL keeps the stream path, where a
    /// restored place is asked of the server as `timeOffset` (StreamSeekControllerTests stand in
    /// for streams with file URLs).
    func testOnlyABookChapterOpensAtItsStartOtherFilesKeepTheStreamPath() async throws {
        _ = makeController()   // writes the files
        XCTAssertTrue(chapters()[0].isBookChapterFile)
        XCTAssertFalse(plainFiles()[0].isBookChapterFile)
        var stream = NavidromeSong(id: "stream-id", title: "s", artist: "Reader", album: nil, duration: 20, coverArtID: nil)
        stream.genre = ClippingStore.bookChapterGenre
        XCTAssertFalse(stream.isBookChapterFile, "a chapter-shaped song that is not a file is not one")

        let before = makeController()
        before.play(plainFiles(), startAt: 0)
        try await wait(8) { before.duration > 1 }
        before.seek(to: 12)
        try await wait(5) { before.currentTime >= 12.2 }
        before.pause()
        before.persistQueueForTesting()

        let after = makeController()
        after.restoreQueue()
        XCTAssertEqual(after.streamStartOffsetForTesting, 12, accuracy: 0.5, "a plain file keeps the stream offset")
        XCTAssertTrue(after.lastStreamURLForTesting?.query?.contains("timeOffset=12") ?? false,
                      "and asks for the place as timeOffset: \(String(describing: after.lastStreamURLForTesting))")
        after.stop()
    }
}
