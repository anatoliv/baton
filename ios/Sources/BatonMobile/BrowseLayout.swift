import SwiftUI

/// Whether a browse screen draws rows or tiles.
///
/// The Mac has offered this on eleven screens for a long time; the phone offered it on one
/// (Albums). The two views answer different questions — a grid is for recognising something
/// by its artwork, a list is for scanning names, durations and dates — and which you want
/// depends on the screen *and* the moment, which is why it's a control rather than a
/// decision someone else makes for you.
///
/// Deliberately **not** synced between devices. Everything else Baton keeps about you
/// travels, but a 13-inch Mac and a 6-inch phone genuinely want different densities:
/// syncing this would guarantee one of them is wrong. It's a fact about the screen you're
/// holding, like the download folder — not a fact about you.
enum BrowseLayout: String, CaseIterable, Identifiable {
    case grid, list

    var id: String { rawValue }

    var symbol: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
    var label: String { self == .grid ? "Grid" : "List" }

    /// Storage key for a screen. Mirrors the Mac's `tonebox.music.<screen>Layout` naming so
    /// the two are recognisable as the same setting when read side by side.
    static func key(_ screen: String) -> String { "tonebox.music.\(screen)Layout" }
}

/// The control itself — a compact segmented pair, sized for a header's accessory slot.
///
/// One component rather than one per screen. The Mac grew eleven separate pickers and
/// eleven `@AppStorage` keys screen by screen, which is exactly why there are eleven; here
/// the seventh screen costs one line.
struct LayoutPicker: View {
    @Binding var layout: BrowseLayout

    var body: some View {
        Picker("Layout", selection: $layout) {
            ForEach(BrowseLayout.allCases) { option in
                Image(systemName: option.symbol)
                    .accessibilityLabel(option.label)
                    .tag(option)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 96)
        .accessibilityIdentifier("LayoutPicker")
    }
}

/// Column layout for a grid on the current canvas.
///
/// One definition, so a grid on the phone and the same grid on an iPad don't drift into
/// different column widths screen by screen.
enum BrowseGrid {
    static let columns = [GridItem(.adaptive(minimum: 160), spacing: 14)]
    static let spacing: CGFloat = 14
    static let padding: CGFloat = 16
}

/// One grid cell: artwork over a title and optional subtitle.
///
/// Every screen that gained a grid — artists, playlists, podcasts, stations, downloads —
/// is the same shape underneath, so it's drawn once here. The tap target isn't included:
/// some of these push a detail and some start playing, and burying that difference inside
/// a shared tile is how a card ends up doing the wrong thing on one screen.
struct BrowseTile: View {
    let artwork: URL?
    let title: String
    var subtitle: String?
    /// Artists read as portraits; everything else is cover art.
    var circular = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(url: artwork, wholeCover: true)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(AnyShape(circular ? AnyShape(Circle())
                                             : AnyShape(RoundedRectangle(cornerRadius: 12))))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

