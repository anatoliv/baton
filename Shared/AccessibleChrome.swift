import SwiftUI

/// Chrome that respects **Reduce Transparency** and **Differentiate Without Color**.
///
/// Neither setting was honoured anywhere in either app. That matters more here than in most
/// apps, for two specific reasons:
///
/// - Baton's chrome is `.ultraThinMaterial` over an artwork-derived colour wash. Reduce
///   Transparency exists for people who find text over a busy, shifting background hard to
///   read, and a wash that changes with every track is exactly that background.
/// - Selection, now-playing and liked states are signalled with the accent colour. Turn
///   colour off as a channel and several of them become indistinguishable from their
///   neutral state — the row you are on looks like every other row.
public extension View {
    /// A material background that becomes an opaque fill under Reduce Transparency.
    func adaptiveMaterial<S: Shape>(_ shape: S) -> some View {
        modifier(AdaptiveMaterialBackground(shape: shape))
    }

    /// Draw `overlay` over this view while `isCovered`, and take what it covers out of the
    /// accessibility tree at the same time.
    ///
    /// A plain `.overlay` hides content from sight and not from VoiceOver. The rows
    /// underneath stay in the tree, so a swipe still reaches a row that is not on the
    /// screen, and a screenshot of the fixed screen looks identical to a screenshot of the
    /// broken one. `Shared/ContentStateView.swift` hit this with the phone's empty states
    ///; the Mac's full-screen player was the same shape.
    ///
    /// The two halves belong together, which is why this is one modifier rather than two
    /// lines at each call site: writing `.overlay` and forgetting `accessibilityHidden` is
    /// exactly the defect, and it is invisible unless someone runs VoiceOver.
    ///
    /// `CoveringOverlayAccessibilityTests` walks the real AppKit accessibility tree over
    /// this modifier and asserts the covered control is gone from it.
    @ViewBuilder
    func coveringOverlay<Overlay: View>(
        _ isCovered: Bool,
        @ViewBuilder overlay: () -> Overlay
    ) -> some View {
        accessibilityHidden(isCovered)
            .overlay { if isCovered { overlay() } }
    }
}

private struct AdaptiveMaterialBackground<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S

    func body(content: Content) -> some View {
        if reduceTransparency {
            // A solid surface colour, not a translucent one: the point of the setting is
            // that nothing shows through.
            content.background(Color.chromeOpaque, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

public extension Color {
    /// The opaque stand-in for `.ultraThinMaterial` when transparency is reduced.
    ///
    /// Deliberately not `.background`: this chrome sits over the artwork wash on a
    /// permanently dark surface, and the system background colour is light in light mode,
    /// which would invert the chrome for the one group of users who asked for *less*
    /// visual complexity.
    static let chromeOpaque = Color(white: 0.12)
}

/// Whether state should carry a shape as well as a colour.
///
/// Read this in a view that signals something with tint alone and add a glyph, a weight, or
/// a border when it is true. Wrapped in a property so the intent reads at the call site —
/// `@Environment(\.accessibilityDifferentiateWithoutColor)` is a mouthful that gets copied
/// wrong.
public struct DifferentiateWithoutColor {
    public var isOn: Bool
    public init(isOn: Bool) { self.isOn = isOn }

    /// A leading marker for a selected/current row, or nil when colour is doing the job.
    public var selectionMarker: String? { isOn ? "chevron.right" : nil }
}
