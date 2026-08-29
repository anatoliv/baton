import AppKit
import BatonAgentKit
import BatonPlaybackKit
import BatonSpeech
import Foundation
import NaturalLanguage
import Observation
import OSLog
import UniformTypeIdentifiers

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
///
/// `@Observable` so the "Save Reading" affordances can appear the moment there is something to
/// save and vanish when there isn't, rather than being permanently enabled and explaining itself
/// in an alert after the fact.
@Observable
@MainActor
final class ReadAloudCoordinator {

    private let music: MusicModel
    @ObservationIgnored
    private var task: Task<Void, Never>?

    /// Injectable so tests can exercise the pipeline without a TTS host on the LAN. Production
    /// wiring is `SpeechService.synthesize`, unchanged.
    @ObservationIgnored
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

    /// Everything an export needs to render the last reading again.
    ///
    /// The chunks here are the *prepared* ones — normalized and through the redactor — so an
    /// export cannot reintroduce something the speaker was protected from. In memory only, and
    /// replaced wholesale when the next reading starts: this is not a store, and nothing here
    /// outlives the process.
    struct Exportable: Equatable {
        let chunks: [String]
        let voice: SpeechConfig.Voice
        let sourceName: String?
        let startedAt: Date
    }

    /// Unfinished readings, for "pick up where I left off".
    ///
    /// Injectable, and that is not decoration: the default store writes to Application Support,
    /// so a test constructing a coordinator without this would quietly read and write the user's
    /// real saved readings.
    let unfinished: UnfinishedReadings

    /// Identity of the reading in progress, so its saved position can be updated or removed
    /// without a second reading clobbering it.
    @ObservationIgnored private var currentReadingID: UUID?
    /// Where each chunk lands in the HUD document, so the engine's `spokenRange` can be mapped
    /// back to a chunk index when the reading stops. Cheaper and more honest than tracking
    /// "enqueued" — the coordinator runs two chunks ahead of what is actually being spoken, and
    /// resuming from the enqueued position would silently skip whatever was still in the queue.
    @ObservationIgnored private var currentRanges: [NSRange] = []

    /// The last reading that was started, exportable until another one replaces it.
    ///
    /// Deliberately **not** cleared by `stop()`. Stopping a reading part-way is a normal thing to
    /// do — you have heard enough — and it should not also throw away the ability to keep the
    /// article you were listening to.
    private(set) var exportable: Exportable?

    /// The live coordinator, for the menu item and the HUD button that offer to save a reading.
    ///
    /// A lookup, not a second owner: `BatonApp` holds the instance for the app's lifetime and this
    /// is weak, matching how `ScreenTextReader.shared` and `ReadAloudHotKey.shared` are reached
    /// from the same feature.
    @ObservationIgnored
    private(set) static weak var current: ReadAloudCoordinator?

    init(music: MusicModel, unfinished: UnfinishedReadings = UnfinishedReadings()) {
        self.music = music
        self.unfinished = unfinished
        Self.current = self
        // Load at launch so the Resume menu is populated the first time it is opened, and so an
        // expired entry is pruned on start rather than lingering until something else writes.
        unfinished.loadIfNeeded()
    }

    // MARK: - Reading

    /// Speak a capture. Replaces any reading already in progress.
    func read(_ capture: ScreenTextReader.Capture) {
        stop()
        if capture.gist {
            readGist(capture)
            return
        }
        speak(prepared: capture.text, profile: capture.profile, sourceName: capture.sourceName)
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
                self.speak(prepared: summary, profile: .generic, sourceName: capture.sourceName)
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
        report(title: "Baton can't summarize that yet", message: message)
    }

    /// One alert for every "this didn't happen, and here is why" in read aloud, so a failed
    /// summary and a failed export are told the same way.
    private static func report(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func speak(prepared raw: String, profile: SpeakableText.SourceProfile, sourceName: String?) {
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
        let startedAt = Date()
        // Recorded before a single chunk is synthesized, so a reading stopped after one sentence
        // is still exportable in full — the export re-renders from the text, not from the audio.
        exportable = Exportable(chunks: chunks, voice: voice, sourceName: sourceName, startedAt: startedAt)
        let id = resumingID ?? UUID()
        resumingID = nil
        currentReadingID = id
        currentRanges = ranges
        task = Task { [weak self] in
            let completed = await self?.speak(chunks, ranges: ranges, voice: voice) ?? false
            guard let self else { return }
            self.isReading = false
            // Cancelled means `stop()` ran, and it has already saved the position.
            guard !Task.isCancelled else { return }
            if completed {
                // Ran to the end: nothing to come back to, so drop any saved position rather
                // than leaving a finished article in the Resume menu.
                self.unfinished.remove(id: id)
            } else {
                // Ended early — the TTS host failed with the fallback switched off. Keep the
                // place. Removing here was the first version of this code and it was wrong in a
                // way that only bites when something else has already gone wrong: you lose the
                // article *because* synthesis broke.
                self.recordPosition(id: id)
            }
        }
    }

    /// Set while a resumed reading is being started, so it keeps the identity of the entry it
    /// came from instead of forking a second one every time you resume the same article.
    @ObservationIgnored private var resumingID: UUID?

    // MARK: - Resuming

    /// Start an unfinished reading again from where it stopped.
    ///
    /// The stored chunks are re-spoken from `resumeIndex`, not re-prepared: they are already
    /// normalized and already through the redactor, and re-running preparation on them could
    /// only change what you hear relative to what you heard before the interruption.
    func resume(_ entry: UnfinishedReadings.Entry) {
        stop()
        let remaining = Array(entry.chunks.dropFirst(entry.resumeIndex))
        guard !remaining.isEmpty else {
            unfinished.remove(id: entry.id)
            return
        }
        resumingID = entry.id
        // `prepare` is idempotent on already-prepared text, and going back through it keeps this
        // path identical to every other reading rather than a second way in.
        speak(prepared: remaining.joined(separator: " "), profile: .generic, sourceName: entry.sourceName)
    }

    /// How far the *engine* has actually got, as a chunk index. Derived from the range it is
    /// speaking rather than from what has been enqueued, because those differ by the lookahead.
    private func spokenChunkIndex() -> Int {
        guard let spoken = music.speech.reading?.spokenRange else { return 0 }
        guard let index = currentRanges.firstIndex(where: { $0.location == spoken.location }) else { return 0 }
        return index
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
        // Save before anything is cleared: `music.speech.reading` is the only record of where the
        // engine got to, and the lines below deliberately drop it.
        if isReading, let id = currentReadingID { recordPosition(id: id) }
        currentReadingID = nil
        currentRanges = []
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

    /// Consecutive synthesis failures before a reading gives up on the host for good.
    ///
    /// Not one. A single failure used to latch the built-in voice for the rest of the reading,
    /// and the most common cause of a single failure turned out to be entirely recoverable: the
    /// TTS host closes idle keep-alive connections, so the first request after a gap — and a
    /// reading is mostly gaps, since it renders only `lookahead` ahead of playback — dies on a
    /// dead socket while the host is perfectly healthy. The audible result was a long article
    /// that changed voice part-way through and stayed changed.
    ///
    /// Two rather than more, because the other half of the original reasoning still holds: a
    /// genuinely unreachable host must not make every sentence wait out a connection timeout.
    /// Two failures in a row is enough to tell "the box is gone" from "that socket was stale",
    /// and `SpeechService` already retries once inside each attempt.
    private let failuresBeforeFallback = 2

    /// Returns whether the whole reading was spoken. False means it ended early, which today
    /// means the TTS host failed with the fallback off.
    @discardableResult
    private func speak(_ chunks: [String], ranges: [NSRange], voice: SpeechConfig.Voice) async -> Bool {
        // Counted, not latched on the first failure. Reset by any success, so one bad chunk in
        // the middle of a long reading costs that sentence rather than every sentence after it.
        var consecutiveFailures = 0
        var hostIsDown = false

        for (index, chunk) in chunks.enumerated() {
            if Task.isCancelled { return false }
            let range = ranges[index]

            // Stay `lookahead` ahead of playback rather than rendering everything up front.
            while music.speech.queuedCount >= lookahead {
                if Task.isCancelled { return false }
                try? await Task.sleep(for: .milliseconds(120))
            }
            if Task.isCancelled { return false }

            if hostIsDown {
                music.speech.play(.native(chunk), text: chunk, documentRange: range)
                continue
            }
            do {
                let audio = try await synthesize(chunk, voice)
                if Task.isCancelled { return false }
                let url = try BatonMCPSpeakTools.writeTemp(audio)
                consecutiveFailures = 0
                music.speech.play(.file(url), text: chunk, documentRange: range)
            } catch {
                consecutiveFailures += 1
                // The error, not a guess at it. This line used to say "TTS host unreachable"
                // and discard `error` — asserting a cause it had not established, while the
                // host was answering in 15 ms. The reason lives in the thrown `SynthError`.
                let reason = (error as? SpeechService.SynthError)?.message ?? error.localizedDescription
                guard SpeechConfig.fallbackEnabled else {
                    readAloudLog.error("synthesis failed and fallback is off — stopping the reading: \(reason, privacy: .public)")
                    return false
                }
                if consecutiveFailures >= failuresBeforeFallback {
                    hostIsDown = true
                    readAloudLog.notice("TTS host failed \(consecutiveFailures) times — the rest of this reading is in the built-in voice: \(reason, privacy: .public)")
                } else {
                    readAloudLog.notice("one chunk failed, still trying the host: \(reason, privacy: .public)")
                }
                music.speech.play(.native(chunk), text: chunk, documentRange: range)
            }
        }
        return true
    }

    /// Save where this reading got to, so it can be resumed.
    private func recordPosition(id: UUID) {
        guard let reading = exportable else { return }
        unfinished.record(id: id, chunks: reading.chunks, resumeIndex: spokenChunkIndex(),
                          sourceName: reading.sourceName, startedAt: reading.startedAt)
    }

    // MARK: - Saving a reading

    /// Whether there is a reading to save. Drives the menu item and the HUD button.
    var canExport: Bool { exportable != nil }

    @ObservationIgnored
    private var exportTask: Task<Void, Never>?

    /// Ask where to keep the last reading, then render it there as one M4A.
    ///
    /// **A save panel rather than a folder, deliberately.** Readings are not persisted
    /// (`specs/read-aloud.md`, decision 1), and a fixed export folder would be indistinguishable
    /// from the persistence this feature promised not to do. Choosing a destination each time is
    /// what makes an export a per-item exception the person performs rather than a store the app
    /// keeps — and it is why nothing about this changes for anyone who never uses it.
    func saveLastReading() {
        guard let reading = exportable else {
            Self.report(title: "Nothing to save yet", message: "Read something aloud first, then save it.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = ReadAloudExport.suggestedName(
            sourceName: reading.sourceName, startedAt: reading.startedAt
        )
        panel.title = "Save Reading"
        panel.message = "Baton reads it again to make the file, so this takes a moment."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        // A second save replaces the first rather than racing it into the same synthesizer.
        exportTask?.cancel()
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { self.exportTask = nil }
            self.music.music.postToast("Saving the reading…", symbol: "waveform", seconds: 4)
            do {
                try await ReadAloudExport.write(
                    chunks: reading.chunks,
                    voice: reading.voice,
                    to: destination,
                    synthesize: self.synthesize
                ) { fraction in
                    guard fraction < 1 else { return }
                    self.music.music.postToast(
                        "Saving the reading… \(Int(fraction * 100))%", symbol: "waveform", seconds: 4
                    )
                }
                self.music.music.postToast("Reading saved to \(destination.lastPathComponent)", seconds: 3)
                await self.offerToSendToTheGateway(destination)
            } catch is CancellationError {
                readAloudLog.notice("export cancelled")
            } catch {
                Self.report(
                    title: "Baton couldn't save that reading",
                    message: error.localizedDescription
                )
            }
        }
    }

    /// Park the exported file on the home gateway, so the phone can collect it.
    ///
    /// Silent when no gateway is configured, which is the common case: someone who exports a
    /// reading to keep it on this Mac should not be told about a feature they have not set up.
    /// Failures are a toast rather than an alert for the same reason — the file they asked for is
    /// already saved, and this is a bonus on top of it.
    private func offerToSendToTheGateway(_ fileURL: URL) async {
        let raw = (UserDefaults.standard.string(forKey: "baton.agent.gatewayURL") ?? "")
            .trimmingCharacters(in: .whitespaces)
        let secret = (NavidromeKeychain.secret(account: "baton.agent.gatewayToken") ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !secret.isEmpty, let url = URL(string: raw), url.host != nil else { return }

        let files = GatewayFiles(gatewayURL: url, token: secret)
        do {
            let sent = try await files.upload(
                fileURL,
                name: fileURL.lastPathComponent,
                contentType: "audio/mp4",
                origin: Host.current().localizedName ?? "Mac"
            )
            readAloudLog.notice("reading uploaded to the gateway (\(sent.size) bytes)")
            music.music.postToast("Sent to your other devices", symbol: "iphone", seconds: 3)
        } catch {
            // Named, not swallowed: "it did not reach the gateway" and "the gateway refused it"
            // are different problems, and the log line is where the difference survives.
            readAloudLog.error("could not send the reading to the gateway: \(error.localizedDescription, privacy: .public)")
            music.music.postToast("Saved, but not sent to your other devices", symbol: "exclamationmark.triangle", seconds: 4)
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
