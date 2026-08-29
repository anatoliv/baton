import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit
import Vision

/// Tier 4: read the pixels, when no application will hand over its text.
///
/// Every other tier depends on the source app cooperating. This one does not — it captures the
/// focused window and recognises the text in it, which is the only way to read a PDF in Preview,
/// an image, a subtitle, a canvas-drawn page, or a remote desktop.
///
/// **It is also the tier that asks the most of the user**, so two rules hold absolutely:
///
/// 1. **Explicitly invoked, never ambient.** No polling, no watching, no "read what changed". A
///    capture happens because a person asked for one, at that moment. This is the property that
///    makes the whole feature acceptable to ship, and it is not a default to be relaxed later.
/// 2. **The captured image never touches disk.** It is recognised in memory and released.
///    Readings are not persisted; neither is what they were read from.
///
/// Scoped to the **focused window**, not the display, so nothing behind or beside it is captured.
@MainActor
enum ScreenTextOCR {

    enum Failure: Error, Equatable {
        /// Screen Recording has not been granted. The one failure the user can fix.
        case notPermitted
        /// Nothing to capture — no focused window belonging to the frontmost app.
        case noWindow
        /// The capture worked and Vision found no text in it.
        case noText
        case failed(String)
    }

    static var isPermitted: Bool { CGPreflightScreenCaptureAccess() }

    /// Ask for the grant. macOS shows its own prompt the first time; afterwards it only opens
    /// System Settings, which is why the caller also offers a link.
    static func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// Capture the frontmost application's focused window and read the text out of it.
    static func readFocusedWindow() async -> Result<String, Failure> {
        guard isPermitted else { return .failure(.notPermitted) }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return .failure(.noWindow) }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            // `windows` comes back front-to-back, so the first match is the one in front — which
            // is the one the user is looking at and asked to have read.
            guard let window = content.windows.first(where: {
                $0.owningApplication?.processID == frontmost.processIdentifier && $0.isOnScreen
            }) else { return .failure(.noWindow) }

            let config = SCStreamConfiguration()
            // Capture at 2× the window's points. Vision's accuracy falls off badly on small
            // text, and a Retina-scale capture is the difference between reading a code comment
            // and inventing one.
            config.width = Int(window.frame.width * 2)
            config.height = Int(window.frame.height * 2)
            config.showsCursor = false

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return recognize(image)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    // MARK: - Recognition

    /// Vision returns observations positioned in space, not a document. Turning boxes back into
    /// sentences in the right order is most of the work here, and getting it wrong produces
    /// fluent nonsense rather than an obvious failure.
    static func recognize(_ image: CGImage) -> Result<String, Failure> {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
        guard let observations = request.results, !observations.isEmpty else { return .failure(.noText) }

        let text = assemble(observations)
        return text.isEmpty ? .failure(.noText) : .success(text)
    }

    /// Group observations into lines and read them top-to-bottom, left-to-right.
    ///
    /// Vision's coordinates are normalised with the **origin at the bottom left**, so "higher on
    /// screen" is a *larger* y. Sorting the obvious way puts the document upside down, which is
    /// the single easiest mistake to make here and produces output that reads as a bug in the
    /// recogniser rather than in the sort.
    static func assemble(_ observations: [VNRecognizedTextObservation]) -> String {
        assemble(observations.compactMap { o in
            guard let candidate = o.topCandidates(1).first else { return nil }
            return Piece(text: candidate.string,
                         midY: o.boundingBox.midY,
                         minX: o.boundingBox.minX,
                         height: o.boundingBox.height,
                         maxX: o.boundingBox.maxX)
        })
    }

    /// One recognised fragment, reduced to what the ordering actually needs. Split out from the
    /// Vision types so the ordering — the part that silently produces fluent nonsense when it is
    /// wrong — can be tested without a screen capture.
    struct Piece: Equatable {
        let text: String
        /// Normalised, **origin at the bottom left**: larger is higher on screen.
        let midY: CGFloat
        let minX: CGFloat
        let height: CGFloat
        /// The fragment's right edge. Needed only to find a **gutter** between columns, which is
        /// a gap in horizontal coverage and therefore cannot be seen from left edges alone.
        var maxX: CGFloat = 1

        init(text: String, midY: CGFloat, minX: CGFloat, height: CGFloat, maxX: CGFloat? = nil) {
            self.text = text
            self.midY = midY
            self.minX = minX
            self.height = height
            self.maxX = maxX ?? minX
        }
    }

    /// Turn positioned fragments into text in the order a person would read them.
    ///
    /// **Columns are handled before lines**, which is the whole subtlety. Grouping by vertical
    /// position first and reading left to right is correct for one column and reads *across the
    /// gutter* on two, producing fluent sentences assembled from alternating halves. That failure
    /// sounds like a broken recogniser rather than a broken sort, so it is the kind that survives
    /// (TBX-3830: a two-column page is exactly what "a PDF reads in the right order" means).
    static func assemble(_ pieces: [Piece]) -> String {
        guard !pieces.isEmpty else { return "" }
        return assembleBlock(pieces, depth: 0)
    }

    /// One region: split into columns if it has any, otherwise read it as lines.
    private static func assembleBlock(_ pieces: [Piece], depth: Int) -> String {
        // Two levels is enough for the layouts this tier meets (a page, then its columns), and a
        // bound means a pathological page cannot recurse forever.
        if depth < 2, let columns = splitIntoColumns(pieces) {
            return columns.map { assembleBlock($0, depth: depth + 1) }.joined(separator: "\n")
        }
        return readAsLines(pieces)
    }

    /// Find a vertical gutter and split on it, or return nil when the region is a single column.
    ///
    /// Deliberately conservative. A false positive silently reorders a page that was already
    /// correct, which is worse than a false negative that leaves it as it is today, so every one
    /// of these guards has to hold.
    private static func splitIntoColumns(_ pieces: [Piece]) -> [[Piece]]? {
        guard pieces.count >= 6 else { return nil }

        let left = pieces.map(\.minX).min() ?? 0
        let right = pieces.map(\.maxX).max() ?? 1
        let span = right - left
        guard span > 0.2 else { return nil }

        // Sweep left to right over the fragments' horizontal extents and find the widest band
        // that no fragment covers.
        let sorted = pieces.sorted { $0.minX < $1.minX }
        var reach = sorted[0].maxX
        var bestGap: (start: CGFloat, end: CGFloat) = (0, 0)
        for piece in sorted.dropFirst() {
            if piece.minX > reach, piece.minX - reach > bestGap.end - bestGap.start {
                bestGap = (reach, piece.minX)
            }
            reach = max(reach, piece.maxX)
        }

        // A gutter is a real one only if it is wide relative to the page. Word spacing and
        // paragraph indents are far narrower than this.
        let width = bestGap.end - bestGap.start
        guard width > span * 0.06 else { return nil }

        let cut = (bestGap.start + bestGap.end) / 2
        let leftColumn = pieces.filter { $0.maxX <= cut }
        let rightColumn = pieces.filter { $0.maxX > cut }
        guard leftColumn.count >= 3, rightColumn.count >= 3 else { return nil }

        // The decisive test: columns run *alongside* each other. Two stacked blocks separated by
        // a wide margin are not columns, and splitting them would reorder a correct page.
        guard verticalOverlap(leftColumn, rightColumn) > 0.5 else { return nil }

        return [leftColumn, rightColumn]
    }

    /// How much of the shorter block's vertical range is shared with the taller one, 0...1.
    private static func verticalOverlap(_ a: [Piece], _ b: [Piece]) -> CGFloat {
        guard let aLow = a.map(\.midY).min(), let aHigh = a.map(\.midY).max(),
              let bLow = b.map(\.midY).min(), let bHigh = b.map(\.midY).max()
        else { return 0 }
        let shared = min(aHigh, bHigh) - max(aLow, bLow)
        guard shared > 0 else { return 0 }
        return shared / max(min(aHigh - aLow, bHigh - bLow), 0.0001)
    }

    /// Top to bottom, left to right within a line. Correct once a region is one column.
    private static func readAsLines(_ pieces: [Piece]) -> String {
        guard !pieces.isEmpty else { return "" }

        // Two fragments belong to the same visual line when their vertical centres are within
        // roughly half a line height of each other. A fixed epsilon would break on any page that
        // mixes heading and body sizes.
        let tolerance = max(pieces.map(\.height).reduce(0, +) / CGFloat(pieces.count) * 0.5, 0.004)

        var lines: [[Piece]] = []
        for piece in pieces.sorted(by: { $0.midY > $1.midY }) {
            if var last = lines.last, let anchor = last.first, abs(anchor.midY - piece.midY) <= tolerance {
                last.append(piece)
                lines[lines.count - 1] = last
            } else {
                lines.append([piece])
            }
        }
        return lines
            .map { $0.sorted { $0.minX < $1.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }
}
