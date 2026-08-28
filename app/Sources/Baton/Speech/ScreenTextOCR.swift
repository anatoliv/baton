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
                         height: o.boundingBox.height)
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
    }

    static func assemble(_ pieces: [Piece]) -> String {
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
