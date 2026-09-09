import SwiftUI
import Testing
@testable import BatonMobile

/// The artwork wash has to stay legible in **both** appearances.
///
/// It did not. `AdaptiveBackdrop` had no colour-scheme branch at all and finished with a
/// black scrim, so picking Settings → Appearance → Light left every browse screen drawing
/// near-black `.primary` text on a near-black ground (I-F2). These assert the thing that
/// actually decides that: the flattened colour the text sits on, at the worst point of the
/// wash, against the body colour that scheme uses.
@Suite("Backdrop contrast")
struct BackdropContrastTests {
    /// Palettes chosen to be hostile rather than typical: a black cover is the worst case
    /// for the light wash, a white one for the dark wash, and the saturated pair are what
    /// real album art looks like when the extractor has something to work with.
    private static let hostile: [(name: String, palette: ArtworkPalette)] = [
        ("neutral fallback", .neutral),
        ("pure black", ArtworkPalette(primary: .black, secondary: .black, accent: .black)),
        ("pure white", ArtworkPalette(primary: .white, secondary: .white, accent: .white)),
        ("deep red", ArtworkPalette(
            primary: Color(red: 0.42, green: 0.03, blue: 0.05),
            secondary: Color(red: 0.14, green: 0.01, blue: 0.02),
            accent: Color(red: 0.86, green: 0.11, blue: 0.16)
        )),
        ("night blue", ArtworkPalette(
            primary: Color(red: 0.05, green: 0.09, blue: 0.31),
            secondary: Color(red: 0.02, green: 0.03, blue: 0.12),
            accent: Color(red: 0.16, green: 0.44, blue: 0.92)
        )),
    ]

    /// WCAG AA for body text. The same floor `uiAccent` already clamps the player accent to.
    private let floor = 4.5

    @Test("The light wash keeps AA against near-black body text, for any artwork")
    func lightToneClearsAA() {
        for (name, palette) in Self.hostile {
            let ground = palette.backdropWorstCase(for: .light)
            let ratio = Contrast.ratio(ground, .black)
            #expect(ratio >= floor,
                    "light wash from \(name) leaves black text at \(ratio):1")
        }
    }

    @Test("The dark wash still keeps AA against white text for artwork the extractor produces")
    func darkToneClearsAAForExtractedPalettes() async throws {
        // Real covers, not synthetic ones: `secondary` is the whole-image average scaled to
        // 0.45, so an extracted palette is always darker than the "pure white" case above,
        // which is why that one is only asked about the light tone.
        let cover = try #require(
            Bundle.main.url(forResource: "demo-2-cover", withExtension: "png"),
            "the demo covers must be bundled"
        )
        let palette = try #require(await ArtworkColorExtractor.palette(from: cover))
        let ground = palette.backdropWorstCase(for: .dark)
        let ratio = Contrast.ratio(ground, .white)
        #expect(ratio >= floor, "dark wash leaves white text at \(ratio):1")
    }

    @Test("The two tones are actually different grounds")
    func tonesDiffer() {
        let palette = ArtworkPalette.neutral
        #expect(palette.backdropLayers(for: .light) != palette.backdropLayers(for: .dark))
        // The bug in one line: the light tone must not end on a black scrim.
        #expect(Contrast.relativeLuminance(palette.backdropWorstCase(for: .light))
                > Contrast.relativeLuminance(palette.backdropWorstCase(for: .dark)))
    }

    @Test("The dark wash is the one that shipped, layer for layer")
    func darkToneIsUnchanged() {
        // A pin, not a preference: the player draws on this and nothing about it was the
        // finding. If this fails, the light fix has moved the dark ground too.
        let palette = ArtworkPalette.neutral
        let layers = palette.backdropLayers(for: .dark)
        #expect(layers.base == palette.secondary)
        #expect(layers.primaryGlow == palette.primary.opacity(0.9))
        #expect(layers.accentGlow == palette.accent.opacity(0.8))
        #expect(layers.bottomGlow == palette.primary.opacity(0.6))
        #expect(layers.scrim == Color.black.opacity(0.28))
    }

    @Test("Compositing is the renderer's arithmetic, not an approximation")
    func compositeMatchesSourceOver() {
        // Half-opacity white over black is mid-grey. If this drifts, every contrast number
        // above is measuring something the screen does not do.
        let result = Contrast.composite(Color.white.opacity(0.5), over: .black)
        let (r, g, b) = Contrast.components(result)
        #expect(abs(r - 0.5) < 0.01)
        #expect(abs(g - 0.5) < 0.01)
        #expect(abs(b - 0.5) < 0.01)
        // A fully opaque top layer wins outright.
        let opaque = Contrast.composite(.white, over: .black)
        #expect(Contrast.relativeLuminance(opaque) > 0.9)
    }
}
