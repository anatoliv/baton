import AppKit
import SwiftUI
import Testing
@testable import Baton

/// WCAG contrast math + the Brand ⇄ Dynamic accent rules that keep the artwork-driven
/// accent legible (see `docs/Baton-macOS-App-Visual-Design-System.md`).
@Suite("Color & Contrast")
struct ColorContrastTests {
    private func solidImage(_ color: NSColor, size: Int = 48) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        return image
    }

    // MARK: WCAG math

    @Test("Black-on-white contrast is the WCAG maximum (~21:1)")
    func extremeContrast() {
        let ratio = Contrast.ratio(.white, .black)
        #expect(ratio > 20.5 && ratio <= 21.01)
    }

    @Test("A color has no contrast with itself (1:1)")
    func selfContrast() {
        let ratio = Contrast.ratio(.batonOrange, .batonOrange)
        #expect(abs(ratio - 1.0) < 0.001)
    }

    @Test("Brand orange clears AA against the dark player backdrop")
    func brandLegibleOnDark() {
        #expect(Contrast.ratio(.batonOrange, .black) >= 4.5)
    }

    @Test("ensureContrast lifts a too-dark accent until it clears the target")
    func ensureContrastLifts() {
        let darkNavy = Color(red: 0.02, green: 0.02, blue: 0.20)
        #expect(Contrast.ratio(darkNavy, .black) < 4.5) // precondition: starts illegible
        let fixed = Contrast.ensureContrast(of: darkNavy, against: .black, min: 4.5)
        #expect(Contrast.ratio(fixed, .black) >= 4.5)
    }

    // MARK: uiAccent (Brand ⇄ Dynamic + contrast)

    @Test("Grayscale artwork falls back to brand orange for the player accent")
    func grayscaleFallsBackToBrand() {
        let gray = ArtworkPalette(primary: .gray, secondary: .black, accent: Color(white: 0.5))
        #expect(gray.uiAccent == Color.batonOrange)
    }

    @Test("No-artwork neutral palette yields a brand-orange player accent")
    func neutralFallsBackToBrand() {
        #expect(ArtworkPalette.neutral.uiAccent == Color.batonOrange)
    }

    @Test("A vibrant dark accent is contrast-corrected, not left illegible")
    func vibrantAccentIsCorrected() {
        // A deep, saturated blue that would be unreadable as-is on the dark backdrop.
        let palette = ArtworkPalette(primary: .blue, secondary: .black, accent: Color(red: 0, green: 0, blue: 0.30))
        #expect(Contrast.ratio(palette.uiAccent, .black) >= 4.5)
    }

    // MARK: Extractor accent stability

    @Test("Accent from vivid art is saturated (not gray), from a whole bucket")
    func accentFromVividArt() {
        let accent = ArtworkColorExtractor.palette(from: solidImage(.systemRed)).accent
        #expect(Contrast.saturation(accent) > 0.3)
    }

    @Test("Accent from grayscale art is near-zero saturation → triggers brand fallback")
    func accentFromGrayArt() {
        let palette = ArtworkColorExtractor.palette(from: solidImage(NSColor(white: 0.5, alpha: 1)))
        #expect(Contrast.saturation(palette.accent) < 0.15)
        #expect(palette.uiAccent == Color.batonOrange)
    }

    // MARK: Backdrop-vs-foreground contract (deliberate two-color design)

    @Test("Raw accent stays as-extracted for the rich backdrop; uiAccent is the lifted one")
    func rawAccentPreservedUIAccentLifted() {
        // A saturated but too-dark accent — illegible on the dark backdrop as-is, yet it
        // is exactly what the AdaptiveBackdrop gradient wants (rich, not washed out).
        let darkTeal = Color(red: 0.0, green: 0.16, blue: 0.15)
        let palette = ArtworkPalette(primary: .teal, secondary: .black, accent: darkTeal)
        // Stored accent is untouched → the backdrop gets the rich color.
        #expect(palette.accent == darkTeal)
        #expect(Contrast.ratio(palette.accent, .black) < 4.5)
        // uiAccent (foreground) is contrast-lifted to clear AA on the dark backdrop.
        #expect(Contrast.ratio(palette.uiAccent, .black) >= 4.5)
        #expect(Contrast.relativeLuminance(palette.uiAccent) > Contrast.relativeLuminance(palette.accent))
    }
}
