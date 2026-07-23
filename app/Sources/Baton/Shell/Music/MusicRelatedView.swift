import SwiftUI

/// "Related" panel for the full-screen player — similar tracks to the current
/// song via OpenSubsonic `getSimilarSongs2` (`MusicLibraryStore.similarSongs`).
/// Tapping a row plays the related list from there.
struct MusicRelatedView: View {
    @Environment(MusicModel.self) private var model
    let song: NavidromeSong
    /// Injected results for previews/snapshots (skips the network load).
    var previewRelated: [NavidromeSong]?
    @State private var related: [NavidromeSong] = []
    @State private var loading = true

    private var shown: [NavidromeSong] {
        model.musicRadioBans.filtered(previewRelated ?? related)
    }

    private var isLoading: Bool {
        previewRelated == nil && loading
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.title).foregroundStyle(.secondary)
                    Text("No related tracks").foregroundStyle(.secondary)
                    Text("Your server had no similar songs for this track.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("\(shown.count) similar").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { playRadio(startAt: 0) } label: { Label("Play all", systemImage: "play.fill") }
                        Button { model.music.enqueue(shown) } label: { Label("Queue all", systemImage: "text.append") }
                    }
                    .font(.caption).buttonStyle(.borderless)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, track in
                                MusicPanelTrackRow(index: index, song: track) { playRadio(startAt: index) }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .task(id: song.id) {
            if previewRelated != nil { return }
            loading = true
            let results = await model.musicLibrary.similarSongs(seedID: song.id)
            // De-duplicate by id (and drop the seed itself). The server can return the
            // same track twice, and a duplicate id makes SwiftUI's ForEach collapse a
            // row into a blank gap — plus a related list shouldn't repeat tracks.
            var seen: Set<String> = [song.id]
            related = results.filter { seen.insert($0.id).inserted }
            loading = false
        }
    }

    private func playRadio(startAt index: Int) {
        model.music.play(shown, startAt: index, source: .init(label: "\(song.title) Radio", kind: .radio, id: nil))
    }
}

/// Compact track row for the narrow full-screen side panels (Related, and other
/// 320px-wide track lists). Matches the Up Next queue aesthetic — a play/now-playing
/// leading glyph, roomy title/artist, a small duration, and a quick like heart, with
/// play-next / add-to-queue / rating on the context menu (the 5-star cluster from the
/// wide library `MusicTrackRow` doesn't fit here and truncates the title).
struct MusicPanelTrackRow: View {
    @Environment(MusicModel.self) private var model
    let index: Int
    let song: NavidromeSong
    var onPlay: () -> Void
    @State private var hovering = false
    @State private var showRemoveConfirm = false

    private var isCurrent: Bool { model.music.nowPlaying?.id == song.id }
    private var isPlaying: Bool { isCurrent && model.music.isPlaying }

    var body: some View {
        HStack(spacing: 11) {
            MusicSongThumb(song: song, size: 36, onPlay: onPlay)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(1)
                if let artist = song.displayArtistName, !artist.isEmpty {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let quality = song.qualityLabel {
                MusicMetaBadge(quality)
            }
            if let duration = song.duration {
                Text(MusicTrackRow.formatDuration(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(background)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeInOut(duration: 0.18), value: isCurrent)
        .contextMenu {
            songPlaybackMenuItems(song, model, onPlay: onPlay)
            Divider()
            songDownloadMenuItems(song, model)
            songActionsMenu(song, model)
            songRadioMenuItem(song, model)
            Menu("Rate", systemImage: "star") {
                ForEach((1 ... 5).reversed(), id: \.self) { star in
                    Button("\(String(repeating: "★", count: star))") {
                        Task { await model.musicLibrary.setRating(song, rating: star) }
                    }
                }
                Button("Clear Rating") {
                    Task { await model.musicLibrary.setRating(song, rating: 0) }
                }
            }
            Divider()
            songRemovalMenuItem(showConfirm: $showRemoveConfirm)
        }
        .songRemovalConfirm(song, model, isPresented: $showRemoveConfirm)
    }

    private var background: Color {
        if isCurrent { return Color.nowPlayingRowTint() }
        return hovering ? Color.primary.opacity(0.07) : .clear
    }
}
