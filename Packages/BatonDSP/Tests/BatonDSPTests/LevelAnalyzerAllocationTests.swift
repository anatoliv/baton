import XCTest
@testable import BatonDSP

/// `LevelAnalyzer.analyze` runs on the audio render thread.
///
/// It is called from the same `MTAudioProcessingTap` callback as the equalizer, one level
/// below `EQTapContext.process(_:)`, on every buffer for as long as anything is playing. Any
/// heap allocation there can block on the malloc lock and glitch the audio. The EQ side has
/// had this test since PR #113 (`EQRenderAllocationTests`) and TBX-5360; this is the same
/// measurement for the meter, which TBX-5360 deliberately left out by passing `levels: nil`.
///
/// What it caught: in a debug build, `for i in 0 ..< frames` and the nested
/// `for c in 0 ..< channelCount` iterate a `Range` through `IndexingIterator`'s unspecialized
/// `Collection` witness, which heap-allocates once per element. Measured on the old loops with
/// this hook, `swift test -c debug`: a 1024-frame stereo buffer allocated 1024 + 1024 × 2 =
/// 3072 times, i.e. one per frame plus one per channel per frame. Release builds specialized
/// it away and measured 0 both before and after; a debug build is what a developer listens
/// to.
final class LevelAnalyzerAllocationTests: XCTestCase {
    private let frames = 1024
    private let channels = 2

    /// A stereo buffer of two tones, one per channel, so the mono sum and every band filter
    /// have real signal to work on rather than early-outing on silence.
    private func makeBuffers() -> [[Float]] {
        (0 ..< channels).map { c in
            let f = c == 0 ? 110.0 : 3_000.0
            let step = 2 * Double.pi * f / 48_000
            return (0 ..< frames).map { i in 0.4 * Float(sin(Double(i) * step)) }
        }
    }

    /// Call `analyze` over `buffers` with the channel-pointer table the tap hands it, and
    /// return what the hook counted while it ran.
    ///
    /// Both channels are pinned inside their `withUnsafeMutableBufferPointer` closures for the
    /// whole call (as locals, so the two pins do not overlap an access to `buffers`); only the
    /// `analyze` call itself sits inside the measurement, so the pinning cannot be what is
    /// counted.
    private func measuredAllocations(_ analyzer: LevelAnalyzer, buffers: inout [[Float]]) -> Int {
        let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: channels)
        table.initialize(repeating: nil, count: channels)
        defer { table.deinitialize(count: channels); table.deallocate() }

        let count = frames
        let channelCount = channels
        var left = buffers[0], right = buffers[1]
        return left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                table[0] = l.baseAddress
                table[1] = r.baseAddress
                return AllocationCounter.measure {
                    _ = analyzer.analyze(
                        channelPointers: UnsafePointer(table), channelCount: channelCount, frames: count
                    )
                }
            }
        }
    }

    /// One steady-state render callback, measured.
    func testAnalyzeOnTheRenderPathAllocatesNothing() throws {
        try XCTSkipUnless(AllocationCounter.isAvailable, "malloc_logger is not available here")

        let analyzer = LevelAnalyzer()
        analyzer.prepare(sampleRate: 48_000)
        var buffers = makeBuffers()

        // Warm up outside the measurement: the first trip resolves lazy globals and the
        // logger's own one-time setup, neither of which is the render path.
        _ = measuredAllocations(analyzer, buffers: &buffers)

        var total = 0
        for _ in 0 ..< 10 {
            total += measuredAllocations(analyzer, buffers: &buffers)
        }
        XCTAssertEqual(
            total, 0,
            "analyze allocated \(total) times across ten \(frames)-frame stereo buffers"
        )
    }

    /// A buffer with a `nil` channel pointer and a NaN sample, so the `continue` paths through
    /// both loops are the ones being measured rather than the happy path.
    func testTheSkipPathsAlsoAllocateNothing() throws {
        try XCTSkipUnless(AllocationCounter.isAvailable, "malloc_logger is not available here")

        let analyzer = LevelAnalyzer()
        analyzer.prepare(sampleRate: 48_000)
        var buffers = makeBuffers()
        buffers[0][17] = .nan
        buffers[0][900] = .infinity

        let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: channels)
        table.initialize(repeating: nil, count: channels)
        defer { table.deinitialize(count: channels); table.deallocate() }
        let count = frames
        let channelCount = channels

        let measured: Int = buffers[0].withUnsafeMutableBufferPointer { buf in
            table[0] = buf.baseAddress
            table[1] = nil                       // the nil-pointer `continue`
            _ = analyzer.analyze(channelPointers: UnsafePointer(table), channelCount: channelCount, frames: count)
            return AllocationCounter.measure {
                _ = analyzer.analyze(channelPointers: UnsafePointer(table), channelCount: channelCount, frames: count)
            }
        }
        XCTAssertEqual(measured, 0, "the skip paths allocated \(measured) times")
    }
}
