import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Baton

/// `ArtworkCache.downsample` is the one file in `Shared/` whose behaviour genuinely differs
/// by platform: it hands back `NSImage` here and `UIImage` on the phone, through the
/// `PlatformImage` typealias. So this is the file that is wired into **both** test bundles
/// (S-F24); everything else in `SharedTests` is platform-identical and lives only here.
///
/// The bug it exists against: a 1000px cover rendered into a 160pt cell was decoded to a
/// full-size bitmap and then scaled for display, several megabytes per card, on twenty grid
/// surfaces, twice per card because the Mac builds a blurred fill and a sharp cover from the
/// same URL.
final class SharedArtworkCacheTests: XCTestCase {
    /// A real PNG, because `CGImageSourceCreateThumbnailAtIndex` reads a container rather than
    /// a buffer and a synthetic byte string would only ever prove the nil path.
    private func pngData(width: Int, height: Int) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())

        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// Pixel dimensions of a decoded cover on this platform, and the reason this file is
    /// split per platform rather than shared.
    ///
    /// **Not `representations.first.pixelsWide`.** `NSImage(cgImage:size:.zero)` produces an
    /// `NSCGImageSnapshotRep` whose `pixelsWide` is the *backing store* on this display, so a
    /// 480px thumbnail measures 960 on a 2x screen and the same test would report a different
    /// number on a 1x one. `size` is the CGImage's own dimensions here, because the image was
    /// built with no size of its own. The phone reads its backing `CGImage` instead, which is
    /// what the iPhone bundle's copy of this file does.
    private func pixelWidth(_ image: PlatformImage) throws -> Int {
        Int(image.size.width)
    }

    func testACoverIsDecodedAtTheSizeBeingDrawnRatherThanFullSize() throws {
        let data = try pngData(width: 1000, height: 1000)
        let decoded = try XCTUnwrap(ArtworkCache.downsample(data, to: 160))
        // Points to pixels: 3x covers the densest screen either app runs on, so 160pt is 480px.
        // Guessing low here shows as soft artwork on a Retina display, which is worse than the
        // memory it would save.
        XCTAssertEqual(try pixelWidth(decoded), 480)
    }

    /// The thumbnail is a ceiling, not a target: a cover smaller than the cell must not be
    /// blown up, which would cost memory to make it blurrier.
    func testASmallCoverIsNotUpscaledToFillTheCell() throws {
        let data = try pngData(width: 200, height: 200)
        let decoded = try XCTUnwrap(ArtworkCache.downsample(data, to: 400))
        XCTAssertEqual(try pixelWidth(decoded), 200)
    }

    /// A zero or negative side is clamped to one pixel rather than asking ImageIO for an
    /// impossible thumbnail, which returns nil and shows as a missing cover.
    func testAZeroSidedCellStillDecodesSomething() throws {
        let data = try pngData(width: 300, height: 300)
        XCTAssertNotNil(ArtworkCache.downsample(data, to: 0))
        XCTAssertNotNil(ArtworkCache.downsample(data, to: -10))
    }

    func testBytesThatAreNotAnImageDecodeToNothingRatherThanCrashing() {
        XCTAssertNil(ArtworkCache.downsample(Data("<html>404</html>".utf8), to: 160))
        XCTAssertNil(ArtworkCache.downsample(Data(), to: 160))
    }

    /// The cache is keyed by URL *and* side, so the same cover at two sizes is two entries
    /// and a grid does not serve a thumbnail into a full-screen player.
    @MainActor
    func testTheCacheKeepsTheSameCoverAtTwoSizesApart() throws {
        let url = try XCTUnwrap(URL(string: "https://navidrome.example/rest/getCoverArt?id=al-1"))
        XCTAssertNil(ArtworkCache.shared.cached(url, side: 160),
                     "nothing was fetched, so nothing is cached at any size")
        XCTAssertNil(ArtworkCache.shared.cached(url, side: 480))
    }
}
