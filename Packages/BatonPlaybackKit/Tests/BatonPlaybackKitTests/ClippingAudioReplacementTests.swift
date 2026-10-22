import AVFoundation
import XCTest
import BatonSubsonicModels
@testable import BatonPlaybackKit

/// A chapter given a new voice is heard in it without a restart.
///
/// Owner report, 2026-10-17: "after changing the voice, the old voices stays active until
/// application is restarted". Change Voice replaces each chapter's file under the same name
/// (`ClippingStore.replaceAudio`), but the player kept the `AVPlayerItem`s it had already made
/// from the old files: the chapter it was on (paused, stopped or playing) and the gapless next
/// chapter it had queued at the start of the current one. An open file outlives its name, so
/// both played the old voice, the next chapter in full, until a relaunch rebuilt the queue.
///
/// Each test hears which audio the player holds through the items' own assets: the old voice
/// is 20 s long and the new one 40 s.
@MainActor
final class ClippingAudioReplacementTests: XCTestCase {
    private let suiteName = "io.tonebox.tests.clippingaudioreplacement"
    private lazy var suite: UserDefaults = {
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }()
    private var directory: URL!
    private var store: ClippingStore!
    private var chapters: [ClippingStore.Item] = []
    private var controller: StreamingPlaybackController?

    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("revoice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ClippingStore(directory: directory.appendingPathComponent("clippings"), defaults: suite,
                              excludesAudioFromBackup: false)
        chapters = try (0..<2).map { index in
            try store.adopt(wav(seconds: 20, frequency: 220 * Double(index + 1)), title: "Chapter \(index + 1)",
                            sourceName: "Reader", durationSeconds: 20, text: "Words.",
                            chapter: .init(documentID: "doc-1", documentTitle: "The Book", author: "Reader",
                                           chapterIndex: index, chapterTitle: "Chapter \(index + 1)"),
                            voice: "kokoro:af_heart")
        }
    }

    override func tearDown() async throws {
        controller?.stop()
        controller = nil
        try? FileManager.default.removeItem(at: directory)
        suite.removePersistentDomain(forName: suiteName)
    }

    private func wav(seconds: Double, frequency: Double) throws -> URL {
        let url = directory.appendingPathComponent("staged-\(UUID().uuidString).wav")
        try EngineTestSignals.sineWAV(frequency: frequency, seconds: seconds).write(to: url)
        return url
    }

    private func makeController() -> StreamingPlaybackController {
        let c = StreamingPlaybackController(streamURLProvider: { URL(string: $0)! }, defaults: suite, systemNowPlaying: false)
        c.gaplessEnabled = true
        c.crossfadeSeconds = 0
        c.setVolume(percent: 0)
        controller = c
        return c
    }

    private func wait(_ seconds: Double, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    /// Chapter `index` made again in the new voice, as `BookVoiceChanges.replace` does it.
    private func revoice(_ index: Int) throws {
        try store.replaceAudio(id: chapters[index].id, with: wav(seconds: 40, frequency: 880),
                               durationSeconds: 40, sha256: "new-\(index)", voice: "kokoro:af_sky")
    }

    private func playBook() async throws -> StreamingPlaybackController {
        let c = makeController()
        c.play(chapters.map(\.asSong), startAt: 0)
        try await wait(8) { c.itemDurationsForTesting.current != nil }
        XCTAssertEqual(c.itemDurationsForTesting.current ?? 0, 20, accuracy: 0.5, "chapter 1 starts in the old voice")
        return c
    }

    /// Paused part way through a chapter, the voice changes: Resume plays the new audio at the
    /// same place in the chapter (the same share of it), not the rest of the old file.
    func testAPausedChapterResumesInTheNewVoiceAtTheSamePlace() async throws {
        let c = try await playBook()
        c.seek(to: 5)
        try await wait(5) { c.currentTime >= 5.2 }
        c.pause()
        let left = c.currentTime

        try revoice(0)
        try await wait(8) { (c.itemDurationsForTesting.current ?? 0) > 30 }
        XCTAssertEqual(c.itemDurationsForTesting.current ?? 0, 40, accuracy: 0.5, "the player holds the new audio")
        // The new item opens at its start and seeks to the place once it is ready.
        try await wait(5) { abs(c.currentTime - left * 2) < 0.6 }
        XCTAssertEqual(c.state, .paused, "still paused: a voice change does not start playback")
        XCTAssertEqual(c.currentTime, left * 2, accuracy: 0.6, "the same place in the chapter, in its new length")
        XCTAssertEqual(c.nowPlaying?.duration, 40, "the queue knows the chapter's new length")
    }

    /// Playing through a chapter when its new audio lands: it goes on in the new voice from the
    /// same place, rather than playing the old file to its end.
    func testAPlayingChapterSwitchesToTheNewVoiceInPlace() async throws {
        let c = try await playBook()
        c.seek(to: 4)
        try await wait(5) { c.currentTime >= 4.2 }

        try revoice(0)
        try await wait(8) { (c.itemDurationsForTesting.current ?? 0) > 30 }
        XCTAssertEqual(c.itemDurationsForTesting.current ?? 0, 40, accuracy: 0.5)
        XCTAssertEqual(c.state, .playing, "playback carries on")
        try await wait(5) { c.currentTime > 8 }
        XCTAssertGreaterThan(c.currentTime, 8, "about twice as far into the longer chapter, still moving")
        XCTAssertEqual(c.nowPlaying?.title, "Chapter 1")
    }

    /// The gapless next chapter is queued at the start of the current one. Made again while the
    /// current one plays, it is heard in the new voice when the book reaches it.
    func testTheQueuedNextChapterIsHeardInTheNewVoice() async throws {
        let c = try await playBook()
        try await wait(5) { c.gaplessPreloadIndexForTesting == 1 && c.itemDurationsForTesting.next != nil }
        XCTAssertEqual(c.itemDurationsForTesting.next ?? 0, 20, accuracy: 0.5, "chapter 2 queued in the old voice")

        try revoice(1)
        try await wait(8) { (c.itemDurationsForTesting.next ?? 0) > 30 }
        XCTAssertEqual(c.itemDurationsForTesting.next ?? 0, 40, accuracy: 0.5, "the queued item is the new audio")

        // Play into chapter 2 across the gapless boundary.
        c.seek(to: 18.5)
        try await wait(10) { c.currentIndex == 1 }
        XCTAssertEqual(c.currentIndex, 1)
        // Logical advancement can precede AVQueuePlayer.currentItem changing. Wait for
        // the replacement asset, not the previous chapter's already-known duration.
        try await wait(5) { (c.itemDurationsForTesting.current ?? 0) > 30 }
        XCTAssertEqual(c.itemDurationsForTesting.current ?? 0, 40, accuracy: 0.5, "chapter 2 plays in the new voice")
    }

    /// Stopped, then the voice changes: Play starts the chapter in the new voice.
    func testAStoppedChapterPlaysInTheNewVoice() async throws {
        let c = try await playBook()
        c.stop()

        try revoice(0)
        c.resume()
        try await wait(8) { (c.itemDurationsForTesting.current ?? 0) > 30 && c.state == .playing }
        XCTAssertEqual(c.itemDurationsForTesting.current ?? 0, 40, accuracy: 0.5)
        XCTAssertEqual(c.state, .playing)
    }

    /// Stop on a Change Voice puts the old audio back the same way, and the player follows it.
    func testPuttingTheOldVoiceBackIsHeardToo() async throws {
        let c = try await playBook()
        c.pause()
        let hold = directory.appendingPathComponent("hold")
        let (_, previous) = try store.replaceAudio(id: chapters[0].id, with: wav(seconds: 40, frequency: 880),
                                                   durationSeconds: 40, sha256: "new", voice: "kokoro:af_sky",
                                                   holdingPreviousIn: hold)
        try await wait(8) { (c.itemDurationsForTesting.current ?? 0) > 30 }
        XCTAssertEqual(c.itemDurationsForTesting.current ?? 0, 40, accuracy: 0.5, "in the new voice first")
        let old = try XCTUnwrap(previous)
        try store.replaceAudio(id: chapters[0].id, with: hold.appendingPathComponent(old.file),
                               durationSeconds: old.durationSeconds, sha256: old.sha256, voice: old.voice)
        try await wait(8) { (c.itemDurationsForTesting.current ?? 99) < 30 }
        XCTAssertEqual(c.itemDurationsForTesting.current ?? 0, 20, accuracy: 0.5, "back in the old voice")
    }

    /// A kept reading read again in another voice (the Mac's Change Voice on a reading) is a file
    /// on this device but not a book chapter: it too opens at its start and seeks to the place,
    /// rather than asking a file for a stream offset nothing honours, which played the new voice
    /// from 0:00 under a playhead that said otherwise (review of TBX-1000000105).
    func testAPausedReadingResumesInTheNewVoiceAtTheSamePlace() async throws {
        let reading = try store.adopt(wav(seconds: 20, frequency: 330), title: "Ghostty reading", sourceName: "Ghostty",
                                      durationSeconds: 20, text: "Words.", voice: "kokoro:af_heart")
        XCTAssertFalse(reading.asSong.isBookChapterFile)
        let c = makeController()
        c.play([reading.asSong], startAt: 0)
        try await wait(8) { c.itemDurationsForTesting.current != nil }
        c.seek(to: 5)
        try await wait(5) { c.currentTime >= 5.2 }
        c.pause()
        let left = c.currentTime

        try store.replaceAudio(id: reading.id, with: wav(seconds: 40, frequency: 880), durationSeconds: 40,
                               sha256: "new", voice: "kokoro:af_sky")
        try await wait(8) { (c.itemDurationsForTesting.current ?? 0) > 30 }
        XCTAssertEqual(c.itemDurationsForTesting.current ?? 0, 40, accuracy: 0.5, "the player holds the new audio")
        XCTAssertEqual(c.streamStartOffsetForTesting, 0, "opened at its start, not as a stream from the place")
        XCTAssertFalse(c.lastStreamURLForTesting?.query?.contains("timeOffset") ?? false,
                       "no stream offset on a file: \(String(describing: c.lastStreamURLForTesting))")
        try await wait(5) { abs(c.currentTime - left * 2) < 0.6 }
        XCTAssertEqual(c.currentTime, left * 2, accuracy: 0.6, "the same place in the reading")
        c.resume()
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertEqual(c.currentTime, left * 2 + 1.5, accuracy: 0.7, "and it plays on from there, the item's own clock")
    }

    /// A reading whose new audio is another kind of file has another URL, so another id in the
    /// queue: the queue follows it rather than keep a file that is gone.
    func testANewFileKindMovesTheQueueToTheNewURL() async throws {
        let c = try await playBook()
        c.pause()
        let staged = directory.appendingPathComponent("staged-\(UUID().uuidString).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 40))
        buffer.frameLength = buffer.frameCapacity
        try AVAudioFile(forWriting: staged, settings: format.settings).write(from: buffer)
        let (replaced, _) = try store.replaceAudio(id: chapters[0].id, with: staged, durationSeconds: 40,
                                                   sha256: "new", voice: "kokoro:af_sky")
        XCTAssertNotEqual(replaced.url, chapters[0].url)
        try await wait(8) { c.nowPlaying?.id == replaced.asSong.id }
        XCTAssertEqual(c.nowPlaying?.id, replaced.asSong.id)
        XCTAssertEqual(c.queue.map(\.id), [replaced.asSong.id, chapters[1].asSong.id])
    }

    /// Change Voice without a hold removed the old audio before moving the new file in, so a
    /// failed move left the clipping with no audio (TBX-1000000506, C2-17).
    func testAFailedReplacementWithoutAHoldKeepsTheOldAudio() throws {
        let item = try XCTUnwrap(store.item(id: chapters[0].id))
        let before = try Data(contentsOf: item.url)
        let missing = directory.appendingPathComponent("never-made-\(UUID().uuidString).wav")
        XCTAssertThrowsError(try store.replaceAudio(id: chapters[0].id, with: missing, durationSeconds: 40,
                                                    sha256: nil, voice: "kokoro:am_adam"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path), "the clipping was left with no audio")
        XCTAssertEqual(try Data(contentsOf: item.url), before)
    }

    /// A ledger that could not be encoded (a NaN book position) was written as nil, which
    /// removed the key and every title, tombstone and place in it (TBX-1000000506, C2-18).
    func testALedgerThatCannotBeEncodedLeavesTheStoredOneAlone() throws {
        var ledger = store.ledger
        ledger.setPosition(documentID: "doc-1", chapterIndex: 1, seconds: 12)
        store.ledger = ledger
        let stored = try XCTUnwrap(suite.data(forKey: ClippingLedger.storageKey))
        ledger.setPosition(documentID: "doc-1", chapterIndex: 1, seconds: .nan)
        store.ledger = ledger
        XCTAssertEqual(suite.data(forKey: ClippingLedger.storageKey), stored, "the ledger key was removed")
    }

    /// An unreadable stored ledger is kept aside before a write replaces it.
    func testAnUnreadableLedgerIsKeptAsideBeforeItIsReplaced() {
        let garbage = Data("not a ledger".utf8)
        suite.set(garbage, forKey: ClippingLedger.storageKey)
        var ledger = store.ledger
        ledger.setPosition(documentID: "doc-2", chapterIndex: 0, seconds: 3)
        store.ledger = ledger
        XCTAssertEqual(suite.data(forKey: ClippingStore.unreadableLedgerKey), garbage)
        XCTAssertNotNil(ClippingLedger.decode(suite.data(forKey: ClippingLedger.storageKey)))
    }
}
