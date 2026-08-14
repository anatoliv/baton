import SwiftUI

/// What was said in a spoken track, timed — the phone's counterpart to the Mac's transcript
/// panel. Lines highlight with the engine clock and tapping one seeks to it, exactly as
/// `LyricsSheet` does, because a transcript is the same shape of timed text.
///
/// Kept separate from `LyricsSheet` rather than folded into it: a podcast has no lyrics, the
/// trigger is a deliberate action rather than an automatic lookup, and a failed transcription
/// must not read like a song that simply has no words.
///
/// See `specs/track-transcription.md`.
struct TranscriptSheet: View {
    let song: NavidromeSong
    let model: MobileModel
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator = TranscriptionCoordinator.shared
    /// Whether the transcript still follows the playhead. Stops the moment the reader scrolls,
    /// resumes only when they ask. See the Mac pane and TBX-2986: the highlight moves several
    /// times a second, so following after a manual scroll dragged the list straight back and
    /// made the transcript impossible to read ahead of the audio.
    @State private var isFollowing = true

    private var transcript: Transcript? { coordinator.transcript(for: song.id) }

    var body: some View {
        NavigationStack {
            Group {
                if let stage = coordinator.stage(for: song.id) {
                    working(stage)
                } else if let transcript, !transcript.isEmpty {
                    lines(transcript)
                } else if let failure = coordinator.failure(for: song.id) {
                    problem(failure)
                } else {
                    offer
                }
            }
            .navigationTitle(song.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    // MARK: - States

    private func working(_ stage: TranscriptionCoordinator.Stage) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(stage.rawValue).foregroundStyle(.secondary)
            Text("This takes a minute or two for a long episode.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func lines(_ transcript: Transcript) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    // A failure raised while a transcript already exists — a refused summary,
                    // most likely. The full-pane failure state is only reachable when there is
                    // nothing to show, so without this the refusal would be invisible.
                    if let failure = coordinator.failure(for: song.id) {
                        Label(failure.message, systemImage: failure.isUnavailable ? "info.circle" : "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let summary = transcript.summary, !summary.isEmpty {
                        summaryBlock(summary)
                        Divider()
                    }
                    ForEach(Array(transcript.segments.enumerated()), id: \.offset) { index, segment in
                        Text(segment.text)
                            .font(.title3.weight(currentIndex == index ? .bold : .regular))
                            .foregroundStyle(currentIndex == index ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .id(index)
                            .onTapGesture {
                                guard transcript.synced else { return }
                                seek(to: segment.start)
                            }
                    }
                }
                .padding()
            }
            // `.animating` is our own `scrollTo`, so following survives its own animation;
            // the other two are the reader.
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating { isFollowing = false }
            }
            .onChange(of: currentIndex) { _, index in
                guard isFollowing, let index else { return }
                withAnimation { proxy.scrollTo(index, anchor: .center) }
            }
            .overlay(alignment: .bottom) {
                if !isFollowing, let currentIndex {
                    Button {
                        isFollowing = true
                        withAnimation { proxy.scrollTo(currentIndex, anchor: .center) }
                    } label: {
                        Label("Jump to current", systemImage: "location.fill")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: isFollowing)
        }
    }

    /// A seek is a deliberate move to a place, so following resumes: the playhead is now
    /// exactly where the reader pointed.
    private func seek(to seconds: Double) {
        model.music.seek(to: seconds)
        isFollowing = true
    }

    private func summaryBlock(_ summary: Summary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Summary").font(.headline)
            if !summary.overview.isEmpty {
                Text(summary.overview).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(summary.sections.enumerated()), id: \.offset) { _, section in
                Button {
                    seek(to: section.start)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(TranscriptSummarizer.timestamp(section.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title).font(.callout.weight(.semibold))
                            Text(section.text)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func problem(_ failure: TranscriptStore.Failure) -> some View {
        // Off the home network is the *ordinary* case on a phone, so an unreachable host says
        // "unavailable" and offers to retry. It is not a fault and must not read as one.
        ContentUnavailableView {
            Label(
                failure.isUnavailable ? "Transcription unavailable" : "Transcription failed",
                systemImage: failure.isUnavailable ? "wifi.slash" : "exclamationmark.triangle"
            )
        } description: {
            Text(failure.message)
        } actions: {
            Button("Try again") { Task { await transcribe() } }
        }
    }

    private var offer: some View {
        ContentUnavailableView {
            Label("No transcript yet", systemImage: "text.viewfinder")
        } description: {
            Text(SpeechConfig.isTranscriptionConfigured
                ? "Transcribe this episode to read along and jump to any moment."
                : "Set a transcription host in Settings → Speech first.")
        } actions: {
            Button("Transcribe") { Task { await transcribe() } }
                .disabled(!SpeechConfig.isTranscriptionConfigured)
        }
    }

    // MARK: - Helpers

    private var currentIndex: Int? {
        transcript?.segmentIndex(at: model.music.currentTime)
    }

    private func transcribe() async {
        await coordinator.transcribe(song: song, client: try? NavidromeConfig.makeClient())
    }
}
