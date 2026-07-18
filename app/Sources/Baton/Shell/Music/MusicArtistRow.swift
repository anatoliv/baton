import SwiftUI

/// Deterministic monogram (initial + color) for an artist name — shared by the
/// artist row and the artist grid card so they stay visually consistent.
enum ArtistMonogram {
    /// First alphanumeric character (skips leading quotes/spaces in messy names).
    static func initial(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return String(trimmed.first ?? name.first ?? "?").uppercased()
    }

    static func color(_ name: String) -> Color {
        // Deterministic hash (String.hashValue is per-process seeded → colors would
        // change every launch). Same name → same color, always.
        let seed = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
        return Color(hue: Double(seed % 360) / 360, saturation: 0.5, brightness: 0.62)
    }
}

/// A rich artist list row — a circular monogram avatar (colored from the name),
/// the artist name, an album count, a chevron, and a hover highlight. Replaces the
/// flat mic-glyph label so the long Artists list is scannable and clearly tappable.
struct MusicArtistRow: View {
    let artist: NavidromeArtist
    /// Forces the hover highlight for snapshots/previews.
    var previewHovering = false
    @State private var hovering = false

    private var isHovering: Bool {
        hovering || previewHovering
    }

    private var initial: String { ArtistMonogram.initial(artist.name) }
    private var avatarColor: Color { ArtistMonogram.color(artist.name) }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(avatarColor.gradient)
                .frame(width: 40, height: 40)
                .overlay(Text(initial).font(.headline).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 1) {
                Text(artist.name)
                    .font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                if let count = artist.albumCount, count > 0 {
                    Text("\(count) album\(count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

