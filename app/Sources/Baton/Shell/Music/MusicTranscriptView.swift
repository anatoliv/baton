import SwiftUI

/// Transcript panel for the full-screen player: what was actually said, timed, with the
/// current line highlighted and every line seekable.
///
/// Renders through `MusicLyricLines` — a transcript and a synced lyric are the same shape, and
/// that view already does the karaoke highlight and the auto-scroll. What is *not* shared is
/// the data path: this never goes through `MusicLibraryStore.lyrics(for:song:)`. A podcast has
/// no lyrics, the trigger is a deliberate action rather than an automatic lookup, and folding
/// them together would make a failed transcription look like a song that simply has no words.
///
/// See `specs/track-transcription.md`.
struct MusicTranscriptView: View {
    @Environment(MusicModel.self) private var model
    let song: NavidromeSong
    /// Injected for previews/snapshots — skips the store and the network.
    var previewTranscript: Transcript?

    @State private var coordinator = TranscriptionCoordinator.shared
    @State private var showsSummary = true
    /// Whether the transcript still follows the playhead.
    ///
    /// It stops the moment the reader scrolls, and only resumes when they ask. Following by
    /// default is right while you listen along; continuing to follow after someone has scrolled
    /// away is what made the pane unusable, because the highlight moves several times a second
    /// and each move dragged the list back. See TBX-2986.
    @State private var isFollowing = true

    private var transcript: Transcript? {
        previewTranscript ?? coordinator.transcript(for: song.id)
    }

    private var currentLine: Int? {
        transcript?.segmentIndex(at: model.music.currentTime)
    }

    var body: some View {
        Group {
            if let stage = coordinator.stage(for: song.id) {
                working(stage)
            } else if let transcript, !transcript.isEmpty {
                content(transcript)
            } else if let failure = coordinator.failure(for: song.id) {
                problem(failure)
            } else {
                offer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: song.id) { _, _ in isFollowing = true }
    }

    // MARK: - States

    private func working(_ stage: TranscriptionCoordinator.Stage) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(stage.rawValue)
                .foregroundStyle(.secondary)
            // An hour of audio is a real wait even on a GPU, and a spinner with no expectation
            // attached is how a working feature gets reported as hung.
            Text("This takes a minute or two for a long episode.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ transcript: Transcript) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let summary = transcript.summary, !summary.isEmpty {
                        TranscriptSummaryView(summary: summary, showsBody: $showsSummary) { seconds in
                            seek(to: seconds)
                        }
                        Divider().padding(.horizontal, 20)
                    } else {
                        summarizeRow
                        Divider().padding(.horizontal, 20)
                    }
                    MusicLyricLines(
                        lyrics: transcript.asLyrics,
                        currentLine: currentLine,
                        // Tap-to-seek is what a transcript has that a lyric sheet never did:
                        // finding the moment someone said the thing is most of the point.
                        onSelectLine: transcript.synced ? { index in
                            guard transcript.segments.indices.contains(index) else { return }
                            seek(to: transcript.segments[index].start)
                        } : nil
                    )
                    footer(transcript)
                }
            }
            // `.interacting` and `.decelerating` are the reader's own scrolling; `.animating`
            // is ours, from the `scrollTo` below, so following survives its own animation.
            // A phase rather than a drag gesture because a Mac trackpad scroll is not a drag.
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating { isFollowing = false }
            }
            .onChange(of: currentLine) { _, newValue in
                guard isFollowing, let newValue else { return }
                withAnimation(.easeInOut) { proxy.scrollTo(newValue, anchor: .center) }
            }
            .overlay(alignment: .bottom) {
                if !isFollowing, let currentLine {
                    Button {
                        resumeFollowing(proxy, to: currentLine)
                    } label: {
                        Label("Jump to current", systemImage: "location.fill")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: isFollowing)
        }
    }

    /// Seeking is a deliberate move to a place, so the pane starts following again: the
    /// playhead is now exactly where the reader just pointed.
    private func seek(to seconds: Double) {
        model.music.seek(to: seconds)
        isFollowing = true
    }

    private func resumeFollowing(_ proxy: ScrollViewProxy, to line: Int) {
        isFollowing = true
        withAnimation(.easeInOut) { proxy.scrollTo(line, anchor: .center) }
    }

    private func footer(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // A failure raised while a transcript already exists — a refused summary, most
            // likely. Without this it would be invisible: the full-pane failure state below
            // is only reachable when there is nothing to show, so pressing Summarize and
            // having it decline would look like the button did nothing at all.
            if let failure = coordinator.failure(for: song.id) {
                Label(failure.message, systemImage: failure.isUnavailable ? "info.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button("Transcribe again") { Task { await transcribe() } }
                    .buttonStyle(.bordered)
                Spacer()
                if !transcript.synced {
                    Label("No timings", systemImage: "clock.badge.questionmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("The recognizer returned text without timings, so lines can't be followed or tapped.")
                }
            }
        }
        .padding(20)
    }

    /// Offered at the TOP of the pane, not the foot. A 48-minute episode is several hundred
    /// lines, and the follow-the-playhead scroll pulls you back to the middle of them, so a
    /// button below the last line is one nobody reaches.
    private var summarizeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { Task { await summarize() } } label: {
                Label("Summarize this episode", systemImage: "text.append")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            Text("An overview plus timestamped sections you can click to jump to. Uses the model from Settings → Remote.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func problem(_ failure: TranscriptStore.Failure) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol(for: failure))
                .font(.title)
                .foregroundStyle(.secondary)
            // Three outcomes, three sentences. "Unavailable" when the host isn't there, which
            // away from home is ordinary. "No speech" when the recognizer ran and found an
            // instrumental — also not a fault. "Failed" only when something actually broke.
            Text(title(for: failure))
                .font(.headline)
            Text(failure.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button(failure.isEmptyOfSpeech ? "Try anyway" : "Try again") { Task { await transcribe() } }
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func symbol(for failure: TranscriptStore.Failure) -> String {
        if failure.isEmptyOfSpeech { return "waveform.slash" }
        return failure.isUnavailable ? "wifi.slash" : "exclamationmark.triangle"
    }

    private func title(for failure: TranscriptStore.Failure) -> String {
        if failure.isEmptyOfSpeech { return "No speech in this track" }
        return failure.isUnavailable ? "Transcription unavailable" : "Transcription failed"
    }

    private var offer: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.viewfinder").font(.title).foregroundStyle(.secondary)
            Text(TranscriptionCoordinator.isOfferedAutomatically(for: song)
                ? "No transcript yet"
                : "This isn't spoken-word audio")
                .font(.headline)
            Text(TranscriptionCoordinator.isOfferedAutomatically(for: song)
                ? "Transcribe this episode to read along, search it, and jump to any moment."
                : "You can still transcribe it, but music usually has lyrics rather than speech.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Transcribe") { Task { await transcribe() } }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
                .disabled(!SpeechConfig.isTranscriptionConfigured)
            if !SpeechConfig.isTranscriptionConfigured {
                Text("Set a transcription host in Settings → Speech first.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func transcribe() async {
        await coordinator.transcribe(song: song, client: try? NavidromeConfig.makeClient())
    }

    /// Reads the summarizing model straight from its store, the way the MCP tool does.
    ///
    /// It used to take `RemoteControlService` from the environment — which the main window
    /// never injects (only Settings, Music Friend and Spoken Summaries do), so the button it
    /// gated was unreachable in the one place it existed. Nothing in a test could see that:
    /// an absent environment object is a nil optional, not a failure.
    private func summarize() async {
        await coordinator.summarize(trackID: song.id, config: RemoteControlSettings().naturalLanguage)
    }
}

/// The summary above the transcript: an overview, then the chapter marks. Each section seeks.
struct TranscriptSummaryView: View {
    let summary: Summary
    @Binding var showsBody: Bool
    let onSeek: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showsBody.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showsBody ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                    Text("Summary").font(.headline)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsBody {
                if !summary.overview.isEmpty {
                    Text(summary.overview)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(summary.sections.enumerated()), id: \.offset) { _, section in
                    Button {
                        onSeek(section.start)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(TranscriptSummarizer.timestamp(section.start))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.title).font(.callout.weight(.semibold))
                                Text(section.text)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
