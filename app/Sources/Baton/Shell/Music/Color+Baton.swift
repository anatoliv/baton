import AppKit
import SwiftUI

/// Baton's brand color + the semantic tokens and WCAG contrast math that back the
/// visual design system (see `docs/Baton-macOS-App-Visual-Design-System.md`).
///
/// The **Brand ⇄ Dynamic** rule: brand orange anchors everything the user acts on
/// (buttons, selection, active toggles) and is installed as the app's `AccentColor`
/// asset, so `Color.accentColor` resolves to Baton orange rather than the user's
/// macOS system accent. The dynamic artwork palette (`ArtworkPalette`) is confined
/// to ambient + player-context surfaces.
extension Color {
    /// Permanent Baton brand orange — `#E98345` (sRGB). The single source of truth;
    /// the `AccentColor` asset mirrors these components so `.accentColor`/`.tint`
    /// resolve here app-wide.
    static let batonOrange = Color(red: 0.914, green: 0.514, blue: 0.271)

    /// Brand tints for interaction states (hover / pressed / disabled).
    static let brandHover = Color.batonOrange.opacity(0.85)
    static let brandPressed = Color.batonOrange.opacity(0.70)
    static let brandMuted = Color.batonOrange.opacity(0.38)

    // MARK: Semantic surface tokens
    //
    // One place for the surface-hierarchy opacities from the design doc, so the
    // values don't live inline at ~40 call sites. `context` is the accent in play
    // for the surface: brand orange in chrome, the dynamic accent in the player.

    /// Selected list/grid row background fill (12%).
    static func selectionTint(_ context: Color = .accentColor) -> Color { context.opacity(0.12) }
    /// Sidebar selection background fill (15%).
    static func sidebarSelectionTint(_ context: Color = .accentColor) -> Color { context.opacity(0.15) }
    /// Now-playing queue row background fill (16%).
    static func nowPlayingRowTint(_ context: Color = .accentColor) -> Color { context.opacity(0.16) }
    /// Neutral hover fill (6%), independent of accent.
    static let hoverTint = Color.primary.opacity(0.06)

    /// Sidebar count-badge fill when its section is selected (18%).
    static func badgeTint(_ context: Color = .accentColor) -> Color { context.opacity(0.18) }
    /// Sidebar count-badge fill when idle (neutral 8%).
    static let badgeIdleTint = Color.primary.opacity(0.08)
    /// Soft glow around the now-playing **source** card (50%).
    static func playingGlowTint(_ context: Color = .accentColor) -> Color { context.opacity(0.5) }
}

/// WCAG relative-luminance + contrast math. The single implementation used by
/// `ArtworkColorExtractor` to guarantee the dynamic accent stays legible against the
/// player backdrop. Pure and synchronous, so it is unit-testable.
enum Contrast {
    /// sRGB components of a `Color` in [0,1], resolved through AppKit. Falls back to
    /// mid-gray if the color can't be expressed in sRGB (e.g. a pattern/catalog color).
    static func components(_ color: Color) -> (r: Double, g: Double, b: Double) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return (0.5, 0.5, 0.5) }
        return (Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
    }

    /// Linearize one gamma-encoded sRGB channel (WCAG definition).
    private static func linearize(_ channel: Double) -> Double {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    /// WCAG relative luminance of a color, in [0,1].
    static func relativeLuminance(_ color: Color) -> Double {
        let (r, g, b) = components(color)
        return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }

    /// WCAG contrast ratio between two colors, in [1, 21].
    static func ratio(_ a: Color, _ b: Color) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        let lighter = max(la, lb), darker = min(la, lb)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// HSB saturation of a color, in [0,1]. Used to detect (near-)grayscale artwork.
    static func saturation(_ color: Color) -> Double {
        let (r, g, b) = components(color)
        let hi = max(r, g, b), lo = min(r, g, b)
        return hi == 0 ? 0 : (hi - lo) / hi
    }

    /// Lighten `color` toward white in small steps until it meets `min` contrast
    /// against `background`. Returns the corrected color, or `fallback` if the target
    /// can't be reached within the step budget (e.g. the color is already near-white).
    static func ensureContrast(
        of color: Color,
        against background: Color,
        min target: Double = 4.5,
        fallback: Color = .batonOrange
    ) -> Color {
        if ratio(color, background) >= target { return color }
        let (r, g, b) = components(color)
        var best = color
        // Blend toward white in 12 steps; accept the first that clears the target.
        for step in 1...12 {
            let t = Double(step) / 12.0
            let lifted = Color(
                red: r + (1 - r) * t,
                green: g + (1 - g) * t,
                blue: b + (1 - b) * t
            )
            best = lifted
            if ratio(lifted, background) >= target { return lifted }
        }
        // Couldn't reach the target by lightening — prefer the brand color if it is
        // itself legible against the background, else the best (lightest) attempt.
        return ratio(fallback, background) >= target ? fallback : best
    }
}
