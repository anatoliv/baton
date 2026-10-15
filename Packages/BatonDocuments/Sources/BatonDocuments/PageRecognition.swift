import Foundation
#if canImport(PDFKit) && canImport(Vision)
import CoreGraphics
import PDFKit
import Vision
#endif

extension LayoutTextImporter {
    /// One line that text recognition found, in the recogniser's normalised space: 0...1 on
    /// both axes, origin at the bottom left. That is Vision's convention and also the PDF's,
    /// so a larger `y` is higher on the page here as in `PlacedLine`.
    public struct RecognizedLine: Sendable, Equatable {
        public var text: String
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public init(text: String, x: Double, y: Double, width: Double, height: Double) {
            self.text = text; self.x = x; self.y = y; self.width = width; self.height = height
        }
    }

    /// A scanned page's recognised lines as `PlacedLine`s in the page's own space, so they go
    /// through `layoutText(ofPages:)` beside the pages that had a text layer and the same
    /// margin, indentation, page-number and heading rules read them.
    ///
    /// Recognition sometimes returns one printed line as two pieces (a gap in the scan, a
    /// heading's number set apart from its words). PDFKit's `selectionsByLine` gives one
    /// selection per printed line, so pieces that share a row are joined left to right.
    ///
    /// - Parameter page: the page's box in PDF points (`minX`, `minY`, `width`, `height`).
    public static func placedLines(recognized: [RecognizedLine],
                                   page: (minX: Double, minY: Double, width: Double, height: Double)) -> [PlacedLine] {
        var pieces: [RecognizedLine] = []
        for line in recognized {
            var piece = line
            piece.text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.text.isEmpty, piece.height > 0 { pieces.append(piece) }
        }
        pieces.sort { middle($0) > middle($1) }

        var rows: [[RecognizedLine]] = []
        for piece in pieces {
            // Same row: each piece's middle lies inside the other, so a tall heading does not
            // swallow the small line beside it.
            if let first = rows.last?.first, contains(first, middle(piece)), contains(piece, middle(first)),
               !rows[rows.count - 1].contains(where: { overlapsHorizontally($0, piece) }) {
                rows[rows.count - 1].append(piece)
            } else {
                rows.append([piece])
            }
        }

        return rows.map { row in
            let ordered = row.sorted { $0.x < $1.x }
            let minX: Double = ordered.map(\.x).min() ?? 0
            let maxX: Double = ordered.map { $0.x + $0.width }.max() ?? 0
            let minY: Double = ordered.map(\.y).min() ?? 0
            return PlacedLine(text: ordered.map(\.text).joined(separator: " "),
                              minX: page.minX + minX * page.width,
                              minY: page.minY + minY * page.height,
                              width: (maxX - minX) * page.width)
        }
    }

    /// One horizontal strip of a page that recognition reads on its own.
    ///
    /// Vision reading a whole book page at once was measured dropping lines: on the sample's
    /// first page, rasterised at 150 dpi, it returned nothing for the four lines under the
    /// chapter heading and ran two other lines together into nonsense, at every render scale
    /// from 2x to 4x. The same lines read cleanly when the request's region of interest was a
    /// band of the page. So a page is read in bands that overlap, and each band keeps only the
    /// lines whose middle falls in its own `core`; the overlap is wider than a line, so a line
    /// cut by one band's edge is read whole by the band that owns it.
    ///
    /// Measured on six pages of the sample, rasterised at 150 dpi, against their text layer
    /// (89 paragraphs, 2247 words): the whole page at once gave 90 paragraphs and 98% of the
    /// words, two bands 92 and 99%, bands of about 200 points (four on a book page) 89 and
    /// 100%. The whole 25-page book in bands of 200 gave its 294 paragraphs and every word.
    /// Each band is a separate request, so a page costs about four times one request.
    public struct RecognitionBand: Sendable, Equatable {
        /// The strip this band owns, bottom to top, normalised to the page.
        public var core: Range<Double>
        /// What recognition is asked to read: the core plus the overlap, inside the page.
        public var regionMinY: Double
        public var regionHeight: Double

        /// Bands of about `bandPoints` each with `overlapPoints` of overlap on either side, for
        /// a page `pageHeight` points tall. A short page is one band, the whole page.
        public static func bands(pageHeight: Double, bandPoints: Double = 200, overlapPoints: Double = 36) -> [RecognitionBand] {
            guard pageHeight > 0 else { return [] }
            let count = max(1, Int((pageHeight / bandPoints).rounded(.up)))
            let overlap = overlapPoints / pageHeight
            return (0..<count).map { i in
                let low = Double(i) / Double(count)
                let high = i == count - 1 ? 1 : Double(i + 1) / Double(count)
                let regionLow = max(0, low - overlap), regionHigh = min(1, high + overlap)
                return RecognitionBand(core: low..<(i == count - 1 ? 1.000_001 : high),
                                       regionMinY: regionLow, regionHeight: regionHigh - regionLow)
            }
        }

        /// A line as recognition reported it inside this band's region, placed on the whole
        /// page; nil when the line belongs to a neighbouring band.
        public func place(_ line: RecognizedLine) -> RecognizedLine? {
            var placed = line
            placed.y = regionMinY + line.y * regionHeight
            placed.height = line.height * regionHeight
            return core.contains(placed.y + placed.height / 2) ? placed : nil
        }
    }

    private static func middle(_ line: RecognizedLine) -> Double { line.y + line.height / 2 }

    private static func contains(_ line: RecognizedLine, _ y: Double) -> Bool {
        y > line.y && y < line.y + line.height
    }

    private static func overlapsHorizontally(_ a: RecognizedLine, _ b: RecognizedLine) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width
    }
}

#if canImport(PDFKit) && canImport(Vision)
/// Reads a page that has no text layer: renders it to an image and runs Vision's text
/// recognition over it (`specs/document-clippings.md`, *Ingestion*, "Scanned PDF").
///
/// Synchronous by design. The importer runs on the import's background task, and
/// `VNImageRequestHandler.perform` blocks that task rather than the main thread.
enum PageRecognizer {
    /// Twice the page's point size, about 144 dpi: enough for Vision's accurate level to read
    /// body text, without the memory a print-resolution render of every page would take.
    static let renderScale: CGFloat = 2
    /// A page that would render larger than this (a poster, a map) is rendered smaller instead.
    static let maximumPixels: CGFloat = 40_000_000

    /// The page's lines as text recognition reads them, placed in the page's space; empty when
    /// nothing was recognised or the page could not be rendered.
    static func placedLines(of page: PDFPage) -> [LayoutTextImporter.PlacedLine] {
        autoreleasepool {
            let box = page.bounds(for: .mediaBox)
            // PDFKit draws a rotated page upright, so the image (and the recognised lines) are
            // in the orientation a reader sees.
            let quarterTurned = (page.rotation / 90) % 2 != 0
            let width = quarterTurned ? box.height : box.width
            let height = quarterTurned ? box.width : box.height
            guard let image = render(page, width: width, height: height) else { return [] }
            return LayoutTextImporter.placedLines(
                recognized: recognize(image, pageHeight: Double(height)),
                page: (minX: Double(box.minX), minY: Double(box.minY), width: Double(width), height: Double(height)))
        }
    }

    static func render(_ page: PDFPage, width: CGFloat, height: CGFloat) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let scale = min(renderScale, (maximumPixels / (width * height)).squareRoot())
        let pixelsWide = Int((width * scale).rounded()), pixelsHigh = Int((height * scale).rounded())
        guard pixelsWide > 0, pixelsHigh > 0,
              let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        // A scan's page is paper: white under whatever the page draws, never transparent.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// Accurate recognition with language correction, in the languages the person reads
    /// (the system's preferred languages that Vision supports), else Vision's default. The
    /// page is read band by band (`RecognitionBand`).
    static func recognize(_ image: CGImage, pageHeight: Double) -> [LayoutTextImporter.RecognizedLine] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var lines: [LayoutTextImporter.RecognizedLine] = []
        for band in LayoutTextImporter.RecognitionBand.bands(pageHeight: pageHeight) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let languages = recognitionLanguages(
                preferred: Locale.preferredLanguages,
                supported: (try? request.supportedRecognitionLanguages()) ?? [])
            if !languages.isEmpty { request.recognitionLanguages = languages }
            request.regionOfInterest = CGRect(x: 0, y: band.regionMinY, width: 1, height: band.regionHeight)
            // A failed band leaves its lines unread; a page none of whose bands read anything
            // is reported as a page without text. Neither fails the whole document.
            do { try handler.perform([request]) } catch { continue }
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let box = observation.boundingBox   // relative to the region of interest
                let line = LayoutTextImporter.RecognizedLine(
                    text: candidate.string, x: Double(box.minX), y: Double(box.minY),
                    width: Double(box.width), height: Double(box.height))
                if let placed = band.place(line) { lines.append(placed) }
            }
        }
        return lines
    }

    /// "en-GB" matches a supported "en-GB" exactly, or else the first supported English.
    static func recognitionLanguages(preferred: [String], supported: [String]) -> [String] {
        var chosen: [String] = []
        for language in preferred {
            let base = language.split(separator: "-").first.map(String.init) ?? language
            let match = supported.first { $0.caseInsensitiveCompare(language) == .orderedSame }
                ?? supported.first { ($0.split(separator: "-").first.map(String.init) ?? $0).caseInsensitiveCompare(base) == .orderedSame }
            if let match, !chosen.contains(match) { chosen.append(match) }
        }
        return chosen
    }
}
#endif
