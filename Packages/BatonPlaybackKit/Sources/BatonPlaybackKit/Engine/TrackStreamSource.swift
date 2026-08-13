#if os(macOS) || os(iOS)
// The engine is macOS/iOS only. watchOS has no AudioToolbox — no `AudioFileStream`, so no
// decoder, so no engine — and it plays downloaded files through AVPlayer. See
// `EngineDeckUnavailable.swift` for the stand-in that keeps the policy layer compiling.

import AVFoundation
import Foundation
import OSLog

let engineLog = Logger(subsystem: "io.tonebox.baton", category: "EnginePlayback")

/// What the download delegate hands the actor. Deliberately plain values rather than the
/// `URLResponse` itself: this crosses a concurrency domain under Swift 6, and a status code
/// and a length are `Sendable` where the response object is not.
private enum DownloadEvent: Sendable {
    case head(statusCode: Int, expectedLength: Int64)
    case data(Data)
}

/// Bridges URLSession's delegate callbacks into an ordered async stream.
///
/// Order is the whole point, and it is why this is a stream rather than a `Task` per
/// callback: URLSession delivers a task's callbacks serially on its delegate queue, and
/// `yield` preserves that order, whereas spawning a task per chunk would let the actor
/// append them interleaved and silently corrupt the byte stream.
///
/// The buffer is unbounded on purpose. Every other policy drops elements, and a dropped
/// chunk here is not backpressure — it is a corrupt track.
private final class StreamDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation

    init(continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // A non-HTTP response (a file: URL in a test) has no status; treat it as 200 so the
        // status guard stays about real HTTP failures.
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        continuation.yield(.head(statusCode: status, expectedLength: response.expectedContentLength))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}

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
    /// The file byte this stream was asked to begin at (0 for an ordinary fetch).
    private var rangeStart: Int64 = 0
    /// Bytes still to throw away because the server ignored `Range` and sent the file from
    /// the top anyway. Then the prefix is discarded here rather than decoded and dropped
    /// later, and the spool still begins exactly where the caller was promised.
    private var bytesToDrop: Int64 = 0
    /// Whether the server actually honoured the range. Reported for the log, and for a
    /// caller that wants to know the seek cost what a full fetch costs.
    private(set) var rangeHonoured = true
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
    ///
    /// - Parameters:
    ///   - fromByte: start the *stream* at this byte of the file, via HTTP `Range`. The
    ///     resulting source's own zero is that byte: its spool, its parse offsets and its
    ///     packet numbering all begin there, so nothing downstream needs to know. What the
    ///     caller must know is that the audio starts part-way into the track, which it
    ///     records as `streamStartOffset` exactly as it does for a `timeOffset` stream.
    ///   - fileTypeHint: required with `fromByte`, because a stream that begins mid-file has
    ///     no header to sniff. See `AudioStreamDecoder.fileTypeHint(forSuffix:)`.
    func start(fromByte: Int64 = 0, fileTypeHint: AudioFileTypeID = 0) throws {
        let spool = try StreamSpool()
        self.spool = spool
        decoder = try AudioStreamDecoder(fileTypeHint: fileTypeHint)
        rangeStart = max(0, fromByte)
        bytesToDrop = 0
        let request = makeRequest(fromByte: rangeStart)
        networkTask = Task { [weak self] in
            await self?.runDownload(request: request)
        }
    }

    private func makeRequest(fromByte: Int64) -> URLRequest {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if fromByte > 0 { request.setValue("bytes=\(fromByte)-", forHTTPHeaderField: "Range") }
        return request
    }

    /// The download loop: chunks → spool. Runs as its own task inside the actor; all spool
    /// access is serialized here with the consumer's pulls.
    ///
    /// This used to iterate `URLSession.bytes(for:)`, which is an `AsyncSequence` of
    /// `UInt8` — one async iterator resumption **per byte**, roughly ten million of them
    /// for a 10 MB track, arriving in bursts at wire speed. The bytes were then
    /// re-accumulated into 16 KB batches by hand. A data delegate hands over `Data` as the
    /// network produces it, so the batching and the ten million resumptions both go away.
    ///
    /// A side effect worth naming, because it is an improvement rather than a wash: the old
    /// batching *withheld* a partial batch. A server that sent 10 KB and then stalled left
    /// those bytes sitting in the array, unspooled and undecodable, until either more
    /// arrived or the stream ended — the opposite of what its own comment intended. Chunks
    /// reach the spool as they land.
    private func runDownload(request: URLRequest) async {
        let (events, continuation) = AsyncThrowingStream<DownloadEvent, Error>.makeStream()
        let delegate = StreamDownloadDelegate(continuation: continuation)
        // A delegate is per-session, so this track gets its own rather than sharing
        // `URLSession.shared`. Invalidated on the way out or the session leaks its delegate.
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        continuation.onTermination = { _ in task.cancel() }
        task.resume()
        defer { session.finishTasksAndInvalidate() }

        do {
            for try await event in events {
                if cancelled { task.cancel(); return }
                switch event {
                case .head(let statusCode, let expectedLength):
                    guard (200 ..< 300).contains(statusCode) else {
                        networkFailure = .http(statusCode)
                        task.cancel()
                        return
                    }
                    // 206 means the range was honoured and the body starts where we asked.
                    // 200 to a range request means the server ignored it and is sending the
                    // whole file — legal, and Navidrome does it for transcodes. Rather than
                    // hand the parser a stream that starts somewhere other than it was told,
                    // drop the prefix as it arrives: same bytes over the wire as before this
                    // feature existed, and the spool still begins where it was promised.
                    if rangeStart > 0, statusCode != 206 {
                        rangeHonoured = false
                        bytesToDrop = rangeStart
                        engineLog.info("engine: server ignored Range — dropping \(self.rangeStart) bytes to reach the seek point")
                    }
                    if expectedLength > 0 { spool?.expectedByteCount = expectedLength }
                case .data(let data):
                    var data = data
                    if bytesToDrop > 0 {
                        let drop = min(bytesToDrop, Int64(data.count))
                        bytesToDrop -= drop
                        data = data.dropFirst(Int(drop))
                        if data.isEmpty { continue }
                    }
                    spool?.append(data)
                }
            }
            // Safe on the cancel path too: `cancel()` drops the spool before cancelling the
            // task, so a torn-down source has nothing left to mark complete.
            spool?.markComplete()
        } catch {
            // A cancelled transfer is a teardown, not a failure. Reporting one would raise a
            // spurious error against a track the user has already moved on from.
            if cancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
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
                // The same check the PCM loop below makes, and its absence here was a hang:
                // a connection that dies *before* a format is parsed leaves the spool
                // incomplete and never growing, so `parseMore` answers `.waiting` forever and
                // this loop polls for the rest of the process's life. Nothing throws, so the
                // feeder never fails, so the retry ladder is never told, so the track stops
                // with no error and no next attempt — invisible, because the only thing that
                // logs here is a failure that never arrives.
                if let failure = networkFailure { throw failure }
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

    /// Re-announce the decoded format on the next pull.
    ///
    /// For a consumer that has lost its *graph* while keeping its bytes: an engine
    /// configuration change (device switch, rate change) invalidates node connections, and
    /// the deck is only ever reconnected by `prepareDeck`, which the feeder calls when it
    /// sees a `.format` chunk. Without this the re-feed after a route change would schedule
    /// PCM into a disconnected deck and render silence.
    ///
    /// Costs nothing: the format is already known, so `nextChunk` returns it without
    /// re-parsing a byte, and the parse offset is untouched.
    func replayFormat() { deliveredFormat = false }

    /// Where `seconds` lives in the *file*, for a seek that has to re-request rather than
    /// reposition in the spool.
    ///
    /// This is the mapping the in-spool seek already uses, asked one question further out:
    /// `AudioFileStreamSeek` answers for any target, not only for bytes that happen to have
    /// arrived, and the byte it names is exactly what an HTTP `Range` request wants. Before
    /// this, a target past the spool threw the mapping away and re-fetched from zero — which
    /// on an hour-long file means tens of megabytes and forty minutes of decoding before one
    /// sample can be scheduled.
    ///
    /// Returns nil when the parser cannot map the target (no packet structure yet), and adds
    /// `rangeStart` back so the answer is a file offset even when this source is itself a
    /// range fetch. Callers treat nil as "fetch from zero", the old path.
    /// - Parameter trackDuration: the whole track's length, which turns the file's size into
    ///   a second, independent estimate. Needed because the parser's own extrapolation is
    ///   only as good as the bitrate it has seen so far.
    func fileByteOffset(forSeconds seconds: TimeInterval, trackDuration: TimeInterval) -> Int64? {
        guard let decoder, decoder.sampleRate > 0, seconds > 0 else { return nil }
        let totalBytes = spool?.expectedByteCount ?? 0

        // A mapped packet is the truth: the parser read a real index (a Xing/VBR table) and
        // the byte it names is exact.
        let frame = Int64(seconds * decoder.sampleRate)
        if let target = decoder.seekTarget(forFrame: frame), !target.isEstimate {
            return clampToFile(rangeStart + target.byteOffset, totalBytes: totalBytes)
        }

        // Otherwise it extrapolated from the average bitrate of what it has parsed, and over
        // a long file that is not a small error. Measured live: forty minutes into a 4797 s
        // track, from four seconds of parsed audio, it named a byte past the end of an 8 MB
        // file and the server answered **416 Range Not Satisfiable**.
        //
        // The file's own size is the better extrapolation and cannot overshoot by
        // construction: bytes are proportional to seconds for anything near-constant
        // bitrate, and the answer is bounded by the file. Only for a stream fetched from
        // zero, where "byte X of this stream" and "byte X of the file" are the same thing.
        guard rangeStart == 0, totalBytes > 0, trackDuration > 0, seconds < trackDuration else { return nil }
        let audioStart = decoder.dataOffset
        let audioBytes = Double(totalBytes - audioStart)
        return clampToFile(audioStart + Int64(audioBytes * (seconds / trackDuration)),
                           totalBytes: totalBytes)
    }

    /// A byte the server can actually serve. Past the end is a 416, which costs a wasted
    /// request and a retry.
    private func clampToFile(_ offset: Int64, totalBytes: Int64) -> Int64? {
        guard offset > 0 else { return nil }
        guard totalBytes > 0 else { return offset }   // unknown length: trust the parser
        return offset < totalBytes ? offset : nil     // past the end: no range, use the old path
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
