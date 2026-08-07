#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import SwiftUI

/// The backdrop behind a mix card — art-directed where an asset exists, procedurally
/// generated where one doesn't.
///
/// Shared verbatim by the Mac and the phone, along with `Shared/MixArt.xcassets`. The two
/// apps draw their own cards, but the *art direction* is one thing: split it and the
/// palettes drift apart release by release until the phone looks like a different product.
///
/// The obvious alternative — a mosaic of the tracks' own cover art — was tried on the Mac
/// and dropped. A YouTube-sourced library's "cover art" is a 16:9 video thumbnail carrying
/// text, faces and channel watermarks; tiled into a 2×2 it reads as clutter rather than as
/// a cover. It also cost a library query per card just to draw a backdrop.
///
/// Deliberately takes the three values it needs rather than a mix type, because the two
/// apps have their own (`MusicMix`, `MobileMix`) and neither can see the other's.
struct MixBackdrop: View {
    /// Asset name in `MixArt.xcassets`, or `nil` for the generated mesh.
    let artwork: String?
    /// Stable identity for the mesh's PRNG — the mix's id, so a card looks the same on
    /// every launch and on both devices.
    let seed: String
    let tint: Color

    var body: some View {
        content
            // A backdrop is scenery, never a control. It matters more than it looks: the
            // size fix below puts a `Color.clear` in the stack, and SwiftUI's `Color` *is*
            // hit-testable — so without this the backdrop silently swallows taps and the
            // card stops opening. That was a call-site detail on the Mac; keeping it here
            // means neither app can forget it.
            .allowsHitTesting(false)
    }

    @ViewBuilder private var content: some View {
        if let artwork {
            ZStack {
                // `Color.clear` first so the *container* decides the size. A bare
                // `scaledToFill` image reports its own scaled size, which inflates the
                // enclosing ZStack — and anything aligned to a corner of that ZStack (the
                // mix's symbol) then lands outside the card's clip and vanishes. The mesh
                // path sizes to the proposal, so this only bit the art-directed cards.
                Color.clear
                    .overlay {
                        Image(artwork)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                // Keeps the title and symbol legible over a bright corner.
                LinearGradient(
                    colors: [.clear, .black.opacity(0.35)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        } else {
            ZStack {
                MixMeshBackdrop(seed: seed, tint: tint)
                // The art-directed cards all sit around 0.05–0.28 mean luminance. An
                // undarkened mesh at a bright tint (mint, cyan) rendered as a flat bright
                // slab beside them — visibly "the one without artwork". This pulls the
                // fallback into the same range so an unmapped card still belongs.
                Color.black.opacity(0.45)
                LinearGradient(
                    colors: [tint.opacity(0.25), .clear, .black.opacity(0.35)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        }
    }
}

/// A deterministic mesh gradient, seeded from the mix's identity.
///
/// Needs no network, no asset and no licensing question in a redistributed app — and being
/// deterministic, the same mix draws the same card every launch, so it becomes
/// recognisable rather than merely decorative.
struct MixMeshBackdrop: View {
    let seed: String
    let tint: Color

    private static let gridSide = 3

    var body: some View {
        MeshGradient(
            width: Self.gridSide,
            height: Self.gridSide,
            points: Self.points(seed: seed),
            colors: Self.colors(seed: seed, tint: tint)
        )
    }

    /// A small deterministic PRNG. `hashValue` is *not* usable here — Swift seeds string
    /// hashing per-process, so the same mix would look different on every launch.
    static func rng(_ seed: String, salt: Int) -> Double {
        var h: UInt64 = 1_469_598_103_934_665_603
        for byte in seed.utf8 {
            h = (h ^ UInt64(byte)) &* 1_099_511_628_211
        }
        h = (h ^ UInt64(truncatingIfNeeded: salt &* 0x9E37_79B9)) &* 1_099_511_628_211
        h ^= h >> 33
        return Double(h % 10_000) / 10_000.0
    }

    /// Interior control points are jittered; the edges stay pinned so the mesh always fills
    /// the card and never leaves a pale corner where the title sits.
    static func points(seed: String) -> [SIMD2<Float>] {
        var out: [SIMD2<Float>] = []
        for row in 0 ..< gridSide {
            for col in 0 ..< gridSide {
                let x = Float(col) / Float(gridSide - 1)
                let y = Float(row) / Float(gridSide - 1)
                let interior = col > 0 && col < gridSide - 1 && row > 0 && row < gridSide - 1
                guard interior else { out.append(SIMD2(x, y)); continue }
                let jx = Float(rng(seed, salt: row * 10 + col) - 0.5) * 0.45
                let jy = Float(rng(seed, salt: row * 10 + col + 100) - 0.5) * 0.45
                out.append(SIMD2(min(max(x + jx, 0.15), 0.85), min(max(y + jy, 0.15), 0.85)))
            }
        }
        return out
    }

    static func colors(seed: String, tint: Color) -> [Color] {
        (0 ..< gridSide * gridSide).map { index in
            let light = rng(seed, salt: index + 200)
            let shift = (rng(seed, salt: index + 300) - 0.5) * 0.16   // stay in the hue family
            return tint
                .opacity(1)
                .hueRotated(by: shift)
                .brightnessAdjusted(by: light * 0.45 - 0.12)
        }
    }
}

/// HSB tweaks used by the mesh. Written against each platform's own colour type because
/// SwiftUI has no cross-platform way to decompose a `Color` into hue and brightness.
extension Color {
    #if canImport(UIKit)
    private func hsba() -> (h: CGFloat, s: CGFloat, b: CGFloat, a: CGFloat)? {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return nil }
        return (h, s, b, a)
    }

    private static func make(h: CGFloat, s: CGFloat, b: CGFloat, a: CGFloat) -> Color {
        Color(UIColor(hue: h, saturation: s, brightness: b, alpha: a))
    }
    #else
    private func hsba() -> (h: CGFloat, s: CGFloat, b: CGFloat, a: CGFloat)? {
        guard let c = NSColor(self).usingColorSpace(.deviceRGB) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s, b, a)
    }

    private static func make(h: CGFloat, s: CGFloat, b: CGFloat, a: CGFloat) -> Color {
        Color(NSColor(hue: h, saturation: s, brightness: b, alpha: a))
    }
    #endif

    func hueRotated(by amount: Double) -> Color {
        guard let c = hsba() else { return self }
        return Self.make(h: (c.h + CGFloat(amount)).truncatingRemainder(dividingBy: 1).magnitude,
                         s: c.s, b: c.b, a: c.a)
    }

    func brightnessAdjusted(by amount: Double) -> Color {
        guard let c = hsba() else { return self }
        return Self.make(h: c.h, s: c.s,
                         b: min(max(c.b + CGFloat(amount), 0.15), 1.0), a: c.a)
    }
}
