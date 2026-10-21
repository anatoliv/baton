#if os(iOS) || os(macOS)
import AVFoundation
import BatonSubsonicKit
import BatonSubsonicModels
import Foundation
import OSLog
import os

/// The sound an alarm or timer rings on the iPhone: the first 29 seconds of its own track, cut
/// into `Library/Sounds/baton-alarm-<id>.caf` (TBX-11171, TBX-1000000410,
/// specs/alarm-and-timer.md). AlarmKit (`.named`) and notifications (`UNNotificationSound`) both
/// take a file by name from the app's `Library/Sounds`, at most 30 seconds, Linear PCM in a CAF
/// among the accepted forms.
///
/// What rings, in order: the clip when it is made, else the bundled chime, else the system's
/// own sound (an empty name).
///
/// A clip is cut from anything Baton can play: a local file directly (downloads, clippings, book
/// chapters, the demo library), and a server stream by fetching it (with the server's extra
/// headers) to a temporary file first,
/// because `AVAssetReader` refuses a non-local URL outright ("Cannot initialize an instance of
/// AVAssetReader with an asset at non-local URL"). Before TBX-1000000410 a stream was handed to
/// the reader as it was, so a server track never had a clip.
@MainActor
public final class AlarmClipStore {
    public static let clipSeconds: Double = 29
    /// Fetching a stream and cutting it. A stream that does not arrive in time keeps the chime.
    public static let defaultTimeout: Duration = .seconds(45)
    /// Baton's chime, bundled in both apps.
    public nonisolated static let chime = "BatonAlarmChime.caf"
    private static let madeFromKey = "baton.alarms.clips"
    private nonisolated static let prefix = "baton-alarm-"

    public let directory: URL
    private let defaults: UserDefaults
    private let session: URLSession
    private let hasChime: Bool
    private let timeout: Duration
    private let log = Logger(subsystem: "io.tonebox.baton", category: "alarms")
    /// Resolves a song to something readable; the app's own stream resolver by default.
    public var resolve: (String) -> URL? = { try? StreamingPlaybackController.resolveStreamURL(songID: $0) }
    /// The HTTP headers a stream from `url` needs: the active server's extra headers (a server
    /// behind a header-checking proxy) when the stream is on that server, as the player and
    /// downloads send them, and none for any other host, so they never leave for a podcast's.
    public var headers: (URL) -> [String: String] = { url in
        guard let server = NavidromeConfig.serverURL, server.host?.lowercased() == url.host?.lowercased(),
              server.port == url.port else { return [:] }
        return NavidromeConfig.customHeaders()
    }
    /// The preparation running now. A second one waits for it, so two syncs never cut the same
    /// clip at once (the store's observer starts a sync for every change, and a cancelled sync
    /// task does not stop one already preparing).
    private var running: Task<Bool, Never>?
    /// A clip that could not be cut, by alarm, with the song and when: not tried again for
    /// `retryAfter`, so a server that is away does not cost every sync a fetch timeout per alarm.
    private var failed: [UUID: (song: String, at: Date)] = [:]
    public var retryAfter: TimeInterval = 10 * 60
    public var now: () -> Date = Date.init

    /// The app's `Library/Sounds`, where AlarmKit and notifications look for a named sound.
    public static var soundsDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Sounds", isDirectory: true)
    }

    public init(directory: URL = AlarmClipStore.soundsDirectory, defaults: UserDefaults = BatonStorage.defaults,
                session: URLSession = .shared,
                hasChime: Bool = Bundle.main.url(forResource: "BatonAlarmChime", withExtension: "caf") != nil,
                timeout: Duration = AlarmClipStore.defaultTimeout) {
        self.directory = directory
        self.defaults = defaults
        self.session = session
        self.hasChime = hasChime
        self.timeout = timeout
    }

    public nonisolated static func fileName(for id: UUID) -> String { "\(prefix)\(id.uuidString).caf" }

    public func clipURL(for id: UUID) -> URL { directory.appendingPathComponent(Self.fileName(for: id)) }

    /// Which song each clip was cut from, so a changed alarm gets a new clip.
    private var madeFrom: [UUID: String] {
        get {
            (defaults.dictionary(forKey: Self.madeFromKey) as? [String: String] ?? [:])
                .reduce(into: [:]) { result, pair in if let id = UUID(uuidString: pair.key) { result[id] = pair.value } }
        }
        set {
            defaults.set(Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.uuidString, $0.value) }), forKey: Self.madeFromKey)
        }
    }

    /// Whether `id` has a clip of its track ready now.
    public func hasClip(for id: UUID) -> Bool {
        madeFrom[id] != nil && FileManager.default.fileExists(atPath: clipURL(for: id).path)
    }

    /// The name to hand AlarmKit or a notification for `id`: the clip, else the chime, else ""
    /// (the system's own sound).
    public func soundName(for id: UUID) -> String {
        if hasClip(for: id) { return Self.fileName(for: id) }
        return hasChime ? Self.chime : ""
    }

    /// Makes the clips the store needs and removes the ones it no longer does. True when a clip
    /// was made or removed, so the caller schedules again with the new sound.
    @discardableResult
    public func prepare(_ store: AlarmStore) async -> Bool {
        let previous = running
        let task = Task { @MainActor [weak self] () -> Bool in
            _ = await previous?.value
            guard let self else { return false }
            return await self.prepareNow(store)
        }
        running = task
        return await task.value
    }

    private func prepareNow(_ store: AlarmStore) async -> Bool {
        var wanted: [UUID: NavidromeSong] = [:]
        for alarm in store.alarms where alarm.isEnabled {
            if let song = alarm.choice.songs[safe: alarm.choice.startIndex] { wanted[alarm.id] = song }
        }
        if let timer = store.timer, let song = timer.choice.songs[safe: timer.choice.startIndex] { wanted[timer.id] = song }
        var made = madeFrom
        var changed = false
        for id in made.keys where wanted[id] == nil {
            try? FileManager.default.removeItem(at: clipURL(for: id))
            made[id] = nil
            changed = true
        }
        // A clip left behind by an alarm deleted while a preparation was cut short.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(Self.prefix) && name.hasSuffix(".caf") {
            let raw = String(name.dropFirst(Self.prefix.count).dropLast(4))
            if let id = UUID(uuidString: raw), wanted[id] == nil {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        for (id, song) in wanted.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            if made[id] == song.id, FileManager.default.fileExists(atPath: clipURL(for: id).path) { continue }
            if made[id] != nil { changed = true }
            made[id] = nil
            madeFrom = made
            if let last = failed[id], last.song == song.id, now().timeIntervalSince(last.at) < retryAfter { continue }
            guard let source = resolve(song.id) else {
                failed[id] = (song.id, now())
                log.info("alarm clip not made for \(id.uuidString, privacy: .public): nothing to read; the chime rings")
                continue
            }
            if await Self.render(from: source, to: clipURL(for: id), seconds: Self.clipSeconds, timeout: timeout,
                                 session: session, headers: source.isFileURL ? [:] : headers(source)) {
                // Cut again from the track whenever it is missing, so it need not take backup space.
                if BackupExclusion.appliesOnThisPlatform { BackupExclusion.exclude(clipURL(for: id)) }
                made[id] = song.id
                failed[id] = nil
                changed = true
                log.info("alarm clip made for \(id.uuidString, privacy: .public)")
            } else {
                failed[id] = (song.id, now())
                log.info("alarm clip not made for \(id.uuidString, privacy: .public); the chime rings")
            }
        }
        madeFrom = made
        return changed
    }

    // MARK: Cutting

    /// Cuts the first `seconds` of `source` into a 16-bit mono 22.05 kHz Linear PCM CAF at
    /// `target`, fetching a remote source to a temporary file first. The clip is written beside
    /// and moved into place only when it is whole and valid, so the system never finds half a
    /// file under the name. False when the source cannot be read in time; then `target` is
    /// left as it was.
    public nonisolated static func render(from source: URL, to target: URL, seconds: Double, timeout: Duration,
                                          session: URLSession = .shared, headers: [String: String] = [:]) async -> Bool {
        let partial = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-alarm-\(UUID().uuidString).partial.caf")
        // A stream that stalls blocks inside AVAssetReader, where cancelling cannot reach it, so
        // the timeout races the work instead of waiting for it.
        let decided = OSAllocatedUnfairLock(initialState: false)
        let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let work = Task.detached(priority: .utility) {
                let ok = await fetchAndCut(from: source, to: partial, seconds: seconds, session: session, headers: headers)
                if decided.withLock({ let first = !$0; $0 = true; return first }) {
                    continuation.resume(returning: ok)
                } else {
                    // The timeout won and its cleanup has run: take away what was written since.
                    try? FileManager.default.removeItem(at: partial)
                }
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                if decided.withLock({ let first = !$0; $0 = true; return first }) {
                    work.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
        defer { try? FileManager.default.removeItem(at: partial) }
        guard ok, let info = clipInfo(at: partial), info.isLinearPCM, info.seconds > 0, info.seconds <= seconds + 0.5 else {
            return false
        }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: target)
            }
            return true
        } catch {
            return false
        }
    }

    /// What a sound file is, for checking a clip: whether it is Linear PCM, and how long.
    public struct ClipInfo: Equatable, Sendable {
        public let isLinearPCM: Bool
        public let seconds: Double
        public let sampleRate: Double
        public let channels: Int
    }

    public nonisolated static func clipInfo(at url: URL) -> ClipInfo? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.fileFormat
        let rate = format.sampleRate
        guard rate > 0 else { return nil }
        return ClipInfo(isLinearPCM: format.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
                        seconds: Double(file.length) / rate, sampleRate: rate, channels: Int(format.channelCount))
    }

    private nonisolated static func fetchAndCut(from source: URL, to target: URL, seconds: Double,
                                                session: URLSession, headers: [String: String]) async -> Bool {
        guard !source.isFileURL else { return await cut(from: AVURLAsset(url: source), to: target, seconds: seconds) }
        guard let (file, mime) = await fetch(source, session: session, headers: headers) else { return false }
        defer { try? FileManager.default.removeItem(at: file) }
        guard !Task.isCancelled else { return false }
        let options: [String: Any] = mime.map { [AVURLAssetOverrideMIMETypeKey: $0] } ?? [:]
        return await cut(from: AVURLAsset(url: file, options: options), to: target, seconds: seconds)
    }

    /// Downloads a stream to a temporary file named with the extension its type calls for, since
    /// AVFoundation reads a local file by its extension.
    nonisolated static func fetch(_ source: URL, session: URLSession, headers: [String: String] = [:]) async -> (URL, String?)? {
        var request = URLRequest(url: source)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let (download, response) = try? await session.download(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: download)
            return nil
        }
        let mime = response.mimeType?.lowercased()
        let named = response.suggestedFilename.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
        let ext = !named.isEmpty && named != "bin" ? named : fileExtension(forMIME: mime) ?? source.pathExtension
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-alarm-source-\(UUID().uuidString)")
            .appendingPathExtension(ext.isEmpty ? "mp3" : ext)
        do {
            try FileManager.default.moveItem(at: download, to: file)
        } catch {
            try? FileManager.default.removeItem(at: download)
            return nil
        }
        return (file, mime)
    }

    nonisolated static func fileExtension(forMIME mime: String?) -> String? {
        switch mime {
        case "audio/mpeg", "audio/mp3", "audio/mpeg3": "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/aac", "audio/x-aac": "m4a"
        case "audio/flac", "audio/x-flac": "flac"
        case "audio/wav", "audio/x-wav", "audio/wave": "wav"
        case "audio/aiff", "audio/x-aiff": "aiff"
        case "audio/x-caf": "caf"
        default: nil
        }
    }

    private nonisolated static func cut(from asset: AVURLAsset, to target: URL, seconds: Double) async -> Bool {
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return false }
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
            let pcm: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 22_050, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
            reader.add(output)
            let writer = try AVAssetWriter(outputURL: target, fileType: .caf)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            guard reader.startReading(), writer.startWriting() else { return false }
            writer.startSession(atSourceTime: .zero)
            while let buffer = output.copyNextSampleBuffer() {
                if Task.isCancelled { reader.cancelReading(); writer.cancelWriting(); return false }
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                input.append(buffer)
            }
            input.markAsFinished()
            await writer.finishWriting()
            return reader.status == .completed && writer.status == .completed
        } catch {
            return false
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
