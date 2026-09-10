import XCTest
@testable import BatonDSP

/// The `while` rewrite of `LevelAnalyzer.analyze` must report exactly the levels
/// the old `for i in 0 ..< frames` loops did, because those levels are what the now-playing
/// bars draw. The loop shape changed for allocation reasons only; the arithmetic did not.
///
/// The reference below is the pre-rewrite body of `analyze`, kept verbatim in its `for` form
/// with the same coefficient, normalisation, adaptive-window and ballistics code the class
/// exposes, so the two are compared on identical inputs buffer by buffer rather than on a
/// single settled value. Filter state, the adaptive window and the ballistics all carry
/// across buffers, so a divergence anywhere would compound and show.
final class LevelAnalyzerEquivalenceTests: XCTestCase {
    private let rate = 48_000.0
    private let frames = 1024
    private let channels = 2

    /// The old `analyze`, as a standalone reference over the same state variables.
    private final class Reference {
        var lowState: Float = 0, lowMidState: Float = 0, highMidState: Float = 0
        var displayed = BandLevels.silent
        var envFloor: [Float] = [1, 1, 1, 1]
        var envCeiling: [Float] = [0, 0, 0, 0]
        let k1: Float, k2: Float, k3: Float

        init(sampleRate: Double) {
            k1 = LevelAnalyzer.onePoleCoefficient(cutoff: LevelAnalyzer.crossovers.0, sampleRate: sampleRate)
            k2 = LevelAnalyzer.onePoleCoefficient(cutoff: LevelAnalyzer.crossovers.1, sampleRate: sampleRate)
            k3 = LevelAnalyzer.onePoleCoefficient(cutoff: LevelAnalyzer.crossovers.2, sampleRate: sampleRate)
        }

        private func adapt(_ value: Float, band: Int) -> Float {
            let decay: Float = 0.975
            envCeiling[band] = max(value, envCeiling[band] * decay + value * (1 - decay))
            envFloor[band] = min(value, envFloor[band] * decay + value * (1 - decay))
            let span = envCeiling[band] - envFloor[band]
            guard span >= 0.04 else { return value }
            return min(max((value - envFloor[band]) / span, 0), 1)
        }

        func analyze(
            channelPointers: UnsafePointer<UnsafeMutablePointer<Float>?>, channelCount: Int, frames: Int
        ) -> BandLevels {
            guard frames > 0, channelCount > 0 else { return displayed }
            var sumLow: Float = 0, sumLowMid: Float = 0, sumHighMid: Float = 0, sumHigh: Float = 0
            var counted = 0
            let scale = 1 / Float(channelCount)
            for i in 0 ..< frames {
                var mono: Float = 0
                for c in 0 ..< channelCount {
                    guard let p = channelPointers[c] else { continue }
                    mono += p[i]
                }
                mono *= scale
                guard mono.isFinite else { continue }
                lowState += k1 * (mono - lowState)
                lowMidState += k2 * (mono - lowMidState)
                highMidState += k3 * (mono - highMidState)
                let low = lowState
                let lowMid = lowMidState - lowState
                let highMid = highMidState - lowMidState
                let high = mono - highMidState
                sumLow += low * low
                sumLowMid += lowMid * lowMid
                sumHighMid += highMid * highMid
                sumHigh += high * high
                counted += 1
            }
            guard counted > 0 else { return displayed }
            let n = Float(counted)
            let target = BandLevels(
                low: adapt(LevelAnalyzer.normalize(rms: (sumLow / n).squareRoot()), band: 0),
                lowMid: adapt(LevelAnalyzer.normalize(rms: (sumLowMid / n).squareRoot()), band: 1),
                highMid: adapt(LevelAnalyzer.normalize(rms: (sumHighMid / n).squareRoot()), band: 2),
                high: adapt(LevelAnalyzer.normalize(rms: (sumHigh / n).squareRoot()), band: 3)
            )
            displayed = BandLevels(
                low: LevelAnalyzer.ballistic(displayed.low, target.low),
                lowMid: LevelAnalyzer.ballistic(displayed.lowMid, target.lowMid),
                highMid: LevelAnalyzer.ballistic(displayed.highMid, target.highMid),
                high: LevelAnalyzer.ballistic(displayed.high, target.high)
            )
            return displayed
        }
    }

    /// A deterministic stereo "track": a kick-like 60 Hz burst every 0.5 s on the left, a
    /// 2.5 kHz tone with a slow tremolo on the right, plus a seeded-noise hiss on both, so
    /// every band moves and the adaptive window has dynamics to chase.
    private func sample(channel: Int, frame: Int) -> Float {
        let t = Double(frame) / rate
        var seed = UInt32(truncatingIfNeeded: frame &* 2_654_435_761 &+ channel &* 97)
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
        let noise = Float(seed % 2001) / 1000 - 1              // −1…1, deterministic
        let beat = t.truncatingRemainder(dividingBy: 0.5)
        let kick = beat < 0.12 ? sin(2 * .pi * 60 * t) * exp(-beat * 25) : 0
        let tone = sin(2 * .pi * 2_500 * t) * (0.5 + 0.5 * sin(2 * .pi * 1.5 * t))
        let s = channel == 0 ? 0.8 * kick + 0.3 * tone : 0.6 * tone + 0.2 * kick
        return Float(s) + 0.02 * noise
    }

    private func run(
        buffers: Int, mutate: (inout [[Float]], Int) -> Void = { _, _ in }
    ) -> [(new: BandLevels, old: BandLevels)] {
        let analyzer = LevelAnalyzer()
        analyzer.prepare(sampleRate: rate)
        let reference = Reference(sampleRate: rate)
        var out: [(BandLevels, BandLevels)] = []
        var data = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channels)
        let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: channels)
        table.initialize(repeating: nil, count: channels)
        defer { table.deinitialize(count: channels); table.deallocate() }

        for b in 0 ..< buffers {
            for c in 0 ..< channels {
                for i in 0 ..< frames { data[c][i] = sample(channel: c, frame: b * frames + i) }
            }
            mutate(&data, b)
            // Pin both channels (as locals, so the two pins do not overlap an access to
            // `data`), then hand the same pointer table to both implementations.
            var l = data[0], r = data[1]
            l.withUnsafeMutableBufferPointer { left in
                r.withUnsafeMutableBufferPointer { right in
                    table[0] = left.baseAddress
                    table[1] = right.baseAddress
                    let a = analyzer.analyze(channelPointers: UnsafePointer(table), channelCount: channels, frames: frames)
                    let r = reference.analyze(channelPointers: UnsafePointer(table), channelCount: channels, frames: frames)
                    out.append((a, r))
                }
            }
        }
        return out.map { (new: $0.0, old: $0.1) }
    }

    private func assertSame(_ pairs: [(new: BandLevels, old: BandLevels)], file: StaticString = #filePath, line: UInt = #line) {
        for (b, pair) in pairs.enumerated() {
            for band in 0 ..< 4 {
                XCTAssertEqual(
                    pair.new[band], pair.old[band], accuracy: 1e-5,
                    "buffer \(b), band \(band): rewrite reports \(pair.new[band]), old loops reported \(pair.old[band])",
                    file: file, line: line
                )
            }
        }
    }

    /// Four seconds of the test track, buffer by buffer.
    func testTheWhileRewriteReportsTheSameLevelsAsTheForLoops() {
        let pairs = run(buffers: Int(rate * 4) / frames)
        assertSame(pairs)
        // And the comparison is not vacuous: the bars actually moved.
        let peaks = pairs.map { $0.new.peak }
        XCTAssertGreaterThan(peaks.max()! - peaks.min()!, 0.3, "the test signal should make the meter swing")
    }

    /// The skip paths, too: a NaN and an infinity dropped into the stream, and a buffer where
    /// one channel pointer is nil, must be skipped identically by both loop shapes.
    func testTheSkipPathsMatchAsWell() {
        let pairs = run(buffers: 40) { data, b in
            if b == 5 { data[0][100] = .nan }
            if b == 9 { data[1][7] = .infinity; data[1][8] = -.infinity }
        }
        assertSame(pairs)

        let analyzer = LevelAnalyzer(); analyzer.prepare(sampleRate: rate)
        let reference = Reference(sampleRate: rate)
        var mono = (0 ..< frames).map { sample(channel: 0, frame: $0) }
        let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 2)
        table.initialize(repeating: nil, count: 2)
        defer { table.deinitialize(count: 2); table.deallocate() }
        mono.withUnsafeMutableBufferPointer { buf in
            table[0] = nil
            table[1] = buf.baseAddress
            for _ in 0 ..< 10 {
                let a = analyzer.analyze(channelPointers: UnsafePointer(table), channelCount: 2, frames: frames)
                let r = reference.analyze(channelPointers: UnsafePointer(table), channelCount: 2, frames: frames)
                for band in 0 ..< 4 { XCTAssertEqual(a[band], r[band], accuracy: 1e-5, "nil-channel buffer, band \(band)") }
            }
        }
    }
}
