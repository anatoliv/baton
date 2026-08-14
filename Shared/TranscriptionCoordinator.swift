import Foundation
import Observation
import OSLog
import BatonAgentKit
import BatonPlaybackKit
import BatonSpeech
import BatonSubsonicKit
import BatonSubsonicModels

private let coordinatorLog = Logger(subsystem: "io.tonebox.baton", category: "TranscriptionCoordinator")

/// Drives transcription and summarization for one track: find the audio, send it to the
/// recognizer, store what comes back, and summarize it on request.
///
/// Lives in `Shared/` because both apps need exactly this and neither app's model type is
/// available to the other. It deliberately takes no `MusicModel` / `MobileModel` — the client
/// and the seek are passed in — which is what lets one file serve both.
///
/// It is **never** invoked automatically. Transcription is a GPU pass over an hour of audio;
/// nothing here runs without someone asking for it.
///
/// See `specs/track-transcription.md`.
@MainActor
@Observable
final class TranscriptionCoordinator {
    /// Overridable for the same reason `TranscriptStore.shared` is: a suite must not drive
    /// the instance that writes to the real store.
    static var shared = TranscriptionCoordinator()

    /// What a track is currently doing, for the pane's progress copy. Absent when idle.
    enum Stage: String, Equatable, Sendable {
        case fetching = "Fetching audio"
        case transcribing = "Transcribing"
        case summarizing = "Summarizing"
    }

    private(set) var stages: [String: Stage] = [:]

    let store: TranscriptStore

    init(store: TranscriptStore = .shared) {
        self.store = store
    }

    // MARK: - Queries

    func transcript(for trackID: String) -> Transcript? { store.transcript(for: trackID) }
    func stage(for trackID: String) -> Stage? { stages[trackID] }
    func failure(for trackID: String) -> TranscriptStore.Failure? { store.failures[trackID] }
    func isBusy(_ trackID: String) -> Bool { stages[trackID] != nil }

    /// Whether to *offer* transcription for this track without being asked.
    ///
    /// Podcast episodes, yes — that is what the feature is for. Library music, no: it has the
    /// lyrics chain, and offering a transcribe button on every song invites someone to spend a
    /// GPU-hour discovering that a synth record has no words in it. Other tracks stay reachable
    /// through an explicit action.
    static func isOfferedAutomatically(for song: NavidromeSong) -> Bool {
        song.mediaKind == .podcastEpisode
    }

    // MARK: - Transcribe

    /// Transcribe a track and store the result. Safe to call twice; the second call is a no-op
    /// while the first is running.
    @discardableResult
    func transcribe(
        song: NavidromeSong,
        client: NavidromeClient?,
        downloads: MusicDownloadStore = .shared,
        session: URLSession = .shared
    ) async -> Transcript? {
        guard SpeechConfig.isTranscriptionConfigured else {
            store.finishWork(on: song.id, failure: .init(
                message: "Transcription isn't set up yet. Add a transcription host in Settings → Speech.",
                isUnavailable: true
            ))
            return nil
        }
        guard store.beginWork(on: song.id) else { return nil }

        var temporaryFile: URL?
        defer {
            if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
            stages[song.id] = nil
        }

        do {
            stages[song.id] = .fetching
            let source = try TranscriptionAudioSource.resolve(song: song, downloads: downloads, client: client)
            let (url, isTemporary) = try await source.materialize(session: session)
            if isTemporary { temporaryFile = url }

            stages[song.id] = .transcribing
            let transcript = try await TranscriptionService.transcribe(
                fileURL: url, trackID: song.id, session: session
            )
            store.save(transcript)
            store.finishWork(on: song.id)
            coordinatorLog.info("transcribed a track into \(transcript.segments.count) segments")
            return transcript
        } catch let error as TranscriptionService.TranscribeError {
            store.finishWork(on: song.id, failure: .init(message: error.message, isUnavailable: error.isUnreachable))
        } catch let error as TranscriptionAudioSource.ResolveError {
            store.finishWork(on: song.id, failure: .init(message: error.message))
        } catch {
            store.finishWork(on: song.id, failure: .init(message: error.localizedDescription))
        }
        return nil
    }

    // MARK: - Summarize

    /// Summarize an existing transcript and attach the result.
    ///
    /// Requires a transcript: summarizing implies transcribing, but doing that silently would
    /// turn one explicit action into two, the second of which is the expensive one.
    @discardableResult
    func summarize(
        trackID: String,
        config: RemoteControlSettings.NaturalLanguageConfig,
        consented: Bool = false,
        session: URLSession = .shared
    ) async -> Summary? {
        // Check the claim BEFORE the transcript, not after. The no-transcript branch below
        // reports its failure through `finishWork`, which releases the claim — and doing that
        // while a transcription was still running for this track would hand the lock away
        // mid-pass and let a third call start a duplicate.
        guard !store.isWorking(on: trackID) else { return nil }
        guard let transcript = store.transcript(for: trackID) else {
            store.finishWork(on: trackID, failure: .init(
                message: "There's no transcript to summarize yet."
            ))
            return nil
        }
        guard store.beginWork(on: trackID) else { return nil }
        defer { stages[trackID] = nil }

        do {
            stages[trackID] = .summarizing
            let summary = try await TranscriptSummarizer.summarize(
                transcript, config: config, consented: consented, session: session
            )
            store.attach(summary, to: trackID)
            store.finishWork(on: trackID)
            return summary
        } catch let error as TranscriptSummarizer.SummaryError {
            // A consent refusal is a question, not a fault — the pane offers the choice rather
            // than showing a red error, so it is flagged the same way an absence is.
            store.finishWork(on: trackID, failure: .init(message: error.message, isUnavailable: error.needsConsent))
        } catch {
            store.finishWork(on: trackID, failure: .init(message: error.localizedDescription))
        }
        return nil
    }
}
