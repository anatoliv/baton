import BatonDocuments
import BatonPlaybackKit
import SwiftUI

/// Read-along (`specs/document-clippings.md`, *Expansions* 6): a chapter of a book
/// as text, with the sentence being heard lit, following the playhead, and every sentence a
/// place to seek to. Shared verbatim by the Mac (the player's Transcript panel for a book, and
/// Read Along from a book in Clippings) and the iPhone (the full player).
///
/// The timing comes from the renderer, by the chapter audio's digest (`ReadAlongStore`); a
/// chapter made before timing was kept shows its words without a highlight, and says why.
///
/// Following stops when the reader scrolls and resumes when they ask or tap a sentence, the
/// rule the transcript pane learned in an internal task: a highlight that moves every few seconds and
/// drags the list back with it makes the text unreadable for anyone looking around.
struct ReadAlongPanel: View {
    let item: ClippingStore.Item
    /// Where the player is in this chapter, or nil when this chapter is not the one playing.
    let currentTime: Double?
    /// The chapter's timing, wherever this device keeps it. Nil: show the text alone.
    let loadTiming: @MainActor (ClippingStore.Item) async -> ReadAlongTiming?
    /// A sentence was tapped: play from `seconds` into this chapter.
    let onSeek: (Double) -> Void

    @State private var readAlong: ReadAlong?
    @State private var isFollowing = true

    /// A sentence's place in the scroll view, for `scrollTo`. Its own type because the
    /// paragraphs' `ForEach` identities are numbers from 0 as well, and a bare `Int` found
    /// paragraph 7 when it meant sentence 7: a jump, or following, landed pages further on,
    /// with the lit sentence nowhere on screen.
    private struct SentenceAnchor: Hashable { let index: Int }

    private var currentIndex: Int? {
        guard let currentTime, let readAlong else { return nil }
        return readAlong.sentenceIndex(at: currentTime)
    }

    var body: some View {
        Group {
            if let readAlong {
                if readAlong.sentences.isEmpty {
                    Text("This chapter has no text to show.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content(readAlong)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ReadAlong")
        #if DEBUG
        // DEBUG only: the playhead this panel was given, so a UI test reads it and the lit
        // sentence in one query and can tell the panel's lag from its own slow sampling
        // Not for VoiceOver: a release build says nothing extra.
        .accessibilityValue(currentTime.map { String(format: "playhead %.2f", $0) } ?? "")
        #endif
        // By the audio as well as the chapter: a chapter given a new voice keeps its row and
        // id, and its sentences sit at other times in the new audio.
        .task(id: Self.timingIdentity(of: item)) {
            readAlong = nil
            isFollowing = true
            let timing = await loadTiming(item)
            readAlong = ReadAlong(timing: timing, fallbackText: item.clipping.text)
        }
    }

    /// What the timing shown belongs to: this chapter in this audio.
    static func timingIdentity(of item: ClippingStore.Item) -> String {
        "\(item.id)|\(item.clipping.sha256 ?? "")|\(item.clipping.voice ?? "")"
    }

    private func content(_ along: ReadAlong) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let title = item.clipping.chapterTitle ?? Optional(item.clipping.title) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(along.paragraphs.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(group.sentences) { sentence in
                                sentenceRow(sentence, timed: along.isTimed)
                            }
                        }
                    }
                    if !along.isTimed {
                        Label("This book was made before Baton kept timings, so the sentence being heard isn't marked.",
                              systemImage: "clock.badge.questionmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("ReadAlongUntimed")
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // `.interacting` and `.decelerating` are the reader's own scrolling; `.animating` is
            // ours, from `scrollTo`, so following survives its own animation.
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating { isFollowing = false }
            }
            .onChange(of: currentIndex) { _, index in
                guard isFollowing, let index else { return }
                withAnimation(.easeInOut) { proxy.scrollTo(SentenceAnchor(index: index), anchor: .center) }
            }
            .onAppear {
                if let currentIndex { proxy.scrollTo(SentenceAnchor(index: currentIndex), anchor: .center) }
            }
            .overlay(alignment: .bottom) {
                if !isFollowing, let currentIndex {
                    Button {
                        isFollowing = true
                        withAnimation(.easeInOut) { proxy.scrollTo(SentenceAnchor(index: currentIndex), anchor: .center) }
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

    @ViewBuilder
    private func sentenceRow(_ sentence: ReadAlong.Sentence, timed: Bool) -> some View {
        let isCurrent = sentence.id == currentIndex
        let text = Text(sentence.text)
            .font(.title3.weight(isCurrent ? .semibold : .regular))
            .foregroundStyle(isCurrent || !timed ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isCurrent ? Color.nowPlayingRowTint() : Color.clear)
            )
            .contentShape(Rectangle())
        if let start = sentence.start {
            Button {
                isFollowing = true
                onSeek(start)
            } label: { text }
                .buttonStyle(.plain)
                .id(SentenceAnchor(index: sentence.id))
                .accessibilityIdentifier("readalong-sentence-\(sentence.id)")
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .accessibilityHint("Plays from this sentence")
                .animation(.easeInOut(duration: 0.25), value: isCurrent)
        } else {
            text
                .id(SentenceAnchor(index: sentence.id))
                .accessibilityIdentifier("readalong-sentence-\(sentence.id)")
        }
    }
}
