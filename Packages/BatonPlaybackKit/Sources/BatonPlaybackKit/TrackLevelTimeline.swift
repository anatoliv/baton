#if !os(watchOS)
import AVFoundation
import Foundation
import BatonDSP

/// Band levels for a whole track, computed offline and indexed by playhead time — how the
/// now-playing bars follow music that AVFoundation won't let us hear live.
///
/// The live route is closed by the platform: `MTAudioProcessingTap` never runs for
/// HTTP-streamed items (proved empirically — a mix attached at `readyToPlay`, rate 0.0,
/// before any render, and the tap still never fired; the same build meters local files
/// fine). But a Subsonic stream is just an HTTP file. So for streamed tracks we fetch the
/// same bytes *beside* playback, run the same `LevelAnalyzer` over them offline, and drive
/// the bars by `levels(at: currentTime)`. The movement is the actual recorded track,
/// beat-accurate at the analysis hop — not a simulation.
///
/// Costs, called out rather than hidden: an analysis fetch re-downloads the track
/// (`analysisFetchCap` bounds the worst case — a 70-minute DJ mix does not get a second
/// 100 MB transfer; the envelope simply ends where the cap ended and the bars fall back).
/// Local files — downloads, gapless-prefetched copies — are analyzed in place with no
/// fetch at all.
public enum TrackLevelTimeline {
    /// Seconds between envelope entries. 50 ms ≈ ground truth for a 15-point bar; finer
    /// buys nothing visible and triples the memory.
    public static let hop: Double = 0.05

    /// The most a background analysis fetch may transfer. At 320 kbps this still covers
    /// ~12 minutes of audio; typical tracks fit whole.
    public static let analysisFetchCap = 30_000_000

    /// In-memory envelopes, newest-kept. Each entry is ~4 KB/minute — eight tracks of
    /// slack costs less than one cover image.
    @MainActor private static var cache: [String: [BandLevels]] = [:]
    @MainActor private static var order: [String] = []
    private static let cacheLimit = 8

    @MainActor private static var inFlight: Set<String> = []

    /// The levels at a playhead position, or nil when this track has no envelope (not
    /// analyzed, or the position is past a capped analysis).
    @MainActor
    public static func levels(id: String, at time: Double) -> BandLevels? {
        guard let envelope = cache[id], time >= 0 else { return nil }
        let index = Int(time / hop)
        guard envelope.indices.contains(index) else { return nil }
        return envelope[index]
    }

    @MainActor
    public static func hasEnvelope(id: String) -> Bool { cache[id] != nil }

    /// Analyze a local audio file into the cache. Returns quietly on any failure — an
    /// indicator must never surface an error for a track that plays fine.
    @MainActor
    public static func analyzeLocal(id: String, url: URL) async {
        guard cache[id] == nil, !inFlight.contains(id) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        let envelope = await Task.detached(priority: .utility) { extract(url: url) }.value
        if let envelope, !envelope.isEmpty { store(id: id, envelope) }
    }

    /// Fetch a streamed track's bytes (bounded by `analysisFetchCap`) and analyze them.
    /// `fetch` is injectable for tests; the default is a plain download of the stream URL.
    @MainActor
    public static func analyzeStream(
        id: String, url: URL,
        fetch: (@Sendable (URL, Int) async -> URL?)? = nil
    ) async {
        guard cache[id] == nil, !inFlight.contains(id) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        let cap = analysisFetchCap
        let download = fetch ?? Self.download
        guard let local = await download(url, cap) else { return }
        defer { try? FileManager.default.removeItem(at: local) }
        let envelope = await Task.detached(priority: .utility) { extract(url: local) }.value
        if let envelope, !envelope.isEmpty { store(id: id, envelope) }
    }

    @MainActor
    public static func clear() {
        cache.removeAll(); order.removeAll()
    }

    @MainActor
    private static func store(id: String, _ envelope: [BandLevels]) {
        cache[id] = envelope
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > cacheLimit, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    /// Download up to `cap` bytes of `url` to a temp file. A Range header would be
    /// cleaner, but Navidrome's transcode endpoint ignores ranges — so read the body
    /// stream and stop at the cap instead.
    private static func download(url: URL, cap: Int) async -> URL? {
        do {
            let (bytes, response) = try await URLSession.shared.bytes(from: url)
            guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true
            else { return nil }
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("baton-levels-\(UUID().uuidString).mp3")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            defer { try? handle.close() }
            var buffer = Data(); buffer.reserveCapacity(1 << 16)
            var written = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 16 {
                    try handle.write(contentsOf: buffer)
                    written += buffer.count
                    buffer.removeAll(keepingCapacity: true)
                    if written >= cap { break }
                }
            }
            if !buffer.isEmpty, written < cap { try handle.write(contentsOf: buffer) }
            return out
        } catch {
            return nil
        }
    }

    /// Decode a file and run the shared band analyzer over it at `hop` resolution.
    /// nonisolated + synchronous: runs on a detached task, touches nothing shared.
    private nonisolated static func extract(url: URL) -> [BandLevels]? {
        let asset = AVURLAsset(url: url)
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        // Synchronous track load is fine off-main; AVAssetReader needs the track anyway.
        guard let track = asset.tracks(withMediaType: .audio).first else { return nil }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let analyzer = LevelAnalyzer()
        var envelope: [BandLevels] = []
        var sampleRate = 44_100.0
        var channels = 1
        var hopFrames = Int(sampleRate * hop)
        var carry: [Float] = []
        var prepared = false

        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            if !prepared, let format = CMSampleBufferGetFormatDescription(sample),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44_100
                channels = max(1, Int(asbd.mChannelsPerFrame))
                hopFrames = max(1, Int(sampleRate * hop))
                analyzer.prepare(sampleRate: sampleRate)
                prepared = true
            }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            let floats = UnsafeRawPointer(pointer).bindMemory(to: Float.self, capacity: length / 4)
            let frameCount = length / 4 / channels
            // Interleaved → mono per frame, appended to the carry until a hop fills.
            for f in 0 ..< frameCount {
                var mono: Float = 0
                for c in 0 ..< channels { mono += floats[f * channels + c] }
                carry.append(mono / Float(channels))
                if carry.count == hopFrames {
                    appendHop(&carry, analyzer: analyzer, into: &envelope)
                }
            }
        }
        if !carry.isEmpty { appendHop(&carry, analyzer: analyzer, into: &envelope) }
        return envelope
    }

    private nonisolated static func appendHop(
        _ carry: inout [Float], analyzer: LevelAnalyzer, into envelope: inout [BandLevels]
    ) {
        carry.withUnsafeMutableBufferPointer { buf in
            var ptr: UnsafeMutablePointer<Float>? = buf.baseAddress
            withUnsafePointer(to: &ptr) {
                envelope.append(analyzer.analyze(channelPointers: $0, channelCount: 1, frames: buf.count))
            }
        }
        carry.removeAll(keepingCapacity: true)
    }
}
#endif
