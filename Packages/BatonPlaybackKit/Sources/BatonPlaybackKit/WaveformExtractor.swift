#if !os(watchOS)
import AVFoundation
import Foundation

/// Builds a normalized amplitude envelope (0…1 bars) for a **local** audio file so the
/// scrubber can show a real waveform. Only works on downloaded tracks — a live stream
/// can't be analyzed ahead of the playhead — so callers fall back to a plain bar when this
/// returns nil. Results are cached per song id and requested bar count.
public enum WaveformExtractor {
    private struct CacheKey: Hashable, Sendable {
        let songID: String
        let barCount: Int
    }

    @MainActor private static var cache: [CacheKey: [Float]] = [:]
    @MainActor private static var inFlight: [CacheKey: Task<[Float]?, Never>] = [:]

#if DEBUG
    typealias Extraction = @Sendable (URL, Int) async -> [Float]?
    @MainActor private static var extractionOverrideForTesting: Extraction?
#endif

    /// Where computed waveforms persist so a downloaded track keeps an instant waveform
    /// across launches (the extraction is the expensive part).
    private nonisolated static var diskDir: URL {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Tonebox/waveforms", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private nonisolated static func diskURL(_ key: CacheKey) -> URL {
        let id = key.songID.replacingOccurrences(of: "/", with: "_")
        return diskDir.appendingPathComponent("\(id)-\(key.barCount).json")
    }

    private nonisolated static func legacyDiskURL(_ id: String) -> URL {
        diskDir.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    private nonisolated static func cachedBars(at url: URL, count: Int) -> [Float]? {
        guard let data = try? Data(contentsOf: url),
              let bars = try? JSONDecoder().decode([Float].self, from: data),
              bars.count == count
        else { return nil }
        return bars
    }

    private nonisolated static func persist(_ bars: [Float], at url: URL) {
        // `.atomic`: the cache is derived data, but a torn file is not free. The decode only
        // runs when the read fails, so a half-written file is re-read on every launch until
        // the track is played again, and each of those reads pays a full PCM extraction.
        // A temporary file and a rename means the reader sees the old bars or the new ones.
        guard let data = try? JSONEncoder().encode(bars) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Cached bars for a song: memory → disk → compute (off the main actor) + persist.
    /// Returns nil if the file can't be read.
    @MainActor
    public static func bars(forSongID id: String, url: URL, count: Int = 120) async -> [Float]? {
        guard count > 0 else { return nil }
        let key = CacheKey(songID: id, barCount: count)
        if let cached = cache[key] { return cached }
        // Disk cache (survives relaunches for downloaded tracks).
        if let bars = cachedBars(at: diskURL(key), count: count) {
            cache[key] = bars
            return bars
        }
        // One release of Baton wrote `<song>.json`. It is safe to migrate that value only
        // when its shape happens to match this request; otherwise recompute at the requested
        // resolution instead of stretching or collapsing the old waveform.
        if let bars = cachedBars(at: legacyDiskURL(id), count: count) {
            cache[key] = bars
            persist(bars, at: diskURL(key))
            return bars
        }
        if let work = inFlight[key] { return await work.value }

#if DEBUG
        let extraction = extractionOverrideForTesting
#endif
        let work = Task {
#if DEBUG
            if let extraction { return await extraction(url, count) }
#endif
            return await extract(url: url, barCount: count)
        }
        inFlight[key] = work
        let result = await work.value
        inFlight[key] = nil
        if let result {
            cache[key] = result
            persist(result, at: diskURL(key))
        }
        return result
    }

#if DEBUG
    @MainActor
    static func resetForTesting(extraction: Extraction? = nil) {
        for work in inFlight.values { work.cancel() }
        inFlight.removeAll()
        cache.removeAll()
        extractionOverrideForTesting = extraction
    }
#endif

    /// Read PCM, reduce to `barCount` peak-amplitude buckets, and normalize to 0…1.
    /// `nonisolated async` so the blocking sample read runs off the main actor.
    private nonisolated static func extract(url: URL, barCount: Int) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var peaks = [Float](repeating: 0, count: barCount)
        var counts = [Int](repeating: 0, count: barCount)
        var sampleIndex = 0
        let sampleRate = (try? await track.load(.naturalTimeScale)) ?? 44_100
        let durationSeconds = ((try? await asset.load(.duration))?.seconds) ?? 0
        let totalSamples = max(1, Int(durationSeconds * Double(sampleRate)))

        while reader.status == .reading, let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let samples = raw.bindMemory(to: Int16.self)
                for sample in samples {
                    let bucket = min(barCount - 1, sampleIndex * barCount / totalSamples)
                    let amp = abs(Float(sample)) / Float(Int16.max)
                    peaks[bucket] = max(peaks[bucket], amp)
                    counts[bucket] += 1
                    sampleIndex += 1
                }
            }
            CMSampleBufferInvalidate(buffer)
        }
        guard reader.status == .completed || reader.status == .reading, sampleIndex > 0 else { return nil }
        return normalizeBars(peaks: peaks, counts: counts)
    }

    /// Pure reduction step, factored out of `extract` so it's testable without a real audio
    /// file: fill empty buckets (a bar with no samples, e.g. from a sparse tail) with the last
    /// real value, then scale to 0…1 by the loudest bar. Returns nil for an all-silent input,
    /// so callers fall back to a plain bar rather than drawing a flat line.
    public nonisolated static func normalizeBars(peaks: [Float], counts: [Int]) -> [Float]? {
        var peaks = peaks
        var last: Float = 0
        for i in peaks.indices {
            if i < counts.count, counts[i] == 0 { peaks[i] = last } else { last = peaks[i] }
        }
        let maxPeak = peaks.max() ?? 1
        guard maxPeak > 0 else { return nil }
        return peaks.map { min(1, $0 / maxPeak) }
    }
}
#else
import Foundation

/// watchOS: AVAssetReader doesn't exist, and the watch UI has no scrubber that
/// draws waveforms — same API shape, no work.
public enum WaveformExtractor {
    public static func bars(forSongID songID: String, url: URL) async -> [Float]? { nil }
}
#endif
