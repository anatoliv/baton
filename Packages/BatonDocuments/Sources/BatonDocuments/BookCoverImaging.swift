#if canImport(ImageIO) && canImport(CoreGraphics) && canImport(CoreText)
import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// The two things a device does to a cover picture before keeping it: make any
/// picture safe and small, and draw a designed cover. Apple platforms only; the gateway never
/// decodes an image, it only checks the signature of what a device already re-encoded.
public enum BookCoverImaging {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case tooLarge
        case notAnImage
        case tooSmall
        case couldNotEncode

        public var description: String {
            switch self {
            case .tooLarge: return "That picture is too large to use as a cover."
            case .notAnImage: return "That file isn't a picture Baton can read."
            case .tooSmall: return "That picture is too small to use as a cover."
            case .couldNotEncode: return "Baton couldn't save that picture as a cover."
            }
        }
    }

    /// Picture formats a cover may come in. Anything else is refused before it is decoded.
    static let acceptedTypes: Set<String> = [
        "public.jpeg", "public.png", "public.heic", "public.heif", "org.webmproject.webp",
        "com.compuserve.gif", "public.tiff", "com.microsoft.bmp",
    ]
    /// A picture claiming more pixels than this is refused unread (a decompression bomb).
    static let maximumSourcePixels = 80_000_000
    static let minimumSide = 40

    /// Any picture in, a cover out: decoded as an image and nothing else, scaled to at most
    /// `BookCoverImage.maximumSide`, drawn onto a fresh opaque sRGB canvas (which drops its
    /// metadata, colour profile quirks and any transparency) and written as a JPEG of at most
    /// `BookCoverImage.maximumBytes`. Used for every picture from outside: an EPUB's own cover,
    /// an Open Library download, a chosen file, and one arriving from the home server.
    public static func sanitize(_ data: Data, maximumSide: Int = BookCoverImage.maximumSide) throws -> Data {
        guard !data.isEmpty, data.count <= BookCoverImage.maximumSourceBytes else { throw Failure.tooLarge }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let type = CGImageSourceGetType(source) as String?, acceptedTypes.contains(type),
              CGImageSourceGetCount(source) >= 1 else { throw Failure.notAnImage }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { throw Failure.notAnImage }
        guard width <= 30_000, height <= 30_000, width * height <= maximumSourcePixels else { throw Failure.tooLarge }
        guard min(width, height) >= minimumSide else { throw Failure.tooSmall }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumSide,
        ] as CFDictionary
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { throw Failure.notAnImage }
        let (w, h) = (decoded.width, decoded.height)
        guard w > 0, h > 0, let context = canvas(width: w, height: h) else { throw Failure.couldNotEncode }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.interpolationQuality = .high
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flat = context.makeImage() else { throw Failure.couldNotEncode }
        for quality in [0.86, 0.75, 0.6, 0.45] {
            if let jpeg = encode(flat, type: "public.jpeg", quality: quality), jpeg.count <= BookCoverImage.maximumBytes {
                return jpeg
            }
        }
        throw Failure.tooLarge
    }

    /// The pixel size of a kept cover, for tests and the finder's layout.
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        return (width, height)
    }

    // MARK: - A designed cover

    /// The size a designed cover is drawn at: 2:3, a paperback's shape, large enough for Now
    /// Playing on a phone and the lock screen.
    public static let designSize = (width: 600, height: 900)

    /// Draws `design` as a PNG. The same design gives the same bytes: nothing random, no date,
    /// fonts named rather than "whatever the system prefers today".
    public static func render(_ design: BookCoverDesign) throws -> Data {
        let (width, height) = designSize
        guard let context = canvas(width: width, height: height) else { throw Failure.couldNotEncode }
        let W = CGFloat(width), H = CGFloat(height)
        let palette = design.palette
        context.setFillColor(color(palette.background))
        context.fill(CGRect(x: 0, y: 0, width: W, height: H))
        drawMotif(design, in: context, width: W, height: H)

        // The title: a bookish serif, as large as the longest word allows, under the ornament's
        // top zone (the top fifth) and clear of the author's line at the foot.
        let margin: CGFloat = 54
        let titleBox = CGRect(x: margin, y: H - 640, width: W - margin * 2, height: 440)
        let titleSize = fittingSize(design.title, font: "Baskerville-SemiBold", in: titleBox, from: 104, to: 34)
        let titleFrame = frame(design.title, font: "Baskerville-SemiBold", size: titleSize, color: palette.ink,
                               kern: -0.5, lineHeight: 1.02, in: titleBox)
        CTFrameDraw(titleFrame, context)

        // A short rule in the accent, under where the title ends, then the author.
        let used = usedHeight(titleFrame)
        let ruleY = max(190, titleBox.maxY - used - 30)
        context.setFillColor(color(palette.accent))
        context.fill(CGRect(x: margin, y: ruleY, width: 64, height: 6))

        let author = design.author.uppercased()
        let authorBox = CGRect(x: margin, y: 58, width: W - margin * 2, height: 92)
        let authorSize = fittingSize(author, font: "AvenirNext-DemiBold", in: authorBox, from: 30, to: 16, kern: 3)
        let authorFrame = frame(author, font: "AvenirNext-DemiBold", size: authorSize, color: palette.ink,
                                kern: 3, lineHeight: 1.15, in: authorBox, bottomAligned: true)
        CTFrameDraw(authorFrame, context)

        guard let image = context.makeImage(), let png = encode(image, type: "public.png", quality: nil) else {
            throw Failure.couldNotEncode
        }
        return png
    }

    private static func drawMotif(_ design: BookCoverDesign, in context: CGContext, width W: CGFloat, height H: CGFloat) {
        let accent = color(design.palette.accent)
        let faint = color(design.palette.ink, alpha: 0.10)
        let wiggle = CGFloat(design.seed >> 32 & 0xFF) / 255 // 0...1, the ornament's own variation
        switch design.motif {
        case .band:
            context.setFillColor(accent)
            context.fill(CGRect(x: 0, y: H * (0.22 + 0.04 * wiggle), width: W, height: 26))
            context.setFillColor(faint)
            context.fill(CGRect(x: 0, y: H * (0.22 + 0.04 * wiggle) + 38, width: W, height: 8))
        case .rings:
            let center = CGPoint(x: W * (0.78 + 0.1 * wiggle), y: H * 0.86)
            context.setLineWidth(10)
            for (i, radius) in [70.0, 130, 190, 250].enumerated() {
                context.setStrokeColor(i == 0 ? accent : faint)
                context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
        case .stripes:
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: H * 0.82, width: W, height: H * 0.18))
            context.setFillColor(faint)
            let step: CGFloat = 34 + 12 * wiggle
            var x: CGFloat = -H
            while x < W + H {
                context.beginPath()
                context.move(to: CGPoint(x: x, y: H * 0.82))
                context.addLine(to: CGPoint(x: x + 14, y: H * 0.82))
                context.addLine(to: CGPoint(x: x + 14 + H * 0.18, y: H))
                context.addLine(to: CGPoint(x: x + H * 0.18, y: H))
                context.closePath()
                context.fillPath()
                x += step
            }
            context.restoreGState()
            context.setFillColor(accent)
            context.fill(CGRect(x: 0, y: H * 0.82 - 10, width: W, height: 10))
        case .frame:
            let inset: CGFloat = 26
            context.setStrokeColor(accent)
            context.setLineWidth(5)
            context.stroke(CGRect(x: inset, y: inset, width: W - inset * 2, height: H - inset * 2))
            context.setStrokeColor(faint)
            context.setLineWidth(2)
            context.stroke(CGRect(x: inset + 12, y: inset + 12, width: W - (inset + 12) * 2, height: H - (inset + 12) * 2))
        }
    }

    // MARK: - Drawing helpers

    private static func canvas(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    private static func encode(_ image: CGImage, type: String, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func color(_ rgb: BookCoverDesign.RGB, alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
    }

    private static func attributed(_ text: String, font name: String, size: CGFloat, color rgb: BookCoverDesign.RGB? = nil,
                                   kern: CGFloat = 0, lineHeight: CGFloat = 1) -> NSAttributedString {
        let font = CTFontCreateWithName(name as CFString, size, nil)
        let spacing = lineHeight
        let wrap = CTLineBreakMode.byWordWrapping
        let paragraph = withUnsafePointer(to: spacing) { spacingPointer in
            withUnsafePointer(to: wrap) { wrapPointer in
                let settings = [
                    CTParagraphStyleSetting(spec: .lineHeightMultiple, valueSize: MemoryLayout<CGFloat>.size, value: spacingPointer),
                    CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: wrapPointer),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): kern,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ]
        if let rgb { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color(rgb) }
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// The largest size, stepping down, at which every word fits the box's width on its own (so
    /// no word is broken) and the whole text fits its height.
    private static func fittingSize(_ text: String, font: String, in box: CGRect, from: CGFloat, to: CGFloat,
                                    kern: CGFloat = -0.5) -> CGFloat {
        var size = from
        while size > to {
            let words = text.split(separator: " ").map(String.init)
            let widest = words.map { lineWidth(attributed($0, font: font, size: size, kern: kern)) }.max() ?? 0
            if widest <= box.width {
                let setter = CTFramesetterCreateWithAttributedString(attributed(text, font: font, size: size, kern: kern, lineHeight: 1.02))
                var fit = CFRange()
                let needed = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                                          CGSize(width: box.width, height: .greatestFiniteMagnitude), &fit)
                if needed.height <= box.height { return size }
            }
            size -= 2
        }
        return to
    }

    private static func lineWidth(_ text: NSAttributedString) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil))
    }

    private static func frame(_ text: String, font: String, size: CGFloat, color rgb: BookCoverDesign.RGB, kern: CGFloat,
                              lineHeight: CGFloat, in box: CGRect, bottomAligned: Bool = false) -> CTFrame {
        let string = attributed(text, font: font, size: size, color: rgb, kern: kern, lineHeight: lineHeight)
        let setter = CTFramesetterCreateWithAttributedString(string)
        var rect = box
        if bottomAligned {
            var fit = CFRange()
            let needed = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                                      CGSize(width: box.width, height: box.height), &fit)
            rect = CGRect(x: box.minX, y: box.minY, width: box.width, height: min(box.height, ceil(needed.height) + 2))
        }
        return CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
    }

    /// How far down from the top of its box a frame's last line reaches.
    private static func usedHeight(_ frame: CTFrame) -> CGFloat {
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard !lines.isEmpty else { return 0 }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let box = CTFrameGetPath(frame).boundingBox
        var descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(lines[lines.count - 1], nil, &descent, nil)
        return box.height - origins[lines.count - 1].y + descent
    }
}
#endif
