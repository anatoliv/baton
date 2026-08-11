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

    // Keys live on `BrowseScreen` in Shared/ now — the Mac had twelve of them spelled out
    // by hand, and a helper that only one of the two apps could reach was how that happened.
}

/// The control itself — one button, sized for a toolbar or a header's accessory slot.
///
/// One component rather than one per screen. The Mac grew eleven separate pickers and
/// eleven `@AppStorage` keys screen by screen, which is exactly why there are eleven; here
/// the seventh screen costs one line.
struct LayoutPicker: View {
    @Binding var layout: BrowseLayout

    /// A single button showing the layout you'd switch *to*, not a segmented pair.
    ///
    /// `.pickerStyle(.segmented)` inside a toolbar item draws its own capsule inside the
    /// capsule the toolbar already puts around the item, and fills the selected half with
    /// a third — a pill in a pill in a pill, sitting beside a back button and a sort
    /// button that are each one plain circle. The outline everyone sees is the middle one,
    /// and no modifier removes it: it belongs to the picker style.
    ///
    /// One button matches the neighbours, is a bigger tap target than half a 96pt
    /// segmented control, and cannot grow a second outline.
    var body: some View {
        Button {
            layout = (layout == .grid) ? .list : .grid
        } label: {
            Image(systemName: layout == .grid ? BrowseLayout.list.symbol : BrowseLayout.grid.symbol)
        }
        // The label names the destination, because that is what a tap does: "Show as
        // list" while you are looking at a grid.
        .accessibilityLabel(layout == .grid ? "Show as \(BrowseLayout.list.label)"
                                            : "Show as \(BrowseLayout.grid.label)")
        .accessibilityIdentifier("LayoutPicker")
    }
}

/// Column layout for a grid on the current canvas.
///
/// One definition, so a grid on the phone and the same grid on an iPad don't drift into
/// different column widths screen by screen.
enum BrowseGrid {
    /// 150, not 160, because 160 sat 10pt inside the cliff.
    ///
    /// A 390pt phone gives the grid `390 − 32 (padding) − 34 (A–Z rail) = 324pt`, and two
    /// 160pt columns need `160 + 14 + 160 = 334`. Ten points short, so Artists in grid
    /// layout collapsed to a single column: one enormous circle per screen. Widening the
    /// rail's reserve by 12pt is what tipped it, and the previous 18pt reserve had cleared
    /// it by only six — the layout was one adjustment away from breaking either way.
    /// 150 needs 314 and leaves real headroom on the narrowest phone that runs this app.
    static let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(url: artwork, wholeCover: true)
                .aspectRatio(1, contentMode: .fit)
                // Square, like every other tile. Artists were the one circular case, and
                // a round crop of a band photo is a round crop of a band photo — it cut
                // the edges off the group shots it was meant to flatter.
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                // Decorative — the title says what this is.
                .accessibilityHidden(true)
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
        // One VoiceOver stop per tile. Every grid on the phone uses this, so leaving it
        // uncombined multiplied every browse screen's swipe count by three.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
    }

}

