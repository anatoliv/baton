import Foundation

/// Page text in, structure out: the shared core of every paged importer (PDF, OCR).
///
/// A page of extracted text is a printed page's furniture plus a book's paragraphs, wrapped
/// at the margin. The listener wants only the book. This removes page numbers and running
/// heads, re-flows wrapped lines into paragraphs, re-joins words broken across lines, finds
/// chapters and the title page, and reports what it did (`ExtractionStats`), so the numbers
/// measured on the sample (24 page numbers, 22 hyphen breaks, 3 chapters) are test fixtures.
///
/// The rules come from the dialogue-cast proof of concept (`specs/poc/dialogue-cast/`), where
/// they were measured against `pdftotext -layout`. PDFKit's `page.string` has no indentation,
/// which on the sample merged 60 of 294 paragraphs (Phase 0), so the PDF importer lays each
/// page out from its line positions first (`layoutText(ofPages:)`), and the text arrives here
/// in the same shape. The short-last-line rule remains for text that has no indentation at all.
public struct LayoutTextImporter: Sendable {
    /// Chapter titles the file itself declares (a PDF outline). A line equal to one of them is
    /// a heading whatever it looks like.
    public var declaredHeadings: [String] = []
    /// Tiebreak for a line-end hyphen the document's own vocabulary cannot decide: is this a
    /// real word? `nil` means "don't know". On Apple platforms the PDF importer passes a spell
    /// checker; on Linux there is none, and the vocabulary alone decides.
    public var isWord: (@Sendable (String) -> Bool?)?
    /// Off for text that never had pages (a `.txt` file), where a last line of "1984" is text.
    public var removesPageFurniture: Bool

    public init(declaredHeadings: [String] = [], isWord: (@Sendable (String) -> Bool?)? = nil,
                removesPageFurniture: Bool = true) {
        self.declaredHeadings = declaredHeadings
        self.isWord = isWord
        self.removesPageFurniture = removesPageFurniture
    }

    public struct Result: Sendable, Equatable {
        public var title: String?
        public var author: String?
        public var frontMatter: [String]
        public var chapters: [DocumentChapter]
        public var stats: ExtractionStats
        public var foundHeadings: Bool
    }

    // MARK: - Lines

    struct Line: Equatable {
        var text: String          // trailing whitespace removed, leading kept
        var page: Int             // 0-based
        var isBlank: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
        var indent: Int { text.prefix { $0 == " " || $0 == "\t" }.count }
        var trimmed: String { text.trimmingCharacters(in: .whitespaces) }
    }

    public func extract(pages: [String]) -> Result {
        var stats = ExtractionStats()
        stats.pages = pages.count
        var lines: [Line] = []
        for (index, page) in pages.enumerated() {
            for raw in page.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
                var text = String(raw)
                while let last = text.last, last == " " || last == "\t" { text.removeLast() }
                lines.append(Line(text: Self.cleanGlyphs(text), page: index))
            }
        }

        if removesPageFurniture {
            lines = removeFurniture(lines, pageCount: pages.count, stats: &stats)
        }

        // Vocabulary for de-hyphenation: every word as printed, with line-end breaks left
        // broken, so a joined form only counts where the document prints it whole.
        var vocabulary: [String: Int] = [:]
        for line in lines where !line.isBlank {
            for word in Self.words(in: line.trimmed) { vocabulary[word, default: 0] += 1 }
        }

        let headingAt = findHeadings(lines)
        let firstHeading = headingAt.keys.min()

        // Title page: what precedes the first heading on the first page, or the first few
        // lines when there are no headings at all.
        var title: String?
        var author: String?
        var frontMatter: [String] = []
        var bodyStart = 0
        let frontEnd = firstHeading ?? min(lines.count, frontMatterScanLimit(lines))
        for i in 0..<frontEnd {
            let line = lines[i]
            if line.isBlank { continue }
            if firstHeading == nil && line.page > 0 { break }
            let text = line.trimmed
            if title == nil, text.count <= 100, !Self.endsSentence(text) {
                title = text
            } else if author == nil, let by = Self.byline(text) {
                author = by
            } else if firstHeading != nil {
                frontMatter.append(text)
            } else {
                break   // no headings: the first ordinary line is the start of the text
            }
            bodyStart = i + 1
        }
        if firstHeading == nil, title == nil { bodyStart = 0 }
        if let firstHeading { bodyStart = firstHeading }

        let bodyText = (bodyStart..<lines.count).filter { headingAt[$0] == nil }.map { lines[$0] }
        let rule = paragraphRule(for: bodyText)
        stats.paragraphRule = rule
        let medianLength = Self.median(bodyText.filter { !$0.isBlank }.map { $0.trimmed.count })

        var chapters: [DocumentChapter] = []
        var paragraph: [String] = []
        var paragraphs: [String] = []
        var currentTitle: (label: String?, title: String)? = nil

        func flushParagraph() {
            let text = Self.collapse(paragraph.joined(separator: " "))
            if !text.isEmpty { paragraphs.append(text) }
            paragraph.removeAll()
        }
        func flushChapter() {
            flushParagraph()
            if !paragraphs.isEmpty || currentTitle != nil {
                chapters.append(DocumentChapter(index: chapters.count,
                                                title: currentTitle?.title ?? title ?? "",
                                                paragraphs: paragraphs,
                                                label: currentTitle?.label))
            }
            paragraphs.removeAll()
        }

        var i = bodyStart
        var previousEndedParagraph = false
        while i < lines.count {
            let line = lines[i]
            if let heading = headingAt[i] {
                flushChapter()
                currentTitle = (heading.label, heading.title)
                i += heading.consumedLines
                previousEndedParagraph = true
                continue
            }
            if line.isBlank {
                if rule == .blankLines, !paragraph.isEmpty, !Self.isPageBreak(at: i, in: lines) {
                    flushParagraph()
                }
                i += 1
                continue
            }
            let text = line.trimmed
            let startsParagraph: Bool
            switch rule {
            case .indentation: startsParagraph = line.indent >= 2 && line.indent < 8
            case .blankLines, .markup: startsParagraph = false
            case .shortLastLine: startsParagraph = previousEndedParagraph
            }
            if startsParagraph { flushParagraph() }

            if let last = paragraph.last, let joined = joinHyphen(last, text, vocabulary: vocabulary, stats: &stats) {
                paragraph[paragraph.count - 1] = joined
            } else {
                paragraph.append(text)
            }
            previousEndedParagraph = rule == .shortLastLine
                && Double(text.count) < Double(medianLength) * 0.75
                && Self.endsSentence(text)
            i += 1
        }
        flushChapter()

        if headingAt.isEmpty, chapters.count == 1 {
            chapters[0].title = title ?? chapters[0].title
        }
        return Result(title: title, author: author, frontMatter: frontMatter,
                      chapters: chapters.filter { !$0.paragraphs.isEmpty },
                      stats: stats, foundHeadings: !headingAt.isEmpty)
    }

    private func frontMatterScanLimit(_ lines: [Line]) -> Int {
        var count = 0
        for (i, line) in lines.enumerated() where !line.isBlank {
            count += 1
            if count > 6 { return i }
        }
        return lines.count
    }

    // MARK: - Furniture

    /// Page numbers and running heads/feet, recognized by *position* (the first or last two
    /// lines of a page) and, for running lines, by *repetition* across pages. Never by content
    /// alone: a line of dialogue can be "Four." and a book can quote its own title.
    func removeFurniture(_ lines: [Line], pageCount: Int, stats: inout ExtractionStats) -> [Line] {
        // Page numbers may sit one line in from the edge (under a running head, over a
        // footnote rule); running heads and feet are the outermost line itself.
        var edge = Set<Int>()
        var outermost = Set<Int>()
        var byPage: [Int: [Int]] = [:]
        for (i, line) in lines.enumerated() where !line.isBlank { byPage[line.page, default: []].append(i) }
        for indices in byPage.values {
            edge.formUnion(indices.prefix(2))
            edge.formUnion(indices.suffix(2))
            if let first = indices.first { outermost.insert(first) }
            if let last = indices.last { outermost.insert(last) }
        }

        var runningPages: [String: Set<Int>] = [:]
        for i in outermost {
            let key = Self.runningKey(lines[i].trimmed)
            guard !key.isEmpty, lines[i].trimmed.count <= 80 else { continue }
            runningPages[key, default: []].insert(lines[i].page)
        }
        let threshold = max(3, Int((Double(pageCount) * 0.4).rounded(.up)))
        let running = Set(runningPages.filter { $0.value.count >= threshold }.keys)

        var out: [Line] = []
        for (i, line) in lines.enumerated() {
            if edge.contains(i) {
                if Self.isPageNumber(line.trimmed) {
                    stats.removedPageNumbers += 1
                    continue
                }
                if outermost.contains(i), running.contains(Self.runningKey(line.trimmed)) {
                    stats.removedRunningLines += 1
                    continue
                }
            }
            out.append(line)
        }
        return out
    }

    static func isPageNumber(_ text: String) -> Bool {
        text.range(of: #"^[-\u2013\u2014\s]*\d{1,4}[-\u2013\u2014\s]*$"#, options: .regularExpression) != nil
            || text.range(of: #"^[ivxlcdm]{1,7}$"#, options: .regularExpression) != nil
            || text.range(of: #"^(?i:page)\s+\d{1,4}(\s+(?i:of)\s+\d{1,4})?$"#, options: .regularExpression) != nil
    }

    /// A running head with its page number stripped, so "THE MACHINE STOPS 7" and
    /// "THE MACHINE STOPS 8" are the same line.
    static func runningKey(_ text: String) -> String {
        let lower = text.lowercased()
            .replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // A bare number is a page number, handled separately; it is not a running line.
        return lower == "#" ? "" : lower
    }

    // MARK: - Headings

    struct Heading: Equatable {
        var label: String?
        var title: String
        var consumedLines: Int
    }

    private static let spelledNumbers = ["one", "two", "three", "four", "five", "six", "seven", "eight",
                                         "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
                                         "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]

    func findHeadings(_ lines: [Line]) -> [Int: Heading] {
        var found: [Int: Heading] = [:]
        var numbered: [(index: Int, number: Int, title: String)] = []
        let declared = Set(declaredHeadings.map { Self.collapse($0).lowercased() })

        for (i, line) in lines.enumerated() where !line.isBlank {
            let text = line.trimmed
            // A heading stands alone: flush left (or centred far in), short, not a sentence.
            let placed = line.indent < 2 || line.indent >= 8
            guard placed, text.count <= 70 else { continue }

            if !declared.isEmpty, declared.contains(Self.collapse(text).lowercased()) {
                found[i] = Heading(label: nil, title: text, consumedLines: 1)
                continue
            }
            // "Chapter IV", "CHAPTER 4: The Storm", "Part One", "Book II."
            if let m = Self.firstMatch(#"(?i)^(chapter|chap\.|book|part)\s+([0-9]{1,3}|[ivxlcdm]{1,8}|[a-z]+)\b[.:]?\s*(.*)$"#, text),
               m[2].range(of: #"^([0-9]{1,3}|[ivxlcdmIVXLCDM]{1,8})$"#, options: .regularExpression) != nil
                || Self.spelledNumbers.contains(m[2].lowercased()) {
                var title = m[3].trimmingCharacters(in: .whitespaces)
                var consumed = 1
                if title.isEmpty, let next = nextTitleLine(after: i, in: lines) {
                    title = next.text
                    consumed = next.offset + 1
                }
                let label = "\(m[1].prefix(1).uppercased())\(m[1].dropFirst().lowercased()) \(m[2])"
                found[i] = Heading(label: label, title: title.isEmpty ? label : title, consumedLines: consumed)
                continue
            }
            // A Roman numeral alone ("IV", "XII."): chapter numbering in a great many books.
            if let m = Self.firstMatch(#"^([IVXLCDM]{1,8})\.?$"#, text) {
                var title = m[1]
                var consumed = 1
                if let next = nextTitleLine(after: i, in: lines) {
                    title = next.text
                    consumed = next.offset + 1
                }
                found[i] = Heading(label: m[1], title: title, consumedLines: consumed)
                continue
            }
            // "1 The Air-Ship", "2. The Mending Apparatus": accepted only as a sequence below.
            if let m = Self.firstMatch(#"^(\d{1,3})\.?\s{1,4}(\p{Lu}[^.!?]{0,60})$"#, text),
               let n = Int(m[1]), !Self.endsSentence(m[2]) {
                numbered.append((i, n, m[2].trimmingCharacters(in: .whitespaces)))
            }
        }

        // Numbered headings look exactly like a numbered list item, so they count only as a
        // run of at least two that climbs (1, 2, 3...). A lone "3 Eggs" in a recipe is text.
        if numbered.count >= 2 {
            let ascending = zip(numbered, numbered.dropFirst()).allSatisfy { $1.number > $0.number }
            if ascending {
                for entry in numbered where found[entry.index] == nil {
                    found[entry.index] = Heading(label: String(entry.number), title: entry.title, consumedLines: 1)
                }
            }
        }
        return found
    }

    /// The line after a bare "Chapter IV" or "IV" that names the chapter, if it looks like a
    /// name: short, not a sentence, and set apart (followed by text, not continuing one).
    private func nextTitleLine(after index: Int, in lines: [Line]) -> (text: String, offset: Int)? {
        var j = index + 1
        while j < lines.count, lines[j].isBlank { j += 1 }
        guard j < lines.count else { return nil }
        let text = lines[j].trimmed
        guard text.count <= 60, !Self.endsSentence(text), lines[j].indent < 2 || lines[j].indent >= 8,
              let first = text.first, first.isUppercase else { return nil }
        // A title is followed by the chapter's text, which is longer than it.
        var k = j + 1
        while k < lines.count, lines[k].isBlank { k += 1 }
        guard k < lines.count, lines[k].trimmed.count > text.count else { return nil }
        return (text, j - index)
    }

    // MARK: - Paragraphs

    /// Pick how this document marks paragraphs. Layout extraction indents every paragraph's
    /// first line; plain extraction often separates them with blank lines; PDFKit may give
    /// neither, and then a line that stops well short of the margin and ends a sentence is
    /// the last line of a paragraph.
    func paragraphRule(for lines: [Line]) -> ParagraphRule {
        let text = lines.filter { !$0.isBlank }
        guard !text.isEmpty else { return .blankLines }
        let indented = text.filter { $0.indent >= 2 && $0.indent < 8 }.count
        if Double(indented) / Double(text.count) >= 0.03 { return .indentation }
        var blanksBetweenText = 0
        for i in 1..<max(1, lines.count - 1) where lines[i].isBlank && !lines[i - 1].isBlank && !lines[i + 1].isBlank
            && lines[i - 1].page == lines[i + 1].page {
            blanksBetweenText += 1
        }
        if Double(blanksBetweenText) / Double(text.count) >= 0.03 { return .blankLines }
        return .shortLastLine
    }

    static func isPageBreak(at index: Int, in lines: [Line]) -> Bool {
        var before = index - 1
        while before >= 0, lines[before].isBlank { before -= 1 }
        var after = index + 1
        while after < lines.count, lines[after].isBlank { after += 1 }
        guard before >= 0, after < lines.count else { return false }
        return lines[before].page != lines[after].page
    }

    // MARK: - Hyphens

    /// Join `previous` (ending in a hyphen) with `next`, or return nil when there is no hyphen
    /// to resolve. The document's own vocabulary decides: a break is joined when the joined
    /// word occurs elsewhere and kept when the hyphenated compound does. On a tie the spell
    /// checker (if any) decides, and failing that the break is joined, because a line-end
    /// hyphen is far more often a typesetter's break than a compound that happens to wrap.
    func joinHyphen(_ previous: String, _ next: String, vocabulary: [String: Int],
                    stats: inout ExtractionStats) -> String? {
        if previous.hasSuffix("\u{00AD}") {   // soft hyphen: always a break
            stats.joinedHyphens += 1
            return String(previous.dropLast()) + next
        }
        guard previous.hasSuffix("-"),
              let leftRange = previous.range(of: #"[\p{L}]+-$"#, options: .regularExpression),
              let rightRange = next.range(of: #"^[\p{L}]+"#, options: .regularExpression) else { return nil }
        let left = String(previous[leftRange].dropLast())
        let right = String(next[rightRange])
        // "well-" + "known" where "well-known" is printed elsewhere, or a dash used as
        // punctuation ("—" is not a hyphen and never reaches here).
        let joined = (left + right).lowercased()
        let compound = "\(left)-\(right)".lowercased()
        let asOne = vocabulary[joined] ?? 0
        let asCompound = vocabulary[compound] ?? 0
        var keep = asCompound > asOne
        if asOne == 0, asCompound == 0, let isWord {
            if isWord(joined) == false, isWord(left.lowercased()) == true, isWord(right.lowercased()) == true {
                keep = true
            }
        }
        if keep {
            stats.keptHyphens += 1
            return previous + next
        }
        stats.joinedHyphens += 1
        return String(previous.dropLast()) + next
    }

    // MARK: - Small helpers

    static func words(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"[\p{L}]+(?:-[\p{L}]+)*"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).lowercased()
        }
    }

    static func firstMatch(_ pattern: String, _ text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func endsSentence(_ text: String) -> Bool {
        text.range(of: #"[.!?,;:][”’"')\]]*$"#, options: .regularExpression) != nil
    }

    static func byline(_ text: String) -> String? {
        guard let m = firstMatch(#"^(?i:by)\s+(.{2,80})$"#, text) else { return nil }
        return m[1].trimmingCharacters(in: .whitespaces)
    }

    static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Ligatures and invisible marks that extraction leaves in and a TTS engine stumbles on.
    static func cleanGlyphs(_ text: String) -> String {
        var out = text
        for (glyph, letters) in [("\u{FB00}", "ff"), ("\u{FB01}", "fi"), ("\u{FB02}", "fl"),
                                 ("\u{FB03}", "ffi"), ("\u{FB04}", "ffl"), ("\u{FB05}", "st"), ("\u{FB06}", "st")] {
            out = out.replacingOccurrences(of: glyph, with: letters)
        }
        out = out.replacingOccurrences(of: "\u{200B}", with: "")   // zero-width space
        out = out.replacingOccurrences(of: "\u{00A0}", with: " ")  // no-break space
        out = out.replacingOccurrences(of: "\t", with: "    ")
        return out
    }

    static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
