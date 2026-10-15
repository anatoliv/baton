import Foundation

/// A file turned into structure: title, author, language and chapters of paragraphs.
///
/// This is what an importer produces and what the import sheet shows. It is not yet shaped
/// for the ear; `DocumentSpeech.prepare` does that and produces a `PreparedBook`.
///
/// `Codable` because the iPhone hands it to a Mac ("Send to my Mac") and because the gateway
/// keeps the text of a book it rendered so a deleted download can be rendered again. The
/// `schemaVersion` field lets a newer reader refuse, rather than misread, a document written
/// by a format it does not know.
public struct ImportedDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// The digest of the *source file's bytes*. It identifies the book: importing the same PDF
    /// twice finds the existing book instead of rendering a second copy.
    public var sourceSHA256: String
    public var sourceKind: SourceKind
    public var fileName: String?
    public var title: String
    public var author: String?
    /// Lowercase BCP-47 language code (`en`, `es`), when it could be detected.
    public var language: String?
    /// The region a file declared with its language ("gb" for `en-GB`), lowercase. Only a
    /// British-or-not signal for the narrator default; absent from older documents,
    /// and from any whose language was guessed rather than declared.
    public var languageRegion: String?
    public var chapters: [DocumentChapter]
    /// Title-page lines that are neither the title nor the byline ("First published in the
    /// Oxford and Cambridge Review, November 1909"). Shown on the import sheet, not spoken.
    public var frontMatter: [String]
    public var warnings: [ImportWarning]
    /// What the importer removed or repaired, so the import sheet can say it and tests can
    /// pin it.
    public var stats: ExtractionStats

    public init(sourceSHA256: String, sourceKind: SourceKind, fileName: String? = nil,
                title: String, author: String? = nil, language: String? = nil, languageRegion: String? = nil,
                chapters: [DocumentChapter], frontMatter: [String] = [], warnings: [ImportWarning] = [],
                stats: ExtractionStats = ExtractionStats()) {
        self.schemaVersion = Self.currentSchemaVersion
        self.sourceSHA256 = sourceSHA256
        self.sourceKind = sourceKind
        self.fileName = fileName
        self.title = title
        self.author = author
        self.language = language
        self.languageRegion = languageRegion
        self.chapters = chapters
        self.frontMatter = frontMatter
        self.warnings = warnings
        self.stats = stats
    }

    /// Every paragraph, in reading order.
    public var paragraphs: [String] { chapters.flatMap(\.paragraphs) }

    /// Words, counted the way the listening estimate needs: whitespace-separated runs.
    public var wordCount: Int {
        chapters.reduce(0) { total, chapter in
            total + chapter.paragraphs.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count }
        }
    }
}

public enum SourceKind: String, Codable, Sendable, CaseIterable {
    case pdf, epub, html, url, text, markdown, rtf
}

public struct DocumentChapter: Codable, Sendable, Equatable {
    /// Zero-based position in the document.
    public var index: Int
    public var title: String
    public var paragraphs: [String]
    /// The book's own numbering, when it has one: "1", "IV", "Chapter 4". Spoken before the
    /// title ("Chapter 1. The Air-Ship"); `nil` when the heading was a title alone.
    public var label: String?

    public init(index: Int, title: String, paragraphs: [String], label: String? = nil) {
        self.index = index
        self.title = title
        self.paragraphs = paragraphs
        self.label = label
    }

    /// What is spoken at the start of the chapter.
    public var spokenHeading: String {
        guard let label, label != title else { return title }
        if label.first?.isNumber == true || label.range(of: #"^[IVXLCDM]+$"#, options: .regularExpression) != nil {
            return "Chapter \(label). \(title)"
        }
        return "\(label). \(title)"
    }
}

/// Something the person should know about the import. Every one is shown on the import sheet:
/// "degrade honestly" means a limitation is stated, not hidden in a log.
public struct ImportWarning: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Pages with no text layer that text recognition could not read either (or that were
        /// not tried, where there is no Vision). They are missing from the book.
        case pagesWithoutText
        /// Pages whose text came from OCR, which can misread.
        case pagesRecognized
        /// No chapter structure was found, so the book is one long chapter.
        case noChapters
        /// The file's own title metadata looked like a file name and was ignored.
        case metadataTitleIgnored
        /// The file is protected and was not read.
        case protectedContent
        /// Nothing speakable was found at all.
        case empty
        /// Content deliberately left out of the reading (code blocks in Markdown).
        case contentSkipped
    }

    public var kind: Kind
    /// Page numbers (1-based) the warning concerns, when it concerns pages.
    public var pages: [Int]
    public var detail: String?

    public init(_ kind: Kind, pages: [Int] = [], detail: String? = nil) {
        self.kind = kind
        self.pages = pages
        self.detail = detail
    }
}

/// What extraction removed or repaired. Pinned by tests against the sample's measured numbers
/// (`specs/document-clippings.md`, *The sample, measured*).
public struct ExtractionStats: Codable, Sendable, Equatable {
    public var pages: Int = 0
    public var removedPageNumbers: Int = 0
    public var removedRunningLines: Int = 0
    public var joinedHyphens: Int = 0
    public var keptHyphens: Int = 0
    /// How paragraph boundaries were found: by indentation, blank lines, or short last lines.
    public var paragraphRule: ParagraphRule = .blankLines

    public init() {}
}

public enum ParagraphRule: String, Codable, Sendable {
    case indentation, blankLines, shortLastLine
    /// The file marks its own paragraphs (HTML, EPUB).
    case markup
}
