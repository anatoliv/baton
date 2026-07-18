import AVFoundation
import MediaToolbox

/// Runs the music player's audio through the `MusicEqualizer`'s biquad bands via an
/// `MTAudioProcessingTap` (the only way to filter a streaming `AVPlayer`). Attached to an
/// `AVPlayerItem`'s `audioMix` only while the EQ is enabled — when off, no tap exists and
/// audio is untouched. The heavy lifting (`process`) runs on the audio render thread and
/// reads coefficients through the lock-protected `EQCoefficients`.
final class AudioEQProcessor: @unchecked Sendable {
    private let coefficients: EQCoefficients
    /// Per-channel, per-band filter state (audio thread only after prepare()).
    private var state: [[BiquadState]] = []

    struct BiquadState { var z1: Float = 0; var z2: Float = 0 }

    init(coefficients: EQCoefficients) { self.coefficients = coefficients }

    /// Build an `AVAudioMix` that pipes `track` through this EQ tap.
    func makeAudioMix(for track: AVAssetTrack) -> AVAudioMix? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        guard status == noErr, let tap else {
            // Balance the passRetained above if creation failed.
            Unmanaged<AudioEQProcessor>.fromOpaque(callbacks.clientInfo!).release()
            return nil
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    fileprivate func prepare(channels: Int) {
        state = Array(repeating: Array(repeating: BiquadState(), count: MusicEqualizer.frequencies.count), count: max(1, channels))
    }

    /// Filter the buffer list in place (Direct Form II Transposed, cascaded bands).
    fileprivate func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let bands = coefficients.snapshot()
        guard !bands.isEmpty else { return }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        if state.count != abl.count || (state.first?.count ?? 0) != bands.count {
            state = Array(repeating: Array(repeating: BiquadState(), count: bands.count), count: abl.count)
        }
        for (ch, buffer) in abl.enumerated() {
            guard let raw = buffer.mData else { continue }
            let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = raw.bindMemory(to: Float.self, capacity: n)
            for i in 0 ..< n {
                var x = samples[i]
                for b in 0 ..< bands.count {
                    let c = bands[b]
                    let y = c.b0 * x + state[ch][b].z1
                    state[ch][b].z1 = c.b1 * x - c.a1 * y + state[ch][b].z2
                    state[ch][b].z2 = c.b2 * x - c.a2 * y
                    x = y
                }
                samples[i] = x
            }
        }
    }
}

// MARK: - MTAudioProcessingTap C callbacks (file-scope, no captures)

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo // the retained AudioEQProcessor pointer
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<AudioEQProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, processingFormat in
    let p = Unmanaged<AudioEQProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    p.prepare(channels: Int(processingFormat.pointee.mChannelsPerFrame))
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
    guard status == noErr else { return }
    let p = Unmanaged<AudioEQProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    p.process(bufferListInOut)
}
