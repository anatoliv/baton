import CryptoKit
import Foundation
import Observation
import OSLog
import BatonSubsonicModels

private let transcriptLog = Logger(subsystem: "io.tonebox.baton", category: "Transcripts")

/// Transcripts on disk, keyed by playback id.
///
/// Keyed the same way `PodcastProgressStore` is — enclosure URL for a client-side episode,
/// `streamID` for a server-side one, Subsonic id for a library track — so a transcript and the
/// listening progress for the same audio agree on what a track is. That store already solved
/// this identity problem; solving it a second way is how the two would drift.
///
/// **One file per transcript**, not one dictionary. An hour of speech is tens of kilobytes of
/// JSON, so a single blob would be rewritten in full every time any episode was transcribed,
/// and would grow without bound in memory once loaded. A small index maps ids to file names
/// because the file name is a hash (ids are URLs, which are neither filesystem-safe nor short
/// enough to be one).
///
/// See `specs/track-transcription.md`.
@MainActor
@Observable
public final class TranscriptStore {
    /// Overridable, so a test suite points at a temp directory instead of writing into the
    /// person's real transcripts. Same idiom as `SpeechConfig.defaults`.
    public static var shared = TranscriptStore()

    /// Track ids with a transcript on disk. Observable, so a row's transcript badge updates
    /// as one is produced or removed.
    public private(set) var transcribedIDs: Set<String> = []
    /// Track ids with work running right now — transcribing or summarizing. Modelled as a set
    /// so a second request for the same track is recognised rather than duplicated.
    public private(set) var inFlight: Set<String> = []
    /// Last failure per track id, retained (not just logged) so the pane can say what went
    /// wrong and offer a retry rather than showing an empty state that looks like "no speech".
    ///
    /// One home for this, not two: the coordinator that drives transcription reads and writes
    /// it here rather than keeping a parallel copy. Failure state living in two places is the
    /// drift this codebase keeps paying for.
    public private(set) var failures: [String: Failure] = [:]

    /// Why a transcription didn't happen, and whether that is an absence or a fault.
    ///
    /// The distinction drives the copy: an unreachable host on a phone off the home network is
    /// the normal case and must read as "unavailable", while a server that answered with an
    /// error is a failure worth showing as one.
    public struct Failure: Equatable, Sendable {
        public var message: String
        public var isUnavailable: Bool

        public init(message: String, isUnavailable: Bool = false) {
            self.message = message
            self.isUnavailable = isUnavailable
        }
    }

    private let directory: URL
    /// trackID → file name. Small even with hundreds of transcripts.
    private var index: [String: String] = [:]
    /// Transcripts already read this session. Bounded by what the user actually opens.
    private var cache: [String: Transcript] = [:]
    private var loaded = false

    public init(directory: URL? = nil) {
        self.directory = directory ?? TranscriptStore.defaultDirectory()
    }

    // MARK: - Load / persist

    private var indexURL: URL { directory.appendingPathComponent("transcripts-index.json") }

    private var indexStore: VersionedStore<[String: String]> {
        VersionedStore(fileURL: indexURL, keepBackup: true)
    }

    /// A transcript is expensive to produce (a GPU pass over an hour of audio), so it is
    /// treated as irreplaceable data and keeps a backup, like listening progress does.
    private func store(for fileName: String) -> VersionedStore<Transcript> {
        VersionedStore(fileURL: directory.appendingPathComponent(fileName), keepBackup: true)
    }

    public func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let saved = indexStore.load() {
            index = saved
            transcribedIDs = Set(saved.keys)
        }
    }

    // MARK: - Queries

    public func hasTranscript(for trackID: String) -> Bool {
        loadIfNeeded()
        return index[trackID] != nil
    }

    /// The transcript for a track, from memory or disk. Nil when there is none.
    ///
    /// This is the path the "cached, and still works with the host unreachable" behaviour runs
    /// through: nothing here touches the network.
    public func transcript(for trackID: String) -> Transcript? {
        loadIfNeeded()
        if let cached = cache[trackID] { return cached }
        guard let fileName = index[trackID] else { return nil }
        guard let loaded = store(for: fileName).load() else {
            // The index claims a file that won't decode. Drop the entry rather than leaving a
            // permanent phantom that makes the UI offer a transcript it can never show.
            transcriptLog.error("transcript file for an indexed track failed to load; dropping the index entry")
            index[trackID] = nil
            transcribedIDs.remove(trackID)
            indexStore.save(index)
            return nil
        }
        cache[trackID] = loaded
        return loaded
    }

    // MARK: - Mutations

    public func save(_ transcript: Transcript) {
        loadIfNeeded()
        let fileName = index[transcript.trackID] ?? Self.fileName(for: transcript.trackID)
        store(for: fileName).save(transcript)
        index[transcript.trackID] = fileName
        indexStore.save(index)
        cache[transcript.trackID] = transcript
        transcribedIDs.insert(transcript.trackID)
        failures[transcript.trackID] = nil
        transcriptLog.info("saved a transcript of \(transcript.segments.count) segments")
    }

    /// Attach a summary to an existing transcript. Returns false when there is nothing to
    /// attach it to — summarizing something that was never transcribed is a caller bug, not a
    /// state to invent a transcript for.
    @discardableResult
    public func attach(_ summary: Summary, to trackID: String) -> Bool {
        guard var transcript = transcript(for: trackID) else { return false }
        transcript.summary = summary
        save(transcript)
        return true
    }

    public func remove(trackID: String) {
        loadIfNeeded()
        if let fileName = index[trackID] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
        }
        index[trackID] = nil
        indexStore.save(index)
        cache[trackID] = nil
        transcribedIDs.remove(trackID)
        failures[trackID] = nil
    }

    /// Forget every transcript — for session teardown. What someone listened to, written down,
    /// is at least as personal as where they got to in it, so it leaves with the account.
    public func clear() {
        loadIfNeeded()
        for fileName in index.values {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
        }
        index.removeAll()
        cache.removeAll()
        transcribedIDs.removeAll()
        failures.removeAll()
        try? FileManager.default.removeItem(at: indexURL)
    }

    // MARK: - In-flight bookkeeping

    /// Claim a track for work — transcribing or summarizing. False when something is already
    /// running for it, which is how a double tap becomes a no-op instead of two GPU passes over
    /// the same hour of audio, and how Summarize declines while a transcription is still going.
    public func beginWork(on trackID: String) -> Bool {
        guard !inFlight.contains(trackID) else { return false }
        inFlight.insert(trackID)
        failures[trackID] = nil
        return true
    }

    public func finishWork(on trackID: String, failure: Failure? = nil) {
        inFlight.remove(trackID)
        failures[trackID] = failure
    }

    public func isWorking(on trackID: String) -> Bool { inFlight.contains(trackID) }

    // MARK: - Paths

    /// A stable, filesystem-safe name for a track id.
    ///
    /// Hashed rather than sanitized because ids are URLs: a percent-escaped enclosure URL is
    /// routinely longer than the 255-byte limit a file name has, and two different URLs can
    /// sanitize to the same string.
    static func fileName(for trackID: String) -> String {
        let digest = SHA256.hash(data: Data(trackID.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "transcript-\(hex).json"
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Baton/Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
