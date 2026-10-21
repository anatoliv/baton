#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A collection's cover as the manifest carries it (specs/collection-sharing.md, decision 3): a
/// JPEG of at most `ShareBookManifest.maxCoverBytes`. An album sends its own cover; a playlist or
/// a selection a 2×2 mosaic of its first four different album covers. Every cover is decoded and
/// encoded again, so what goes is always a plain JPEG within the cap with no metadata (no camera
/// or location tags from an embedded image), whatever the server handed over.
public enum ShareCollectionCover {
    /// Pixel sides tried, largest first, and the JPEG qualities at each.
    static let sides = [600, 512, 420, 340, 256, 200, 160]
    static let qualities: [Double] = [0.82, 0.7, 0.58, 0.46]

    /// One cover, scaled to fit and encoded as a JPEG within `maxBytes`, or nil when the bytes are
    /// not an image or nothing fits.
    public static func jpeg(_ data: Data, maxBytes: Int = ShareBookManifest.maxCoverBytes) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = thumbnail(source, side: sides[0]) else { return nil }
        return fit(image, maxBytes: maxBytes)
    }

    /// A 2×2 mosaic of up to four covers (two make a checkerboard, three repeat the first in the
    /// last corner, one is just that cover), as a JPEG within `maxBytes`. Nil when none decodes.
    public static func mosaic(_ covers: [Data], maxBytes: Int = ShareBookManifest.maxCoverBytes) -> Data? {
        let images = covers.prefix(4).compactMap { data -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return thumbnail(source, side: sides[0] / 2)
        }
        guard let first = images.first else { return nil }
        if images.count == 1 { return fit(first, maxBytes: maxBytes) }
        let cells: [CGImage] = switch images.count {
        case 2: [images[0], images[1], images[1], images[0]]
        case 3: [images[0], images[1], images[2], images[0]]
        default: Array(images.prefix(4))
        }
        let side = sides[0], half = side / 2
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        // Reading order: top left, top right, bottom left, bottom right (CoreGraphics' origin is bottom left).
        let origins = [CGPoint(x: 0, y: half), CGPoint(x: half, y: half), CGPoint(x: 0, y: 0), CGPoint(x: half, y: 0)]
        for (image, origin) in zip(cells, origins) {
            context.draw(image, in: aspectFill(image, in: CGRect(origin: origin, size: CGSize(width: half, height: half))))
        }
        guard let drawn = context.makeImage() else { return nil }
        return fit(drawn, maxBytes: maxBytes)
    }

    /// The image's own type, for checks: "image/jpeg", "image/png" or nil.
    public static func type(of data: Data) -> String? { ShareBookManifest.Cover.type(of: data) }

    // MARK: Pieces

    private static func thumbnail(_ source: CGImageSource, side: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ] as CFDictionary)
    }

    private static func aspectFill(_ image: CGImage, in cell: CGRect) -> CGRect {
        let scale = max(cell.width / CGFloat(image.width), cell.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The largest side and best quality whose JPEG fits.
    private static func fit(_ image: CGImage, maxBytes: Int) -> Data? {
        for side in sides {
            let scaled = side >= max(image.width, image.height) ? image : (resize(image, side: side) ?? image)
            for quality in qualities {
                if let data = encode(scaled, quality: quality), data.count <= maxBytes { return data }
            }
        }
        return nil
    }

    private static func resize(_ image: CGImage, side: Int) -> CGImage? {
        let scale = CGFloat(side) / CGFloat(max(image.width, image.height))
        let width = max(1, Int(CGFloat(image.width) * scale)), height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif
