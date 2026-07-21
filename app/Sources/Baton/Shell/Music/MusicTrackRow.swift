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
                if let artist = song.displayArtistName, !artist.isEmpty {
                    Text(artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            // VoiceOver reads the track as one phrase ("Title, by Artist, now playing") instead of
            // two separate text nodes; the rating/like controls stay individually accessible. (W-56)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(trackAccessibilityLabel)
            Spacer(minLength: 8)

            DownloadStatusBadge(songID: song.id)
            if let quality = song.qualityLabel {
                MusicMetaBadge(quality)
            }
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

    private var trackAccessibilityLabel: String {
        var label = song.title
        if let artist = song.artist, !artist.isEmpty { label += ", by \(artist)" }
        if isCurrent { label += ", now playing" }
        return label
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
                .accessibilityLabel("Rate \(star) star\(star == 1 ? "" : "s")")
                .accessibilityAddTraits(star <= rating ? .isSelected : [])
            }
        }
        .accessibilityValue(rating == 0 ? "Not rated" : "\(rating) of 5 stars")
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

/// A like (heart) toggle — pink when liked, muted otherwise. Reused for tracks, albums, and
/// artists so the affordance is identical everywhere.
struct MusicLikeHeart: View {
    let isLiked: Bool
    var help: String = ""
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.subheadline)
                .foregroundStyle(isLiked ? AnyShapeStyle(Color.pink) : AnyShapeStyle(.secondary.opacity(0.55)))
                .frame(width: 22, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help.isEmpty ? (isLiked ? "Unlike" : "Like") : help)
        .accessibilityAddTraits(isLiked ? .isSelected : [])
    }
}

/// A small, subtle metadata pill — format/quality (e.g. "FLAC · 24/96"), genre, or a release-type
/// badge. Deliberately understated so it reads as secondary chrome, not a control.
struct MusicMetaBadge: View {
    let text: String
    var prominent = false

    init(_ text: String, prominent: Bool = false) {
        self.text = text
        self.prominent = prominent
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(prominent ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.14))
            )
            .fixedSize()
            .accessibilityLabel(text)
    }
}
