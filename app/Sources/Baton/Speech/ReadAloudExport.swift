import AVFoundation
import Foundation
@_exported import BatonSpeech

/// Renders a reading to one audio file the person chose to keep.
///
/// **Why this synthesizes again rather than joining what was played.** The obvious
/// implementation — concatenate the WAV chunks already staged in the speech temp directory —
/// cannot work: `SpeechPlaybackEngine.startFile` deletes each clip the moment it starts playing
/// it, so by the time a reading has finished there is nothing left on disk to
/// join. Keeping them instead would mean a reading's audio living on disk for the life of the
/// reading, which narrows the promise in `specs/read-aloud.md` that readings are not persisted.
/// Re-synthesizing costs a wait and keeps that promise exactly as it was: the only thing this
/// feature ever writes is the file the person picked in a save panel.
///
/// The text it re-synthesizes is the *prepared* text — already normalized and already through the
/// redactor, because that is what the coordinator kept. So an exported reading cannot contain
/// something the speaker was protected from, and that is a property of where redaction sits in the
/// pipeline rather than a check performed here.
@MainActor
enum ReadAloudExport {

    /// What everything is converted to before encoding: 24 kHz mono, which is what the TTS host
    /// returns. Chunks that arrive at another rate (the built-in voice renders at its own) are
    /// resampled to this rather than the file being written at whichever rate happened to come
    /// first — a reading that falls back mid-way would otherwise change speed at that sentence.
    static let sampleRate: Double = 24_000

    enum ExportError: LocalizedError {
        case nothingToExport
        case noAudio
        case cannotWrite(URL, String)

        var errorDescription: String? {
            switch self {
            case .nothingToExport:
                return "There's no reading to save yet."
            case .noAudio:
                return "Baton couldn't produce any audio for that reading."
            case let .cannotWrite(url, reason):
                return "Couldn't write \(url.lastPathComponent): \(reason)"
            }
        }
    }

    /// Synthesize `chunks` in order and write them to `destination` as AAC in an M4A container.
    ///
    /// `synthesize` is injected for the same reason the coordinator injects it: the pipeline is
    /// testable without a TTS host on the LAN. A chunk the host cannot render falls back to the
    /// built-in voice, matching what a *reading* does — an export of a reading that was itself
    /// read in the built-in voice must not fail for the reason it was read that way.
    ///
    /// `progress` is called on the main actor with 0…1 after each chunk, so a long article can
    /// show where it has got to. Cancelling the surrounding task removes the partial file.
    static func write(
        chunks: [String],
        voice: SpeechConfig.Voice,
        to destination: URL,
        synthesize: (String, SpeechConfig.Voice) async throws -> Data = { text, voice in
            try await SpeechService.synthesize(text: text, voice: voice)
        },
        progress: (Double) -> Void = { _ in }
    ) async throws {
        guard !chunks.isEmpty else { throw ExportError.nothingToExport }

        guard let canonical = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ) else { throw ExportError.noAudio }

        let output: AVAudioFile
        do {
            output = try AVAudioFile(
                forWriting: destination,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw ExportError.cannotWrite(destination, error.localizedDescription)
        }

        // Any failure past this point leaves a half-written file that would play as a truncated
        // reading — worse than no file, because it looks like it worked.
        var wroteAnything = false
        do {
            var hostIsDown = false
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()

                var rendered: AVAudioPCMBuffer?
                if !hostIsDown {
                    do {
                        rendered = try decode(try await synthesize(chunk, voice), as: canonical)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Same rule as a reading: once the host has failed, stop asking it.
                        hostIsDown = true
                        readAloudLog.notice("export: TTS host unreachable — continuing in the built-in voice")
                    }
                }
                if rendered == nil {
                    rendered = await NativeSpeechRenderer.render(chunk, voice: NativeSpeechRenderer.systemVoice)
                        .flatMap { try? convert($0.pcm, to: canonical) }
                }
                try Task.checkCancellation()

                if let buffer = rendered, buffer.frameLength > 0 {
                    try output.write(from: buffer)
                    wroteAnything = true
                } else {
                    // One unrenderable sentence should not lose the other three hundred. Say so,
                    // because a silently shorter file is exactly the kind of failure that is only
                    // noticed by someone listening on a walk.
                    readAloudLog.error("export: no audio for one chunk — it is missing from the file")
                }
                progress(Double(index + 1) / Double(chunks.count))
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        guard wroteAnything else {
            try? FileManager.default.removeItem(at: destination)
            throw ExportError.noAudio
        }
    }

    /// The name to offer in the save panel. A reading has no title, so the two things actually
    /// known about it are where it came from and when it was read; inventing anything else would
    /// be a guess presented as a fact.
    static func suggestedName(sourceName: String?, startedAt: Date) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        let source = (sourceName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "Reading"
        // ":" and "/" are the two characters a save panel will not take in a file name, and an
        // app name is free to contain either.
        let safe = source.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(safe) \(stamp.string(from: startedAt)).m4a"
    }

    // MARK: - PCM plumbing

    /// Decode synthesized audio (the host returns a WAV) into the canonical format.
    ///
    /// Routed through a temp file because `AVAudioFile` reads URLs rather than `Data` — the same
    /// reason `SpeechAudioPlayer` does it — and the scratch file is removed on every path out.
    private static func decode(_ data: Data, as format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-export-\(UUID().uuidString).wav")
        try data.write(to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let file = try AVAudioFile(forReading: scratch, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw ExportError.noAudio }
        try file.read(into: buffer)
        return try convert(buffer, to: format)
    }

    /// Resample/remix a buffer into `format`, or return it unchanged when it already matches.
    ///
    /// The unchanged case is not an optimization — `AVAudioConverter` between identical formats is
    /// a no-op that still costs a copy, and the common path (the TTS host, already 24 kHz mono)
    /// takes it every chunk.
    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format.sampleRate == format.sampleRate,
           buffer.format.channelCount == format.channelCount,
           buffer.format.commonFormat == format.commonFormat {
            return buffer
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw ExportError.noAudio
        }
        // Round up: a rate ratio that divides unevenly loses the final partial frame otherwise,
        // which is a click at every sentence boundary rather than a silent shortfall.
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw ExportError.noAudio
        }

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        guard out.frameLength > 0 else { throw ExportError.noAudio }
        return out
    }
}
