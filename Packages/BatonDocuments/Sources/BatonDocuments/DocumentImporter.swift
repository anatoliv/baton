import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(PDFKit)
import PDFKit
#endif

/// The front door: a file in, an `ImportedDocument` out, whatever the format.
///
/// Formats arrive card by card (`specs/document-clippings-plan.md`). Today: PDF (Apple
/// platforms; scanned pages through Vision text recognition), plain text, Markdown, HTML
/// files, web pages (`importURL`) and EPUB. RTF is refused with a clear error rather than
/// read badly.
public enum DocumentImporter {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unsupportedFormat(String)
        case unreadable(String)
        /// A web address that could not be read: not a web address, unreachable, refused, or
        /// not a page Baton reads. Worded for a link rather than a file.
        case unreadableLink(String)
        case protected
        case empty

        public var description: String {
            switch self {
            case .unsupportedFormat(let ext): return "Baton cannot read .\(ext) files yet."
            case .unreadable(let why): return "The file could not be read: \(why)"
            case .unreadableLink(let why): return "The link could not be read: \(why)"
            case .protected: return "This file is protected, so Baton cannot read it."
            case .empty: return "No text was found in this file."
            }
        }
    }

    public static func kind(for url: URL) -> SourceKind? {
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "txt", "text": return .text
        case "md", "markdown", "mdown": return .markdown
        case "epub": return .epub
        case "html", "htm", "xhtml": return .html
        case "rtf": return .rtf
        default: return nil
        }
    }

    /// - Parameter isWord: a spell checker for the line-end hyphen tiebreak
    ///   (`LayoutTextImporter.isWord`). The Mac app passes `NSSpellChecker`, the phone
    ///   `UITextChecker`; both are main-actor APIs, so the caller owns how it is reached.
    public static func importFile(at url: URL, isWord: (@Sendable (String) -> Bool?)? = nil) throws -> ImportedDocument {
        guard let kind = kind(for: url) else { throw Failure.unsupportedFormat(url.pathExtension) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw Failure.unreadable(error.localizedDescription) }
        let digest = SHA256Digest.hex(of: data)
        let fallbackTitle = prettyTitle(fromFileName: url.deletingPathExtension().lastPathComponent)

        var warnings: [ImportWarning] = []
        let result: LayoutTextImporter.Result
        switch kind {
        case .pdf:
            result = try readPDF(data: data, isWord: isWord, warnings: &warnings)
        case .text:
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                throw Failure.unreadable("not text")
            }
            result = PlainTextImporter.read(text)
        case .markdown:
            guard let text = String(data: data, encoding: .utf8) else { throw Failure.unreadable("not UTF-8 text") }
            let (r, skipped) = MarkdownImporter.read(text, fallbackTitle: fallbackTitle)
            if skipped > 0 { warnings.append(ImportWarning(.contentSkipped, detail: "\(skipped) code blocks")) }
            result = r
        case .html:
            return try importHTML(data: data, contentType: nil, digest: digest, kind: .html,
                                  fileName: url.lastPathComponent, fallbackTitle: fallbackTitle)
        case .epub:
            let output = try EPUBImporter.read(data, fallbackTitle: fallbackTitle)
            var document = try assemble(output.result, digest: digest, kind: .epub, fileName: url.lastPathComponent,
                                        fallbackTitle: fallbackTitle, warnings: output.warnings)
            if let declared = output.language {
                document.language = declared
                document.languageRegion = output.languageRegion
            }
            return document
        case .url, .rtf:
            throw Failure.unsupportedFormat(url.pathExtension.lowercased())
        }
        return try assemble(result, digest: digest, kind: kind, fileName: url.lastPathComponent,
                            fallbackTitle: fallbackTitle, warnings: warnings)
    }

    static func importHTML(data: Data, contentType: String?, digest: String, kind: SourceKind,
                           fileName: String?, fallbackTitle: String) throws -> ImportedDocument {
        let output = HTMLImporter.read(HTMLParser.decode(data, contentType: contentType), fallbackTitle: fallbackTitle)
        if let script = output.warnings.first(where: { $0.kind == .empty }), let why = script.detail {
            throw Failure.unreadable(why)
        }
        var document = try assemble(output.result, digest: digest, kind: kind, fileName: fileName,
                                    fallbackTitle: fallbackTitle, warnings: output.warnings)
        if let declared = output.language {
            document.language = declared
            document.languageRegion = output.languageRegion
        }
        return document
    }

    // MARK: - Web pages

    /// What fetching a URL needs from the caller: `pageFetch` in the apps, a scripted answer
    /// in tests.
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// The largest page Baton reads. A long book as one HTML file is a few megabytes; anything
    /// past this is not an article.
    public static let maximumPageBytes = 30 * 1024 * 1024

    /// The network, read only up to `maximumPageBytes`: a link that serves gigabytes is cut off
    /// as it streams instead of being held whole before the size check.
    public static let pageFetch: Fetch = { try await CappedDownload.data(for: $0, limit: maximumPageBytes) }

    /// A web page by its address: fetched, then read like an HTML file, or like a PDF or text
    /// file when that is what the address serves.
    ///
    /// The book's identity is the digest of the *text read*, not of the bytes: a page's bytes
    /// change with every visit (ads, timestamps, tracking ids) while its article does not, and
    /// importing the same article twice should find the existing book.
    public static func importURL(_ url: URL, fetch: Fetch = pageFetch) async throws -> ImportedDocument {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else {
            throw Failure.unreadableLink("it is not a web address (https://...)")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("text/html,application/xhtml+xml,application/pdf,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await fetch(request) } catch is CappedDownload.TooLarge {
            throw Failure.unreadableLink("the page is larger than Baton reads")
        } catch {
            throw Failure.unreadableLink("the page could not be fetched (\(error.localizedDescription))")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.unreadableLink(http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 402
                ? "the site would not show this page without signing in (error \(http.statusCode))"
                : "the site answered with error \(http.statusCode)")
        }
        guard data.count <= maximumPageBytes else { throw Failure.unreadableLink("the page is larger than Baton reads") }

        let finalURL = response.url ?? url
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? response.mimeType
        let mime = contentType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let pathTitle = finalURL.deletingPathExtension().lastPathComponent
        let fallbackTitle = prettyTitle(fromFileName: pathTitle.isEmpty || pathTitle == "/" ? (finalURL.host ?? "Web page") : pathTitle)
        let fileName = finalURL.absoluteString

        var document: ImportedDocument
        // What the page held, read as a file would be; its refusals are worded for the link.
        do {
            switch mime {
            case "application/pdf":
                var warnings: [ImportWarning] = []
                let result = try readPDF(data: data, isWord: nil, warnings: &warnings)
                document = try assemble(result, digest: SHA256Digest.hex(of: data), kind: .pdf, fileName: fileName,
                                        fallbackTitle: fallbackTitle, warnings: warnings)
                return document
            case "text/plain":
                let text = HTMLParser.decode(data, contentType: contentType)
                document = try assemble(PlainTextImporter.read(text), digest: "", kind: .url, fileName: fileName,
                                        fallbackTitle: fallbackTitle, warnings: [])
            case "", "text/html", "application/xhtml+xml", "application/xml", "text/xml":
                document = try importHTML(data: data, contentType: contentType, digest: "", kind: .url,
                                          fileName: fileName, fallbackTitle: fallbackTitle)
            default:
                throw Failure.unreadableLink("the address serves \(mime), not a page Baton can read")
            }
        } catch Failure.unreadable(let why) {
            throw Failure.unreadableLink(why)
        } catch Failure.empty {
            throw Failure.unreadableLink("no text was found on the page")
        }
        let text = document.chapters.map { ([$0.title] + $0.paragraphs).joined(separator: "\n") }.joined(separator: "\n\n")
        document.sourceSHA256 = SHA256Digest.hex(of: Data(text.utf8))
        return document
    }

    /// Shared tail of every importer: titles, language, warnings, and the refusal of an empty
    /// result.
    static func assemble(_ result: LayoutTextImporter.Result, digest: String, kind: SourceKind,
                         fileName: String?, fallbackTitle: String, warnings: [ImportWarning]) throws -> ImportedDocument {
        guard result.chapters.contains(where: { !$0.paragraphs.isEmpty }) else { throw Failure.empty }
        var warnings = warnings
        if !result.foundHeadings { warnings.append(ImportWarning(.noChapters)) }
        let title = result.title ?? fallbackTitle
        var chapters = result.chapters
        for i in chapters.indices {
            chapters[i].index = i
            if chapters[i].title.isEmpty { chapters[i].title = title }
        }
        let sample = chapters.prefix(3).flatMap(\.paragraphs).joined(separator: " ")
        return ImportedDocument(sourceSHA256: digest, sourceKind: kind, fileName: fileName,
                                title: title, author: result.author, language: LanguageGuess.detect(sample),
                                chapters: chapters, frontMatter: result.frontMatter,
                                warnings: warnings, stats: result.stats)
    }

    /// "the-machine-stops_v2" → "The Machine Stops V2". Last resort for a title.
    public static func prettyTitle(fromFileName name: String) -> String {
        let words = name.replacingOccurrences(of: #"[-_.]+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// PDF metadata titles are often the file the PDF was made from ("The-Machine-Stops.dvi",
    /// "Microsoft Word - draft3.docx"), which is worse than the title page. Use one only when
    /// it looks like a title.
    public static func metadataTitleIsUsable(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.contains(" ") else { return false }
        if t.range(of: #"\.(dvi|tex|docx?|odt|pages|rtf|indd|pdf|ps|txt)$"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        if t.range(of: #"^(Microsoft Word|untitled)"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        return true
    }

    #if canImport(PDFKit)
    /// PDFKit's `page.string` has no indentation, and indentation is how most books mark a
    /// paragraph. Each line's position does survive, so the text is laid out from it.
    static func placedLines(of page: PDFPage) -> [LayoutTextImporter.PlacedLine] {
        guard let selection = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }
        return selection.selectionsByLine().map { line in
            let b = line.bounds(for: page)
            return .init(text: line.string ?? "", minX: b.minX, minY: b.minY, width: b.width)
        }
    }
    #endif

    static func hasText(_ line: LayoutTextImporter.PlacedLine) -> Bool {
        !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func readPDF(data: Data, isWord: (@Sendable (String) -> Bool?)?,
                        warnings: inout [ImportWarning]) throws -> LayoutTextImporter.Result {
        #if canImport(PDFKit)
        guard let pdf = PDFDocument(data: data) else { throw Failure.unreadable("not a PDF") }
        if pdf.isLocked || pdf.isEncrypted && !pdf.allowsCopying { throw Failure.protected }
        var placed = (0..<pdf.pageCount).map { pdf.page(at: $0).map(Self.placedLines(of:)) ?? [] }
        // A page with no text layer is a scan: text recognition reads it, and its lines join
        // the others before layout, so one set of margin, paragraph and heading rules reads the
        // whole document. What recognition read is named (it can misread), and so is a page it
        // found nothing on, rather than either being silently dropped.
        var recognized: [Int] = []
        var empty: [Int] = []
        for i in placed.indices where !placed[i].contains(where: Self.hasText) {
            #if canImport(Vision)
            if let page = pdf.page(at: i) { placed[i] = PageRecognizer.placedLines(of: page) }
            #endif
            if placed[i].contains(where: Self.hasText) { recognized.append(i + 1) } else { empty.append(i + 1) }
        }
        if !recognized.isEmpty { warnings.append(ImportWarning(.pagesRecognized, pages: recognized)) }
        if !empty.isEmpty { warnings.append(ImportWarning(.pagesWithoutText, pages: empty)) }
        let pages = LayoutTextImporter.layoutText(ofPages: placed)

        var outline: [String] = []
        if let root = pdf.outlineRoot {
            for i in 0..<root.numberOfChildren { if let label = root.child(at: i)?.label { outline.append(label) } }
        }
        var result = LayoutTextImporter(declaredHeadings: outline, isWord: isWord).extract(pages: pages)
        let attributes = pdf.documentAttributes ?? [:]
        if let metaTitle = attributes[PDFDocumentAttribute.titleAttribute] as? String, !metaTitle.isEmpty {
            if metadataTitleIsUsable(metaTitle) {
                if result.title == nil { result.title = metaTitle }
            } else {
                warnings.append(ImportWarning(.metadataTitleIgnored, detail: metaTitle))
            }
        }
        if result.author == nil, let metaAuthor = attributes[PDFDocumentAttribute.authorAttribute] as? String,
           !metaAuthor.trimmingCharacters(in: .whitespaces).isEmpty {
            result.author = metaAuthor
        }
        return result
        #else
        throw Failure.unsupportedFormat("pdf")
        #endif
    }
}
