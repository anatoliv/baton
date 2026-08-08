#if canImport(MediaToolbox)
import AVFoundation
import MediaToolbox
import BatonSubsonicKit
import BatonSubsonicModels

/// Runs the music player's audio through the `MusicEqualizer`'s biquad bands via an
/// `MTAudioProcessingTap` (the only way to filter a streaming `AVPlayer`). Attached to an
/// `AVPlayerItem`'s `audioMix` only while the EQ is enabled.
///
/// Each tap owns its OWN filter state + coefficient cache via the tap's storage (an
/// `EQTapContext`), so two taps live at once (outgoing + incoming around a gapless/crossfade
/// boundary) never share mutable state — previously a single shared processor raced its
/// `state` across render threads, risking corruption/crash. The shared object here provides
/// only the coefficient source; the render path allocates nothing and never blocks.
public final class AudioEQProcessor: @unchecked Sendable {
    private let coefficients: EQCoefficients
    /// Where the tap publishes band levels for the now-playing bars. Shared across taps on
    /// purpose: two exist only momentarily around a gapless/crossfade boundary, and the
    /// indicator wants whatever is currently audible, not one particular item's history.
    private let levels: LevelSnapshot?

    public init(coefficients: EQCoefficients, levels: LevelSnapshot? = nil) {
        self.coefficients = coefficients
        self.levels = levels
    }

    /// Build an `AVAudioMix` that pipes `track` through this EQ, with per-tap state.
    public func makeAudioMix(for track: AVAssetTrack) -> AVAudioMix? {
        let context = EQTapContext(coefficients: coefficients, levels: levels)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged<EQTapContext>.fromOpaque(callbacks.clientInfo!).release()
            return nil
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}

/// Per-tap filter state + coefficient cache, owned by exactly one `MTAudioProcessingTap`. All
/// buffers are C-allocated once in `prepare` and used lock-/alloc-free in `process`; freed in
/// `deinit` (via the tap's finalize). Internal + testable in isolation.
public final class EQTapContext: @unchecked Sendable {
    public struct BiquadState { var z1: Float = 0; var z2: Float = 0 }

    private let coefficients: EQCoefficients
    private let maxBands = MusicEqualizer.frequencies.count
    /// Render-thread coefficient cache (fixed capacity; refreshed via a non-blocking trylock).
    private let coeffs: UnsafeMutablePointer<Biquad>
    private var bandCount = 0
    /// Per-tap filter memory: `channels * maxBands`, flat. nil until `prepare`.
    private var state: UnsafeMutablePointer<BiquadState>?
    private var channels = 0
    /// The tap's actual processing sample rate — coefficients are computed for THIS, not a
    /// hardcoded 44.1 kHz, so bands land at the right frequencies on 48/96 kHz material.
    private var sampleRate = 44_100.0
    private var cachedGeneration: UInt64 = .max // force a refresh on the first process
    /// Auto pre-gain that keeps a combined boost from clipping.
    private var preGain: Float = 1

    /// Band-level metering for the now-playing bars. Nil when nothing is displaying them,
    /// in which case `process` does not even look at the samples for metering.
    private let levels: LevelSnapshot?
    private let analyzer = LevelAnalyzer()
    /// Caps the channels the meter looks at, and sizes the preallocated pointer scratch.
    /// Beyond stereo the extra channels add nothing a 15-point indicator can show.
    static let maxMeteredChannels = 8
    /// Preallocated so `meter` never allocates on the render thread.
    private let channelPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    public init(coefficients: EQCoefficients, levels: LevelSnapshot? = nil) {
        self.coefficients = coefficients
        self.levels = levels
        coeffs = .allocate(capacity: maxBands)
        coeffs.initialize(repeating: .identity, count: maxBands)
        channelPointers = .allocate(capacity: Self.maxMeteredChannels)
        channelPointers.initialize(repeating: nil, count: Self.maxMeteredChannels)
    }

    deinit {
        coeffs.deinitialize(count: maxBands)
        coeffs.deallocate()
        channelPointers.deinitialize(count: Self.maxMeteredChannels)
        channelPointers.deallocate()
        levels?.clear()   // don't leave the bars frozen on this tap's last frame
        freeState()
    }

    private func freeState() {
        if let state {
            state.deinitialize(count: channels * maxBands)
            state.deallocate()
        }
        state = nil
    }

    /// Allocate per-channel × per-band filter memory once, off the render loop. Called from
    /// `tapPrepare`. The band count is fixed, so `process` never needs to reallocate.
    public func prepare(channels: Int, sampleRate: Double = 44_100) {
        freeState()
        self.sampleRate = sampleRate > 0 ? sampleRate : 44_100
        cachedGeneration = .max // recompute coefficients for the (possibly new) rate next process
        let ch = max(1, channels)
        self.channels = ch
        let s = UnsafeMutablePointer<BiquadState>.allocate(capacity: ch * maxBands)
        s.initialize(repeating: BiquadState(), count: ch * maxBands)
        state = s
        analyzer.prepare(sampleRate: self.sampleRate)
    }

    /// Filter the buffer list in place (Direct Form II Transposed, cascaded bands). No heap
    /// allocation and no blocking lock on the render thread.
    public func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>) {
        // Recompute coefficients for our rate only when the band set changed (non-blocking);
        // keep the cached set otherwise. No heap allocation on the steady-state render path.
        if let r = coefficients.refreshIfChanged(knownGeneration: cachedGeneration, sampleRate: sampleRate, into: coeffs, capacity: maxBands) {
            cachedGeneration = r.generation
            bandCount = r.count
            preGain = r.preGain
        }
        // Meter *before* the EQ guard: with no bands enabled the filter loop is skipped
        // entirely, but the indicator still has to follow the music. Metering only reads
        // the samples — it never writes them — so it cannot affect what you hear.
        meter(bufferList)
        guard bandCount > 0, let state else { return }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        let activeChannels = min(abl.count, channels)
        for chIdx in 0 ..< activeChannels {
            let buffer = abl[chIdx]
            guard let raw = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = raw.bindMemory(to: Float.self, capacity: count)
            let st = state + chIdx * maxBands
            for i in 0 ..< count {
                var x = samples[i] * preGain // pre-attenuate so a combined boost can't clip
                for b in 0 ..< bandCount {
                    let c = coeffs[b]
                    let y = c.b0 * x + st[b].z1
                    st[b].z1 = c.b1 * x - c.a1 * y + st[b].z2
                    st[b].z2 = c.b2 * x - c.a2 * y
                    x = y
                }
                samples[i] = x
            }
        }
    }

    /// Read band levels off the buffer and publish them for the now-playing bars.
    ///
    /// Read-only and allocation-free. Handles the two buffer shapes AVFoundation hands a tap:
    /// several single-channel buffers (deinterleaved, the usual case) and one interleaved
    /// buffer. In the interleaved case we hand the analyzer the whole buffer as one "channel"
    /// — its mono sum is then a sum over interleaved frames, which for a level meter is the
    /// same picture.
    private func meter(_ bufferList: UnsafeMutablePointer<AudioBufferList>) {
        guard let levels else { return }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        guard abl.count > 0 else { return }

        // `channelPointers` is allocated once in init — a Swift Array here would heap-allocate
        // on every render callback, which is the one thing this path must never do.
        var used = 0
        var frames = Int.max

        for index in 0 ..< min(abl.count, Self.maxMeteredChannels) {
            let buffer = abl[index]
            guard let raw = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let perChannel = count / max(1, Int(buffer.mNumberChannels))
            channelPointers[used] = raw.bindMemory(to: Float.self, capacity: count)
            used += 1
            frames = min(frames, perChannel)
        }
        guard used > 0, frames > 0, frames != .max else { return }

        levels.store(analyzer.analyze(channelPointers: channelPointers, channelCount: used, frames: frames))
    }
}

// MARK: - MTAudioProcessingTap C callbacks (file-scope, no captures)

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo // the retained EQTapContext pointer
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<EQTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, processingFormat in
    let ctx = Unmanaged<EQTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    ctx.prepare(
        channels: Int(processingFormat.pointee.mChannelsPerFrame),
        sampleRate: processingFormat.pointee.mSampleRate
    )
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
    guard status == noErr else { return }
    let ctx = Unmanaged<EQTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    ctx.process(bufferListInOut)
}
#endif
