import AVFoundation
import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import XCTest
@testable import BatonPlaybackKit

/// The sleep timer while a queue of clippings plays on its own.
///
/// Pressing Play on a clipping plays it and everything after it, so a listener who sets the
/// timer is usually somewhere in the middle of a queue. Both kinds of timer have to stop there:
/// "End of chapter" at the end of the clipping that is playing, and a timed one wherever the
/// clock runs out, whichever clipping that turns out to be.
@MainActor
final class ClippingSleepTimerTests: XCTestCase {
    private var dir: URL!
    private var readings: [NavidromeSong] = []
    private var controllers: [StreamingPlaybackController] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("baton-tbx-10992-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Real files, long enough never to end by themselves during a test: a file that is not
        // there sends the player into its retry ladder, and a timer pauses only what is playing.
        // A simulated end puts the playhead at the end first (`end(_:)`): once the player has
        // loaded a file it knows its 30 s, and an end at 0:00 would be taken for a stream that
        // ran out early and re-requested instead.
        readings = []
        for n in 1 ... 3 {
            let url = try Self.silence(in: dir, named: "reading-\(n)", seconds: 30)
            readings.append(NavidromeSong(id: url.absoluteString, title: "Reading \(n)", artist: "Ghostty"))
        }
    }

    override func tearDownWithError() throws {
        controllers.forEach { $0.stop() }
        controllers = []
        try? FileManager.default.removeItem(at: dir)
    }

    private nonisolated static func silence(in dir: URL, named name: String, seconds: Double) throws -> URL {
        let url = dir.appendingPathComponent("\(name).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(8_000 * seconds))!
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
        return url
    }

    private func end(_ c: StreamingPlaybackController) {
        c.placePlayheadAtEndForTesting()
        c.simulateTrackEndedForTesting()
    }

    private func controller() -> StreamingPlaybackController {
        let c = StreamingPlaybackController(
            streamURLProvider: { URL(string: $0)! },
            coverArtURLProvider: { _ in nil },
            defaults: UserDefaults(suiteName: ThrowawayDefaults.name("tbx10992.sleep"))!,
            systemNowPlaying: false
        )
        // What both apps install: a clipping Baton made is speech (MusicModel, MobileBookPlayback).
        c.isSpokenItem = { MediaKind(id: $0.id) == .localFile }
        c.gaplessEnabled = false
        c.crossfadeSeconds = 0
        controllers.append(c)
        return c
    }

    private func waitUntil(_ condition: () -> Bool, seconds: Double = 5) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// "End of chapter" set on the middle clipping stops when that clipping ends. The next one
    /// is loaded and paused, so Play carries on from there, and nothing after it plays.
    func testEndOfChapterStopsAtTheEndOfTheClippingThatIsPlaying() {
        let c = controller()
        c.play(readings, startAt: 1)
        XCTAssertEqual(SleepTimerOptions.endLabel(for: c.nowPlaying, isSpoken: c.isSpokenNowPlaying), "End of chapter",
                       "a reading is offered the spoken choice, the same words as a book chapter")
        c.sleepAtEndOfTrack()

        end(c)

        XCTAssertEqual(c.state, .paused, "the queue stops at the end of the clipping")
        XCTAssertEqual(c.currentIndex, 2)
        XCTAssertEqual(c.nowPlaying?.id, readings[2].id, "the next clipping waits, paused")
        XCTAssertFalse(c.sleepTimerArmed)
    }

    /// A timed sleep keeps running across clippings and stops whichever one is playing then.
    func testATimedSleepStopsPartWayThroughTheQueue() {
        let c = controller()
        c.play(readings, startAt: 0)
        c.armSleepTimer(seconds: 0.3, fadeSeconds: 0.2)

        end(c)
        XCTAssertEqual(c.currentIndex, 1, "the queue moved on to the next clipping")
        XCTAssertEqual(c.state, .playing)
        XCTAssertTrue(c.sleepTimerArmed, "moving to the next clipping leaves the timer running")

        waitUntil { c.state == .paused }

        XCTAssertEqual(c.state, .paused, "the timer stopped the queue")
        XCTAssertEqual(c.currentIndex, 1, "on the clipping that was playing when it ran out")
        XCTAssertFalse(c.sleepTimerArmed)
    }

    /// The case short clippings make likely: the next one starts during the fade. Starting an
    /// item resets the fade, which used to drop the pause with it, so the queue played on at
    /// full volume with the timer gone.
    func testATimedSleepStillStopsWhenTheNextClippingStartsDuringTheFade() {
        let c = controller()
        c.play(readings, startAt: 0)
        c.armSleepTimer(seconds: 0.1, fadeSeconds: 1.0)
        waitUntil({ c.fadeMultiplier < 1 }, seconds: 3)
        XCTAssertLessThan(c.fadeMultiplier, 1, "the fade is under way")

        end(c)   // the next clipping starts mid-fade
        XCTAssertEqual(c.currentIndex, 1)

        waitUntil { c.state == .paused }

        XCTAssertEqual(c.state, .paused, "the timer still stopped the queue")
        XCTAssertEqual(c.currentIndex, 1)
        XCTAssertFalse(c.sleepTimerArmed)
        XCTAssertEqual(c.fadeMultiplier, 1, "the next Play is at full volume")
    }

    /// Cancelling during the fade means it: nothing pauses afterwards.
    func testCancellingDuringTheFadeStopsNothing() {
        let c = controller()
        c.play(readings, startAt: 0)
        c.armSleepTimer(seconds: 0.1, fadeSeconds: 0.4)
        waitUntil({ c.fadeMultiplier < 1 }, seconds: 3)

        c.cancelSleepTimer()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        XCTAssertEqual(c.state, .playing)
        XCTAssertFalse(c.sleepTimerArmed)
    }
}
