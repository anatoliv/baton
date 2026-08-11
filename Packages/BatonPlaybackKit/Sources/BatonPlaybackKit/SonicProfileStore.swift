#if !os(watchOS)
import AVFoundation
import Foundation
import BatonDSP

/// Sonic profiles for tracks, measured once from the audio and kept.
///
/// `SonicProfile` turns a waveform into energy, brightness and tempo; this is what gets
/// those numbers out of files and in front of a mix builder. It exists as a sibling of
/// `TrackLevelTimeline` and deliberately mirrors it — same offline decode, same
/// analyze-local-files-in-place rule, same "return quietly on failure" posture, because a
/// track that will not analyze must still play.
///
/// Where it differs, and why:
///
/// **It never fetches.** `TrackLevelTimeline` will re-download a streamed track because its
/// output drives an indicator the user is looking at *right now*. A sonic profile is only
/// useful when building a mix later, so spending a second full transfer per track to get it
/// is a bad trade. It analyzes what is already on disk — downloads, and the copies the
/// gapless prefetcher leaves behind — which over normal listening is most of the library
/// people actually play.
///
/// **It persists.** The band envelope is worth ~4 KB a minute and is only interesting while
/// a track plays, so it lives in memory and is dropped. A profile is three floats and is
/// interesting forever; re-deriving it on every launch would waste the decode.
public actor SonicProfileStore {
    public static let shared = SonicProfileStore()

    /// Profiles read at most this many seconds into a track.
    ///
    /// Tempo and tilt are properties of the recording, not of its length, and both settle
    /// long before a track ends — while decoding a whole 70-minute DJ set to learn it is
    /// 122 BPM costs a minute of CPU for an answer the first two would have given. Ninety
    /// seconds is long enough that a slow intro does not dominate the measurement.
    public static let analysisSeconds: Double = 90

    private var profiles: [String: SonicProfile]
    private var inFlight: Set<String> = []
    private let storeURL: URL?

    init(storeURL: URL? = SonicProfileStore.defaultStoreURL()) {
        self.storeURL = storeURL
        self.profiles = SonicProfileStore.load(from: storeURL)
    }

    /// The profile for a track, if one has been measured.
    public func profile(for id: String) -> SonicProfile? { profiles[id] }

    /// Every profile measured so far — what a mix builder sorts and filters on.
    public func allProfiles() -> [String: SonicProfile] { profiles }

    public func hasProfile(for id: String) -> Bool { profiles[id] != nil }

    /// Measure a local audio file, unless it is already measured or in flight.
    ///
    /// Returns the profile so a caller that wants it immediately does not have to poll,
    /// and nil when the file cannot be analyzed — an unreadable or exotic file is not an
    /// error worth surfacing, it just has no profile.
    @discardableResult
    public func analyzeLocal(id: String, url: URL) async -> SonicProfile? {
        if let existing = profiles[id] { return existing }
        guard !inFlight.contains(id) else { return nil }
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        let seconds = Self.analysisSeconds
        let profile = await Task.detached(priority: .utility) {
            Self.analyze(url: url, seconds: seconds)
        }.value
        guard let profile else { return nil }
        profiles[id] = profile
        persist()
        return profile
    }

    /// Forget everything measured. Paired with the same control that clears the other
    /// derived caches, so "clear cached data" means what it says.
    public func clear() {
        profiles.removeAll()
        persist()
    }

    // MARK: - Decoding

    /// Decode up to `seconds` of `url` to mono float samples and profile them.
    ///
    /// Mono-summed before analysis: a stereo-dependent tempo or brightness would move with
    /// the mix rather than the music, which is the same reason `LevelAnalyzer` analyzes the
    /// channel sum.
    nonisolated static func analyze(url: URL, seconds: Double) -> SonicProfile? {
        let asset = AVURLAsset(url: url)
        guard let reader = try? AVAssetReader(asset: asset),
              let track = asset.tracks(withMediaType: .audio).first else { return nil }

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

        var samples: [Float] = []
        var sampleRate = 44_100.0
        var channels = 1
        var limit = Int(sampleRate * seconds)

        while samples.count < limit, let sample = output.copyNextSampleBuffer() {
            if let format = CMSampleBufferGetFormatDescription(sample),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44_100
                channels = max(1, Int(asbd.mChannelsPerFrame))
                limit = Int(sampleRate * seconds)
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            let floats = UnsafeRawPointer(pointer).bindMemory(to: Float.self, capacity: length / 4)
            let count = length / 4
            if channels == 1 {
                samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
            } else {
                var frame = 0
                while frame + channels <= count {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += floats[frame + channel] }
                    samples.append(sum / Float(channels))
                    frame += channels
                }
            }
        }
        reader.cancelReading()
        guard !samples.isEmpty else { return nil }
        return SonicAnalyzer.analyze(samples: samples, sampleRate: sampleRate)
    }

    // MARK: - Persistence

    nonisolated static func defaultStoreURL() -> URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                         in: .userDomainMask,
                                                         appropriateFor: nil, create: true)
        else { return nil }
        let directory = support.appendingPathComponent("Baton", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("sonic-profiles.json")
    }

    nonisolated static func load(from url: URL?) -> [String: SonicProfile] {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: SonicProfile].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persist() {
        guard let storeURL, let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
#endif
