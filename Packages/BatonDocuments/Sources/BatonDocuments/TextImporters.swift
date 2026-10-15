import Foundation

/// Plain text: a single "page" through the layout importer, without page furniture removal
/// (there are no pages), after stripping a Project Gutenberg wrapper when there is one.
///
/// Gutenberg is singled out because it is where most public-domain books a person will hand
/// Baton come from, and its licence header and footer are several minutes of legal text that
/// nobody wants read as chapter one.
public enum PlainTextImporter {
    public static func read(_ text: String) -> LayoutTextImporter.Result {
        let (body, header) = stripGutenberg(text)
        var result = LayoutTextImporter(removesPageFurniture: false).extract(pages: [body])
        if let title = header.title { result.title = title }
        if let author = header.author { result.author = author }
        if !result.foundHeadings, result.chapters.count == 1, let title = header.title {
            result.chapters[0].title = title
        }
        return result
    }

    struct GutenbergHeader { var title: String?; var author: String? }

    static func stripGutenberg(_ text: String) -> (body: String, header: GutenbergHeader) {
        guard let start = text.range(of: #"\*\*\*\s*START OF (THE|THIS) PROJECT GUTENBERG EBOOK[^\n]*\n"#,
                                     options: [.regularExpression, .caseInsensitive]) else {
            return (text, GutenbergHeader())
        }
        let preamble = String(text[..<start.lowerBound])
        var header = GutenbergHeader()
        header.title = LayoutTextImporter.firstMatch(#"(?m)^Title:\s*(.+)$"#, preamble)?[1]
            .trimmingCharacters(in: .whitespaces)
        header.author = LayoutTextImporter.firstMatch(#"(?m)^Author:\s*(.+)$"#, preamble)?[1]
            .trimmingCharacters(in: .whitespaces)
        var body = text[start.upperBound...]
        if let end = body.range(of: #"\*\*\*\s*END OF (THE|THIS) PROJECT GUTENBERG EBOOK"#,
                                options: [.regularExpression, .caseInsensitive]) {
            body = body[..<end.lowerBound]
        }
        return (String(body), header)
    }
}

/// Markdown: headings are chapters, markup is removed, code is left out.
///
/// The chapter level is the shallowest heading level that occurs at least twice, so a note with
/// one `# Title` and several `## Sections` gets the sections as chapters and the title as the
/// book's title. Deeper headings become short paragraphs of their own, which is how a person
/// reading aloud would treat a subheading.
public enum MarkdownImporter {
    public static func read(_ text: String, fallbackTitle: String) -> (result: LayoutTextImporter.Result, skippedCode: Int) {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        // Front matter (YAML between --- lines at the very top).
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            lines.removeSubrange(0...end)
        }

        var skippedCode = 0
        var inFence = false
        var kept: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") || line.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") {
                if !inFence { skippedCode += 1 }
                inFence.toggle()
                continue
            }
            if !inFence { kept.append(line) }
        }

        let headings = kept.compactMap { line -> Int? in
            guard let m = LayoutTextImporter.firstMatch(#"^(#{1,6})\s+\S"#, line) else { return nil }
            return m[1].count
        }
        let counts = Dictionary(grouping: headings, by: { $0 }).mapValues(\.count)
        let chapterLevel = counts.filter { $0.value >= 2 }.keys.min()

        var title: String?
        var chapters: [DocumentChapter] = []
        var current: (title: String, paragraphs: [String])? = nil
        var paragraph: [String] = []

        func flushParagraph() {
            let text = LayoutTextImporter.collapse(paragraph.joined(separator: " "))
            if !text.isEmpty {
                if current == nil { current = (title ?? fallbackTitle, []) }
                current!.paragraphs.append(text)
            }
            paragraph.removeAll()
        }
        func flushChapter() {
            flushParagraph()
            if let c = current, !c.paragraphs.isEmpty {
                chapters.append(DocumentChapter(index: chapters.count, title: c.title, paragraphs: c.paragraphs))
            }
            current = nil
        }

        for line in kept {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let m = LayoutTextImporter.firstMatch(#"^(#{1,6})\s+(.+?)\s*#*$"#, trimmed) {
                let level = m[1].count
                let text = stripInline(m[2])
                if level == chapterLevel {
                    flushChapter()
                    current = (text, [])
                } else if title == nil, chapters.isEmpty, current == nil, paragraph.isEmpty,
                          chapterLevel.map({ level < $0 }) ?? true {
                    title = text
                } else {
                    flushParagraph()
                    paragraph = [text.hasSuffix(".") ? text : text + "."]
                    flushParagraph()
                }
                continue
            }
            if trimmed.isEmpty || trimmed.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                flushParagraph()
                continue
            }
            // A list item or a table row is its own paragraph.
            if trimmed.range(of: #"^([-*+]|\d{1,3}[.)])\s+"#, options: .regularExpression) != nil
                || trimmed.hasPrefix("|") {
                flushParagraph()
                if trimmed.range(of: #"^\|?\s*:?-{3,}"#, options: .regularExpression) != nil { continue }
                paragraph = [stripInline(trimmed
                    .replacingOccurrences(of: #"^([-*+]|\d{1,3}[.)])\s+"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "|", with: ", "))]
                flushParagraph()
                continue
            }
            paragraph.append(stripInline(trimmed.replacingOccurrences(of: #"^>\s?"#, with: "", options: .regularExpression)))
        }
        flushChapter()

        var stats = ExtractionStats()
        stats.pages = 1
        stats.paragraphRule = .blankLines
        let result = LayoutTextImporter.Result(title: title ?? fallbackTitle, author: nil, frontMatter: [],
                                               chapters: chapters, stats: stats, foundHeadings: chapterLevel != nil)
        return (result, skippedCode)
    }

    /// Markup off, words kept: links keep their text, images go, emphasis and code ticks go.
    static func stripInline(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\[([^\]]+)\]\[[^\]]*\]"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(\*\*|__)(.+?)\1"#, with: "$2", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?<![\w*])[*_](?!\s)(.+?)(?<!\s)[*_](?![\w*])"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "`", with: "")
        out = out.replacingOccurrences(of: #"~~(.+?)~~"#, with: "$1", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }
}
