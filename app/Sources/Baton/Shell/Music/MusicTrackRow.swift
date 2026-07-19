import SwiftUI

/// One track row in the music player: play affordance, title/artist, a 5-star
/// rating control, and a like (heart) toggle. Ratings + likes write through to the
/// server via `MusicLibraryStore` (optimistic), so they double as the pipeline signal.
struct MusicTrackRow: View {
    @Environment(MusicModel.self) private var model
    let song: NavidromeSong
    /// Whether this row is the one currently loaded in the player.
    var isCurrent: Bool = false
    var onPlay: () -> Void
    @State private var showRemoveConfirm = false

    var body: some View {
        HStack(spacing: 10) {
            MusicSongThumb(song: song, onPlay: onPlay)

            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                if let artist = song.artist, !artist.isEmpty {
                    Text(artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)

            DownloadStatusBadge(songID: song.id)
            if let duration = song.duration {
                Text(Self.formatDuration(duration))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            MusicRatingStars(song: song)
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.18), value: isCurrent)
        .onTapGesture(count: 2, perform: onPlay)
        .contextMenu {
            songPlaybackMenuItems(song, model, onPlay: onPlay)
            PinMenuButton(item: .song(song), model: model)
            Divider()
            songDownloadMenuItems(song, model)
            songRadioMenuItem(song, model)
            Divider()
            songRemovalMenuItem(showConfirm: $showRemoveConfirm)
        }
        .songRemovalConfirm(song, model, isPresented: $showRemoveConfirm)
    }

    static func formatDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// A 1–5 star rating control. Tapping a star sets that rating; tapping the current
/// rating clears it (rating 0). Writes through to the server.
/// The 5-star rating control, generic over what it rates: a current value + a setter.
/// `MusicRatingStars` (songs) and the album row both use it so the look is identical.
struct MusicStarRating: View {
    let rating: Int
    var onRate: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1 ... 5, id: \.self) { star in
                Button { onRate(rating == star ? 0 : star) } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.subheadline)
                        .foregroundStyle(star <= rating ? Color.yellow : .secondary.opacity(0.45))
                        .frame(width: 16, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Rate \(star)")
            }
        }
    }
}

struct MusicRatingStars: View {
    @Environment(MusicModel.self) private var model
    let song: NavidromeSong

    var body: some View {
        MusicStarRating(rating: model.musicLibrary.rating(song)) { newRating in
            Task { await model.musicLibrary.setRating(song, rating: newRating) }
        }
    }
}
