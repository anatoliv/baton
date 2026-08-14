import SwiftUI

/// Lyrics panel for the full-screen player. When the server returns time-synced
/// lyrics (`getLyricsBySongId`), the current line is highlighted karaoke-style and
/// auto-scrolls with playback; otherwise the plain lyric text is shown.
struct MusicLyricsView: View {
    @Environment(MusicModel.self) private var model
    let song: NavidromeSong
    /// Injected lyrics for previews/snapshots (skips the network load).
    var previewLyrics: NavidromeLyrics?
    @State private var lyrics: NavidromeLyrics?
    @State private var loading = true

    private var displayLyrics: NavidromeLyrics? {
        previewLyrics ?? lyrics
    }

    private var isLoading: Bool {
        previewLyrics == nil && loading
    }

    /// A two-hour set is not a song that happens to be missing its words, and saying so is
    /// kinder than the generic empty state after a lookup that never had a chance.
    private var emptyMessage: String {
        LRCLIBLyrics.isLikelyLyricless(durationSeconds: song.duration)
            ? "Too long to have lyrics — mixes and sets aren't written down"
            : "No lyrics for this track"
    }

    private var currentLine: Int? {
        guard let lyrics = displayLyrics, lyrics.synced else { return nil }
        let time = model.music.currentTime
        var index: Int?
        for (idx, line) in lyrics.lines.enumerated() {
            if let start = line.start, start <= time { index = idx } else if line.start != nil { break }
        }
        return index
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lyrics = displayLyrics, !lyrics.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        MusicLyricLines(lyrics: lyrics, currentLine: currentLine)
                    }
                    .onChange(of: currentLine) { _, newValue in
                        if let newValue { withAnimation(.easeInOut) { proxy.scrollTo(newValue, anchor: .center) } }
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "text.quote").font(.title).foregroundStyle(.secondary)
                    Text(emptyMessage).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: song.id) {
            if let previewLyrics { lyrics = previewLyrics; loading = false; return }
            loading = true
            lyrics = await model.musicLibrary.lyrics(for: song.id, song: song)
            loading = false
        }
    }
}

/// The lyric lines themselves — eager `VStack` (renderable in snapshots) with the
/// current synced line highlighted karaoke-style.
///
/// Shared with the transcript pane, which is the same shape of timed text. `onSelectLine` is
/// what the transcript adds: tapping a line seeks to it. Lyrics pass nil, because a lyric line
/// carries the server's idea of a timing rather than a measured one, and seeking to it would
/// be a guess dressed up as a control.
struct MusicLyricLines: View {
    let lyrics: NavidromeLyrics
    let currentLine: Int?
    var onSelectLine: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, item in
                lineView(index, item)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func lineView(_ index: Int, _ item: NavidromeLyrics.Line) -> some View {
        let text = Text(item.text.isEmpty ? " " : item.text)
            .font(.title3.weight(index == currentLine ? .bold : .regular))
            .foregroundStyle(color(index))
        if let onSelectLine {
            Button { onSelectLine(index) } label: {
                text.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(index)
            .animation(.easeInOut(duration: 0.25), value: currentLine)
        } else {
            text
                .id(index)
                .animation(.easeInOut(duration: 0.25), value: currentLine)
        }
    }

    private func color(_ index: Int) -> Color {
        guard lyrics.synced else { return .white.opacity(0.85) }
        if index == currentLine { return .white }
        return .white.opacity(0.4)
    }
}
