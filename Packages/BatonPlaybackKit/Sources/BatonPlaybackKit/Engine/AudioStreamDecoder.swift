#if os(macOS) || os(iOS)
// The engine is macOS/iOS only. watchOS has no AudioToolbox — no `AudioFileStream`, so no
// decoder, so no engine — and it plays downloaded files through AVPlayer. See
// `EngineDeckUnavailable.swift` for the stand-in that keeps the policy layer compiling.

import AVFoundation
import AudioToolbox
import Foundation

/// Turns a **compressed audio byte stream** into float PCM buffers, incrementally.
///
/// This is the piece AVPlayer never let us stand inside: `AudioFileStream` parses bytes
/// with no up-front container knowledge (the same parser family AVPlayer's own streaming
/// path uses), emitting the data format and then packets with their byte positions; an
/// `AVAudioConverter` then decodes those packets to PCM. Owning this stage is what makes
/// the EQ and the level meter reachable for streamed audio at all.
///
/// Formats: whatever `AudioFileStream` + Core Audio decode — MP3 (the `format=mp3`
/// transcode, the load-bearing case), ADTS AAC, WAV/AIFF/CAF, and fast-start MP4. What it
/// does *not* handle: Ogg/Opus (no Core Audio support — fails cleanly via
/// `kAudioFileStreamError_UnsupportedFileType`-class errors, never silently) and MP4 with
/// a trailing `moov` (the parser can't find headers until the whole file has arrived; the
/// caller's fallback is to spool to completion and open with `AVAudioFile`).
///
/// Not `Sendable`: owned by exactly one `TrackStreamSource` actor. `AudioFileStream`'s C
/// callbacks fire synchronously inside `AudioFileStreamParseBytes` on the caller's thread,
/// so all mutation stays serialized by that actor.
final class AudioStreamDecoder {
    enum DecodeError: Error, CustomStringConvertible {
        case openFailed(OSStatus)
        case parseFailed(OSStatus)
        case unsupportedFormat(String)
        case converterFailed(String)

        var description: String {
            switch self {
            case .openFailed(let s): "AudioFileStreamOpen failed (\(s))"
            case .parseFailed(let s):
                // The two statuses seen for genuinely un-parseable payloads (Ogg, HTML
                // error pages) — surface them as "unsupported", which is the truth the
                // retry ladder should act on (skip, don't retry forever).
                "AudioFileStreamParseBytes failed (\(s))"
            case .unsupportedFormat(let m): "unsupported stream format: \(m)"
            case .converterFailed(let m): "audio converter failed: \(m)"
            }
        }
    }

    private var streamID: AudioFileStreamID?

    /// The stream's native format, known once the parser has seen enough bytes.
    private(set) var sourceFormat: AudioStreamBasicDescription?
    /// Where the audio data begins in the byte stream — `AudioFileStreamSeek` offsets are
    /// relative to this, so every absolute spool position adds it back.
    private(set) var dataOffset: Int64 = 0
    /// True once packets can be produced (format + packet tables parsed).
    private(set) var isReadyToProducePackets = false
    private var maxPacketSize: UInt32 = 0

    /// The PCM format this decoder emits: float32, deinterleaved, at the source's rate
    /// and channel count. The engine graph converts onward from here.
    private(set) var pcmFormat: AVAudioFormat?
    private var compressedFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    /// Frames per compressed packet (1152 for MP3, 1024 for AAC, 1 for LPCM).
    var framesPerPacket: Int { Int(sourceFormat?.mFramesPerPacket ?? 0) }
    var sampleRate: Double { sourceFormat?.mSampleRate ?? 0 }

    /// Rough compressed bytes per second, for mapping spooled bytes → reachable seconds.
    /// Derived from the parser's average packet size once packets flow; nil until then
    /// (callers treat unknown as unreachable — the safe side, per `StreamSeek`).
    private(set) var estimatedBytesPerSecond: Double?
    private var packetBytesSeen: Int64 = 0
    private var packetsSeen: Int64 = 0

    /// Packets parsed but not yet converted (drained by `parse`'s return).
    private var pendingPackets: [(data: Data, frames: Int)] = []
    private var pendingDescs: [AudioStreamPacketDescription] = []
    /// LPCM path: raw sample bytes staged for format conversion (no packet structure).
    private var pendingPCMBytes = Data()

    /// Set after an external reposition (seek): the next parse passes the discontinuity
    /// flag so the parser resynchronizes, and the converter is rebuilt — MP3/AAC decoders
    /// are stateful (bit reservoir), so decoding across a jump would smear garbage.
    private var pendingDiscontinuity = false

    init() throws {
        var id: AudioFileStreamID?
        let status = AudioFileStreamOpen(
            Unmanaged.passUnretained(self).toOpaque(),
            propertyCallback, packetsCallback,
            0, // no file-type hint: let the parser sniff, as AVPlayer's path does
            &id
        )
        guard status == noErr, let id else { throw DecodeError.openFailed(status) }
        streamID = id
    }

    deinit {
        if let streamID { AudioFileStreamClose(streamID) }
    }

    // MARK: - Parsing

    /// Feed the next chunk of stream bytes; returns any PCM decoded from it.
    /// Chunks must arrive in stream order (modulo an announced `signalDiscontinuity`).
    func parse(_ data: Data) throws -> [AVAudioPCMBuffer] {
        guard let streamID else { return [] }
        let flags: AudioFileStreamParseFlags = pendingDiscontinuity ? [.discontinuity] : []
        pendingDiscontinuity = false
        let status = data.withUnsafeBytes { raw in
            AudioFileStreamParseBytes(streamID, UInt32(raw.count), raw.baseAddress, flags)
        }
        guard status == noErr else { throw DecodeError.parseFailed(status) }
        return try drainPending()
    }

    /// Announce that the next bytes do not follow the previous ones (a seek landed).
    /// Rebuilds the converter so no decoder state crosses the jump.
    ///
    /// The discontinuity flag is only passed for *packetized* formats: it exists so the
    /// parser resynchronizes on the next MP3/AAC frame header. LPCM refuses it outright
    /// (`kAudioFileStreamError_DiscontinuityCantRecover`, 'dta!' — measured) — and needs
    /// nothing: raw sample bytes decode identically from any frame-aligned offset.
    func signalDiscontinuity() {
        pendingDiscontinuity = !isLPCM
        pendingPackets.removeAll()
        pendingDescs.removeAll()
        pendingPCMBytes.removeAll()
        rebuildConverter()
    }

    // MARK: - Seeking

    struct SeekTarget {
        /// Absolute byte offset in the stream (data offset already added back).
        let byteOffset: Int64
        /// The frame the mapped packet actually starts at — the caller trims
        /// `targetFrame - packetStartFrame` frames from the first decoded buffer to land
        /// sample-accurately.
        let packetStartFrame: Int64
        /// The parser extrapolated from average bitrate rather than a parsed packet
        /// table. The landing is then approximate (a transcoded CBR stream lands close);
        /// callers skip the sample trim in that case rather than trim to a fiction.
        let isEstimate: Bool
    }

    /// Map a target frame to the byte to resume parsing from. Available once the format
    /// is known; returns nil for targets the parser cannot map (no packet structure yet).
    func seekTarget(forFrame frame: Int64) -> SeekTarget? {
        guard let streamID, isReadyToProducePackets, framesPerPacket > 0 else { return nil }
        let packet = max(0, frame / Int64(framesPerPacket))
        var byteOffset: Int64 = 0
        var flags = AudioFileStreamSeekFlags()
        guard AudioFileStreamSeek(streamID, packet, &byteOffset, &flags) == noErr else { return nil }
        return SeekTarget(
            byteOffset: dataOffset + byteOffset,
            packetStartFrame: packet * Int64(framesPerPacket),
            isEstimate: flags.contains(.offsetIsEstimated)
        )
    }

    // MARK: - Conversion

    private func rebuildConverter() {
        converter = nil
        if let compressedFormat, let pcmFormat {
            converter = AVAudioConverter(from: compressedFormat, to: pcmFormat)
        }
    }

    /// Build formats + converter once the parser announces the data format.
    private func adoptSourceFormat(_ asbd: AudioStreamBasicDescription) {
        sourceFormat = asbd
        // LPCM's byte rate is exact from the format itself; packetized formats estimate
        // it from observed packets as they flow (see `handlePackets`).
        if asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBytesPerFrame > 0 {
            estimatedBytesPerSecond = Double(asbd.mBytesPerFrame) * asbd.mSampleRate
        }
        var mutable = asbd
        guard let inFormat = AVAudioFormat(streamDescription: &mutable) else { return }
        compressedFormat = inFormat
        // Emit at the source's own rate/channels; the engine's mixer resamples onward.
        // Deinterleaved float32 is both the converter's natural output and exactly what
        // `AVAudioPlayerNode` schedules without copying.
        pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: asbd.mChannelsPerFrame,
            interleaved: false
        )
        rebuildConverter()
    }

    private var isLPCM: Bool { sourceFormat?.mFormatID == kAudioFormatLinearPCM }

    /// Convert everything staged by the parser callbacks into PCM buffers.
    private func drainPending() throws -> [AVAudioPCMBuffer] {
        if isLPCM { return try drainPCM() }
        guard !pendingPackets.isEmpty else { return [] }
        guard let compressedFormat, let pcmFormat, let converter else {
            pendingPackets.removeAll(); pendingDescs.removeAll()
            throw DecodeError.unsupportedFormat("packets before a usable data format")
        }

        let packets = pendingPackets
        let descs = pendingDescs
        pendingPackets.removeAll()
        pendingDescs.removeAll()

        // One compressed buffer per drain: memcpy the packets in, hand it to the
        // converter exactly once, and accept a partial decode (`inputRanDry` is the
        // normal outcome — the decoder keeps its own priming latency).
        let maxSize = Int(max(maxPacketSize, descs.map { $0.mDataByteSize }.max() ?? 0, 1))
        let compressed = AVAudioCompressedBuffer(
            format: compressedFormat,
            packetCapacity: AVAudioPacketCount(packets.count),
            maximumPacketSize: maxSize
        )
        var writeOffset = 0
        for (index, packet) in packets.enumerated() {
            packet.data.withUnsafeBytes { raw in
                compressed.data.advanced(by: writeOffset)
                    .copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
            var desc = descs[index]
            desc.mStartOffset = Int64(writeOffset)
            compressed.packetDescriptions![index] = desc
            writeOffset += packet.data.count
        }
        compressed.packetCount = AVAudioPacketCount(packets.count)
        compressed.byteLength = UInt32(writeOffset)

        let frameCapacity = AVAudioFrameCount(packets.reduce(0) { $0 + $1.frames } + framesPerPacket)
        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCapacity) else {
            throw DecodeError.converterFailed("could not allocate output buffer")
        }
        return try Self.convertOnce(converter: converter, input: compressed, into: out)
    }

    /// LPCM (WAV/AIFF/CAF-PCM): no packet decode, just an interleave/width conversion.
    private func drainPCM() throws -> [AVAudioPCMBuffer] {
        guard !pendingPCMBytes.isEmpty, let compressedFormat, let pcmFormat else { return [] }
        let bytesPerFrame = Int(compressedFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { throw DecodeError.unsupportedFormat("LPCM with no frame size") }
        let frames = pendingPCMBytes.count / bytesPerFrame
        guard frames > 0 else { return [] }
        let usable = frames * bytesPerFrame

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: compressedFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            throw DecodeError.converterFailed("could not allocate LPCM staging buffer")
        }
        inBuffer.frameLength = AVAudioFrameCount(frames)
        pendingPCMBytes.withUnsafeBytes { raw in
            inBuffer.audioBufferList.pointee.mBuffers.mData?
                .copyMemory(from: raw.baseAddress!, byteCount: usable)
        }
        pendingPCMBytes.removeFirst(usable)

        if compressedFormat == pcmFormat { return [inBuffer] }
        guard let converter = AVAudioConverter(from: compressedFormat, to: pcmFormat),
              let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            throw DecodeError.converterFailed("could not build LPCM converter")
        }
        return try Self.convertOnce(converter: converter, input: inBuffer, into: out)
    }

    /// Feed `input` to the converter exactly once and accept a partial decode
    /// (`inputRanDry` is the normal outcome — the codec keeps its own priming latency).
    ///
    /// The input block is `@Sendable` in the API's type, but `convert` calls it
    /// **synchronously on the calling thread** — the feed box never actually crosses a
    /// concurrency domain, which is what the `@unchecked Sendable` on it asserts.
    private static func convertOnce(
        converter: AVAudioConverter, input: AVAudioBuffer, into out: AVAudioPCMBuffer
    ) throws -> [AVAudioPCMBuffer] {
        final class Feed: @unchecked Sendable {
            var fed = false
            let buffer: AVAudioBuffer
            init(_ buffer: AVAudioBuffer) { self.buffer = buffer }
        }
        let feed = Feed(input)
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if feed.fed { outStatus.pointee = .noDataNow; return nil }
            feed.fed = true
            outStatus.pointee = .haveData
            return feed.buffer
        }
        if status == .error {
            throw DecodeError.converterFailed(conversionError?.localizedDescription ?? "unknown")
        }
        return out.frameLength > 0 ? [out] : []
    }

    // MARK: - Parser callbacks (fire synchronously inside AudioFileStreamParseBytes)

    fileprivate func handleProperty(_ propertyID: AudioFileStreamPropertyID) {
        guard let streamID else { return }
        switch propertyID {
        case kAudioFileStreamProperty_DataFormat:
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            if AudioFileStreamGetProperty(streamID, propertyID, &size, &asbd) == noErr {
                adoptSourceFormat(asbd)
            }
        case kAudioFileStreamProperty_DataOffset:
            var offset: Int64 = 0
            var size = UInt32(MemoryLayout<Int64>.size)
            if AudioFileStreamGetProperty(streamID, propertyID, &size, &offset) == noErr {
                dataOffset = offset
            }
        case kAudioFileStreamProperty_ReadyToProducePackets:
            isReadyToProducePackets = true
            var upperBound: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_PacketSizeUpperBound, &size, &upperBound) == noErr, upperBound > 0 {
                maxPacketSize = upperBound
            } else {
                maxPacketSize = 2048 // generous for MP3/AAC; only sizes a scratch buffer
            }
        default:
            break
        }
    }

    fileprivate func handlePackets(
        bytes: UInt32, packets: UInt32,
        data: UnsafeRawPointer, descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        if isLPCM || descriptions == nil {
            // Constant-bitrate payload with no packet table — raw sample bytes.
            pendingPCMBytes.append(Data(bytes: data, count: Int(bytes)))
            return
        }
        guard let descriptions else { return }
        for i in 0 ..< Int(packets) {
            let desc = descriptions[i]
            let packetData = Data(bytes: data.advanced(by: Int(desc.mStartOffset)), count: Int(desc.mDataByteSize))
            let frames = desc.mVariableFramesInPacket > 0 ? Int(desc.mVariableFramesInPacket) : framesPerPacket
            pendingPackets.append((packetData, frames))
            pendingDescs.append(desc)
            packetBytesSeen += Int64(desc.mDataByteSize)
        }
        packetsSeen += Int64(packets)
        if packetsSeen > 0, framesPerPacket > 0, sampleRate > 0 {
            let avgPacketBytes = Double(packetBytesSeen) / Double(packetsSeen)
            estimatedBytesPerSecond = avgPacketBytes * sampleRate / Double(framesPerPacket)
        }
    }
}

// MARK: - C callback trampolines (file scope, no captures)

private let propertyCallback: AudioFileStream_PropertyListenerProc = { clientData, _, propertyID, _ in
    Unmanaged<AudioStreamDecoder>.fromOpaque(clientData).takeUnretainedValue()
        .handleProperty(propertyID)
}

private let packetsCallback: AudioFileStream_PacketsProc = { clientData, numberBytes, numberPackets, inputData, packetDescriptions in
    Unmanaged<AudioStreamDecoder>.fromOpaque(clientData).takeUnretainedValue()
        .handlePackets(bytes: numberBytes, packets: numberPackets, data: inputData, descriptions: packetDescriptions)
}

#endif
