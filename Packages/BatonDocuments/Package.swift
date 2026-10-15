// swift-tools-version:6.0
import PackageDescription

// Document clippings' shared logic: turning a file into a structured document, and a document
// into a book ready to render (`specs/document-clippings.md`).
//
// Foundation only, and it builds on Linux. The Mac and the iPhone import and shape documents
// with it, and the gateway decodes the `PreparedBook` they send and renders it. So one
// definition of the wire format and one set of shaping rules serve all three; "when something
// exists in more than one place, put it in one". Apple-only parts (PDFKit,
// NaturalLanguage, CryptoKit) sit behind `#if canImport`, with a portable path beside each.
let package = Package(
    name: "BatonDocuments",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "BatonDocuments", targets: ["BatonDocuments"])],
    targets: [
        .target(name: "BatonDocuments"),
        .testTarget(name: "BatonDocumentsTests", dependencies: ["BatonDocuments"],
                    // The dialogue-cast gold labels and cast sheet for the sample (ids and the first
                    // few characters of each quote only; the book itself is never checked in).
                    resources: [.copy("Fixtures")]),
    ]
)
