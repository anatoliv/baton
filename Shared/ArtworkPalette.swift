#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Observation
import SwiftUI

/// A small palette of colors extracted from cover art, used to paint the adaptive
/// "color-from-artwork" backdrops (Plexamp UltraBlur / Apple Music style).
struct ArtworkPalette: Equatable {
    var primary: Color
    var secondary: Color
    var accent: Color

    /// Neutral fallback when there's no art / extraction fails. The accent is a pure
    /// gray (zero saturation) so `uiAccent` resolves it to brand orange — a "no
    /// artwork" track gets a Baton-orange player accent rather than a dead gray one.
    static let neutral = ArtworkPalette(
        primary: Color(red: 0.10, green: 0.10, blue: 0.13),
        secondary: Color(red: 0.06, green: 0.06, blue: 0.09),
        accent: Color(red: 0.22, green: 0.22, blue: 0.22)
    )

    /// The accent as applied to **foreground** player controls (progress fill, volume
    /// fill, favorite/active state), against the `.dark` backdrop tone. Enforces the
    /// design doc's Brand ⇄ Dynamic + contrast rules: (near-)grayscale artwork falls
    /// back to brand orange; otherwise the vibrant accent is lightened until it clears
    /// AA (4.5:1) against flat black.
    ///
    /// Kept as the property every existing caller already uses, defaulting to `.dark`:
    /// the player surfaces (`FullScreenNowPlaying`, `MiniPlayerWindowView`, the iOS
    /// player) force a dark backdrop regardless of the app's appearance setting, and
    /// flat black is at least as dark as that real backdrop
    /// (`backdropWorstCase(for: .dark)`), so it stays the conservative reference this
    /// value has always been checked against.
    var uiAccent: Color { uiAccent(for: .dark) }

    /// `uiAccent`, told which backdrop tone it is actually drawn against.
    ///
    /// This used to be one fixed reference — flat black — on the reasoning that
    /// `AdaptiveBackdrop` is always dark. That stopped being true the moment Light mode
    /// got its own wash (WS7, PR #60): `NowPlayingBar` in the main window follows the
    /// ambient appearance rather than forcing `.dark`, so in Light mode its accent was
    /// still being lightened to survive *black* while the ground behind it had been
    /// pulled toward white (`backdropLayers(for: .light)`) — an accent legible on
    /// black can be nearly invisible on that light wash. For `.light` this clamps
    /// against `backdropWorstCase(for: .light)` instead: this palette's own flattened,
    /// worst-case rendering of the light wash, rather than a guess that assumed dark.
    func uiAccent(for tone: BackdropTone) -> Color {
        if Contrast.saturation(accent) < 0.15 { return .batonOrange }
        let reference: Color = tone == .dark ? .black : backdropWorstCase(for: .light)
        return Contrast.ensureContrast(of: accent, against: reference, min: 4.5)
    }
}

/// Extracts a dominant/vibrant/dark palette from cover art by downsampling to a
/// small grid and bucketing colors. Pure + synchronous core (unit-tested); the
/// async URL loader feeds the live UI.
enum ArtworkColorExtractor {
    /// Canonical cover-art size (px) used for palette extraction on every now-playing
    /// surface (main window, full-screen, mini player). Decoupled from each surface's
    /// display-image size so all windows derive the *same* accent for a given track.
    static let coverSize = 400

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

        /// Vibrancy of this bucket's *average* color = saturation × brightness. Used to
        /// pick the accent from a whole bucket rather than a single stray pixel, so one
        /// noise pixel can't swing the accent.
        var vibrancy: Double {
            guard samples > 0 else { return 0 }
            let r = Double(red) / Double(samples), g = Double(green) / Double(samples), b = Double(blue) / Double(samples)
            let hi = max(r, g, b), lo = min(r, g, b)
            let saturation = hi == 0 ? 0 : (hi - lo) / hi
            return saturation * (hi / 255)
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
    #if canImport(AppKit)
    static func palette(from image: NSImage) -> ArtworkPalette {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .neutral
        }
        return palette(from: cgImage)
    }
    #else
    static func palette(from image: UIImage) -> ArtworkPalette {
        guard let cgImage = image.cgImage else { return .neutral }
        return palette(from: cgImage)
    }
    #endif

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
        // whole-image average.
        let dominant = buckets.max { $0.value.samples < $1.value.samples }?.value
        let primary = (dominant ?? total).color()
        let secondary = total.color(scale: 0.45)

        // Accent = the most vibrant *bucket* with enough support to not be single-pixel
        // noise (≥ 0.5% of pixels). Falls back to the single most-vibrant pixel when no
        // bucket qualifies (e.g. a tiny or near-flat image). Contrast/grayscale handling
        // for foreground use happens in `ArtworkPalette.uiAccent`.
        let minSupport = max(2, total.samples / 200)
        let accent = buckets.values
            .filter { $0.samples >= minSupport }
            .max { $0.vibrancy < $1.vibrancy }
            .map { $0.color() } ?? vibrant.color

        return ArtworkPalette(primary: primary, secondary: secondary, accent: accent)
    }

    /// Loads a cover-art URL and extracts its palette (off the main thread).
    ///
    /// File URLs are read directly rather than through `URLSession`, which
    /// does not serve `file://` from a data task — it fails, the palette
    /// falls back to neutral, and the adaptive backdrop silently stays grey.
    /// That is not a hypothetical: it is every track in the bundled demo
    /// library (artwork is `Bundle.main.url(forResource:)`) and any locally
    /// cached cover, so the headline color-from-artwork feature was dead for
    /// the whole demo experience — including the one a reviewer sees.
    static func palette(from url: URL) async -> ArtworkPalette? {
        let data: Data
        if url.isFileURL {
            guard let fileData = try? Data(contentsOf: url) else { return nil }
            data = fileData
        } else {
            guard let (loaded, response) = try? await URLSession.shared.data(from: url) else { return nil }
            // A refused or missing cover answers with an error body, not an image. Decoding
            // catches most of those, but checking the status first is what tells a 401 apart
            // from a dropped connection instead of filing both under "no palette".
            if let http = response as? HTTPURLResponse,
               ArtworkCache.classify(status: http.statusCode) != .loaded { return nil }
            data = loaded
        }
        #if canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        #else
        guard let image = UIImage(data: data) else { return nil }
        #endif
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
    /// Bounded. This was a plain dictionary that only ever grew: play through a 2,600-album
    /// library in one session and it holds 2,600 palettes, none of which will be asked for
    /// again. Small because the useful window is "tracks you have played recently" — the
    /// wash is re-derived in milliseconds for anything older.
    @ObservationIgnored private var cache: [URL: ArtworkPalette] = [:]
    @ObservationIgnored private var cacheOrder: [URL] = []
    private static let cacheLimit = 64
    @ObservationIgnored private var currentURL: URL?
    /// Readable so a test can await the extraction instead of sleeping and hoping.
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    /// Point the loader at a new cover-art URL. No-ops if unchanged. Falls back to
    /// neutral when `url` is nil.
    func update(url: URL?) {
        guard url != currentURL else { return }
        currentURL = url
        task?.cancel()
        guard let url else { palette = .neutral; return }
        if let cached = cache[url] { palette = cached; return }
        task = Task { [weak self] in
            let extracted = await ArtworkColorExtractor.palette(from: url)
            guard let self, !Task.isCancelled, currentURL == url else { return }
            // Only a real extraction is remembered. This used to cache the neutral fallback
            // after any failure, so one Wi-Fi blip while a track started left that track's
            // backdrop grey for the rest of the session, or until 64 other tracks evicted
            // it. A failure now costs one refetch on the next visit instead.
            if let extracted { remember(url, extracted) }
            withAnimation(.easeInOut(duration: 0.6)) { self.palette = extracted ?? .neutral }
        }
    }

    /// Least-recently-inserted eviction. Insertion order rather than access order on
    /// purpose: a palette is looked up once when its track starts and then not again, so
    /// "recently used" and "recently added" are the same thing here, and the simpler one
    /// cannot get the bookkeeping wrong.
    private func remember(_ url: URL, _ palette: ArtworkPalette) {
        if cache[url] == nil { cacheOrder.append(url) }
        cache[url] = palette
        while cacheOrder.count > Self.cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}

// MARK: - Backdrop tone

extension ArtworkPalette {
    /// Which ground the wash is painted for.
    ///
    /// The wash used to have only one answer, and it was always the dark one: deep
    /// `secondary` under three glows and a black scrim. That is right in the player,
    /// where the transport is white on purpose. It is wrong everywhere else the moment
    /// somebody picks Settings → Appearance → Light, because the text above it flips to
    /// near-black while the ground stays near-black with it.
    enum BackdropTone: Equatable, Sendable {
        case dark, light

        /// What a caller with no forced tone actually gets: the ambient appearance,
        /// light or dark. `AdaptiveBackdrop.resolvedTone` and any other caller whose
        /// backdrop follows `\.colorScheme` (rather than forcing `.dark`, the way the
        /// player surfaces do) should use this rather than re-deriving the same
        /// two-way match — `MusicView`'s `NowPlayingBar` accent is the other caller.
        static func resolved(for colorScheme: ColorScheme) -> BackdropTone {
            colorScheme == .light ? .light : .dark
        }
    }

    /// The four flat colours `AdaptiveBackdrop` stacks, resolved for a tone. Pure, so the
    /// legibility of the result can be asserted without rendering anything.
    struct BackdropLayers: Equatable {
        /// The ground the glows sit on.
        var base: Color
        /// Top-leading glow, opacity already applied.
        var primaryGlow: Color
        /// Top-trailing glow.
        var accentGlow: Color
        /// Bottom glow.
        var bottomGlow: Color
        /// The wash's last layer, which sets how far the whole thing is pulled toward
        /// one end of the range.
        var scrim: Color
    }

    /// How far the light tone drags each extracted colour toward white. High on purpose:
    /// the point of the light wash is that near-black body text sits on it, so the tint
    /// has to survive a saturated, dark cover without ever getting close to that text.
    private static let lightBaseLift = 0.86
    private static let lightGlowLift = 0.80

    func backdropLayers(for tone: BackdropTone) -> BackdropLayers {
        switch tone {
        case .dark:
            return BackdropLayers(
                base: secondary,
                primaryGlow: primary.opacity(0.9),
                accentGlow: accent.opacity(0.8),
                bottomGlow: primary.opacity(0.6),
                scrim: Color.black.opacity(0.28)
            )
        case .light:
            return BackdropLayers(
                base: Contrast.blend(secondary, toward: .white, amount: Self.lightBaseLift),
                primaryGlow: Contrast.blend(primary, toward: .white, amount: Self.lightGlowLift)
                    .opacity(0.55),
                accentGlow: Contrast.blend(accent, toward: .white, amount: Self.lightGlowLift)
                    .opacity(0.45),
                bottomGlow: Contrast.blend(primary, toward: .white, amount: Self.lightGlowLift)
                    .opacity(0.40),
                scrim: Color.white.opacity(0.45)
            )
        }
    }

    /// The flattest, least forgiving colour a caller's text can end up on: every glow
    /// stacked at full strength over the base, then the scrim. Nothing on screen is ever
    /// darker than this in the light tone or lighter than it in the dark tone, so a
    /// contrast floor measured here holds for the whole wash.
    func backdropWorstCase(for tone: BackdropTone) -> Color {
        let layers = backdropLayers(for: tone)
        var flat = layers.base
        for glow in [layers.primaryGlow, layers.accentGlow, layers.bottomGlow, layers.scrim] {
            flat = Contrast.composite(glow, over: flat)
        }
        return flat
    }
}

/// The adaptive gradient backdrop rendered from an `ArtworkPalette` — the headline
/// "color-from-artwork" surface. Layer content over it with `.ultraThinMaterial`
/// for the smoked-glass look.
///
/// Follows the colour scheme it is placed in unless a `tone` is passed. Player surfaces
/// pass `.dark` and mean it: they draw white transport on this ground whatever the app's
/// appearance setting says, and `.preferredColorScheme(.dark)` on an ancestor is a
/// presentation-level request rather than a promise about this view's environment.
struct AdaptiveBackdrop: View {
    let palette: ArtworkPalette
    /// Nil follows `\.colorScheme`; a value overrides it.
    var tone: ArtworkPalette.BackdropTone?

    @Environment(\.colorScheme) private var colorScheme

    private var resolvedTone: ArtworkPalette.BackdropTone {
        tone ?? .resolved(for: colorScheme)
    }

    var body: some View {
        let layers = palette.backdropLayers(for: resolvedTone)
        ZStack {
            layers.base
            RadialGradient(
                colors: [layers.primaryGlow, .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 520
            )
            RadialGradient(
                colors: [layers.accentGlow, .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 460
            )
            RadialGradient(
                colors: [layers.bottomGlow, .clear],
                center: .bottom,
                startRadius: 0,
                endRadius: 520
            )
            layers.scrim
        }
        .ignoresSafeArea()
    }
}
