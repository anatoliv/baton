import AVFoundation
import Foundation
@_exported import BatonSpeech

/// Renders the built-in voice to PCM instead of letting it speak for itself.
///
/// `AVSpeechSynthesizer.speak` plays through a path Baton does not own, so it cannot be sent
/// to a chosen output device — the native voice was the half of §3.5 that no amount of
/// swapping `AVAudioPlayer` for `AVPlayer` could have fixed. `write(_:toBufferCallback:)` is
/// the same synthesizer handing over buffers rather than playing them, which is exactly what
/// a graph needs.
///
/// **This matters most in the case it is easiest to forget.** The native voice is the
/// *fallback*: it speaks when the TTS server is unreachable. Routing that works only while
/// the server is up would be routing that fails when things are already going wrong.
///
/// **The word highlight gets better, not worse.** The HUD highlights the word being spoken
/// from `willSpeakRangeOfSpeechString`. Under `speak` those callbacks arrive as the audio
/// plays, so "now" is implicit. Under `write` they arrive during *synthesis*, which is far
/// faster than realtime — publishing them directly would race the highlight to the end of
/// the sentence before a word had been heard. So each range is stamped with how much audio
/// had been produced when it arrived, and `SpeechPlaybackEngine` replays that timeline
/// against the actual playhead. The result is sample-accurate rather than approximate, and
/// it survives pausing and seeking, which the old callback-as-it-happens version did not.
@MainActor
enum NativeSpeechRenderer {

    /// A word boundary and the moment it is reached, in seconds from the start of the clip.
    struct Word: Equatable {
        let range: NSRange
        let time: TimeInterval
    }

    struct Render {
        let pcm: AVAudioPCMBuffer
        let words: [Word]
    }

    /// Synthesize `text` to a single buffer, or nil when the system produced nothing.
    ///
    /// Nil is a real outcome, not a theoretical one — a missing voice, an empty string, or a
    /// synthesizer that declines — and the caller falls back to speaking aloud unrouted,
    /// because a summary the user cannot hear is worse than one on the wrong speaker.
    static func render(_ text: String, voice: AVSpeechSynthesisVoice?) async -> Render? {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice

        let collector = BufferCollector()
        let synthesizer = AVSpeechSynthesizer()
        let delegate = RangeDelegate { range in collector.mark(range) }
        synthesizer.delegate = delegate

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = OneShot { continuation.resume() }
            synthesizer.write(utterance) { buffer in
                // A zero-length buffer is how `write` says it has finished.
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    done.fire()
                    return
                }
                collector.append(pcm)
            }
        }
        // Keep both alive across the await — the synthesizer holds its delegate weakly, and a
        // deallocated synthesizer stops mid-write.
        withExtendedLifetime((synthesizer, delegate)) {}

        guard let pcm = collector.assembled() else { return nil }
        return Render(pcm: pcm, words: collector.words(sampleRate: pcm.format.sampleRate))
    }

    /// Accumulates the synthesizer's chunks plus the word boundaries interleaved with them.
    ///
    /// Not main-actor isolated: `write`'s callback and the delegate are delivered on the
    /// synthesizer's own queue, so this takes a lock rather than assuming isolation it does
    /// not have. (`MainActor.assumeIsolated` here would trap the first time Apple delivered
    /// off-main — the same trap the pipeline's configuration observer documents.)
    private final class BufferCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [AVAudioPCMBuffer] = []
        private var frames: AVAudioFrameCount = 0
        private var marks: [(range: NSRange, frame: AVAudioFrameCount)] = []

        func append(_ buffer: AVAudioPCMBuffer) {
            lock.lock(); defer { lock.unlock() }
            chunks.append(buffer)
            frames += buffer.frameLength
        }

        /// Stamp a word boundary with the audio produced so far — its start time.
        func mark(_ range: NSRange) {
            lock.lock(); defer { lock.unlock() }
            marks.append((range, frames))
        }

        func assembled() -> AVAudioPCMBuffer? {
            lock.lock(); defer { lock.unlock() }
            guard let first = chunks.first, frames > 0,
                  let out = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: frames)
            else { return nil }
            out.frameLength = 0
            for chunk in chunks {
                guard chunk.format == first.format else { continue }
                Self.copy(chunk, into: out)
            }
            return out.frameLength > 0 ? out : nil
        }

        func words(sampleRate: Double) -> [Word] {
            lock.lock(); defer { lock.unlock() }
            guard sampleRate > 0 else { return [] }
            return marks.map { Word(range: $0.range, time: Double($0.frame) / sampleRate) }
        }

        private static func copy(_ source: AVAudioPCMBuffer, into destination: AVAudioPCMBuffer) {
            let offset = Int(destination.frameLength)
            let count = Int(source.frameLength)
            let channels = Int(source.format.channelCount)
            if let src = source.floatChannelData, let dst = destination.floatChannelData {
                for channel in 0 ..< channels {
                    (dst[channel] + offset).update(from: src[channel], count: count)
                }
            } else if let src = source.int16ChannelData, let dst = destination.int16ChannelData {
                for channel in 0 ..< channels {
                    (dst[channel] + offset).update(from: src[channel], count: count)
                }
            } else if let src = source.int32ChannelData, let dst = destination.int32ChannelData {
                for channel in 0 ..< channels {
                    (dst[channel] + offset).update(from: src[channel], count: count)
                }
            } else {
                return
            }
            destination.frameLength += source.frameLength
        }
    }

    /// `write`'s callback can fire again after the terminating empty buffer; resuming a
    /// continuation twice is a crash, so the resume happens exactly once.
    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        func fire() {
            lock.lock()
            let first = !fired
            fired = true
            lock.unlock()
            if first { action() }
        }
    }

    /// Word boundaries during synthesis. Deliberately separate from the playback engine's own
    /// synthesizer delegate: this one is about *timing the render*, not about the HUD.
    private final class RangeDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        private let onRange: (NSRange) -> Void
        init(onRange: @escaping (NSRange) -> Void) { self.onRange = onRange }
        func speechSynthesizer(
            _ synthesizer: AVSpeechSynthesizer,
            willSpeakRangeOfSpeechString characterRange: NSRange,
            utterance: AVSpeechUtterance
        ) {
            onRange(characterRange)
        }
    }
}
