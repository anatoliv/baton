import Testing
import UIKit
@testable import BatonMobile

/// The color-from-artwork wash, from a real bundled cover.
///
/// The visible half (does the backdrop actually paint the screen) was
/// verified on the simulator. This pins the half a screenshot can't prove
/// reliably: that a real cover yields a real, tinted palette rather than the
/// neutral fallback, which is what the whole feature hinges on.
@Suite("Artwork wash")
struct ArtworkWashTests {
    /// A cover that ships inside the app, so this exercises the same file
    /// URL the demo library hands the palette loader.
    private func demoCoverURL() throws -> URL {
        try #require(
            Bundle.main.url(forResource: "demo-2-cover", withExtension: "png"),
            "the demo covers must be bundled — the demo library and this test both need them"
        )
    }

    @Test("A bundled file:// cover yields a real palette, not the neutral fallback")
    func fileURLCoverExtracts() async throws {
        // Demo-library artwork is a `file://` URL from the app bundle rather
        // than a server cover, so this is the path the demo experience — and
        // App Review — actually takes.
        let palette = await ArtworkColorExtractor.palette(from: try demoCoverURL())
        let resolved = try #require(palette, "a bundled cover must extract")
        #expect(resolved != .neutral, "a real cover must not fall back to the neutral palette")
    }

    @Test("The extracted palette carries the cover's colour, not grey")
    func paletteIsTinted() async throws {
        let resolved = try #require(await ArtworkColorExtractor.palette(from: try demoCoverURL()))
        // demo-2 is a blue-grey cover; its wash must read as blue, or the
        // backdrop is indistinguishable from the neutral fallback on screen.
        let rgb = UIColor(resolved.secondary).cgColor.components ?? []
        try #require(rgb.count >= 3)
        #expect(rgb[2] > rgb[0], "blue channel should lead for a blue cover")
    }

    @Test("A missing file fails closed rather than throwing")
    func missingFileIsNil() async {
        let missing = URL(fileURLWithPath: "/definitely/not/here.png")
        #expect(await ArtworkColorExtractor.palette(from: missing) == nil)
    }
}
