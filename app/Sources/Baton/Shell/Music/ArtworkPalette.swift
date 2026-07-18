import AppKit
import Observation
import SwiftUI

/// A small palette of colors extracted from cover art, used to paint the adaptive
/// "color-from-artwork" backdrops (Plexamp UltraBlur / Apple Music style).
struct ArtworkPalette: Equatable {
    var primary: Color
    var secondary: Color
    var accent: Color

    /// Neutral dark fallback when there's no art / extraction fails.
    static let neutral = ArtworkPalette(
        primary: Color(red: 0.10, green: 0.10, blue: 0.13),
        secondary: Color(red: 0.06, green: 0.06, blue: 0.09),
        accent: Color(red: 0.20, green: 0.20, blue: 0.26)
    )
}

/// Extracts a dominant/vibrant/dark palette from cover art by downsampling to a
/// small grid and bucketing colors. Pure + synchronous core (unit-tested); the
/// async URL loader feeds the live UI.
enum ArtworkColorExtractor {
    /// Running RGB accumulator for a color bucket (or the whole image).
    private struct RGBAccumulator {
        var red = 0, green = 0, blue = 0, samples = 0
        mutating func add(red: Int, green: Int, blue: Int) {
            self.red += red; self.green += green; self.blue += blue; samples += 1
        }

        func color(scale: Double = 1) -> Color {
            guard samples > 0 else { return .black }
            return Color(
                red: Double(red) / Double(samples) / 255 * scale,
                green: Double(green) / Double(samples) / 255 * scale,
                blue: Double(blue) / Double(samples) / 255 * scale
            )
        }
    }

    /// The most vibrant pixel seen so far (saturation × brightness).
    private struct VibrantPick {
        var score = 0.0
        var red = 40, green = 40, blue = 60
        var color: Color {
            Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
        }
    }

    /// Extract a palette from an already-loaded image. Deterministic, no I/O.
    static func palette(from image: NSImage) -> ArtworkPalette {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .neutral
        }
        return palette(from: cgImage)
    }

    static func palette(from cgImage: CGImage) -> ArtworkPalette {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .neutral }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        // Histogram in a coarse 12-bit color space; track counts + vibrancy.
        var buckets: [Int: RGBAccumulator] = [:]
        var vibrant = VibrantPick()
        var total = RGBAccumulator()

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
            let key = (red >> 4) << 8 | (green >> 4) << 4 | (blue >> 4)
            buckets[key, default: RGBAccumulator()].add(red: red, green: green, blue: blue)
            total.add(red: red, green: green, blue: blue)
            // Vibrancy = saturation × brightness (favor rich, not gray/black/white).
            let brightest = Double(max(red, green, blue)), darkest = Double(min(red, green, blue))
            let saturation = brightest == 0 ? 0 : (brightest - darkest) / brightest
            let score = saturation * (brightest / 255)
            if score > vibrant.score { vibrant = VibrantPick(score: score, red: red, green: green, blue: blue) }
        }
        guard total.samples > 0 else { return .neutral }

        // Primary = most-populated bucket's averaged color; secondary = darkened
        // whole-image average; accent = the most vibrant pixel.
        let dominant = buckets.max { $0.value.samples < $1.value.samples }?.value
        let primary = (dominant ?? total).color()
        let secondary = total.color(scale: 0.45)
        return ArtworkPalette(primary: primary, secondary: secondary, accent: vibrant.color)
    }

    /// Loads a cover-art URL and extracts its palette (off the main thread).
    static func palette(from url: URL) async -> ArtworkPalette? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data)
        else { return nil }
        return palette(from: image)
    }
}

/// Observable loader that keeps a current `ArtworkPalette` in sync with a cover-art
/// URL, caching by URL so switching back to a track is instant. Drives the adaptive
/// backdrops in the now-playing views.
@MainActor
@Observable
final class ArtworkPaletteLoader {
    private(set) var palette: ArtworkPalette = .neutral
    @ObservationIgnored private var cache: [URL: ArtworkPalette] = [:]
    @ObservationIgnored private var currentURL: URL?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Point the loader at a new cover-art URL. No-ops if unchanged. Falls back to
    /// neutral when `url` is nil.
    func update(url: URL?) {
        guard url != currentURL else { return }
        currentURL = url
        task?.cancel()
        guard let url else { palette = .neutral; return }
        if let cached = cache[url] { palette = cached; return }
        task = Task { [weak self] in
            let result = await ArtworkColorExtractor.palette(from: url) ?? .neutral
            guard let self, !Task.isCancelled, currentURL == url else { return }
            cache[url] = result
            withAnimation(.easeInOut(duration: 0.6)) { self.palette = result }
        }
    }
}

/// The adaptive gradient backdrop rendered from an `ArtworkPalette` — the headline
/// "color-from-artwork" surface. Layer content over it with `.ultraThinMaterial`
/// for the smoked-glass look.
struct AdaptiveBackdrop: View {
    let palette: ArtworkPalette

    var body: some View {
        ZStack {
            palette.secondary
            RadialGradient(
                colors: [palette.primary.opacity(0.9), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 520
            )
            RadialGradient(
                colors: [palette.accent.opacity(0.8), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 460
            )
            RadialGradient(
                colors: [palette.primary.opacity(0.6), .clear],
                center: .bottom,
                startRadius: 0,
                endRadius: 520
            )
            Color.black.opacity(0.28)
        }
        .ignoresSafeArea()
    }
}
