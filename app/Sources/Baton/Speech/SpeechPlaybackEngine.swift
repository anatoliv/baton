import AVFoundation
import Foundation
import Observation
// The TTS config + synthesis layer (SpeechConfig, SpeechService, speechLog) is the third leaf
// of the  module split. Re-exported so every existing call site stays unqualified; the
// playback engine + notifier stay in the app (they tie into MusicModel).
@_exported import BatonSpeech

/// Ducks (or pauses) the music transport while a spoken summary plays, and restores it after.
/// Abstracted so the engine can be tested with a fake that only records begin/end pairing —
/// the concrete implementation acquires/releases a `StreamingPlaybackController` focus token.
///
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
/// can never sound at once.
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

    /// Which agent the live utterance came from — shown above the transcript so several agents
    /// speaking in turn are told apart on sight.
    ///
    /// **Never spoken.** It used to be: `SpeechSessionLabels.announce` prefixed it into the
    /// synthesized text on a speaker change. Showing it is strictly better — it is there on
    /// *every* summary rather than only the ones that changed speaker, it costs no listening
    /// time, and it keeps the transcript equal to the audio, which the word-highlight depends
    /// on (it maps character offsets onto the text it renders).
    private(set) var currentSessionLabel: String?

    /// The label kept for the lingering card after speaking ends — `lastSummaryText`'s counterpart.
    private(set) var lastSessionLabel: String?
    /// Summaries waiting for in-app confirmation (mode = "banner"), oldest first.
    ///
    /// **A queue, not a slot.** It was one `Alert?`, so a second summary arriving before the
    /// first was answered overwrote it and that summary was never seen or heard by anyone —
    /// silently, with the tool having already reported `banner_shown`. Several agents speaking
    /// at once is the normal case this feature was built for, so the losing case was the
    /// designed-for case.
    private(set) var pendingAlerts: [Alert] = []

    /// The banner on screen: the oldest one still waiting. The UI shows one at a time, which is
    /// right — a stack of banners is worse than a queue behind one — but they now take turns
    /// instead of replacing each other.
    var pendingAlert: Alert? { pendingAlerts.first }

    /// How many spoken things are waiting: utterances queued behind the one playing, plus
    /// summaries still waiting to be confirmed. Zero while nothing is pending, which is what the
    /// UI keys off — an indicator that says "0 waiting" on every ordinary summary is noise.
    ///
    /// A reading is deliberately excluded. Its queue is *sentences of one document*, so counting
    /// them would report "23 waiting" for a single article and mean something entirely different
    /// to the person reading it than "23 summaries are waiting".
    var waitingCount: Int {
        (reading == nil ? utteranceQueue.count : 0) + max(0, pendingAlerts.count - 1)
    }

    /// Whether there's a last summary to Replay (server clips replay from cached audio — offline —
    /// and native ones re-run the built-in voice).
    var canReplay: Bool { replayData != nil || replayNativeText != nil }
    /// Whether ∓10s seek applies right now.
    ///
    /// This used to be "server audio only; the built-in voice can't seek", which was true
    /// while the native voice was `AVSpeechSynthesizer` speaking for itself. Now that it is
    /// synthesized to buffers and played through the same graph, it has a duration and a
    /// playhead like any clip, so it seeks too. The exception is the fallback path, where
    /// synthesis produced nothing and the synthesizer is speaking directly — hence the
    /// predicate is "is this rendering through our graph", not "is this native".
    var canSeek: Bool { isSpeaking && isRenderedThroughGraph && (duration ?? 0) > 0 }

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
        /// Which agent it came from — displayed, never spoken. See `currentSessionLabel`.
        var sessionLabel: String?
        static func == (lhs: Alert, rhs: Alert) -> Bool { lhs.id == rhs.id }
    }

    /// Speech's own audio graph — the thing that makes a spoken summary follow the output
    /// device the user picked. See `SpeechAudioPlayer` for why it is a separate engine rather
    /// than the music one.
    @ObservationIgnored private let audio = SpeechAudioPlayer()
    /// Kept only for the fallback path below, where synthesis-to-buffers was not available and
    /// the built-in voice has to speak for itself (unrouted, but audible).
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var synthDelegate: SynthDelegate?
    /// Whether the active utterance is the native voice vs a server clip. Still drives the
    /// HUD's wording; it no longer decides which engine plays, because both now go through
    /// `audio` whenever synthesis succeeded.
    @ObservationIgnored private var currentIsNative = false
    /// Whether the active utterance is rendering through `audio` — true for every server clip,
    /// and for the native voice whenever it could be synthesized to buffers. False only on the
    /// fallback path, where `AVSpeechSynthesizer` is speaking for itself.
    ///
    /// This is the predicate pause/resume/seek route on. `currentIsNative` used to serve that
    /// purpose, and it would now be wrong: a native utterance that rendered is seekable.
    @ObservationIgnored private var isRenderedThroughGraph = false
    /// Word boundaries for the native voice, stamped with when they are reached. Replayed
    /// against the playhead so the HUD highlight tracks the audio rather than the synthesis.
    @ObservationIgnored private var wordTimeline: [NativeSpeechRenderer.Word] = []
    /// Invalidates an in-flight synthesis when the user cancels or moves on before it lands.
    @ObservationIgnored private var renderGeneration = 0
    /// Polls the playhead to publish `progress` (and the live word) for the HUD.
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    /// Cached audio of the last server clip, so Replay works offline (no re-synthesis). Its display
    /// text rides in `replayText`. For a native summary, `replayNativeText` holds the words instead.
    @ObservationIgnored private var replayData: Data?
    @ObservationIgnored private var replayText: String?
    @ObservationIgnored private var replayNativeText: String?
    /// Pending utterances behind the one currently playing — drained FIFO so two rapid summaries
    /// play in order instead of interrupting each other. Each carries its source text (when known)
    /// for the HUD label.
    /// `documentRange` is set only for reading chunks: where this utterance sits in the whole
    /// reading, so the HUD highlight advances when the utterance *starts* rather than when it
    /// was enqueued — which is up to `lookahead` sentences earlier.
    @ObservationIgnored private var utteranceQueue: [(utterance: Utterance, text: String?, documentRange: NSRange?, sessionLabel: String?)] = []

    /// Pending utterances behind the active one (test visibility for FIFO behaviour).
    var queuedCount: Int { utteranceQueue.count }

    /// Set while a **reading** is playing — text captured off the screen, spoken as a queue of
    /// sentences rather than as one summary. Carries the whole document and the range of the
    /// sentence currently being spoken, so the HUD can show the reading entire and highlight
    /// where it is, instead of showing one sentence at a time with no context.
    ///
    /// `nil` for ordinary spoken summaries, which are a single utterance and need none of this.
    /// Cleared when the session drains, so the HUD cannot linger on a finished reading.
    var reading: ReadingContext?

    /// The whole reading, plus where in it the current utterance sits.
    struct ReadingContext: Equatable {
        /// Every chunk of the reading, joined — what the HUD renders.
        var text: String
        /// The range of `text` currently being spoken. Kokoro returns no word timings, so this
        /// is a *sentence*, which is as fine as the server path can be. See specs/read-aloud.md.
        var spokenRange: NSRange
    }

    /// Play whichever kind of utterance a summary resolved to (server audio or native voice).
    /// Enqueues and plays in order; starting from idle ducks the music for the whole session.
    /// `text` (when known) labels the speaking HUD; `sessionLabel` names the agent it came
    /// from, shown above the transcript and deliberately never spoken.
    func play(
        _ utterance: Utterance,
        text: String? = nil,
        documentRange: NSRange? = nil,
        sessionLabel: String? = nil
    ) {
        utteranceQueue.append((utterance, text, documentRange, sessionLabel))
        if !isSpeaking { startNextUtterance() }
    }

    /// Play audio `data` immediately (the in-app pane's manual "play this clip"). A one-off that
    /// replaces any queued utterances; still ducks the music for its duration.
    func play(data: Data) {
        utteranceQueue.removeAll()
        currentText = nil
        currentSessionLabel = nil
        currentIsNative = false
        isPaused = false
        beginSessionIfIdle()
        startData(data)
    }

    /// Play audio previously written to a temp file. Routed through the queue like any utterance.
    func play(fileURL: URL, text: String? = nil, sessionLabel: String? = nil) {
        play(.file(fileURL), text: text, sessionLabel: sessionLabel)
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
        renderGeneration &+= 1   // abandon any synthesis still in flight
        audio.unload()
        synthesizer.stopSpeaking(at: .immediate)
        if isSpeaking { endSession() }
    }

    /// User-facing alias for `stop()` — cancel everything from the HUD.
    func cancel() { stop() }

    /// Pause the current utterance in place (HUD **Pause**). Routes to the right engine; a no-op
    /// when nothing is speaking or it's already paused.
    func pause() {
        guard isSpeaking, !isPaused else { return }
        if isRenderedThroughGraph { audio.pause() } else { synthesizer.pauseSpeaking(at: .word) }
        isPaused = true
    }

    /// Resume a paused utterance (HUD **Resume**).
    func resume() {
        guard isSpeaking, isPaused else { return }
        if isRenderedThroughGraph { audio.resume() } else { synthesizer.continueSpeaking() }
        isPaused = false
    }

    /// Toggle pause/resume — the HUD's primary button.
    func togglePause() { isPaused ? resume() : pause() }

    /// Seek the current server clip by ±`seconds` (HUD ⏪/⏩). No-op for the built-in voice, which
    /// can't seek. Updates `progress` immediately so the bar tracks the jump.
    func seek(by seconds: Double) {
        guard isRenderedThroughGraph else { return }
        seek(to: audio.currentTime + seconds)
    }

    /// Seek the current clip to an absolute `time` (HUD scrubber drag). No-op on the fallback
    /// path, where the synthesizer is speaking for itself and has no playhead. Updates
    /// `progress` immediately so the bar tracks the jump.
    func seek(to time: Double) {
        guard isRenderedThroughGraph, audio.duration > 0 else { return }
        audio.seek(to: time)
        progress = min(max(audio.currentTime / audio.duration, 0), 1)
        publishSpokenWord(at: audio.currentTime)
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
        currentSessionLabel = nil
        reading = nil
        progressTask?.cancel()
        progressTask = nil
        if duration != nil { progress = 1 }
        ducking?.endSpeechDuck()
    }

    /// Publish 0…1 progress for the HUD, and the live word for the native voice.
    ///
    /// Both now come from the same place — the playhead of the clip actually rendering — which
    /// is what lets the built-in voice have a progress bar at all. It used to have neither a
    /// duration nor a position, because `AVSpeechSynthesizer` exposes neither.
    private func startProgressTracking() {
        stopProgressTracking()
        guard audio.duration > 0 else { progress = nil; return }
        progress = 0
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.audio.duration > 0 else { return }
                let now = self.audio.currentTime
                self.progress = min(max(now / self.audio.duration, 0), 1)
                self.publishSpokenWord(at: now)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// The word the voice has reached, from the timeline captured during synthesis.
    ///
    /// The synthesizer's own `willSpeakRange` callbacks arrive while *rendering*, which is
    /// much faster than realtime — publishing them as they arrived would run the highlight to
    /// the end of the sentence before a word had been heard. Replaying them against the
    /// playhead keeps the highlight on the word being spoken, and keeps it correct through a
    /// pause or a seek, which the old live-callback version could not manage.
    private func publishSpokenWord(at time: TimeInterval) {
        guard !wordTimeline.isEmpty else { return }
        let reached = wordTimeline.last { $0.time <= time }?.range
        if reached != spokenRange { spokenRange = reached }
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
        // Advance the reading highlight now, as this utterance begins — not at enqueue time,
        // which runs ahead of playback by however far the lookahead has rendered.
        if let range = next.documentRange { reading?.spokenRange = range }
        spokenRange = nil
        progress = nil // don't inherit the previous utterance's progress (would jump-scroll the HUD)
        currentSessionLabel = next.sessionLabel
        lastSessionLabel = next.sessionLabel
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
            // so nothing accumulates in tmp after playback.
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
        wordTimeline = []
        do {
            try audio.load(data: data)
            audio.onFinish = { [weak self] in self?.onUtteranceFinished() }
            isRenderedThroughGraph = true
            duration = audio.duration
            replayData = data // cache for offline Replay; text set by caller (currentText)
            replayText = currentText
            replayNativeText = nil
            audio.play()
            startProgressTracking()
        } catch {
            speechLog.error("speech playback failed: \(error.localizedDescription)")
            isRenderedThroughGraph = false
            onUtteranceFinished()
        }
    }

    /// The built-in voice, synthesized to buffers and played through our own graph.
    ///
    /// This is the half of §3.5 that could not be fixed any other way: `AVSpeechSynthesizer`
    /// has no output-device API, so as long as it spoke for itself the fallback voice came out
    /// of the system default no matter where the user had pointed Baton. And it is the voice
    /// that speaks precisely when the TTS server is unreachable — so routing that skipped it
    /// would have failed in the situation it most needed to work.
    private func startNative(_ text: String) {
        audio.unload() // mutual: nothing else may be sounding
        stopProgressTracking()
        duration = nil
        replayData = nil
        replayNativeText = text // cache for Replay (re-runs the built-in voice)

        // Prefer an enhanced/premium voice for the current locale if one is installed.
        // Shared with `ReadAloudExport` so an exported reading is read by the voice you heard.
        let voice = NativeSpeechRenderer.systemVoice

        renderGeneration &+= 1
        let generation = renderGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let render = await NativeSpeechRenderer.render(text, voice: voice)
            // Cancelled, or superseded by another utterance, while we were synthesizing.
            guard generation == self.renderGeneration else { return }
            guard let render else {
                // Synthesis produced nothing. Speak it aloud unrouted rather than silently
                // dropping the summary — a summary on the wrong speaker beats no summary.
                speechLog.error("speech: native synthesis produced no audio — speaking unrouted")
                self.speakDirectly(text, voice: voice)
                return
            }
            self.wordTimeline = render.words
            self.audio.adopt(render.pcm)
            self.audio.onFinish = { [weak self] in self?.onUtteranceFinished() }
            self.isRenderedThroughGraph = true
            self.duration = self.audio.duration
            self.audio.play()
            self.startProgressTracking()
        }
    }

    /// The fallback: let `AVSpeechSynthesizer` play it. Unrouted — it follows the system
    /// output — and with no playhead, so no progress bar and no seek.
    private func speakDirectly(_ text: String, voice: AVSpeechSynthesisVoice?) {
        isRenderedThroughGraph = false
        wordTimeline = []
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        let delegate = SynthDelegate(
            onFinish: { [weak self] in self?.onUtteranceFinished() },
            onWord: { [weak self] range in self?.spokenRange = range }
        )
        synthesizer.delegate = delegate
        synthDelegate = delegate
        synthesizer.speak(utterance)
    }

    // MARK: - Routing

    #if os(macOS)
    /// Send spoken summaries to `deviceID` (nil follows the system default).
    ///
    /// Called by the same picker that routes music, so the two stay together — which is the
    /// whole point of the ticket. Remembered by the player, so a summary that starts *after*
    /// the choice honours it too, not only one already speaking.
    @discardableResult
    func setOutputDevice(_ deviceID: AudioDeviceID?) -> Bool {
        audio.setOutputDevice(deviceID)
    }
    #endif

    // MARK: - In-app banner (mode = "banner")
    func presentBanner(text: String, utterance: Utterance, sessionLabel: String? = nil) {
        pendingAlerts.append(Alert(text: text, utterance: utterance, sessionLabel: sessionLabel))
    }

    func confirmBanner() {
        guard !pendingAlerts.isEmpty else { return }
        let alert = pendingAlerts.removeFirst()
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

    /// Dismiss the banner on screen. The next one waiting takes its place rather than being
    /// discarded with it: dismissing one summary is not a decision about the others.
    func dismissBanner() {
        if !pendingAlerts.isEmpty { pendingAlerts.removeFirst() }
    }

    /// Dismiss every waiting summary at once — the × on the HUD, where "close this" plainly means
    /// all of it rather than "show me the next one".
    func dismissAllBanners() { pendingAlerts.removeAll() }
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

// `PlayerDelegate` used to sit here, bridging `AVAudioPlayer`'s completion callback. Speech no
// longer uses `AVAudioPlayer` at all: it has no output-device API, which is what kept spoken
// summaries pinned to the system output while the picker moved the music. `SpeechAudioPlayer`
// owns the completion path now, with the generation guard a scheduled-buffer callback needs.
