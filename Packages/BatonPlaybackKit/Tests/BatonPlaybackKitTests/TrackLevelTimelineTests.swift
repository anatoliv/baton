#if !os(watchOS)
import AVFoundation
import XCTest
import BatonDSP
@testable import BatonPlaybackKit

/// The offline envelope that drives the now-playing bars for streamed tracks.
///
/// The live tap can't run for HTTP items, so the bars' honesty for streams rests entirely
/// on this: the envelope must say *what* the track does *when* it does it. The core test
/// writes a file whose first half is bass and second half is treble, and asserts the
/// timeline flips bands at the midpoint — time-accuracy and band-accuracy in one.
@MainActor
final class TrackLevelTimelineTests: XCTestCase {
    override func setUp() async throws {
        TrackLevelTimeline.clear()
    }

    /// Write a WAV: `seconds` of a sine at `firstHz`, then `seconds` at `secondHz`.
    private func writeToneFile(firstHz: Double, secondHz: Double, seconds: Double = 1.0) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeline-\(UUID().uuidString).wav")
        let rate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(rate * seconds)
        for hz in [firstHz, secondHz] {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            let data = buffer.floatChannelData![0]
            for i in 0 ..< Int(frames) {
                data[i] = 0.6 * Float(sin(2 * .pi * hz * Double(i) / rate))
            }
            try file.write(from: buffer)
        }
        return url
    }

    func testTheEnvelopeFollowsTheTrackInTime() async throws {
        let url = try writeToneFile(firstHz: 70, secondHz: 8_000)
        defer { try? FileManager.default.removeItem(at: url) }
        await TrackLevelTimeline.analyzeLocal(id: "song", url: url)

        XCTAssertTrue(TrackLevelTimeline.hasEnvelope(id: "song"))

        // Sample well inside each half (avoiding the ballistic settling at boundaries).
        let early = try XCTUnwrap(TrackLevelTimeline.levels(id: "song", at: 0.6))
        let late = try XCTUnwrap(TrackLevelTimeline.levels(id: "song", at: 1.6))

        XCTAssertGreaterThan(early.low, early.high,
                             "at 0.6s the track is a 70 Hz tone — the low band must dominate")
        XCTAssertGreaterThan(late.high, late.low,
                             "at 1.6s the track is an 8 kHz tone — the high band must dominate")
    }

    func testTimeOutsideTheEnvelopeIsNil() async throws {
        let url = try writeToneFile(firstHz: 200, secondHz: 400, seconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        await TrackLevelTimeline.analyzeLocal(id: "short", url: url)

        XCTAssertNotNil(TrackLevelTimeline.levels(id: "short", at: 0.4))
        XCTAssertNil(TrackLevelTimeline.levels(id: "short", at: 60),
                     "past the analyzed audio (e.g. a capped fetch) the bars must fall back, not repeat")
        XCTAssertNil(TrackLevelTimeline.levels(id: "short", at: -1))
    }

    func testAnUnreadableFileYieldsNoEnvelopeAndNoError() async {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-audio-\(UUID().uuidString).mp3")
        try? Data("this is not audio".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }
        await TrackLevelTimeline.analyzeLocal(id: "bogus", url: bogus)
        XCTAssertFalse(TrackLevelTimeline.hasEnvelope(id: "bogus"))
    }

    func testStreamAnalysisUsesTheInjectedFetchAndCleansUp() async throws {
        let real = try writeToneFile(firstHz: 100, secondHz: 100, seconds: 0.3)
        // The fetch hands over a COPY, because analyzeStream deletes its input when done.
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("fetched-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: real, to: copy)
        defer { try? FileManager.default.removeItem(at: real) }

        await TrackLevelTimeline.analyzeStream(
            id: "streamed", url: URL(string: "https://example.com/rest/stream?id=1&format=mp3")!,
            fetch: { _, cap in
                XCTAssertEqual(cap, TrackLevelTimeline.analysisFetchCap)
                return copy
            }
        )
        XCTAssertTrue(TrackLevelTimeline.hasEnvelope(id: "streamed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path),
                       "the fetched temp file must be deleted after analysis")
    }

    func testAFailedFetchLeavesNoEnvelope() async {
        await TrackLevelTimeline.analyzeStream(
            id: "gone", url: URL(string: "https://example.com/x")!, fetch: { _, _ in nil }
        )
        XCTAssertFalse(TrackLevelTimeline.hasEnvelope(id: "gone"))
    }

    func testTheCacheEvictsOldestBeyondTheLimit() async throws {
        for i in 0 ..< 9 {
            let url = try writeToneFile(firstHz: 200, secondHz: 200, seconds: 0.1)
            defer { try? FileManager.default.removeItem(at: url) }
            await TrackLevelTimeline.analyzeLocal(id: "t\(i)", url: url)
        }
        XCTAssertFalse(TrackLevelTimeline.hasEnvelope(id: "t0"), "the oldest entry should be evicted")
        XCTAssertTrue(TrackLevelTimeline.hasEnvelope(id: "t8"))
    }

    /// The monitor prefers the live tap and only reads the envelope when the tap is silent.
    func testMonitorFallsBackToTheEnvelopeOnlyWhenTheTapIsSilent() async throws {
        let url = try writeToneFile(firstHz: 70, secondHz: 70, seconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        await TrackLevelTimeline.analyzeLocal(id: "fb", url: url)

        let monitor = AudioLevelMonitor(defaults: UserDefaults(suiteName: "baton.fb.\(UUID().uuidString)")!)
        monitor.playheadProvider = { ("fb", 0.3, true) }
        monitor.retain()

        // Tap silent → envelope drives the bars.
        monitor.snapshot.clear()
        monitor.sampleNow()
        XCTAssertTrue(monitor.isLive, "envelope levels must count as a live signal")
        XCTAssertGreaterThan(monitor.levels.low, monitor.levels.high, "the 70 Hz envelope should read as bass")

        // Tap active → it wins over the envelope.
        monitor.snapshot.store(BandLevels(low: 0.1, lowMid: 0.1, highMid: 0.9, high: 0.9))
        monitor.sampleNow()
        XCTAssertGreaterThan(monitor.levels.high, monitor.levels.low, "a live tap must take priority")

        // Paused → no envelope reading, even though one exists.
        monitor.playheadProvider = { ("fb", 0.3, false) }
        monitor.snapshot.clear()
        monitor.sampleNow()
        XCTAssertFalse(monitor.isLive)
    }
}
#endif
