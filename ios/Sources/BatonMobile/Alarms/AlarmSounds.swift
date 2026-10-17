import AVFoundation
import BatonPlaybackKit
import Foundation
import OSLog
import os

/// The sound an alarm or timer rings through a notification on the iPhone (iOS 18 to 25), and
/// through AlarmKit only with the DEBUG opt-in until a phone check (TBX-11171,
/// specs/alarm-and-timer.md).
///
/// AlarmKit and notifications take a sound file by name, from the app bundle or the app's
/// `Library/Sounds`, at most 30 seconds, Linear PCM in a CAF among the accepted forms. So for
/// each alarm Baton tries to cut the first 29 seconds of its track into
/// `Library/Sounds/baton-alarm-<id>.caf`. That works for anything Baton can read as a file or a
/// plain HTTP stream (downloads, clippings, books, the demo library). Anything else keeps the
/// bundled chime.
@MainActor
final class AlarmSounds {
    static let clipSeconds: Double = 29
    static let renderTimeout: Duration = .seconds(15)
    private let log = Logger(subsystem: "io.tonebox.baton", category: "alarms")
    /// Which song each clip was cut from, so a changed alarm gets a new clip.
    private var madeFrom: [UUID: String] {
        get { (BatonStorage.defaults.dictionary(forKey: "baton.alarms.clips") as? [String: String] ?? [:])
            .reduce(into: [:]) { result, pair in if let id = UUID(uuidString: pair.key) { result[id] = pair.value } } }
        set { BatonStorage.defaults.set(Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.uuidString, $0.value) }),
                                        forKey: "baton.alarms.clips") }
    }
    /// Resolves a song to something readable; the app's own stream resolver.
    var resolve: (String) -> URL? = { try? StreamingPlaybackController.resolveStreamURL(songID: $0) }

    static var directory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Sounds", isDirectory: true)
    }

    static func fileName(for id: UUID) -> String { "baton-alarm-\(id.uuidString).caf" }

    /// The name to hand AlarmKit or a notification for `id`.
    func soundName(for id: UUID) -> String {
        let name = Self.fileName(for: id)
        return FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent(name).path) && madeFrom[id] != nil
            ? name : AlarmNotificationBridge.chime
    }

    /// Makes the clips the store needs and removes the ones it no longer does.
    func prepare(_ store: AlarmStore) async {
        var wanted: [UUID: NavidromeSong] = [:]
        for alarm in store.alarms where alarm.isEnabled {
            if let song = alarm.choice.songs[safe: alarm.choice.startIndex] { wanted[alarm.id] = song }
        }
        if let timer = store.timer, let song = timer.choice.songs[safe: timer.choice.startIndex] { wanted[timer.id] = song }
        var made = madeFrom
        for id in made.keys where wanted[id] == nil {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(Self.fileName(for: id)))
            made[id] = nil
        }
        for (id, song) in wanted where made[id] != song.id {
            made[id] = nil
            guard let source = resolve(song.id) else { continue }
            let target = Self.directory.appendingPathComponent(Self.fileName(for: id))
            if await Self.render(from: source, to: target, seconds: Self.clipSeconds, timeout: Self.renderTimeout) {
                made[id] = song.id
                log.info("alarm clip made for \(id.uuidString, privacy: .public)")
            } else {
                log.info("alarm clip not made for \(id.uuidString, privacy: .public); the chime rings")
            }
        }
        madeFrom = made
    }

    /// Cuts the first `seconds` of `source` into a 16-bit mono 22.05 kHz Linear PCM CAF.
    /// False when the source cannot be read in time; nothing is left at `target` then.
    nonisolated static func render(from source: URL, to target: URL, seconds: Double, timeout: Duration) async -> Bool {
        // A stream that stalls blocks inside AVAssetReader, where cancelling cannot reach it, so
        // the timeout races the work instead of waiting for it.
        let decided = OSAllocatedUnfairLock(initialState: false)
        let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let work = Task.detached(priority: .utility) {
                let ok = await cut(from: source, to: target, seconds: seconds)
                if decided.withLock({ let first = !$0; $0 = true; return first }) { continuation.resume(returning: ok) }
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                if decided.withLock({ let first = !$0; $0 = true; return first }) {
                    work.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
        if !ok { try? FileManager.default.removeItem(at: target) }
        return ok
    }

    private nonisolated static func cut(from source: URL, to target: URL, seconds: Double) async -> Bool {
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            let asset = AVURLAsset(url: source)
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
