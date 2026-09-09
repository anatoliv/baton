import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import BatonMobile

/// The iPhone half of `SharedTests` (S-F24).
///
/// `Shared/` is compiled into both apps and is not a package, so its tests live in the two
/// app bundles. The Mac bundle carries the whole `SharedTests` group; only the files whose
/// behaviour actually differs by platform are wired in here as well, and `ArtworkCache` is
/// the one that does: `downsample` returns `UIImage` on the phone and `NSImage` on the Mac
/// through the `PlatformImage` typealias, and the pixel dimensions come off a different
/// object on each. Duplicating the platform-identical files would only prove the same thing
/// twice at the cost of a second place to forget to edit.
final class SharedArtworkCacheTests: XCTestCase {
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

    /// On iOS the backing `CGImage` is the honest source of pixel dimensions. `UIImage.size`
    /// is in points and would divide by the scale, which is what makes this file platform
    /// specific rather than shared with the Mac bundle.
    private func pixelWidth(_ image: PlatformImage) throws -> Int {
        try XCTUnwrap(image.cgImage).width
    }

    func testACoverIsDecodedAtTheSizeBeingDrawnRatherThanFullSize() throws {
        let data = try pngData(width: 1000, height: 1000)
        let decoded = try XCTUnwrap(ArtworkCache.downsample(data, to: 160))
        // Points to pixels: 3x covers the densest screen either app runs on, so 160pt is 480px.
        XCTAssertEqual(try pixelWidth(decoded), 480)
    }

    func testASmallCoverIsNotUpscaledToFillTheCell() throws {
        let data = try pngData(width: 200, height: 200)
        let decoded = try XCTUnwrap(ArtworkCache.downsample(data, to: 400))
        XCTAssertEqual(try pixelWidth(decoded), 200)
    }

    func testAZeroSidedCellStillDecodesSomething() throws {
        let data = try pngData(width: 300, height: 300)
        XCTAssertNotNil(ArtworkCache.downsample(data, to: 0))
        XCTAssertNotNil(ArtworkCache.downsample(data, to: -10))
    }

    func testBytesThatAreNotAnImageDecodeToNothingRatherThanCrashing() {
        XCTAssertNil(ArtworkCache.downsample(Data("<html>404</html>".utf8), to: 160))
        XCTAssertNil(ArtworkCache.downsample(Data(), to: 160))
    }
}
