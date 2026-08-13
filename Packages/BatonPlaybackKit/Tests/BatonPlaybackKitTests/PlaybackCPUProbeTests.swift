import XCTest
@testable import BatonPlaybackKit

/// The iOS half of Stage 6 has no per-app energy API, so the proxy is the process's own CPU
/// time per second of audio. A proxy nobody has checked is worse than no proxy, so these are
/// the checks that matter: that it measures CPU rather than wall clock, that it only goes
/// forward, and that the ratio divides by the right thing.
final class PlaybackCPUProbeTests: XCTestCase {

    func testItReportsSomething() throws {
        let cpu = try XCTUnwrap(PlaybackCPUProbe.processCPUSeconds(),
                                "no CPU reading at all — the probe cannot be used to measure anything")
        XCTAssertGreaterThan(cpu, 0, "a running process has burned some CPU by definition")
    }

    func testItOnlyEverGoesForward() throws {
        let first = try XCTUnwrap(PlaybackCPUProbe.processCPUSeconds())
        var sink = 0.0
        for i in 0 ..< 200_000 { sink += Double(i).squareRoot() }
        XCTAssertGreaterThan(sink, 0)
        let second = try XCTUnwrap(PlaybackCPUProbe.processCPUSeconds())

        XCTAssertGreaterThanOrEqual(second, first, "a CPU counter that goes backwards is unusable")
    }

    /// The claim that makes it a CPU probe rather than a stopwatch: work costs more than
    /// waiting. Sleeping burns wall clock and almost no CPU; a busy loop burns both.
    func testSleepingIsNotChargedAndWorkingIs() throws {
        let beforeSleep = try XCTUnwrap(PlaybackCPUProbe.processCPUSeconds())
        Thread.sleep(forTimeInterval: 0.30)
        let afterSleep = try XCTUnwrap(PlaybackCPUProbe.processCPUSeconds())
        let sleptCPU = afterSleep - beforeSleep

        let beforeWork = try XCTUnwrap(PlaybackCPUProbe.processCPUSeconds())
        let deadline = Date().addingTimeInterval(0.30)
        var sink = 0.0
        while Date() < deadline { sink += Double.random(in: 0 ... 1).squareRoot() }
        XCTAssertGreaterThan(sink, 0)
        let afterWork = try XCTUnwrap(PlaybackCPUProbe.processCPUSeconds())
        let workedCPU = afterWork - beforeWork

        XCTAssertLessThan(sleptCPU, 0.10, "0.3 s of sleeping should cost almost no CPU, got \(sleptCPU) s")
        XCTAssertGreaterThan(workedCPU, sleptCPU * 2,
                             "0.3 s of work (\(workedCPU) s CPU) should cost clearly more than 0.3 s of sleep (\(sleptCPU) s)")
    }

    /// Per *audio* second, not per wall-clock second — otherwise a window containing a pause
    /// or a stall reads as cheaper for having played less.
    func testTheCostIsPerAudioSecondNotPerWallClockSecond() {
        let sample = PlaybackCPUProbe.Sample(cpuSeconds: 6, audioSeconds: 600)
        XCTAssertEqual(try XCTUnwrap(sample.cpuMillisecondsPerAudioSecond), 10, accuracy: 0.001)

        // Same CPU, half the audio heard: twice the cost per second of music.
        let halved = PlaybackCPUProbe.Sample(cpuSeconds: 6, audioSeconds: 300)
        XCTAssertEqual(try XCTUnwrap(halved.cpuMillisecondsPerAudioSecond), 20, accuracy: 0.001)
    }

    /// A window with no audio in it must refuse to produce a number rather than divide by
    /// zero and report something confident.
    func testNoAudioMeansNoNumber() {
        let sample = PlaybackCPUProbe.Sample(cpuSeconds: 3, audioSeconds: 0)
        XCTAssertNil(sample.cpuMillisecondsPerAudioSecond)
        XCTAssertTrue(sample.summary.contains("nothing to divide by"))
    }

    func testAWindowMeasuresTheDifferenceRatherThanTheTotal() throws {
        // Pretend playback is already 100 s in when the window opens: the window must not
        // charge the engine for audio it never covered.
        let window = try XCTUnwrap(PlaybackCPUProbe.Window(audioSecondsSoFar: 100))
        let sample = try XCTUnwrap(window.sample(audioSecondsSoFar: 160))

        XCTAssertEqual(sample.audioSeconds, 60, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(sample.cpuSeconds, 0)
        XCTAssertLessThan(sample.cpuSeconds, 5, "the window should hold its own CPU delta, not the process total")
    }
}
