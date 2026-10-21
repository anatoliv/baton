import Foundation

/// A web page or HTML file turned into chapters of paragraphs: the article, not the page.
///
/// A page is mostly not the thing a person wants read: menus, cookie banners, share buttons,
/// "related stories", comments. The reading is found the way reader modes find it, in a
/// small way: drop what is plainly furniture (scripts, navigation, headers, footers, asides,
/// forms, hidden elements, and anything whose class or id says sidebar, share, comments...),
/// prefer an `<article>` or `<main>` when the page has one that holds the text, and otherwise
/// score each container by the paragraphs in it (length and commas, as Readability does) and
/// take the best, with any sibling that scores close to it. Paragraphs that are mostly links
/// (a table of contents, a list of related links) are left out.
///
/// Headings become chapters the way Markdown's do: the shallowest level that occurs at least
/// twice. A whole book saved as HTML (Project Gutenberg's HTML edition, say) is one page whose
/// `<h2>`s are its chapters, and comes out as chapters; an article with one `<h1>` is one
/// chapter under its title.
///
/// Tables, code and figures are left out and said so on the import sheet: read aloud, a table
/// is a list of numbers with no columns, and the person should know the book has a gap.
public enum HTMLImporter {
    public struct Output: Sendable, Equatable {
        public var result: LayoutTextImporter.Result
        /// The page's declared language (`<html lang>`), when it has one.
        public var language: String?
        public var warnings: [ImportWarning]
        /// The region declared with it ("gb" for `lang="en-GB"`).
        public var languageRegion: String? = nil
    }

    public static func read(_ html: String, fallbackTitle: String) -> Output {
        let document = HTMLParser.parse(html)
        let head = document.first(named: "head")
        let body = document.first(named: "body") ?? document
        let metadata = Metadata(document: document, head: head)

        var skipped = Skipped()
        // Headings are read before furniture goes, because an article's title often lives in a
        // `<header>` that is about to be removed.
        let allH1 = body.descendants(named: ["h1"]).map(BlockWalker.headingText).filter { !$0.isEmpty }
        let bylineAuthor = Self.bylineAuthor(in: body)
        let scripts = document.descendants(named: ["script"]).count
        removeFurniture(body)
        let roots = contentRoots(body)

        var walker = BlockWalker()
        for root in roots { walker.walk(root) }
        walker.flush()
        skipped.add(walker.skipped)
        var blocks = trimGutenberg(walker.blocks)
        blocks.removeAll { $0.kind == .paragraph && $0.isMostlyLinks }

        var title = metadata.gutenbergTitle ?? bestTitle(h1s: allH1, metadata: metadata)
        var author = metadata.gutenbergAuthor ?? metadata.author ?? bylineAuthor
        var sections: [String] = []
        var (chapters, frontMatter, foundHeadings) = buildChapters(blocks, title: &title, author: &author, skippedSections: &sections)
        skipped.sections = sections
        if chapters.isEmpty {
            chapters = [DocumentChapter(index: 0, title: title ?? fallbackTitle, paragraphs: [])]
        }

        var stats = ExtractionStats()
        stats.paragraphRule = .markup
        var warnings: [ImportWarning] = []
        if let detail = skipped.detail { warnings.append(ImportWarning(.contentSkipped, detail: detail)) }
        if chapters.allSatisfy({ $0.paragraphs.isEmpty }), scripts >= 3 {
            warnings.append(ImportWarning(.empty, detail: "This page builds its text with JavaScript, which Baton does not run. Save it as a PDF, or open it in your browser's reader view and save that."))
        }
        let result = LayoutTextImporter.Result(title: title, author: author, frontMatter: frontMatter,
                                               chapters: chapters, stats: stats, foundHeadings: foundHeadings)
        return Output(result: result, language: metadata.language, warnings: warnings, languageRegion: metadata.languageRegion)
    }

    // MARK: - Metadata

    struct Metadata {
        var title: String?
        var openGraphTitle: String?
        var siteName: String?
        var author: String?
        var language: String?
        var languageRegion: String?
        var gutenbergTitle: String?
        var gutenbergAuthor: String?

        init(document: HTMLNode, head: HTMLNode?) {
            let scope = head ?? document
            title = scope.first(named: "title")?.textContent.nilIfEmpty
            var metas: [String: String] = [:]
            for meta in document.descendants(named: ["meta"]) {
                guard let key = (meta.attribute("name") ?? meta.attribute("property"))?.lowercased(),
                      let content = meta.attribute("content").map(LayoutTextImporter.collapse), !content.isEmpty,
                      metas[key] == nil else { continue }
                metas[key] = content
            }
            openGraphTitle = metas["dc.title"] ?? metas["og:title"] ?? metas["twitter:title"]
            siteName = metas["og:site_name"] ?? metas["application-name"]
            let creator = metas["author"] ?? metas["dc.creator"] ?? metas["dcterms.creator"]
                ?? metas["article:author"].flatMap { $0.hasPrefix("http") ? nil : $0 }
            author = creator.map(HTMLImporter.personName)
            if let lang = document.first(named: "html")?.attribute("lang") ?? document.first(named: "html")?.attribute("xml:lang") {
                (language, languageRegion) = LanguageTag.split(lang)
            }
            // "The Project Gutenberg eBook of The Machine Stops, by E. M. Forster"
            if let t = title,
               let m = LayoutTextImporter.firstMatch(#"(?i)^the project gutenberg e-?book of\s+(.+?)(?:,\s+by\s+(.+))?$"#, t) {
                gutenbergTitle = m[1]
                gutenbergAuthor = m[2].nilIfEmpty
            }
        }
    }

    /// "Forster, E. M. (Edward Morgan), 1879-1970" → "E. M. Forster"; "By Jane Doe" → "Jane Doe".
    static func personName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #",?\s*\d{3,4}\s*-\s*(\d{3,4})?\s*$"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"(?i)^by\s+"#, with: "", options: .regularExpression)
        name = LayoutTextImporter.collapse(name)
        let parts = name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, !parts[0].contains(" ") || parts[1].contains(".") {
            return "\(parts[1]) \(parts[0])"
        }
        return name
    }

    /// The title the page declares for sharing (Dublin Core, Open Graph), which is written for
    /// people and has no site name; then a lone `<h1>`; then the document title without its
    /// site name: "Article | Site" is the usual order, so the first part, unless the first
    /// part is the site's declared name.
    static func bestTitle(h1s: [String], metadata: Metadata) -> String? {
        let h1 = h1s.count == 1 ? h1s[0] : nil
        // "The Machine Stops - Wikipedia" holds the page's one heading and more: the heading.
        if let h1, let declared = metadata.openGraphTitle ?? metadata.title, declared.count > h1.count,
           declared.lowercased().contains(h1.lowercased()) { return h1 }
        if let og = metadata.openGraphTitle { return og }
        if let h1 { return h1 }
        guard let title = metadata.title else { return h1s.first }
        guard let separator = [" | ", " - ", " \(Typography.enDash) ", " \(Typography.emDash) ", " \u{00B7} ", " :: "]
            .first(where: { title.contains($0) }) else { return title }
        let parts = title.components(separatedBy: separator).map(LayoutTextImporter.collapse).filter { !$0.isEmpty }
        let site = metadata.siteName?.lowercased()
        return parts.first { $0.lowercased() != site } ?? title
    }

    static func bylineAuthor(in body: HTMLNode) -> String? {
        for node in body.descendants() {
            let rel = node.attribute("rel")?.lowercased()
            let itemprop = node.attribute("itemprop")?.lowercased()
            let cls = (node.attribute("class") ?? "").lowercased()
            if rel == "author" || itemprop == "author" || cls.range(of: #"\b(byline|author)\b"#, options: .regularExpression) != nil {
                let text = node.textContent
                if text.count >= 3, text.count <= 80 { return personName(text) }
            }
        }
        return nil
    }

    // MARK: - Furniture

    static let furnitureElements: Set<String> = ["script", "style", "noscript", "template", "svg", "math", "iframe",
                                                 "object", "embed", "canvas", "form", "button", "select", "input",
                                                 "textarea", "nav", "aside", "header", "footer", "menu", "dialog",
                                                 "head", "audio", "video", "map"]
    static let furnitureRoles: Set<String> = ["navigation", "banner", "complementary", "contentinfo", "search",
                                              "dialog", "alert", "menu", "menubar", "toolbar"]

    static let negativeName = #"(?i)(^|[^a-z0-9])(comments?|sidebar|share|sharing|social|related|promo|advert|ads?|sponsored|cookies?|newsletter|subscribe|signup|footer|navbar|nav|menu|breadcrumbs?|masthead|banner|popup|modal|skip-link|toolbar|pagination|pg-header|pg-footer|pg-boilerplate|noprint|hatnote|navbox|mw-editsection|mw-jump-link|catlinks|printfooter|sitesub|toc)([^a-z0-9]|$)"#
    static let positiveName = #"(?i)(^|[^a-z0-9])(article|content|entry|post|main|story|chapter|text|body|prose)([^a-z0-9]|$)"#

    /// In a book (EPUB) a `<header>` holds the chapter's heading and an `<aside>` a footnote,
    /// so only what is never prose goes.
    static let bookFurnitureElements: Set<String> = ["script", "style", "noscript", "template", "svg", "math", "iframe",
                                                     "object", "embed", "canvas", "form", "button", "select", "input",
                                                     "textarea", "nav", "aside", "head", "audio", "video", "map"]

    static func isFurniture(_ node: HTMLNode, book: Bool = false) -> Bool {
        if book {
            if bookFurnitureElements.contains(node.name) { return true }
            if node.attributes["hidden"] != nil || node.attribute("aria-hidden")?.lowercased() == "true" { return true }
            let names = [node.attribute("class"), node.attribute("id")].compactMap { $0 }.joined(separator: " ")
            return names.range(of: #"pg-(header|footer|boilerplate)"#, options: .regularExpression) != nil
        }
        if furnitureElements.contains(node.name) { return true }
        if let role = node.attribute("role")?.lowercased(), furnitureRoles.contains(role) { return true }
        if node.attributes["hidden"] != nil || node.attribute("aria-hidden")?.lowercased() == "true" { return true }
        if let style = node.attribute("style")?.lowercased().replacingOccurrences(of: " ", with: ""),
           style.contains("display:none") || style.contains("visibility:hidden") { return true }
        let names = [node.attribute("class"), node.attribute("id")].compactMap { $0 }.joined(separator: " ")
        if !names.isEmpty, names.range(of: negativeName, options: .regularExpression) != nil,
           names.range(of: positiveName, options: .regularExpression) == nil
            // Gutenberg's own wrappers are furniture whatever else they are called.
            || names.range(of: #"pg-(header|footer|boilerplate)"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    static func removeFurniture(_ root: HTMLNode, book: Bool = false) {
        for node in root.descendants() where node.parent != nil && isFurniture(node, book: book) {
            node.detach()
        }
    }

    // MARK: - Choosing the content

    /// Text in paragraph-like leaves under `node`.
    static func paragraphLength(_ node: HTMLNode) -> Int {
        node.descendants(named: ["p", "li", "blockquote", "dd", "pre"]).reduce(0) { $0 + ownTextLength($1) }
            + (["p", "li", "blockquote"].contains(node.name) ? ownTextLength(node) : 0)
    }

    private static func ownTextLength(_ node: HTMLNode) -> Int {
        node.children.reduce(0) { total, child in
            child.kind == .text ? total + child.text.trimmingCharacters(in: .whitespacesAndNewlines).count
                : (["p", "li", "blockquote", "dd", "pre", "div", "section"].contains(child.name) ? total : total + ownTextLength(child))
        }
    }

    static func contentRoots(_ body: HTMLNode) -> [HTMLNode] {
        let total = paragraphLength(body)
        guard total > 0 else { return [body] }

        // An <article> or <main> that holds most of the text is the content.
        for names in [["article"], ["main"]] {
            let found = body.descendants(named: Set(names)) + (names == ["main"] ? body.descendants().filter { $0.attribute("role") == "main" } : [])
            let holding = found.filter { Double(paragraphLength($0)) >= 0.5 * Double(total) }
            if let best = holding.max(by: { paragraphLength($0) < paragraphLength($1) }) { return [best] }
        }

        // Readability's score: each paragraph gives its parent 1 + commas + length/100 (at most
        // 3), and its grandparent half that.
        var scores: [ObjectIdentifier: (node: HTMLNode, score: Double)] = [:]
        for p in body.descendants(named: ["p", "pre", "blockquote"]) {
            let text = p.textContent
            guard text.count >= 25 else { continue }
            let score = 1 + Double(text.filter { $0 == "," }.count) + min(Double(text.count) / 100, 3)
            if let parent = p.parent { add(parent, score, to: &scores) }
            if let grand = p.parent?.parent { add(grand, score / 2, to: &scores) }
        }
        guard let top = scores.values.max(by: { $0.score < $1.score }) else { return [body] }

        // Siblings that score near the top are the same article split into blocks, and a
        // sibling with the top's own class is the next of the same thing (a book's
        // `<div class="chapter">`s), however short.
        guard let parent = top.node.parent else { return [top.node] }
        let threshold = max(10, top.score * 0.2)
        let topClass = top.node.attribute("class")
        var roots: [HTMLNode] = []
        for sibling in parent.children where sibling.kind == .element {
            if sibling === top.node { roots.append(sibling); continue }
            if let topClass, !topClass.isEmpty, sibling.name == top.node.name, sibling.attribute("class") == topClass {
                roots.append(sibling); continue
            }
            if let s = scores[ObjectIdentifier(sibling)], s.score >= threshold { roots.append(sibling); continue }
            if sibling.name == "p", sibling.textContent.count >= 80, !Block.mostlyLinks(sibling) { roots.append(sibling) }
        }
        // Content that sits directly in the body and holds most of its text is a book laid
        // out as one page; what is left beside it, once the furniture is gone, is the
        // book's own setting (its title page, a heading between parts). Then the whole body
        // is read.
        let chosen = roots.reduce(0) { $0 + paragraphLength($1) }
        if parent === body, Double(chosen) >= 0.8 * Double(total) { return [body] }
        return roots
    }

    private static func add(_ node: HTMLNode, _ score: Double, to scores: inout [ObjectIdentifier: (node: HTMLNode, score: Double)]) {
        let id = ObjectIdentifier(node)
        scores[id] = (node, (scores[id]?.score ?? 0) + score)
    }

    // MARK: - Blocks

    struct Block: Equatable {
        enum Kind: Equatable { case heading(Int), paragraph }
        var kind: Kind
        var text: String
        var linkCharacters: Int

        var isMostlyLinks: Bool { text.count > 0 && Double(linkCharacters) >= 0.5 * Double(text.count) }

        static func mostlyLinks(_ node: HTMLNode) -> Bool {
            let all = node.textContent.count
            let links = node.descendants(named: ["a"]).filter { $0.attribute("href") != nil }.reduce(0) { $0 + $1.textContent.count }
            return all > 0 && Double(links) >= 0.5 * Double(all)
        }
    }

    struct Skipped {
        var tables = 0, code = 0, figures = 0
        var sections: [String] = []
        mutating func add(_ other: Skipped) {
            tables += other.tables; code += other.code; figures += other.figures
        }
        var detail: String? {
            var parts = [(tables, "table"), (code, "code block"), (figures, "figure")].compactMap { n, what in
                n > 0 ? "\(n) \(what)\(n == 1 ? "" : "s")" : nil
            }
            if !sections.isEmpty { parts.append("the \(sections.joined(separator: ", ")) section\(sections.count == 1 ? "" : "s")") }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
    }

    static let blockElements: Set<String> = ["p", "div", "section", "article", "main", "body", "li", "ul", "ol",
                                             "blockquote", "dd", "dt", "dl", "center", "address", "hr", "tr",
                                             "td", "th", "figcaption", "details", "summary", "hgroup", "html"]

    /// Walks the content in order and cuts it into headings and paragraphs.
    struct BlockWalker {
        var blocks: [Block] = []
        var skipped = Skipped()
        private var lines: [String] = [""]
        private var linkCharacters = 0
        private var linkDepth = 0
        var inHeading = false
        /// Where each `id` falls: the index of the block it starts or sits in. An EPUB's table
        /// of contents points at these.
        var anchors: [String: Int] = [:]

        /// Printed page numbers ("{23}") and picture captions, which the page shows in the
        /// margin or under a picture and a reader skips.
        static func isMarginalia(_ node: HTMLNode) -> Bool {
            let names = (node.attribute("class") ?? "").lowercased()
            let type = (node.attribute("epub:type") ?? node.attribute("role") ?? "").lowercased()
            return names.range(of: #"(^|[^a-z])(pagenum|pageno|page-?number|pagebreak|caption|headerlink|anchorjs-link|heading-anchor)([^a-z]|$)"#, options: .regularExpression) != nil
                || type.contains("pagebreak")
        }

        /// A node to read, or the end of an element whose children have all been read.
        private enum Step {
            case visit(HTMLNode)
            case leave(isLink: Bool, isBlock: Bool)
        }

        /// In document order, with its own stack rather than recursion: an import runs on a
        /// 512 KB pool thread, and a debug build's frames overflowed it at about 130 levels.
        mutating func walk(_ root: HTMLNode) {
            var work: [Step] = [.visit(root)]
            while let step = work.popLast() {
                switch step {
                case .visit(let node):
                    switch node.kind {
                    case .text:
                        lines[lines.count - 1] += node.text
                        if linkDepth > 0 { linkCharacters += node.text.trimmingCharacters(in: .whitespacesAndNewlines).count }
                    case .document:
                        work.append(contentsOf: node.children.reversed().map(Step.visit))
                    case .element:
                        element(node, &work)
                    }
                case .leave(let isLink, let isBlock):
                    if isLink { linkDepth -= 1 }
                    if isBlock { flush() }
                }
            }
        }

        private mutating func element(_ node: HTMLNode, _ work: inout [Step]) {
            let name = node.name
            if let id = node.attribute("id") ?? (name == "a" ? node.attribute("name") : nil), anchors[id] == nil {
                if HTMLImporter.blockElements.contains(name) || Self.headingLevel(name) != nil { flush() }
                anchors[id] = blocks.count
            }
            switch name {
            case "table":
                // A layout table (one cell per row, prose inside) is read; a data table is not.
                let cells = node.descendants(named: ["td", "th"])
                let rows = node.descendants(named: ["tr"])
                if !rows.isEmpty, cells.count > rows.count {
                    flush()
                    if !Block.mostlyLinks(node) { skipped.tables += 1 }
                    return
                }
                work.append(contentsOf: node.children.reversed().map(Step.visit))
                return
            case "pre":
                flush()
                skipped.code += 1
                return
            case "code":
                // Inline code in a sentence is read; a block of it is not.
                if node.parent?.name != "p", node.textContent.count > 80 {
                    flush()
                    skipped.code += 1
                    return
                }
            case "figure", "picture":
                if name == "figure" { flush(); skipped.figures += 1 }
                return
            case "img":
                // A drop cap is the chapter's first letter set as a picture ("M" + "R. BENNET");
                // a heading set as a picture says what it is in `alt`. Other pictures are
                // not read.
                if let alt = node.attribute("alt").map(Self.clean), !alt.isEmpty,
                   inHeading || (alt.count <= 2 && alt.allSatisfy(\.isLetter)) {
                    lines[lines.count - 1] += alt
                }
                return
            case "rt", "rp":
                return
            case _ where Self.isMarginalia(node):
                return
            case "sup":
                // Footnote markers: "[12]", "12", "*".
                if node.textContent.range(of: #"^\[?[0-9*†‡a-z]{1,4}\]?$"#, options: .regularExpression) != nil { return }
            case "a":
                let type = (node.attribute("epub:type") ?? node.attribute("role") ?? node.attribute("class") ?? "").lowercased()
                if type.contains("noteref") || type.contains("doc-noteref") { return }
            case "br":
                lines.append("")
                return
            default:
                break
            }

            if let level = Self.headingLevel(name) {
                flush()
                for inside in node.descendants() {
                    if let id = inside.attribute("id") ?? inside.attribute("name"), anchors[id] == nil { anchors[id] = blocks.count }
                }
                var inner = BlockWalker()
                inner.inHeading = true
                node.children.forEach { inner.walk($0) }
                let text = inner.lines.map(Self.clean).filter { !$0.isEmpty }.joined(separator: "\n")
                if !text.isEmpty { blocks.append(Block(kind: .heading(level), text: text, linkCharacters: 0)) }
                return
            }

            let isLink = name == "a" && node.attribute("href") != nil
            let isBlock = HTMLImporter.blockElements.contains(name)
            if isBlock { flush() }
            if isLink { linkDepth += 1 }
            work.append(.leave(isLink: isLink, isBlock: isBlock))
            work.append(contentsOf: node.children.reversed().map(Step.visit))
        }

        /// A heading's words as they are read: picture titles in, page numbers and "¶" out.
        static func headingText(_ node: HTMLNode) -> String {
            var inner = BlockWalker()
            inner.inHeading = true
            node.children.forEach { inner.walk($0) }
            return inner.lines.map(clean).filter { !$0.isEmpty }.joined(separator: " ")
        }

        static func headingLevel(_ name: String) -> Int? {
            guard name.count == 2, name.first == "h", let n = Int(name.dropFirst()), (1...6).contains(n) else { return nil }
            return n
        }

        static func clean(_ text: String) -> String {
            LayoutTextImporter.collapse(LayoutTextImporter.cleanGlyphs(text))
        }

        mutating func flush() {
            defer { lines = [""]; linkCharacters = 0 }
            // A blank line (`<br><br>`) inside one block is a paragraph break: older pages set a
            // whole essay in one element that way.
            var groups: [[String]] = [[]]
            for line in lines.map(Self.clean) {
                if line.isEmpty { if !groups[groups.count - 1].isEmpty { groups.append([]) } } else { groups[groups.count - 1].append(line) }
            }
            groups.removeAll { $0.isEmpty }
            guard !groups.isEmpty else { return }
            let total = groups.joined().reduce(0) { $0 + $1.count }
            let links = linkCharacters
            for kept in groups {
                // Verse: several short lines broken by <br>. Each line is its own paragraph, so it
                // gets the pause a reader gives a line end instead of running into the next.
                if kept.count >= 3, kept.allSatisfy({ $0.count <= 70 }) {
                    // A list of links set with <br> is navigation, not verse.
                    if Double(links) >= 0.5 * Double(total) { return }
                    for line in kept { blocks.append(Block(kind: .paragraph, text: line, linkCharacters: 0)) }
                    continue
                }
                let text = kept.joined(separator: " ")
                // The block's link share, spread over its paragraphs by length.
                let share = total > 0 ? Int(Double(links) * Double(text.count) / Double(total)) : 0
                blocks.append(Block(kind: .paragraph, text: text, linkCharacters: share))
            }
        }
    }

    // MARK: - Gutenberg

    /// Gutenberg's HTML edition wraps the book in the same licence text as the plain one. The
    /// newer files put it in `pg-header`/`pg-footer` (removed as furniture); older ones only
    /// have the "*** START OF" and "*** END OF" lines, which this cuts at.
    static func trimGutenberg(_ blocks: [Block]) -> [Block] {
        var out = blocks
        if let start = out.firstIndex(where: { $0.text.range(of: #"(?i)\*\*\*\s*START OF (THE|THIS) PROJECT GUTENBERG"#, options: .regularExpression) != nil }) {
            out.removeSubrange(...start)
        }
        if let end = out.firstIndex(where: { $0.text.range(of: #"(?i)\*\*\*\s*END OF (THE|THIS) PROJECT GUTENBERG"#, options: .regularExpression) != nil }) {
            out.removeSubrange(end...)
        }
        return out
    }

    // MARK: - Chapters

    /// A few short lines that are not sentences: "by", "Jane Austen,", "First published 1909".
    /// Shown on the import sheet, not read.
    static func isTitlePage(_ lines: [String]) -> Bool {
        guard !lines.isEmpty, lines.count <= 15 else { return false }
        let average = lines.reduce(0) { $0 + $1.count } / lines.count
        let sentences = lines.filter { $0.range(of: #"[.!?][\u201D\u2019"')]*$"#, options: .regularExpression) != nil }.count
        return (average <= 40 || lines.count <= 3) && lines.allSatisfy({ $0.count <= 120 }) && sentences * 3 <= lines.count
    }

    /// A heading that is only a numeral ("I.", "3"): it numbers a section, and read aloud
    /// "I." is the word "I".
    static func isBareNumeral(_ text: String) -> Bool {
        text.range(of: #"^([IVXLCDM]{1,8}|[0-9]{1,3})\.?$"#, options: .regularExpression) != nil
    }

    static func isApparatus(_ title: String) -> Bool {
        title.range(of: #"(?i)^(references|notes|footnotes|citations|sources|bibliography|external links|see also|further reading|works cited)\.?$"#,
                    options: .regularExpression) != nil
    }

    static func buildChapters(_ blocks: [Block], title: inout String?, author: inout String?,
                              skippedSections: inout [String])
        -> (chapters: [DocumentChapter], frontMatter: [String], foundHeadings: Bool) {
        var blocks = blocks
        // "by E. M. Forster" set as a heading is the byline, not a chapter.
        blocks.removeAll { block in
            guard case .heading = block.kind, let name = LayoutTextImporter.byline(block.text.replacingOccurrences(of: "\n", with: " ")) else { return false }
            if author == nil { author = personName(name) }
            return true
        }
        let levels = blocks.compactMap { block -> Int? in
            if case .heading(let l) = block.kind, l <= 4 { return l }
            return nil
        }
        let counts = Dictionary(grouping: levels, by: { $0 }).mapValues(\.count)
        let chapterLevel = counts.filter { $0.value >= 2 }.keys.min()

        struct Draft { var title: String; var label: String?; var paragraphs: [String]; var bareLabel: Bool }
        var preface: [String] = []
        var drafts: [Draft] = []

        func addParagraph(_ text: String) {
            if drafts.isEmpty { preface.append(text) } else { drafts[drafts.count - 1].paragraphs.append(text) }
        }

        for block in blocks {
            switch block.kind {
            case .paragraph:
                addParagraph(block.text)
            case .heading(let level):
                let flat = block.text.replacingOccurrences(of: "\n", with: " ")
                if let chapterLevel, level == chapterLevel {
                    let (label, name) = splitHeading(block.text)
                    drafts.append(Draft(title: name ?? label ?? flat, label: label, paragraphs: [], bareLabel: name == nil && label != nil))
                } else if let chapterLevel, level < chapterLevel {
                    if title == nil { title = flat }
                    else if flat.lowercased() != title?.lowercased() { addParagraph(flat) }
                } else if isBareNumeral(flat) {
                    // A numeral alone under a chapter numbers its sections; read aloud, "I." is
                    // the word "I". The paragraph break is pause enough.
                    continue
                } else if var last = drafts.last, last.paragraphs.isEmpty, last.bareLabel {
                    // "CHAPTER I" then a smaller "The Air-Ship": the second names the first.
                    last.title = flat
                    last.bareLabel = false
                    drafts[drafts.count - 1] = last
                } else if chapterLevel == nil, title == nil, level == 1 {
                    title = flat
                } else if flat.lowercased() != title?.lowercased() {
                    addParagraph(flat)
                }
            }
        }

        // A table of contents loses its links above and leaves an empty "Contents" chapter.
        drafts.removeAll { $0.paragraphs.isEmpty || $0.title.range(of: #"(?i)^(table of )?contents\.?$"#, options: .regularExpression) != nil }
        // An article's apparatus at the end is for looking things up, not for listening.
        while drafts.count > 1, let last = drafts.last, isApparatus(last.title) {
            skippedSections.insert(last.title, at: 0)
            drafts.removeLast()
        }

        var frontMatter: [String] = []
        if !drafts.isEmpty, !preface.isEmpty {
            // A few short lines before the first chapter are a title page ("First published
            // 1909"); sentences are an opening, and are read.
            if isTitlePage(preface) {
                frontMatter = preface.filter { $0.lowercased() != title?.lowercased() }
            } else {
                drafts.insert(Draft(title: "", label: nil, paragraphs: preface, bareLabel: false), at: 0)
            }
        } else if drafts.isEmpty {
            drafts = [Draft(title: title ?? "", label: nil, paragraphs: preface, bareLabel: false)]
        }
        let chapters = drafts.enumerated().map { i, d in
            DocumentChapter(index: i, title: d.title, paragraphs: d.paragraphs, label: d.label)
        }
        return (chapters, frontMatter, chapterLevel != nil && chapters.count >= 2)
    }

    /// "CHAPTER IV. The Storm" → ("Chapter IV", "The Storm"); "IV" → ("IV", nil);
    /// "I\nTHE AIR-SHIP" → ("I", "THE AIR-SHIP"); "Introduction" → (nil, "Introduction").
    static func splitHeading(_ heading: String) -> (label: String?, title: String?) {
        let lines = heading.components(separatedBy: "\n")
        let flat = lines.joined(separator: " ")
        if let m = LayoutTextImporter.firstMatch(#"(?i)^(chapter|chap\.|book|part)\s+([0-9]{1,3}|[ivxlcdm]{1,8}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty)\b[.:]?\s*(.*)$"#, flat) {
            let label = "\(m[1].prefix(1).uppercased())\(m[1].dropFirst().lowercased()) \(m[2])"
            let rest = m[3].trimmingCharacters(in: CharacterSet(charactersIn: " .:-\(Typography.emDash)"))
            return (label, rest.isEmpty ? nil : rest)
        }
        if lines.count >= 2, let m = LayoutTextImporter.firstMatch(#"^([IVXLCDM]{1,8}|[0-9]{1,3})\.?$"#, lines[0].trimmingCharacters(in: .whitespaces)) {
            return (m[1], lines.dropFirst().joined(separator: " "))
        }
        if let m = LayoutTextImporter.firstMatch(#"^([IVXLCDM]{1,8}|[0-9]{1,3})\.(?:\s+(.+))?$"#, flat) ?? LayoutTextImporter.firstMatch(#"^([IVXLCDM]{1,8})()$"#, flat) {
            return (m[1], m[2].isEmpty ? nil : m[2])
        }
        return (nil, flat)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
