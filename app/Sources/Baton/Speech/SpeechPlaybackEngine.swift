import AVFoundation
import Foundation
import Observation
// The TTS config + synthesis layer (SpeechConfig, SpeechService, speechLog) is the third leaf
// of the W-51 module split. Re-exported so every existing call site stays unqualified; the
// playback engine + notifier stay in the app (they tie into MusicModel).
@_exported import BatonSpeech

/// Ducks (or pauses) the music transport while a spoken summary plays, and restores it after.
/// Abstracted so the engine can be tested with a fake that only records begin/end pairing —
/// the concrete implementation acquires/releases a `StreamingPlaybackController` focus token.
/// (W-43 / SPEECH-01)
@MainActor
protocol SpeechDucking: AnyObject {
    func beginSpeechDuck()
    func endSpeechDuck()
}

/// Plays one-off spoken summaries (the `speak_summary` MCP tool), deliberately separate from
/// the music queue (`StreamingPlaybackController`) and the internet-radio engine — a spoken
/// alert is a transient utterance with no song id, duration, or queue. Modeled on
/// `RadioPlaybackEngine`, but uses `AVAudioPlayer` since the audio arrives as in-memory `Data`.
///
/// While speaking, it ducks the music transport (`ducking`) so the summary is audible over the
/// library player instead of fighting it, and restores the level once the whole speaking session
/// drains. Utterances queue FIFO — two rapid `speak_summary` calls play in order rather than
/// cutting each other off — and the file/native paths stop one another so `.file` and `.native`
/// can never sound at once. (W-43)
///
/// Also owns the transient in-app "banner" alert state (`pendingAlert`) that the UI observes
/// for `mode: "banner"` — a summary waiting for the user to press Play.
@MainActor
@Observable
final class SpeechPlaybackEngine {
    /// Ducks/restores the music transport for the duration of a speaking session. Injected by
    /// `MusicModel`; nil in isolated engine tests that don't care about ducking.
    @ObservationIgnored weak var ducking: (any SpeechDucking)?
    /// True while an utterance is actively playing (or paused mid-utterance).
    private(set) var isSpeaking = false
    /// True while the active utterance is paused by the user (via the speaking HUD).
    private(set) var isPaused = false
    /// A best-effort snippet of what's being spoken, for the HUD label. Nil for clips whose
    /// source text isn't known (e.g. a notification's Play action, or a pane preview).
    private(set) var currentText: String?
    /// 0…1 playback progress for the HUD, for **server audio** (`AVAudioPlayer` knows its
    /// duration). Nil for the native voice, which has no duration.
    private(set) var progress: Double?
    /// Total duration of the current server-audio clip (drives the time labels and whether the
    /// ∓10s seek is available). Nil for the built-in voice, which has no duration.
    private(set) var duration: Double?
    /// The character range the built-in voice is currently speaking (from the synth delegate), so
    /// the HUD can highlight/scroll to the live word. Nil for server audio (no per-word timing).
    private(set) var spokenRange: NSRange?
    /// The summary text kept for the HUD to display *after* speaking ends (so the card can linger
    /// for Replay). Unlike `currentText`, it isn't cleared when the session ends.
    private(set) var lastSummaryText: String?
    /// A summary waiting for in-app confirmation (mode = "banner"): the text + what to play.
    private(set) var pendingAlert: Alert?

    /// Whether there's a last summary to Replay (server clips replay from cached audio — offline —
    /// and native ones re-run the built-in voice).
    var canReplay: Bool { replayData != nil || replayNativeText != nil }
    /// Whether ∓10s seek applies right now (server audio only; the built-in voice can't seek).
    var canSeek: Bool { isSpeaking && !currentIsNative && (duration ?? 0) > 0 }

    /// What to actually play: synthesized audio from a self-hosted server (a temp WAV), or —
    /// when the server was unreachable — the raw text spoken by the built-in macOS voice.
    enum Utterance: Equatable {
        case file(URL)
        case native(String)
    }

    struct Alert: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let utterance: Utterance
        static func == (lhs: Alert, rhs: Alert) -> Bool { lhs.id == rhs.id }
    }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var delegate: PlayerDelegate?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var synthDelegate: SynthDelegate?
    /// Whether the active utterance is the native voice (synthesizer) vs a file (`AVAudioPlayer`),
    /// so pause/resume routes to the right engine.
    @ObservationIgnored private var currentIsNative = false
    /// Polls `AVAudioPlayer.currentTime` to publish `progress` for the HUD while a file plays.
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    /// Cached audio of the last server clip, so Replay works offline (no re-synthesis). Its display
    /// text rides in `replayText`. For a native summary, `replayNativeText` holds the words instead.
    @ObservationIgnored private var replayData: Data?
    @ObservationIgnored private var replayText: String?
    @ObservationIgnored private var replayNativeText: String?
    /// Pending utterances behind the one currently playing — drained FIFO so two rapid summaries
    /// play in order instead of interrupting each other. Each carries its source text (when known)
    /// for the HUD label. (W-43 / SPEECH-02)
    @ObservationIgnored private var utteranceQueue: [(utterance: Utterance, text: String?)] = []

    /// Pending utterances behind the active one (test visibility for FIFO behaviour).
    var queuedCount: Int { utteranceQueue.count }

    /// Play whichever kind of utterance a summary resolved to (server audio or native voice).
    /// Enqueues and plays in order; starting from idle ducks the music for the whole session.
    /// `text` (when known) labels the speaking HUD.
    func play(_ utterance: Utterance, text: String? = nil) {
        utteranceQueue.append((utterance, text))
        if !isSpeaking { startNextUtterance() }
    }

    /// Play audio `data` immediately (the in-app pane's manual "play this clip"). A one-off that
    /// replaces any queued utterances; still ducks the music for its duration.
    func play(data: Data) {
        utteranceQueue.removeAll()
        currentText = nil
        currentIsNative = false
        isPaused = false
        beginSessionIfIdle()
        startData(data)
    }

    /// Play audio previously written to a temp file. Routed through the queue like any utterance.
    func play(fileURL: URL, text: String? = nil) {
        play(.file(fileURL), text: text)
    }

    /// Speak `text` with the built-in macOS voice — the offline fallback when a self-hosted
    /// TTS host is unreachable. Routed through the queue like any utterance.
    func speakNative(_ text: String) {
        play(.native(text), text: text)
    }

    /// Stop the current utterance, drop anything queued behind it, and restore the ducked music.
    /// Surfaced to the user as **Cancel** in the speaking HUD.
    func stop() {
        utteranceQueue.removeAll()
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
        if isSpeaking { endSession() }
    }

    /// User-facing alias for `stop()` — cancel everything from the HUD.
    func cancel() { stop() }

    /// Pause the current utterance in place (HUD **Pause**). Routes to the right engine; a no-op
    /// when nothing is speaking or it's already paused.
    func pause() {
        guard isSpeaking, !isPaused else { return }
        if currentIsNative { synthesizer.pauseSpeaking(at: .word) } else { player?.pause() }
        isPaused = true
    }

    /// Resume a paused utterance (HUD **Resume**).
    func resume() {
        guard isSpeaking, isPaused else { return }
        if currentIsNative { synthesizer.continueSpeaking() } else { player?.play() }
        isPaused = false
    }

    /// Toggle pause/resume — the HUD's primary button.
    func togglePause() { isPaused ? resume() : pause() }

    /// Seek the current server clip by ±`seconds` (HUD ⏪/⏩). No-op for the built-in voice, which
    /// can't seek. Updates `progress` immediately so the bar tracks the jump.
    func seek(by seconds: Double) {
        guard !currentIsNative, let player else { return }
        seek(to: player.currentTime + seconds)
    }

    /// Seek the current server clip to an absolute `time` (HUD scrubber drag). No-op for the
    /// built-in voice. Updates `progress` immediately so the bar tracks the jump.
    func seek(to time: Double) {
        guard !currentIsNative, let player, player.duration > 0 else { return }
        player.currentTime = min(max(time, 0), player.duration)
        progress = min(max(player.currentTime / player.duration, 0), 1)
    }

    /// Re-speak the last summary (HUD **Replay**). Reuses the cached audio for a server clip (works
    /// offline) or re-runs the built-in voice for a native one.
    func replayLast() {
        if let data = replayData {
            let text = replayText
            play(data: data)
            currentText = text
            lastSummaryText = text
        } else if let text = replayNativeText {
            speakNative(text)
        }
    }

    // MARK: - Session + queue machinery

    /// Duck the music the first time playback starts from idle (no-op while already speaking, so
    /// the level isn't re-ducked between queued utterances).
    private func beginSessionIfIdle() {
        if !isSpeaking { ducking?.beginSpeechDuck() }
        isSpeaking = true
    }

    /// The speaking session fully drained: restore the music and mark idle. Keeps `lastSummaryText`,
    /// `duration`, `spokenRange`, and the replay cache so the HUD can linger for Replay; leaves a
    /// completed (`1.0`) progress bar for server audio.
    private func endSession() {
        isSpeaking = false
        isPaused = false
        currentText = nil
        progressTask?.cancel()
        progressTask = nil
        if duration != nil { progress = 1 }
        ducking?.endSpeechDuck()
    }

    /// Publish 0…1 progress for the HUD while a file plays. Native speech has no duration, so it
    /// leaves `progress` nil.
    private func startProgressTracking() {
        stopProgressTracking()
        guard let player, player.duration > 0 else { progress = nil; return }
        progress = 0
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player, player.duration > 0 else { return }
                self.progress = min(max(player.currentTime / player.duration, 0), 1)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func stopProgressTracking() {
        progressTask?.cancel()
        progressTask = nil
        progress = nil
    }

    /// Called when the current utterance finishes (or fails): advance the queue, or end the
    /// session — and restore the ducked music — once nothing remains.
    private func onUtteranceFinished() {
        if utteranceQueue.isEmpty { endSession() } else { startNextUtterance() }
    }

    private func startNextUtterance() {
        guard !utteranceQueue.isEmpty else { endSession(); return }
        beginSessionIfIdle()
        isPaused = false
        let next = utteranceQueue.removeFirst()
        spokenRange = nil
        progress = nil // don't inherit the previous utterance's progress (would jump-scroll the HUD)
        switch next.utterance {
        case let .file(url):
            currentIsNative = false
            currentText = next.text
            lastSummaryText = next.text
            startFile(url)
        case let .native(text):
            currentIsNative = true
            currentText = next.text ?? text
            lastSummaryText = next.text ?? text
            startNative(text)
        }
    }

    private func startFile(_ url: URL) {
        defer {
            // Delete the staged clip once consumed — AVAudioPlayer(data:) keeps its own copy,
            // so nothing accumulates in tmp after playback. (W-19 / SPEECH-04)
            if url.deletingLastPathComponent().lastPathComponent == "baton-speech" {
                try? FileManager.default.removeItem(at: url)
            }
        }
        guard let data = try? Data(contentsOf: url) else {
            speechLog.error("speech temp file missing: \(url.path, privacy: .public)")
            onUtteranceFinished()
            return
        }
        startData(data)
    }

    private func startData(_ data: Data) {
        synthesizer.stopSpeaking(at: .immediate) // mutual: never let native + file sound at once
        do {
            let player = try AVAudioPlayer(data: data)
            let delegate = PlayerDelegate { [weak self] in self?.onUtteranceFinished() }
            player.delegate = delegate
            self.player = player
            self.delegate = delegate
            duration = player.duration
            replayData = data // cache for offline Replay; text set by caller (currentText)
            replayText = currentText
            replayNativeText = nil
            player.play()
            startProgressTracking()
        } catch {
            speechLog.error("speech playback failed: \(error.localizedDescription)")
            onUtteranceFinished()
        }
    }

    private func startNative(_ text: String) {
        player?.stop() // mutual: stop any file playback before speaking natively
        player = nil
        stopProgressTracking() // native speech has no duration → no progress bar
        duration = nil
        replayData = nil
        replayNativeText = text // cache for Replay (re-runs the built-in voice)
        let utterance = AVSpeechUtterance(string: text)
        // Prefer an enhanced/premium voice for the current locale if one is installed. Use the
        // BCP-47 form ("en-US") — Locale.current.identifier is "en_US" (underscore), which the
        // voice initializer rejects, previously yielding nil. (W-19 / SPEECH-07)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier(.bcp47))
            ?? AVSpeechSynthesisVoice(language: "en-US")
        let delegate = SynthDelegate(
            onFinish: { [weak self] in self?.onUtteranceFinished() },
            onWord: { [weak self] range in self?.spokenRange = range }
        )
        synthesizer.delegate = delegate
        synthDelegate = delegate
        synthesizer.speak(utterance)
    }

    // MARK: - In-app banner (mode = "banner")
    func presentBanner(text: String, utterance: Utterance) {
        pendingAlert = Alert(text: text, utterance: utterance)
    }

    func confirmBanner() {
        guard let alert = pendingAlert else { return }
        pendingAlert = nil
        // When a summary is *also* auto-played (the user's delivery does both), the immediate play
        // consumes and deletes the temp clip — so the banner's own `.file(url)` no longer exists and
        // Play would silently do nothing. Fall back to the cached audio in that case. (SPEECH)
        if case let .file(url) = alert.utterance,
           !FileManager.default.fileExists(atPath: url.path) {
            if canReplay {
                replayLast()
            } else {
                speechLog.error("banner clip already consumed and nothing cached to replay")
            }
        } else {
            play(alert.utterance, text: alert.text)
        }
    }

    func dismissBanner() { pendingAlert = nil }
}

/// Bridges `AVSpeechSynthesizer`'s finish + per-word callbacks to closures (native fallback path).
/// The `willSpeakRange` callback drives the HUD's live word highlight/scroll.
private final class SynthDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let onFinish: @MainActor () -> Void
    let onWord: @MainActor (NSRange) -> Void
    init(onFinish: @escaping @MainActor () -> Void, onWord: @escaping @MainActor (NSRange) -> Void) {
        self.onFinish = onFinish
        self.onWord = onWord
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // The synthesizer delegate isn't contractually main-thread; hop instead of
        // asserting isolation (assumeIsolated would trap if delivered off-main).
        let onFinish = self.onFinish
        Task { @MainActor in onFinish() }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let onWord = self.onWord
        Task { @MainActor in onWord(characterRange) }
    }
}

/// Bridges `AVAudioPlayer`'s completion callback to a closure. Not `@MainActor` (the delegate
/// protocol isn't), but `AVAudioPlayer` invokes it on the main run loop; the closure hops
/// back onto the main actor via the captured `@MainActor` engine method.
private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: @MainActor () -> Void
    init(onFinish: @escaping @MainActor () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // AVAudioPlayer delivery isn't a documented main-thread contract; hop to the
        // main actor rather than asserting isolation.
        let onFinish = self.onFinish
        Task { @MainActor in onFinish() }
    }
}
