import AVFoundation
import XCTest
@testable import BatonPlaybackKit

/// **Appendix D item 5, measured:** does `engine.stop()` flush buffers already scheduled on
/// an `AVAudioPlayerNode`?
///
/// It is not a curiosity. `setOutputDevice` stops the engine to re-point its output unit and
/// its own comment says that drops the scheduled buffers — but `DeckState.scheduledFrames` is
/// never reset, so `aheadSeconds` stays stale-positive and `clockTick`'s dry-detection never
/// raises `isBuffering`. A stall in that state is invisible to the thing that exists to
/// notice stalls. The fix is one line either way, and which line it is depends entirely on
/// this answer:
///
/// - flushes ⇒ resetting `scheduledFrames` is right;
/// - does not flush ⇒ resetting *understates* what is queued and invents a spurious
///   buffering state on every device switch.
///
/// So it is measured rather than assumed, which is the plan's own instruction: do not promote
/// a needs-measurement item to a fact by implementing it confidently.
@MainActor
final class EngineStopFlushTests: XCTestCase {

    private let rate = 44_100.0

    /// A flag the completion handler can set from whichever queue AVFAudio calls it on.
    private final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var at: Date?
        private let start = Date()
        func mark() { lock.lock(); if at == nil { at = Date() }; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return at != nil }
        /// Seconds from scheduling to the completion firing — the discriminator, since a
        /// discarded buffer completes at once and a played one completes at its own length.
        var elapsed: Double? { lock.lock(); defer { lock.unlock() }; return at.map { $0.timeIntervalSince(start) } }
    }

    private func tone(_ format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0 ..< Int(format.channelCount) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0 ..< Int(frames) {
                samples[frame] = Float(0.5 * sin(2 * .pi * 440 * Double(frame) / format.sampleRate))
            }
        }
        return buffer
    }

    /// Manual-rendering mode, where the answer is directly observable: render, restart the
    /// engine, render again, and listen to what comes out.
    func testWhetherStoppingTheEngineFlushesScheduledBuffersOffline() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: 2, interleaved: false)!
        let pipeline = try EngineAudioPipeline(outputMode: .offline(format: format, maxFrames: 4096))
        defer { pipeline.shutdown() }

        pipeline.prepareDeck(.a, format: format)
        pipeline.schedule(tone(format, seconds: 2.0), on: .a)
        pipeline.play(.a)

        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        func render(_ seconds: Double) throws -> Double {
            var collected: [Float] = []
            var rendered = 0
            let total = Int(seconds * rate)
            while rendered < total {
                let frames = AVAudioFrameCount(min(4096, total - rendered))
                guard try pipeline.renderOffline(frames: frames, into: out) == .success else { break }
                let channel = out.floatChannelData![0]
                collected.append(contentsOf: (0 ..< Int(out.frameLength)).map { channel[$0] })
                rendered += Int(frames)
            }
            return EngineTestSignals.rms(collected)
        }

        XCTAssertGreaterThan(try render(0.25), 0.1, "the deck did not play before the stop — nothing to measure")
        let playedBefore = pipeline.playedFrames(on: .a)
        let aheadBefore = pipeline.aheadSeconds(on: .a)

        // The device-change sequence, exactly: stop, then start again.
        pipeline.stopEngineForTesting()
        try pipeline.startEngineForTesting()
        pipeline.play(.a)

        let after = try render(0.5)
        let playedAfter = pipeline.playedFrames(on: .a)

        // No assertion on which way it goes — this test exists to *report* the behaviour, and
        // asserting the answer it happens to find would turn a measurement into a belief.
        print("""
        APPENDIX-D-5 (offline): before stop played=\(playedBefore) ahead=\(String(format: "%.2f", aheadBefore))s \
        — after restart rms=\(String(format: "%.4f", after)) played=\(playedAfter) \
        ahead=\(String(format: "%.2f", pipeline.aheadSeconds(on: .a)))s \
        ⇒ \(after > 0.05 ? "SURVIVED the engine stop (not flushed)" : "FLUSHED by the engine stop")
        """)
        XCTAssertTrue(pipeline.isEngineRunningForTesting, "the engine did not restart, so nothing below means anything")
    }

    /// What the measurement above buys: after the engine has been stopped underneath the
    /// decks, the bookkeeping no longer claims audio is queued.
    ///
    /// `aheadSeconds` staying stale-positive is not cosmetic — it is the input to
    /// `clockTick`'s dry-detection, so while it lies the engine cannot report buffering, and
    /// a stall right after a device change is invisible to the one thing that watches for
    /// stalls. (§2.5 / TBX-2874)
    func testEngineStopClearsWhatTheDecksThinkIsQueued() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: 2, interleaved: false)!
        let pipeline = try EngineAudioPipeline(outputMode: .offline(format: format, maxFrames: 4096))
        defer { pipeline.shutdown() }

        pipeline.prepareDeck(.a, format: format)
        pipeline.schedule(tone(format, seconds: 2.0), on: .a)
        pipeline.play(.a)
        XCTAssertGreaterThan(pipeline.aheadSeconds(on: .a), 1.5, "nothing was queued, so there is nothing to clear")

        pipeline.simulateConfigurationChangeForTesting()

        XCTAssertEqual(pipeline.aheadSeconds(on: .a), 0, accuracy: 0.001,
                       "the decks still claim queued audio the engine stop threw away — dry-detection stays blind")
        XCTAssertEqual(pipeline.scheduledSeconds(on: .a), 0, accuracy: 0.001)
    }

    /// The cross-check the ticket asks for, on a live device graph: manual-rendering mode is
    /// not the mode the app runs in, and `stop()` semantics may differ where there is a real
    /// output timeline. Silent (`volume = 0`) — this runs in the gate, on somebody's machine,
    /// possibly at night.
    ///
    /// Skips where there is no usable output device, which is a normal state on a headless
    /// runner and not a failure.
    func testWhetherStoppingTheEngineFlushesScheduledBuffersOnADevice() throws {
        let pipeline: EngineAudioPipeline
        do { pipeline = try EngineAudioPipeline(outputMode: .device) } catch {
            throw XCTSkip("no usable audio output device here — the live half is not measurable: \(error)")
        }
        defer { pipeline.shutdown() }
        pipeline.masterVolume = 0

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: 2, interleaved: false)!
        pipeline.prepareDeck(.a, format: format)

        // The observable has to be the *buffer*, not the clock. A player node's `playerTime`
        // keeps advancing while it is starved — the offline half of this file demonstrates
        // that directly, rendering pure silence while `playedFrames` climbed by 21k — so
        // "frames went up" cannot tell a surviving buffer from an empty node running on.
        // The completion handler can: it fires when the buffer is consumed *or* discarded, so
        // firing seconds before the buffer's own length has elapsed means it was dropped.
        let fired = Fired()
        pipeline.schedule(tone(format, seconds: 4.0), on: .a) { fired.mark() }
        pipeline.play(.a)

        Thread.sleep(forTimeInterval: 0.4)
        let playedBefore = pipeline.playedFrames(on: .a)
        guard playedBefore > 0 else {
            throw XCTSkip("the device graph never advanced its player clock — not measurable here")
        }
        XCTAssertFalse(fired.value, "the 4 s buffer completed inside 0.4 s — the probe is not measuring what it thinks")

        pipeline.stopEngineForTesting()
        Thread.sleep(forTimeInterval: 0.3)          // let a flush's completions land
        let firedOnStop = fired.value
        try pipeline.startEngineForTesting()
        pipeline.play(.a)
        // Then wait past the buffer's own 4 s. A survivor completes near its length; a node
        // left holding nothing never completes at all.
        let deadline = Date().addingTimeInterval(5.5)
        while !fired.value, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let playedAfter = pipeline.playedFrames(on: .a)

        print("""
        APPENDIX-D-5 (device): completion at stop=\(firedOnStop ? "FIRED ⇒ flushed" : "not fired"); \
        completion overall=\(fired.elapsed.map { String(format: "%.2fs", $0) } ?? "NEVER") against a 4.00s buffer \
        ⇒ \(fired.elapsed.map { $0 > 3.0 ? "SURVIVED the stop and played on" : "discarded early" } ?? "the node was left holding nothing"); \
        playedFrames \(playedBefore) → \(playedAfter), which on its own proves nothing because a starved node's clock advances too.
        """)
    }
}
