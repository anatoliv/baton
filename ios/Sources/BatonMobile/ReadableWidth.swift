import SwiftUI

/// Stops content from spanning an iPad.
///
/// The app ships universal and every screen was laid out for a phone, where "fill the
/// width" is always right. On a 13-inch iPad the same code gives you body text at 150
/// characters a line and settings rows whose chevron sits a hand's width from its label —
/// both technically correct and both unreadable. Typographic measure tops out around 70
/// characters however much glass you own.
///
/// A no-op in compact width, so the phone is untouched.
private struct ReadableWidth: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let limit: CGFloat

    func body(content: Content) -> some View {
        if sizeClass == .regular {
            content
                .frame(maxWidth: limit)
                .frame(maxWidth: .infinity)   // ...and centre that column in the canvas
        } else {
            content
        }
    }
}

extension View {
    /// Cap this content's width on a regular-width canvas and centre it.
    ///
    /// `limit` defaults to a comfortable measure for prose and settings rows. Grids should
    /// *not* use this — a grid's whole job is to reflow into whatever width it's given, and
    /// Albums already does that correctly.
    func readableWidth(_ limit: CGFloat = 700) -> some View {
        modifier(ReadableWidth(limit: limit))
    }
}

/// How large a card should be drawn for the current canvas.
///
/// Phone-sized cards are stranded on an iPad: a 142pt tile in the corner of a 1,032pt
/// canvas reads as a mistake rather than as a choice.
enum CardMetrics {
    /// How much wider a shelf card gets as the text under it grows.
    ///
    /// The card width was keyed only on size class, so at the largest accessibility size
    /// every album title rendered as "Varia…" and every artist as "Kimik…": a shelf of
    /// covers with no words on it.
    ///
    /// Not `@ScaledMetric`, for two reasons. The step is deliberately discrete, since a
    /// card only needs to change size at the point the label stops fitting; and the growth
    /// has to be capped, because a card wide enough for uncapped accessibility type is
    /// wider than the phone and the shelf stops being a shelf. 1.5x at the top end fits
    /// "Various Artists" over two lines and still leaves the next card in view on a 393pt
    /// screen, which is what tells you the row scrolls.
    static func typeScale(_ typeSize: DynamicTypeSize) -> CGFloat {
        switch typeSize {
        case .accessibility1, .accessibility2: return 1.25
        case .accessibility3, .accessibility4, .accessibility5: return 1.5
        default: return typeSize >= .xxLarge ? 1.1 : 1
        }
    }

    static func shelfCard(_ sizeClass: UserInterfaceSizeClass?,
                          _ typeSize: DynamicTypeSize = .large) -> CGFloat {
        (sizeClass == .regular ? 200 : 142) * typeScale(typeSize)
    }

    static func detailArt(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? 260 : 190
    }
}
