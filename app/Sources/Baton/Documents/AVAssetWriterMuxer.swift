import AVFoundation
import BatonDocuments
import Foundation

/// Encodes a rendered chapter on the Mac: the joined WAV in, an AAC-LC M4A out, tagged.
///
/// The gateway does the same job with ffmpeg (`BookRenderer`'s other `AudioMuxing`); this is the
/// Mac's, so a book renders with no extra service installed. `AVAudioFile` can write AAC (that is
/// how `ReadAloudExport` keeps a reading) but cannot attach metadata, and a chapter needs its
/// tags: the player and any other audiobook app show the book, the author and the chapter
/// number from them. So this is an `AVAssetWriter` reading the WAV as PCM.
///
/// Written to a sibling temporary file and moved into place, so an interrupted encode never
/// leaves a short M4A where a finished one is expected.
struct AVAssetWriterMuxer: AudioMuxing {
    enum MuxError: Error, CustomStringConvertible {
        case noAudioTrack(URL)
        case cannotRead(String)
        case cannotWrite(String)

        var description: String {
            switch self {
            case let .noAudioTrack(url): return "\(url.lastPathComponent) has no audio"
            case let .cannotRead(why): return "could not read the chapter audio: \(why)"
            case let .cannotWrite(why): return "could not encode the chapter: \(why)"
            }
        }
    }

    func encode(wav: URL, to destination: URL, bitrate: Int, channels: Int, tags: [String: String]) async throws {
        try await encode(wav: wav, to: destination, bitrate: bitrate, channels: channels, sampleRate: nil, tags: tags)
    }

    /// At exactly `sampleRate` and `channels`: the reader hands the encoder PCM
    /// already in that format, so every chapter file is alike and an M4B export's stream copy
    /// never joins two formats.
    func encode(wav: URL, to destination: URL, bitrate: Int, channels: Int, sampleRate: Int,
                tags: [String: String]) async throws {
        try await encode(wav: wav, to: destination, bitrate: bitrate, channels: channels, sampleRate: Optional(sampleRate), tags: tags)
    }

    private func encode(wav: URL, to destination: URL, bitrate: Int, channels: Int, sampleRate requested: Int?,
                        tags: [String: String]) async throws {
        let asset = AVURLAsset(url: wav)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MuxError.noAudioTrack(wav)
        }
        let sourceFormat = try await track.load(.formatDescriptions).first
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let sampleRate = requested.map(Double.init) ?? sourceFormat?.mSampleRate ?? 24_000

        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial.m4a")
        try? FileManager.default.removeItem(at: partial)

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: partial, fileType: .m4a)
        } catch {
            throw MuxError.cannotRead(error.localizedDescription)
        }
        var pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // Asked for a format: the reader converts to it, so the encoder is given exactly that.
        if requested != nil {
            pcm[AVSampleRateKey] = sampleRate
            pcm[AVNumberOfChannelsKey] = channels
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
        reader.add(output)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitrate,
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw MuxError.cannotWrite("the encoder refused these settings") }
        writer.add(input)
        writer.metadata = Self.metadata(from: tags)

        guard reader.startReading() else {
            throw MuxError.cannotRead(reader.error?.localizedDescription ?? "unknown")
        }
        guard writer.startWriting() else {
            throw MuxError.cannotWrite(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let pump = Pump(reader: reader, writer: writer, output: output, input: input)
        do {
            try await pump.run()
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }

        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw MuxError.cannotWrite(error.localizedDescription)
        }
    }

    /// The tags `BookRenderer` passes ("title", "album", "artist", "track" as "2/3", "genre") as
    /// iTunes atoms, which is what an M4A's readers look for.
    static func metadata(from tags: [String: String]) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: (NSCopying & NSObjectProtocol)?,
                  dataType: String? = nil) -> AVMetadataItem? {
            guard let value else { return nil }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            if let dataType { item.dataType = dataType }
            return item
        }
        func text(_ key: String) -> NSString? {
            guard let value = tags[key], !value.isEmpty else { return nil }
            return value as NSString
        }
        var items: [AVMetadataItem?] = [
            item(.iTunesMetadataSongName, text("title")),
            item(.iTunesMetadataAlbum, text("album")),
            item(.iTunesMetadataArtist, text("artist")),
            item(.iTunesMetadataUserGenre, text("genre")),
        ]
        // `trkn` is eight bytes: two reserved, track, total, two reserved, big-endian.
        if let track = tags["track"] {
            let parts = track.split(separator: "/").compactMap { UInt16($0) }
            if let number = parts.first {
                let total = parts.count > 1 ? parts[1] : 0
                var bytes = Data([0, 0])
                bytes.append(contentsOf: [UInt8(number >> 8), UInt8(number & 0xFF), UInt8(total >> 8), UInt8(total & 0xFF)])
                bytes.append(contentsOf: [0, 0])
                items.append(item(.iTunesMetadataTrackNumber, bytes as NSData,
                                  dataType: kCMMetadataBaseDataType_RawData as String))
            }
        }
        return items.compactMap { $0 }
    }

    /// The reader-to-writer loop. AVFoundation's objects are not `Sendable`; they are only ever
    /// touched on the one serial queue the writer input pulls on, which is what makes the
    /// unchecked conformance true.
    private final class Pump: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        let queue = DispatchQueue(label: "io.tonebox.baton.documents.mux")

        init(reader: AVAssetReader, writer: AVAssetWriter, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) {
            self.reader = reader
            self.writer = writer
            self.output = output
            self.input = input
        }

        func run() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    while input.isReadyForMoreMediaData {
                        if let buffer = output.copyNextSampleBuffer() {
                            if !input.append(buffer) {
                                reader.cancelReading()
                                input.markAsFinished()
                                writer.cancelWriting()
                                continuation.resume(throwing: MuxError.cannotWrite(
                                    writer.error?.localizedDescription ?? "the encoder stopped"))
                                return
                            }
                            continue
                        }
                        input.markAsFinished()
                        if reader.status == .failed {
                            writer.cancelWriting()
                            continuation.resume(throwing: MuxError.cannotRead(
                                reader.error?.localizedDescription ?? "unknown"))
                            return
                        }
                        writer.finishWriting { [self] in
                            if writer.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: MuxError.cannotWrite(
                                    writer.error?.localizedDescription ?? "status \(writer.status.rawValue)"))
                            }
                        }
                        return
                    }
                }
            }
        }
    }
}
