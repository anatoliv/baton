import Foundation

/// A collection track's audio as it goes into the link (specs/collection-sharing.md, decision 5):
/// AAC in an M4A file. The music server is asked for AAC at the chosen bit rate; an answer that
/// is AAC (ADTS or MP4) is remuxed into M4A untouched, and anything else (a server that answers
/// with the original, an offline download, a local file) is converted on the device.
public enum ShareCollectionAudio {
    public enum Container: Equatable, Sendable {
        /// Raw AAC frames, as Navidrome's `format=aac` transcode answers.
        case adts
        /// An MP4 family file (M4A); its codec still has to be checked.
        case mp4
        case other
    }

    /// What the first bytes of a file say it is.
    public static func container(of head: Data) -> Container {
        let bytes = [UInt8](head.prefix(12))
        if bytes.count >= 8, bytes[4 ... 7] == [0x66, 0x74, 0x79, 0x70] { return .mp4 } // "ftyp"
        // ADTS: a 12-bit sync word and layer 00. An ID3 tag in front is not ADTS as far as we know.
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xF6 == 0xF0 { return .adts }
        return .other
    }

    /// A file name extension AVFoundation will open these bytes by, from the answer's content
    /// type and, failing that, the bytes.
    public static func fileExtension(contentType: String?, head: Data) -> String {
        switch container(of: head) {
        case .adts: return "aac"
        case .mp4: return "m4a"
        case .other: break
        }
        let type = (contentType ?? "").lowercased()
        if type.contains("flac") { return "flac" }
        if type.contains("ogg") || type.contains("opus") { return "ogg" }
        if type.contains("wav") { return "wav" }
        if type.contains("aiff") { return "aiff" }
        if type.contains("mpeg") || type.contains("mp3") { return "mp3" }
        let bytes = [UInt8](head.prefix(4))
        if bytes.starts(with: [0x66, 0x4C, 0x61, 0x43]) { return "flac" } // "fLaC"
        if bytes.starts(with: [0x4F, 0x67, 0x67, 0x53]) { return "ogg" }  // "OggS"
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "wav" }  // "RIFF"
        if bytes.starts(with: [0x46, 0x4F, 0x52, 0x4D]) { return "aiff" } // "FORM"
        return "mp3"
    }

    /// Whole seconds as the wire carries them: rounded up, and never 0.
    public static func wireSeconds(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 1 }
        return max(1, Int(seconds.rounded(.up)))
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The input has no audio this device can read.
        case unreadable
        /// Reading or writing the M4A failed.
        case conversion(String)
    }
}

#if canImport(AVFoundation) && !os(watchOS)
import AVFoundation
import CoreMedia

extension ShareCollectionAudio {
    /// Makes `output` (an `.m4a` that does not exist yet) from `input`: the AAC stream copied as it
    /// is when the input is AAC at no more than the target rate's allowance, otherwise decoded and
    /// encoded as AAC at `bitRate`. Only the first audio track goes; artwork and anything else in
    /// the input stay behind. Returns the output's measured duration in whole seconds, and whether
    /// the stream was copied (`remuxed`) rather than encoded again.
    public static func makeM4A(from input: URL, to output: URL, bitRate: Int) async throws -> (seconds: Int, remuxed: Bool) {
        let asset = AVURLAsset(url: input)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { throw Failure.unreadable }
        let formats = (try? await track.load(.formatDescriptions)) ?? []
        guard let format = formats.first else { throw Failure.unreadable }
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let size = ((try? FileManager.default.attributesOfItem(atPath: input.path))?[.size] as? Int) ?? 0
        let isAAC = CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC
        let measuredRate = duration > 0 ? Double(size) * 8 / duration : .infinity
        if isAAC, measuredRate <= Double(bitRate) * ShareCollectionLimits.rateAllowance {
            do {
                try await copy(track: track, asset: asset, format: format, to: output, settings: nil)
                return (try await measure(output), true)
            } catch {
                // A stream the MP4 writer cannot take as it is is converted instead.
                try? FileManager.default.removeItem(at: output)
            }
        }
        let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        let channels = min(2, max(1, Int(description?.mChannelsPerFrame ?? 2)))
        try await copy(track: track, asset: asset, format: nil, to: output, settings: encoderSettings(channels: channels, bitRate: bitRate))
        return (try await measure(output), false)
    }

    static func encoderSettings(channels: Int, bitRate: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: ShareCollectionLimits.sampleRate(forBitRate: bitRate),
         AVNumberOfChannelsKey: channels,
         AVEncoderBitRateKey: bitRate, AVChannelLayoutKey: layout(channels),
         // Constant, so a track's size is what the caps were checked against, whatever the music.
         AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant]
    }

    private static func layout(_ channels: Int) -> Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }

    /// The measured length of a finished file, in wire seconds.
    public static func measure(_ url: URL) async throws -> Int {
        let duration = try await AVURLAsset(url: url).load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw Failure.conversion("The converted file has no length.") }
        return wireSeconds(seconds)
    }

    /// Reads the track and writes an M4A: compressed samples as they are when `settings` is nil
    /// (with `format` as the writer's hint), else decoded to PCM and encoded with `settings`.
    private static func copy(track: AVAssetTrack, asset: AVAsset, format: CMFormatDescription?, to output: URL,
                             settings: [String: Any]?) async throws {
        let reader = try AVAssetReader(asset: asset)
        let channels = (settings?[AVNumberOfChannelsKey] as? Int) ?? 2
        let readerSettings: [String: Any]? = settings == nil ? nil : [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: (settings?[AVSampleRateKey] as? Int) ?? 44_100, AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: layout(channels),
        ]
        let source = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        source.alwaysCopiesSampleData = false
        guard reader.canAdd(source) else { throw Failure.unreadable }
        reader.add(source)
        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        let sink = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
        sink.expectsMediaDataInRealTime = false
        guard writer.canAdd(sink) else { throw Failure.conversion("This device can't write AAC at that rate.") }
        writer.add(sink)
        guard reader.startReading() else { throw Failure.unreadable }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw Failure.conversion(writer.error?.localizedDescription ?? "Writing the M4A failed.")
        }
        writer.startSession(atSourceTime: .zero)
        let pump = SamplePump(reader: reader, source: source, writer: writer, sink: sink)
        try await withTaskCancellationHandler {
            try await pump.run()
        } onCancel: { pump.cancel() }
    }
}

/// Moves samples from the reader to the writer on a queue of its own, as the writer asks for them.
private final class SamplePump: @unchecked Sendable {
    private let reader: AVAssetReader
    private let source: AVAssetReaderTrackOutput
    private let writer: AVAssetWriter
    private let sink: AVAssetWriterInput
    private let queue = DispatchQueue(label: "baton.share.collection.m4a")
    private let lock = NSLock()
    private var cancelled = false
    /// Touched only on `queue`, where the writer's callbacks run one at a time.
    private var resumed = false

    init(reader: AVAssetReader, source: AVAssetReaderTrackOutput, writer: AVAssetWriter, sink: AVAssetWriterInput) {
        self.reader = reader; self.source = source; self.writer = writer; self.sink = sink
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        reader.cancelReading()
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func run() async throws {
        let finished: Bool = await withCheckedContinuation { continuation in
            sink.requestMediaDataWhenReady(on: queue) { [self] in
                while sink.isReadyForMoreMediaData {
                    if isCancelled { break }
                    if let buffer = source.copyNextSampleBuffer() {
                        if !sink.append(buffer) { break }
                    } else {
                        break
                    }
                }
                // Done when the reader has nothing more, the writer refused a sample, or cancelled.
                let more = !isCancelled && reader.status == .reading && writer.status == .writing && sink.isReadyForMoreMediaData == false
                if !more, !resumed {
                    resumed = true
                    sink.markAsFinished()
                    continuation.resume(returning: !isCancelled && reader.status == .completed && writer.status == .writing)
                }
            }
        }
        guard finished else {
            writer.cancelWriting()
            if isCancelled { throw CancellationError() }
            throw ShareCollectionAudio.Failure.conversion(
                writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "Converting the audio failed.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ShareCollectionAudio.Failure.conversion(writer.error?.localizedDescription ?? "Finishing the M4A failed.")
        }
    }
}
#endif
