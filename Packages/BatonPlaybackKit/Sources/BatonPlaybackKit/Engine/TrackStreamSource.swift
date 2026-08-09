#if os(macOS) || os(iOS)
// The engine is macOS/iOS only. watchOS has no AudioToolbox — no `AudioFileStream`, so no
// decoder, so no engine — and it plays downloaded files through AVPlayer. See
// `EngineDeckUnavailable.swift` for the stand-in that keeps the policy layer compiling.

import AVFoundation
import Foundation
import OSLog

let engineLog = Logger(subsystem: "io.tonebox.baton", category: "EnginePlayback")

/// One track's streaming pipeline: URLSession → `StreamSpool` → `AudioStreamDecoder` →
/// PCM chunks, **pulled** by the consumer.
///
/// Pull, not push, is the backpressure story: the feeder (on the controller) awaits
/// `nextChunk()` only while the deck's scheduled-ahead is below the high-water mark, so
/// the decoder idles exactly when enough audio is queued — nothing needs to suspend the
/// socket, and nothing buffers unboundedly. The network side always runs at full speed
/// into the spool (disk is the cheap resource; decoded PCM is the bounded one).
///
/// An actor: URLSession bytes hop in to append, the consumer hops in to pull, and the
/// non-Sendable spool + decoder stay serialized behind it.
actor TrackStreamSource {
    /// `@unchecked Sendable` is a documented hand-off, not a shared-state claim:
    /// every `.pcm` buffer is freshly allocated inside the decoder's drain, returned
    /// without the decoder (or this actor) retaining any reference, and consumed exactly
    /// once by the feeder that scheduled the pull. `AVAudioFormat` is immutable.
    enum Chunk: @unchecked Sendable {
        /// The stream's decoded-PCM format — always delivered before the first `.pcm`.
        case format(AVAudioFormat)
        case pcm(AVAudioPCMBuffer)
    }

    enum SourceError: Error, CustomStringConvertible {
        case http(Int)
        case transport(String)
        case decode(String)

        var description: String {
            switch self {
            case .http(let code): "stream request failed: HTTP \(code)"
            case .transport(let m): m
            case .decode(let m): m
            }
        }
    }

    private let url: URL
    private let headers: [String: String]
    private var spool: StreamSpool?
    private var decoder: AudioStreamDecoder?
    /// Next spool byte to hand the parser. Moves forward as chunks are pulled, and jumps
    /// on a seek.
    private var parseOffset: Int64 = 0
    private var networkTask: Task<Void, Never>?
    private var networkFailure: SourceError?
    private var deliveredFormat = false
    /// Frames to drop from the front of the next decoded buffer (sample-accurate seek
    /// landing). Consumed once.
    private var pendingTrimFrames: Int = 0
    /// PCM decoded *while discovering the format* — the parse chunk that reveals the
    /// header usually also contains the first audio, and dropping it would silently
    /// shave the track's opening (measured: 0.37 s lost on a WAV). Drained before any
    /// further parsing; cleared by a seek.
    private var stagedBuffers: [AVAudioPCMBuffer] = []
    private var cancelled = false

    /// How many bytes to hand the parser per pull — small enough to keep pull latency
    /// low, large enough to amortize the file read.
    private static let parseChunkBytes = 32 * 1024
    /// Poll interval while waiting for the spool to grow. Polling (not a continuation)
    /// keeps the wait trivially cancellation-safe; 50 ms of pull latency is invisible
    /// behind seconds of scheduled audio.
    private static let growthPoll = Duration.milliseconds(50)

    init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }

    /// Kick off the download. Separate from `init` so the caller controls when the
    /// network is touched.
    func start() throws {
        let spool = try StreamSpool()
        self.spool = spool
        decoder = try AudioStreamDecoder()
        let request = makeRequest()
        networkTask = Task { [weak self] in
            await self?.runDownload(request: request)
        }
    }

    private func makeRequest() -> URLRequest {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// The download loop: bytes → spool, batched. Runs as its own task inside the actor;
    /// all spool access is serialized here with the consumer's pulls.
    private func runDownload(request: URLRequest) async {
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse {
                guard (200 ..< 300).contains(http.statusCode) else {
                    networkFailure = .http(http.statusCode)
                    return
                }
                if http.expectedContentLength > 0 {
                    spool?.expectedByteCount = http.expectedContentLength
                }
            }
            // 16 KB batches: small enough that a slow trickle reaches the decoder
            // promptly (time-to-first-audio, and honest stall behaviour — a 64 KB batch
            // held back ~0.7 s of a stalled WAV, measured), large enough to amortize
            // the spool write.
            var batch = [UInt8]()
            batch.reserveCapacity(16 * 1024)
            for try await byte in bytes {
                if cancelled { return }
                batch.append(byte)
                if batch.count >= 16 * 1024 {
                    spool?.append(Data(batch))
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if !batch.isEmpty { spool?.append(Data(batch)) }
            spool?.markComplete()
        } catch is CancellationError {
            // cancelled — the source is being torn down; nothing to report
        } catch {
            networkFailure = .transport(error.localizedDescription)
        }
    }

    // MARK: - Pull

    /// The next decoded chunk, waiting for the network as needed. Returns nil at a clean
    /// end of stream; throws on network or decode failure. Serialized by the actor —
    /// callers must not pull concurrently (the single feeder task is the only caller).
    func nextChunk() async throws -> Chunk? {
        guard let spool, let decoder else { return nil }
        if let failure = networkFailure { throw failure }

        // Announce the format once it's known (parse until it is). PCM decoded along
        // the way is staged, not dropped — the header and the first audio usually share
        // a parse chunk.
        if !deliveredFormat {
            while decoder.pcmFormat == nil {
                switch try await parseMore(spool: spool, decoder: decoder) {
                case .produced(let buffers): stagedBuffers.append(contentsOf: buffers)
                case .waiting: continue
                case .ended: break
                }
                if spool.isComplete, spool.byteCount <= parseOffset { break }
            }
            if let format = decoder.pcmFormat {
                deliveredFormat = true
                return .format(format)
            }
            // Stream ended before a format emerged: an unsupported payload (Ogg, an HTML
            // error page) — report it as such rather than as a silent empty track.
            throw SourceError.decode("stream ended before any audio format was found")
        }

        // Drain anything staged during format discovery first.
        while !stagedBuffers.isEmpty {
            let staged = stagedBuffers.removeFirst()
            if let buffer = trimmed([staged]) { return .pcm(buffer) }
        }

        // Parse until at least one PCM buffer lands (a chunk of MP3 bytes can parse to
        // zero complete packets), the stream ends, or we're cancelled.
        while true {
            if let failure = networkFailure { throw failure }
            switch try await parseMore(spool: spool, decoder: decoder) {
            case .produced(let buffers):
                if let buffer = trimmed(buffers) { return .pcm(buffer) }
            case .waiting:
                continue
            case .ended:
                return nil
            }
        }
    }

    private enum ParseStep { case produced([AVAudioPCMBuffer]), waiting, ended }

    private func parseMore(spool: StreamSpool, decoder: AudioStreamDecoder) async throws -> ParseStep {
        guard let data = spool.read(at: parseOffset, length: Self.parseChunkBytes) else {
            if spool.isComplete { return .ended }
            // Nothing spooled at the read position yet — the network is behind. Wait a
            // beat; cancellation lands between polls.
            try await Task.sleep(for: Self.growthPoll)
            return .waiting
        }
        parseOffset += Int64(data.count)
        let produced: [AVAudioPCMBuffer]
        do {
            produced = try decoder.parse(data)
        } catch {
            throw SourceError.decode("\(error)")
        }
        return produced.isEmpty ? .waiting : .produced(produced)
    }

    /// Apply a pending seek trim to the first decoded buffer after a reposition, and fold
    /// multiple buffers from one drain into their first (the converter effectively always
    /// returns one, but the API allows more).
    private func trimmed(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard var buffer = buffers.first else { return nil }
        for extra in buffers.dropFirst() {
            // Extremely rare path; keep the later buffer if the first was fully trimmed.
            if buffer.frameLength == 0 { buffer = extra }
        }
        if pendingTrimFrames > 0 {
            let drop = min(pendingTrimFrames, Int(buffer.frameLength))
            pendingTrimFrames -= drop
            if drop > 0, let trimmedBuffer = Self.dropFirst(frames: drop, of: buffer) {
                buffer = trimmedBuffer
            }
        }
        return buffer.frameLength > 0 ? buffer : nil
    }

    /// A copy of `buffer` without its first `frames` frames (deinterleaved float only).
    static func dropFirst(frames: Int, of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let remaining = Int(buffer.frameLength) - frames
        guard remaining > 0 else {
            buffer.frameLength = 0
            return buffer
        }
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(remaining)),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else { return nil }
        for channel in 0 ..< Int(buffer.format.channelCount) {
            dst[channel].update(from: src[channel] + frames, count: remaining)
        }
        out.frameLength = AVAudioFrameCount(remaining)
        return out
    }

    // MARK: - Seek

    enum SeekOutcome: Equatable {
        /// Repositioned inside the spool; subsequent pulls decode from the target.
        case repositioned
        /// The target's bytes haven't arrived (or can't be mapped) — the caller
        /// re-requests the stream with `timeOffset` instead (see `StreamSeek`).
        case unreachable
    }

    /// Reposition decoding to `seconds` (stream-local). Only reachable positions
    /// succeed — the spool must already hold the mapped byte.
    func seek(toSeconds seconds: TimeInterval) -> SeekOutcome {
        guard let spool, let decoder, decoder.sampleRate > 0 else { return .unreachable }
        let targetFrame = Int64(seconds * decoder.sampleRate)
        guard let target = decoder.seekTarget(forFrame: targetFrame),
              target.byteOffset < spool.byteCount else { return .unreachable }
        parseOffset = target.byteOffset
        stagedBuffers.removeAll() // pre-seek audio must not play after the jump
        decoder.signalDiscontinuity()
        // Land sample-accurately when the parser mapped a real packet; an estimated
        // offset already isn't frame-true, so trimming to it would be a fiction.
        pendingTrimFrames = target.isEstimate ? 0 : Int(targetFrame - target.packetStartFrame)
        return .repositioned
    }

    /// The stream-local seconds range decodable right now — what has actually spooled,
    /// in seconds, via the decoder's running bytes-per-second estimate. Feeds the
    /// unchanged `StreamSeek.strategy` as this stream's "seekable range". Conservative:
    /// unknown rate ⇒ empty ⇒ the caller reloads (the safe side).
    func reachableSeconds() -> ClosedRange<TimeInterval>? {
        guard let spool, let decoder,
              let bytesPerSecond = decoder.estimatedBytesPerSecond, bytesPerSecond > 0 else { return nil }
        let audioBytes = max(0, spool.byteCount - decoder.dataOffset)
        let end = Double(audioBytes) / bytesPerSecond
        return end > 0 ? 0...end : nil
    }

    /// Whether the download has delivered every byte (distinguishes "stream ended" from
    /// "network is behind" for the stall story).
    var downloadComplete: Bool { spool?.isComplete ?? false }
    var spooledBytes: Int64 { spool?.byteCount ?? 0 }

    func cancel() {
        cancelled = true
        networkTask?.cancel()
        networkTask = nil
        spool?.closeAndDelete()
        spool = nil
    }
}

#endif
