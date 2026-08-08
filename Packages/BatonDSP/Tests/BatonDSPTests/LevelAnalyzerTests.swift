import XCTest
@testable import BatonDSP

/// The band analyzer behind the now-playing bars.
///
/// It runs on the audio render thread, so the tests care about two different things: that
/// it *reads* the music correctly (a bass tone lights the low bar, a hiss lights the high
/// one), and that no input can wedge it — a NaN, a silent buffer, or a rate change must
/// leave it working rather than stuck.
final class LevelAnalyzerTests: XCTestCase {
    private let rate = 44_100.0

    /// Feed `seconds` of a sine at `frequency` and return the settled levels.
    private func levels(
        frequency: Double, amplitude: Float = 0.5, seconds: Double = 0.5,
        analyzer: LevelAnalyzer? = nil
    ) -> BandLevels {
        let a = analyzer ?? {
            let x = LevelAnalyzer(); x.prepare(sampleRate: rate); return x
        }()
        let frames = 1024
        let buffers = Int((rate * seconds) / Double(frames))
        var phase = 0.0
        let step = 2 * Double.pi * frequency / rate
        var out = BandLevels.silent
        var samples = [Float](repeating: 0, count: frames)
        for _ in 0 ..< buffers {
            for i in 0 ..< frames {
                samples[i] = amplitude * Float(sin(phase))
                phase += step
            }
            out = samples.withUnsafeMutableBufferPointer { buf -> BandLevels in
                var ptr: UnsafeMutablePointer<Float>? = buf.baseAddress
                return withUnsafePointer(to: &ptr) {
                    a.analyze(channelPointers: $0, channelCount: 1, frames: frames)
                }
            }
        }
        return out
    }

    private func feed(_ analyzer: LevelAnalyzer, _ samples: [Float], repeats: Int = 1) -> BandLevels {
        var data = samples
        var out = BandLevels.silent
        for _ in 0 ..< repeats {
            out = data.withUnsafeMutableBufferPointer { buf -> BandLevels in
                var ptr: UnsafeMutablePointer<Float>? = buf.baseAddress
                return withUnsafePointer(to: &ptr) {
                    analyzer.analyze(channelPointers: $0, channelCount: 1, frames: buf.count)
                }
            }
        }
        return out
    }

    // MARK: - It reads the music

    func testABassToneLightsTheLowBar() {
        let l = levels(frequency: 60)
        XCTAssertGreaterThan(l.low, l.lowMid)
        XCTAssertGreaterThan(l.low, l.highMid)
        XCTAssertGreaterThan(l.low, l.high)
    }

    func testATrebleToneLightsTheHighBar() {
        let l = levels(frequency: 9_000)
        XCTAssertGreaterThan(l.high, l.low, "9 kHz must not read as bass")
        XCTAssertGreaterThan(l.high, l.lowMid)
    }

    func testAMidToneLightsAMiddleBar() {
        let l = levels(frequency: 500)
        XCTAssertGreaterThan(l.lowMid, l.high)
        XCTAssertGreaterThan(l.lowMid, l.low, "500 Hz belongs to the low-mid band, not bass")
    }

    func testLouderReadsHigherThanQuieter() {
        let loud = levels(frequency: 300, amplitude: 0.8)
        let quiet = levels(frequency: 300, amplitude: 0.02)
        XCTAssertGreaterThan(loud.peak, quiet.peak)
        XCTAssertGreaterThan(quiet.peak, 0, "quiet music must still show movement, not a flat floor")
    }

    func testSilenceReadsAsZero() {
        let a = LevelAnalyzer(); a.prepare(sampleRate: rate)
        let out = feed(a, [Float](repeating: 0, count: 1024), repeats: 20)
        XCTAssertEqual(out.peak, 0, accuracy: 0.001)
    }

    // MARK: - Ballistics

    func testItRisesFasterThanItFalls() {
        let a = LevelAnalyzer(); a.prepare(sampleRate: rate)
        // A loud buffer, then silence: measure how far it climbs in one buffer versus how
        // far it drops in one buffer from a comparable distance.
        let loud = (0 ..< 1024).map { _ in Float.random(in: -0.7 ... 0.7) }
        let afterOneLoud = feed(a, loud).peak
        _ = feed(a, loud, repeats: 40)              // settle at the top
        let settled = feed(a, loud).peak
        let afterOneSilent = feed(a, [Float](repeating: 0, count: 1024)).peak
        XCTAssertGreaterThan(afterOneLoud, 0, "must react within a single buffer")
        XCTAssertGreaterThan(afterOneSilent, settled * 0.5,
                             "release should be gradual — a meter that drops to zero in one buffer flickers")
    }

    func testLevelsStayInRange() {
        let a = LevelAnalyzer(); a.prepare(sampleRate: rate)
        let full = (0 ..< 1024).map { _ in Float.random(in: -1 ... 1) }
        let out = feed(a, full, repeats: 60)
        for i in 0 ..< 4 {
            XCTAssertGreaterThanOrEqual(out[i], 0)
            XCTAssertLessThanOrEqual(out[i], 1)
        }
    }

    // MARK: - It cannot be wedged

    /// One NaN in the stream would otherwise poison the running state permanently — the
    /// bars would freeze and never recover for the rest of the session.
    func testANaNDoesNotWedgeTheMeter() {
        let a = LevelAnalyzer(); a.prepare(sampleRate: rate)
        var poisoned = [Float](repeating: 0.4, count: 1024)
        poisoned[10] = .nan
        poisoned[11] = .infinity
        _ = feed(a, poisoned, repeats: 4)
        let after = feed(a, (0 ..< 1024).map { _ in Float.random(in: -0.6 ... 0.6) }, repeats: 20)
        XCTAssertTrue(after.peak.isFinite)
        XCTAssertGreaterThan(after.peak, 0, "the meter must recover and keep reading")
    }

    func testZeroFramesOrChannelsIsHarmless() {
        let a = LevelAnalyzer(); a.prepare(sampleRate: rate)
        var empty = [Float]()
        let out = empty.withUnsafeMutableBufferPointer { buf -> BandLevels in
            var ptr: UnsafeMutablePointer<Float>? = buf.baseAddress
            return withUnsafePointer(to: &ptr) {
                a.analyze(channelPointers: $0, channelCount: 0, frames: 0)
            }
        }
        XCTAssertEqual(out, .silent)
    }

    func testAnalyzingBeforePrepareIsHarmless() {
        let a = LevelAnalyzer()   // no prepare: sampleRate is 0
        let out = feed(a, [Float](repeating: 0.5, count: 512))
        XCTAssertEqual(out, .silent, "no rate means no coefficients — report silence, don't divide by zero")
    }

    func testANullChannelPointerIsSkipped() {
        let a = LevelAnalyzer(); a.prepare(sampleRate: rate)
        var ptr: UnsafeMutablePointer<Float>? = nil
        let out = withUnsafePointer(to: &ptr) {
            a.analyze(channelPointers: $0, channelCount: 1, frames: 256)
        }
        XCTAssertTrue(out.peak.isFinite)
    }

    // MARK: - Rate handling

    func testCoefficientsStayStableAtAnyRate() {
        for fs in [8_000.0, 44_100, 48_000, 96_000, 192_000] {
            let k = LevelAnalyzer.onePoleCoefficient(cutoff: 4_000, sampleRate: fs)
            XCTAssertTrue(k.isFinite)
            XCTAssertGreaterThan(k, 0)
            XCTAssertLessThanOrEqual(k, 1, "a coefficient above 1 makes the one-pole diverge")
        }
    }

    /// A cutoff above Nyquist (4 kHz at an 8 kHz rate) must clamp rather than diverge.
    func testACutoffAboveNyquistIsClamped() {
        let k = LevelAnalyzer.onePoleCoefficient(cutoff: 20_000, sampleRate: 8_000)
        XCTAssertLessThanOrEqual(k, 1)
        XCTAssertTrue(k.isFinite)
    }

    func testPrepareAtANewRateResetsCleanly() {
        let a = LevelAnalyzer()
        a.prepare(sampleRate: 44_100)
        _ = feed(a, (0 ..< 512).map { _ in Float.random(in: -0.5 ... 0.5) }, repeats: 10)
        a.prepare(sampleRate: 96_000)
        let out = feed(a, [Float](repeating: 0, count: 512))
        XCTAssertEqual(out.peak, 0, accuracy: 0.001, "a rate change starts from silence, not from stale state")
    }

    // MARK: - Normalization

    func testNormalizeSpansTheWindow() {
        XCTAssertEqual(LevelAnalyzer.normalize(rms: 0), 0)
        let atFloor = LevelAnalyzer.normalize(rms: pow(10, LevelAnalyzer.floorDB / 20))
        let atCeiling = LevelAnalyzer.normalize(rms: pow(10, LevelAnalyzer.ceilingDB / 20))
        XCTAssertEqual(atFloor, 0, accuracy: 0.01)
        XCTAssertEqual(atCeiling, 1, accuracy: 0.01)
    }

    /// The point of the dB mapping: a quiet passage still moves visibly. Linear RMS would
    /// leave −40 dBFS at 1% of the bar height — indistinguishable from silence.
    func testQuietMusicIsStillVisible() {
        let quiet = LevelAnalyzer.normalize(rms: pow(10, -40 / 20))
        XCTAssertGreaterThan(quiet, 0.25, "−40 dBFS should be clearly off the floor")
        XCTAssertLessThan(quiet, 0.75)
    }
}
