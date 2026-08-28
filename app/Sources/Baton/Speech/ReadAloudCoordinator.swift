import AppKit
import BatonAgentKit
import BatonPlaybackKit
import BatonSpeech
import Foundation
import NaturalLanguage
import OSLog

/// Turns a captured selection into speech: prepare, synthesize with lookahead, enqueue.
///
/// Deliberately small, because most of what a reading needs already exists.
/// `SpeechPlaybackEngine` owns a FIFO utterance queue that drains on finish, ducks the music
/// through `ControllerSpeechDucker` (restoring the exact prior level rather than pausing), and
/// drives the speaking HUD. This type feeds that queue; it does not build one.
///
/// **Why chunked rather than one call.** A 3000-word article is roughly 30 seconds of synthesis
/// before the first sound, cannot be stopped cleanly part-way, and — because Kokoro returns a WAV
/// with no word timings — could never highlight anything finer than "the whole document". Chunking
/// at sentences fixes all three: first audio lands in about a second, stopping is immediate, and
/// one sentence per utterance is the read-along granularity the server path can actually support.
@MainActor
final class ReadAloudCoordinator {

    private let music: MusicModel
    private var task: Task<Void, Never>?

    /// Injectable so tests can exercise the pipeline without a TTS host on the LAN. Production
    /// wiring is `SpeechService.synthesize`, unchanged.
    var synthesize: (String, SpeechConfig.Voice) async throws -> Data = { text, voice in
        try await SpeechService.synthesize(text: text, voice: voice)
    }

    /// How many rendered chunks may wait behind the one playing. Two is enough to cover the gap
    /// between utterances without rendering (and writing to disk) a whole article that the user
    /// may stop after one sentence.
    private let lookahead = 2

    /// True while a reading is being prepared or spoken. Distinct from `music.speech.isSpeaking`,
    /// which is also true for an agent's spoken summary.
    private(set) var isReading = false

    /// What the reading is, whole, for the HUD. Kept in memory only — readings are never
    /// persisted, by decision, so this dies with the reading.
    private(set) var fullText: String?

    init(music: MusicModel) {
        self.music = music
    }

    // MARK: - Reading

    /// Speak a capture. Replaces any reading already in progress.
    func read(_ capture: ScreenTextReader.Capture) {
        stop()
        if capture.gist {
            readGist(capture)
            return
        }
        speak(prepared: capture.text, profile: capture.profile)
    }

    /// Summarize first, then speak the summary.
    ///
    /// The text is redacted and normalized *before* it reaches the model, not just before it
    /// reaches the speaker. Summarizing sends the text somewhere — even a LAN host is somewhere —
    /// and a token in a terminal buffer should not make that trip either.
    private func readGist(_ capture: ScreenTextReader.Capture) {
        let cleaned = SpeakableText.prepare(capture.text, profile: capture.profile).joined(separator: " ")
        guard !cleaned.isEmpty else { return }

        isReading = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await TranscriptSummarizer.summarize(
                    text: cleaned,
                    config: RemoteControlSettings().naturalLanguage
                )
                guard !Task.isCancelled else { return }
                self.speak(prepared: summary, profile: .generic)
            } catch {
                self.isReading = false
                let message = (error as? TranscriptSummarizer.SummaryError)?.message ?? error.localizedDescription
                readAloudLog.notice("gist unavailable: \(message)")
                Self.explain(message)
            }
        }
    }

    /// The unavailable state, said plainly. Following the precedent the conversation eval set:
    /// a model that is not configured is *not measurable*, not broken — but the person who just
    /// chose "Summarize with Baton" and heard nothing needs to be told which.
    private static func explain(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Baton can't summarize that yet"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func speak(prepared raw: String, profile: SpeakableText.SourceProfile) {
        let chunks = SpeakableText.prepare(raw, profile: profile)
        guard !chunks.isEmpty else {
            readAloudLog.notice("nothing speakable in the selection after normalization")
            return
        }
        let (document, ranges) = Self.layout(chunks)
        fullText = document
        isReading = true

        // Hand the HUD the whole reading up front, highlighting the first sentence. The engine
        // advances the range as each utterance starts.
        music.speech.reading = .init(text: document, spokenRange: ranges[0])

        let voice = resolvedVoice(for: profile, text: document)
        task = Task { [weak self] in
            await self?.speak(chunks, ranges: ranges, voice: voice)
            self?.isReading = false
        }
    }

    /// Join the chunks into the document the HUD renders, and record where each one lands in it.
    ///
    /// Kept as one function so the text and the offsets cannot drift: computing the ranges
    /// separately from the join is exactly how a highlight ends up one separator out per
    /// sentence, which is invisible at chunk one and badly wrong by chunk forty.
    static func layout(_ chunks: [String]) -> (document: String, ranges: [NSRange]) {
        var document = ""
        var ranges: [NSRange] = []
        for (index, chunk) in chunks.enumerated() {
            if index > 0 { document += " " }
            let location = (document as NSString).length
            document += chunk
            ranges.append(NSRange(location: location, length: (chunk as NSString).length))
        }
        return (document, ranges)
    }

    /// Stop a reading: cancel synthesis still in flight *and* stop playback.
    ///
    /// Both halves are required. Cancelling only the task leaves the already-queued chunks
    /// playing; stopping only the engine leaves this loop happily rendering more chunks into a
    /// queue the user has just emptied.
    func stop() {
        task?.cancel()
        task = nil
        if isReading { music.speech.stop() }
        // Explicit rather than relying on `endSession`: stopping before anything began speaking
        // never reaches that path, and a stale reading left on the engine would keep the HUD
        // showing a document nobody is reading.
        music.speech.reading = nil
        isReading = false
        fullText = nil
    }

    // MARK: - The pipeline

    private func speak(_ chunks: [String], ranges: [NSRange], voice: SpeechConfig.Voice) async {
        // Once the host has failed, stop asking it. Retrying per chunk would add the connection
        // timeout to every sentence, turning an unreachable host into a reading that stutters
        // for minutes instead of simply speaking in the built-in voice.
        var hostIsDown = false

        for (index, chunk) in chunks.enumerated() {
            if Task.isCancelled { return }
            let range = ranges[index]

            // Stay `lookahead` ahead of playback rather than rendering everything up front.
            while music.speech.queuedCount >= lookahead {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(120))
            }
            if Task.isCancelled { return }

            if hostIsDown {
                music.speech.play(.native(chunk), text: chunk, documentRange: range)
                continue
            }
            do {
                let audio = try await synthesize(chunk, voice)
                if Task.isCancelled { return }
                let url = try BatonMCPSpeakTools.writeTemp(audio)
                music.speech.play(.file(url), text: chunk, documentRange: range)
            } catch {
                guard SpeechConfig.fallbackEnabled else {
                    readAloudLog.error("TTS host unreachable and fallback is off — stopping the reading")
                    return
                }
                hostIsDown = true
                readAloudLog.notice("TTS host unreachable — reading continues in the built-in voice")
                music.speech.play(.native(chunk), text: chunk, documentRange: range)
            }
        }
    }

    /// Which voice reads this source.
    ///
    /// Per-source voices are off by default (decision 3), so unless the user turned them on
    /// every reading uses the configured default. When they are on, `browser` and `terminal`
    /// resolve through the same user-editable `SpeechConfig` category map as `ops` and `deploy`
    /// — one mechanism, not a second lookup table.
    private func resolvedVoice(for profile: SpeakableText.SourceProfile, text: String) -> SpeechConfig.Voice {
        // Language wins over source. Reading Spanish in an English voice is a worse outcome
        // than losing the "this came from a browser" cue, and it is the one a listener notices
        // immediately.
        if let language = Self.languageCategory(for: text) {
            return SpeechConfig.resolve(category: language, explicitVoice: nil, engineOverride: nil)
        }
        let category = ReadAloudSettings.perSourceVoices
            ? ScreenTextReader.voiceCategory(for: profile)
            : nil
        return SpeechConfig.resolve(category: category, explicitVoice: nil, engineOverride: nil)
    }

    /// The voice category for the reading's language, or `nil` to leave the choice alone.
    ///
    /// Three deliberate restraints, each of which is the difference between helpful and
    /// irritating:
    ///
    /// 1. **Detected once, over the whole reading** — never per chunk. A Spanish quotation
    ///    inside an English article must not flip the voice for one paragraph and back.
    /// 2. **A confidence floor**, because `NLLanguageRecognizer` will happily name a language
    ///    for three words of a log line.
    /// 3. **Only when a voice is actually mapped** for that language. An unmapped language
    ///    reads in the configured voice rather than refusing or picking something odd —
    ///    `SpeechConfig.resolve` would silently fall back to `default` anyway, but then a
    ///    *source* voice would have been discarded for nothing.
    ///
    /// On-device, no network, no permission.
    static func languageCategory(for text: String, minimumConfidence: Double = 0.85) -> String? {
        // Too short to judge. Language recognition on a fragment is guesswork, and guessing
        // wrong here is audible.
        guard text.count >= 40 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return nil }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard (hypotheses[language] ?? 0) >= minimumConfidence else { return nil }

        // English is the assumed default everywhere in this app; naming it as a category would
        // override a perfectly good source voice for no gain.
        let code = language.rawValue
        guard code != "en" else { return nil }
        return SpeechConfig.voiceMap()[code] != nil ? code : nil
    }
}

// MARK: - Note on history

/// Readings write nothing to `SpeechHistory`, and that is **structural rather than a flag**:
/// the only `speechHistory.record(...)` call in the app is in `BatonMCPSpeakTools.run`, which
/// serves the `speak_summary` tool. A reading talks to `SpeechPlaybackEngine` directly and so
/// cannot reach it. `ReadAloudHistoryTests` asserts this, because "no code path happens to call
/// it" is exactly the kind of property that a later refactor breaks silently — and the cost
/// would be a 50-entry store evicting a user's spoken summaries on one long article.
let readAloudLog = Logger(subsystem: "io.tonebox.baton", category: "read-aloud")
