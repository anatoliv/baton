import SwiftUI

/// The **spoken-summary player core**: an auto-scrolling, highlight-what's-speaking transcript, a
/// scrubber (server audio only), and the ∓10s / Play-Pause-Replay transport — all bound to the live
/// `model.speech` engine. Deliberately chrome-less (no card surface, no close/history buttons, no
/// forced color scheme) so it can be dropped into two very different hosts unchanged:
///
///  - the floating **speaking HUD** (`SpeakingHUDContent`), which wraps it in the glass card, the
///    corner controls, and a forced dark scheme; and
///  - the **Spoken Summaries** window's detail pane (`SpeechHistoryView`), where replaying a row
///    plays *here*, inline, instead of spawning the floating HUD on top of the window.
///
/// Both hosts observe the same engine, so whichever is on screen reflects the same playback.
struct SpeakingPlayerView: View {
    @Environment(MusicModel.self) private var model
    private var speech: SpeechPlaybackEngine { model.speech }

    /// Idle-state text to display when nothing is speaking — the Spoken Summaries window passes the
    /// *loaded/selected* entry here so the pane previews it before Play. When nil, the pane falls
    /// back to the engine's last summary (the floating HUD's behavior).
    var idleText: String? = nil
    /// The idle-state primary button. When set (the window), it's a **Play** that starts the loaded
    /// summary; when nil (the HUD), the idle button is **Replay last**.
    var idlePlay: IdlePlay? = nil
    /// Whether the engine is currently rendering *the text this pane is showing* — i.e. the loaded
    /// entry is the one playing. Drives Pause/scrubber/word-highlight vs. the idle Play button. When
    /// nil (the HUD), it follows `speech.isSpeaking`, since the HUD always shows the live utterance.
    var live: Bool? = nil
    /// Idle-state session label, alongside `idleText` — the Spoken Summaries window passes the
    /// selected entry's label so the header names the row you are looking at, not whoever spoke
    /// most recently. When nil the pane follows the engine, which is the floating HUD's behavior.
    var idleSessionLabel: String? = nil

    /// An explicit idle-state play action + its glyph, supplied by the host.
    struct IdlePlay {
        let icon: String
        let help: String
        let action: () -> Void
    }

    /// The transcript's sentences, kept across evaluations and rebuilt only when the text changes.
    @State private var sentenceCache = TranscriptSentenceIndex.Cache()

    /// True when the pane's transcript is the live utterance — so its transport controls it.
    private var isLive: Bool { live ?? speech.isSpeaking }

    /// The accent that tints the scrubber, matching the mini player's warm fill.
    private var accent: Color { .batonOrange }
    /// The transcript to render. When a host supplies `idleText` (the Spoken Summaries window passes
    /// the loaded/selected entry), always show *that* — so the pane matches the selected row, and the
    /// live word-highlight tracks it whenever the engine is playing the same summary. With no override
    /// (the floating HUD), follow the live engine: the current utterance, then the last summary.
    private var text: String {
        if let idleText { return idleText }
        // A reading is a queue of sentences, not one summary. Show the whole document so the
        // transport and the auto-scroll mean something across it — otherwise the pane would
        // flick through one sentence at a time with no sense of where you are.
        if let reading = speech.reading { return reading.text }
        return speech.currentText ?? speech.lastSummaryText ?? ""
    }

    /// Who this summary came from. Follows `idleText`'s rule: an explicit host value wins, so the
    /// history window's header matches its selected row; otherwise the live utterance's label,
    /// then the one the lingering card is still showing.
    private var sessionLabel: String? {
        if idleText != nil { return idleSessionLabel }
        return speech.currentSessionLabel ?? speech.lastSessionLabel
    }

    /// "2 more waiting" — the count of spoken things queued behind this one.
    ///
    /// Deliberately a count and not a list. Several agents talking at once is the case this
    /// exists for, and what a listener needs to know is "is this nearly over" rather than the
    /// text of things they have not heard yet. It is also, usefully, the only way to *see* that
    /// the queue is working: before this, a summary that was queued and one that was silently
    /// dropped looked exactly the same from outside.
    private func waitingIndicator(_ count: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "clock")
                .font(.caption2)
            Text(count == 1 ? "1 more waiting" : "\(count) more waiting")
                .font(.caption)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        // Announced rather than left as decoration: it changes while the user is listening
        // rather than looking, which is exactly when VoiceOver users need it most.
        // Named for what is actually queued: articles while reading one, summaries otherwise.
        .accessibilityLabel({
            let noun = speech.reading != nil
                ? (count == 1 ? "reading" : "readings")
                : (count == 1 ? "summary" : "summaries")
            return count == 1 ? "One more \(noun) waiting" : "\(count) more \(noun) waiting"
        }())
    }

    var body: some View {
        VStack(spacing: 0) {
            // Who is speaking, above the transcript. Displayed only — nothing here is ever
            // synthesized, which is the whole point: a name you can see costs no listening time.
            if let sessionLabel, !sessionLabel.isEmpty {
                sessionHeader(sessionLabel)
            }

            // How many more are waiting to be spoken. Silent at zero, which is the ordinary
            // case: a "0 waiting" chip on every single summary would be pure noise.
            if speech.waitingCount > 0 {
                waitingIndicator(speech.waitingCount)
            }

            // Transcript greedily fills all the space above the controls — no dead gap above the bar.
            transcript.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Scrubber + transport, pinned together at the very bottom (no gap below the bar).
            VStack(spacing: 10) {
                // The scrubber renders its own elapsed / −remaining labels — server audio only, and
                // only while this pane's summary is the one live (so it never controls another clip).
                // Hidden during a reading: `duration` belongs to the *current sentence*, so the
                // scrubber would claim to span a document and in fact scrub one utterance. A
                // scrubber that lies about its extent is worse than no scrubber.
                if isLive, speech.reading == nil, let d = speech.duration {
                    MusicScrubber(currentTime: (speech.progress ?? 0) * d, duration: d, tint: accent) {
                        speech.seek(to: $0)
                    }
                }
                transport
            }
            .padding(.top, 10)
        }
    }

    // MARK: Session header (who this came from — shown, never spoken)

    /// A quiet caption and a hairline. Deliberately understated: it is orientation, not content,
    /// and it sits in a card whose whole job is the sentence below it. Inset to match the
    /// transcript's own padding, and to clear the hosts' top-corner controls.
    private func sessionHeader(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider().opacity(0.5)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
        // One element for VoiceOver, phrased as the relationship rather than the bare name:
        // "baton" alone reads as a stray word before the summary.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Summary from \(label)")
    }

    // MARK: Transcript (fills the space, auto-scrolls to the spoken sentence)

    private var transcript: some View {
        // Built once per text, not per evaluation: this body runs every 100 ms while audio plays.
        let index = sentenceCache.index(for: text)
        let active = activeSentence(in: index)
        return SpeakingTranscriptList(index: index, active: active)
            .equatable() // only a new sentence or a new text re-renders the rows, not each tick
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The live word-highlight is visual-only; expose the transcript to VoiceOver as one element,
            // announcing which sentence is speaking so it isn't silent structure.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isLive ? "Now speaking" : "Summary transcript")
            .accessibilityValue(Self.voiceOverValue(text: text, index: index, active: active))
    }

    /// What VoiceOver reads for the transcript (F5). The whole text used to be the value, which
    /// for a book is 70,000 characters read as one element. While speaking it is the sentence
    /// being spoken; otherwise a short summary is read whole, as before, and a long text says how
    /// it starts and how much follows.
    static func voiceOverValue(text: String, index: TranscriptSentenceIndex, active: Int?,
                               wholeTextLimit: Int = 600) -> String {
        if let active, index.sentences.indices.contains(active) { return index.sentences[active].text }
        if index.utf16Length <= wholeTextLimit { return text }
        guard let first = index.sentences.first?.text else { return text }
        let more = index.sentences.count - 1
        return more > 0 ? "\(first) (and \(more) more \(more == 1 ? "sentence" : "sentences"))" : first
    }

    /// The sentence to highlight and scroll to, or nil when this pane's text is not the one playing.
    ///
    /// The spoken position and the index are both UTF-16, the units the coordinator's ranges and
    /// the synthesizer's word ranges arrive in, so emoji earlier in the text cannot move it.
    private func activeSentence(in index: TranscriptSentenceIndex) -> Int? {
        guard isLive else { return nil } // no word-highlight unless this pane's summary is playing
        let location = TranscriptSentenceIndex.spokenLocation(
            // During a reading the position is the current sentence's place in the whole
            // document, advanced by playback within that sentence. `progress` is progress through
            // one utterance, not through the reading, so it is never used against the whole text.
            reading: speech.reading?.spokenRange,
            wordRange: speech.spokenRange,
            progress: speech.progress,
            utf16Length: index.utf16Length
        )
        return index.sentenceIndex(containing: location)
    }

    // MARK: Transport (∓10s seek · Play/Pause/Replay) — copies the mini player's sizing/style

    private var transport: some View {
        // ∓10s only acts on a live, seekable clip — never on another summary the engine is playing.
        let canSeek = isLive && speech.canSeek
        return HStack(spacing: 20) {
            Button { speech.seek(by: -10) } label: { Image(systemName: "gobackward.10") }
                .foregroundStyle(canSeek ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .disabled(!canSeek)
                .help("Back 10 seconds")
                .accessibilityLabel("Back 10 seconds")

            if isLive {
                Button { speech.togglePause() } label: {
                    Image(systemName: speech.isPaused ? "play.circle.fill" : "pause.circle.fill")
                        .font(.system(size: 32))
                }
                .help(speech.isPaused ? "Resume" : "Pause")
                .accessibilityLabel(speech.isPaused ? "Resume" : "Pause")
            } else if let idlePlay {
                // Host-supplied idle action (the window's Play, which starts the loaded summary).
                Button(action: idlePlay.action) {
                    Image(systemName: idlePlay.icon).font(.system(size: 32))
                }
                .help(idlePlay.help)
                .accessibilityLabel(idlePlay.help)
            } else {
                Button { speech.replayLast() } label: {
                    Image(systemName: "arrow.counterclockwise.circle.fill").font(.system(size: 32))
                }
                .disabled(!speech.canReplay)
                .help("Replay")
                .accessibilityLabel("Replay")
            }

            Button { speech.seek(by: 10) } label: { Image(systemName: "goforward.10") }
                .foregroundStyle(canSeek ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .disabled(!canSeek)
                .help("Forward 10 seconds")
                .accessibilityLabel("Forward 10 seconds")
        }
        .buttonStyle(.plain)
        .font(.title3)
        .frame(maxWidth: .infinity)
    }
}

/// The transcript rows: lazy, so a book-length reading lays out only what is on screen, and
/// equatable on the index and the active sentence, so the 100 ms progress ticks that do not move
/// the highlight do not re-render it.
private struct SpeakingTranscriptList: View, Equatable {
    let index: TranscriptSentenceIndex
    /// The sentence being spoken, or nil when nothing in this transcript is.
    let active: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(index.sentences.indices, id: \.self) { i in
                        Text(index.sentences[i].text)
                            .font(.callout)
                            .foregroundStyle(i == active ? .primary : .secondary)
                            .fontWeight(i == active ? .semibold : .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(.horizontal, 18) // keep text clear of any host's top-corner controls
            }
            // A pane opened part-way through a reading starts at the spoken sentence, not the top.
            .onAppear { if let active { proxy.scrollTo(active, anchor: .center) } }
            .onChange(of: active) { _, i in
                guard let i else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(i, anchor: .center) }
            }
        }
    }
}

extension View {
    /// The mini player's panel surface, replicated so the speaking card looks identical wherever it's
    /// hosted: real **Liquid Glass** on macOS 26+ (a borderless, transparent host refracts what's
    /// behind it), falling back to the opaque rounded window-background fill on older systems.
    @ViewBuilder
    func speakingCardSurface(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
        }
    }
}
