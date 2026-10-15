import Foundation

/// An EPUB turned into chapters: the spine gives the reading order, the table of contents
/// gives the chapters and their names, and each chapter file is read with the HTML importer's
/// walker.
///
/// Chapters follow the table of contents rather than the files, because the two rarely agree:
/// publishers split long chapters over several files, and Project Gutenberg's EPUBs put several
/// chapters in one file and point at each with an anchor. A file the contents does not name
/// continues the chapter before it. Without a usable contents, the headings decide, as for a
/// web page.
///
/// Protected books are refused, not read: an `encryption.xml` that encrypts anything other
/// than fonts (font obfuscation is not DRM and is common) or an Adobe `rights.xml`
/// (`specs/document-clippings.md`, *No DRM circumvention*).
public enum EPUBImporter {
    public struct Output: Sendable, Equatable {
        public var result: LayoutTextImporter.Result
        public var language: String?
        public var warnings: [ImportWarning]
        /// The region declared with the language ("gb" for `en-GB`).
        public var languageRegion: String? = nil
    }

    static let fontObfuscation: Set<String> = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]

    public static func read(_ data: Data, fallbackTitle: String) throws -> Output {
        let zip: ZipArchive
        do { zip = try ZipArchive(data) } catch {
            throw DocumentImporter.Failure.unreadable("this is not an EPUB Baton can open: \(error)")
        }
        let book = try Package(zip: zip)

        var blocks: [HTMLImporter.Block] = []
        var fileStart: [String: Int] = [:]
        var fileEnd: [String: Int] = [:]
        var anchors: [String: Int] = [:]
        var skipped = HTMLImporter.Skipped()
        for path in book.spine {
            guard fileStart[path] == nil, let bytes = try? zip.contents(of: path) else { continue }
            let document = HTMLParser.parse(HTMLParser.decode(bytes))
            let body = document.first(named: "body") ?? document
            HTMLImporter.removeFurniture(body, book: true)
            var walker = HTMLImporter.BlockWalker()
            walker.walk(body)
            walker.flush()
            skipped.add(walker.skipped)
            fileStart[path] = blocks.count
            for (id, index) in walker.anchors { anchors["\(path)#\(id)"] = blocks.count + index }
            blocks.append(contentsOf: walker.blocks)
            fileEnd[path] = blocks.count
        }

        // Gutenberg's licence and link lists are left out; their places are kept, so the
        // contents' positions still point at the right blocks.
        var excluded = Set<Int>()
        if let start = blocks.firstIndex(where: { $0.text.range(of: #"(?i)\*\*\*\s*START OF (THE|THIS) PROJECT GUTENBERG"#, options: .regularExpression) != nil }) {
            excluded.formUnion(0...start)
        }
        if let end = blocks.firstIndex(where: { $0.text.range(of: #"(?i)\*\*\*\s*END OF (THE|THIS) PROJECT GUTENBERG"#, options: .regularExpression) != nil }) {
            excluded.formUnion(end..<blocks.count)
        }
        for (i, block) in blocks.enumerated() where block.kind == .paragraph && block.isMostlyLinks { excluded.insert(i) }

        var title = book.title
        var author = book.author
        var frontMatter: [String] = []
        var chapters: [DocumentChapter] = []
        var sections: [String] = []

        // Where each contents entry starts. Two entries at one place ("Part One", then its
        // first chapter) become the later, more specific one; an entry pointing backwards is
        // a contents out of order, and is ignored rather than allowed to reorder the book.
        //
        // Cover, title page and copyright are not chapters: each covers its own file, which is
        // left out (and named, when it had words), and is not a start, so an empty cover page
        // cannot swallow the title page after it.
        var starts: [(index: Int, title: String)] = []
        for entry in book.contents {
            // "I", "II" under a story are its sections, not chapters: the paragraph break
            // between them is pause enough.
            if entry.depth > 0, HTMLImporter.isBareNumeral(entry.title) { continue }
            guard let index = entry.fragment.flatMap({ anchors["\(entry.path)#\($0)"] }) ?? fileStart[entry.path] else { continue }
            if isPublisherMatter(entry.title) {
                let range = index..<(fileEnd[entry.path] ?? index)
                if range.contains(where: { !excluded.contains($0) }) { sections.append(entry.title) }
                excluded.formUnion(range)
                continue
            }
            // Entries named like the book, before its first chapter, are its title page
            // ("Frankenstein;", then "or, the Modern Prometheus"). Their lines join the opening.
            if let bookTitle = title, starts.isEmpty, sameTitle(entry.title, bookTitle) { continue }
            if let last = starts.last {
                if index == last.index { starts[starts.count - 1].title = entry.title; continue }
                if index < last.index { continue }
            }
            starts.append((index, entry.title))
        }

        if starts.count >= 2 {
            let opening = (0..<starts[0].index).filter { !excluded.contains($0) }.map { blocks[$0] }
            let openingText = opening.map { $0.text.replacingOccurrences(of: "\n", with: " ") }
                .filter { $0.lowercased() != title?.lowercased() && LayoutTextImporter.byline($0) == nil }
            if HTMLImporter.isTitlePage(openingText) {
                frontMatter = openingText
            } else if !openingText.isEmpty {
                chapters.append(chapter(opening, tocTitle: nil))
            }
            for (n, start) in starts.enumerated() {
                let end = n + 1 < starts.count ? starts[n + 1].index : blocks.count
                let part = (start.index..<end).filter { !excluded.contains($0) }.map { blocks[$0] }
                chapters.append(chapter(part, tocTitle: start.title))
            }
            chapters.removeAll { $0.paragraphs.isEmpty || $0.title.range(of: #"(?i)^(table of )?contents\.?$"#, options: .regularExpression) != nil }
            while chapters.count > 1, let last = chapters.last, HTMLImporter.isApparatus(last.title) {
                sections.append(last.title)
                chapters.removeLast()
            }
        } else {
            let kept = blocks.indices.filter { !excluded.contains($0) }.map { blocks[$0] }
            var apparatus: [String] = []
            let built = HTMLImporter.buildChapters(kept, title: &title, author: &author, skippedSections: &apparatus)
            chapters = built.chapters
            frontMatter = built.frontMatter
            sections += apparatus
        }
        for i in chapters.indices { chapters[i].index = i }
        if chapters.isEmpty { chapters = [DocumentChapter(index: 0, title: title ?? fallbackTitle, paragraphs: [])] }

        skipped.sections = sections
        var stats = ExtractionStats()
        stats.paragraphRule = .markup
        var warnings: [ImportWarning] = []
        if let detail = skipped.detail { warnings.append(ImportWarning(.contentSkipped, detail: detail)) }
        let result = LayoutTextImporter.Result(title: title, author: author, frontMatter: frontMatter, chapters: chapters,
                                               stats: stats, foundHeadings: chapters.count >= 2)
        return Output(result: result, language: book.language, warnings: warnings, languageRegion: book.languageRegion)
    }

    /// The book's cover picture, for the shelf: the manifest item marked `cover-image`
    /// (EPUB 3) or named by `<meta name="cover">` (EPUB 2).
    public static func cover(_ data: Data) -> (data: Data, mediaType: String)? {
        guard let zip = try? ZipArchive(data), let book = try? Package(zip: zip), let cover = book.cover,
              let bytes = try? zip.contents(of: cover.path) else { return nil }
        return (bytes, cover.mediaType)
    }

    /// "Frankenstein; or, the Modern Prometheus" and "or, the Modern Prometheus"; "Pride and
    /// Prejudice" and "PRIDE. and PREJUDICE".
    static func sameTitle(_ a: String, _ b: String) -> Bool {
        let x = normalized(a), y = normalized(b)
        guard x.count >= 4, y.count >= 4 else { return false }
        return x.hasPrefix(y) || y.hasPrefix(x) || x.hasSuffix(y) || y.hasSuffix(x)
    }

    /// Gutenberg's contents takes the whole heading, picture caption and all: "I hope Mr.
    /// Bingley will like it. CHAPTER II." The chapter is what follows the label.
    static func cleanContentsTitle(_ title: String) -> String {
        guard let m = LayoutTextImporter.firstMatch(#"(?i)^(.+?[.!?][\u201D\u2019"']*\s+)((chapter|book|part)\s+([0-9]{1,3}|[ivxlcdm]{1,8})\b.*)$"#, title) else { return title }
        return m[2]
    }

    /// Cover, title page, copyright: the publisher's pages, which no narrator reads.
    static func isPublisherMatter(_ title: String) -> Bool {
        title.range(of: #"(?i)^(cover|front cover|title( page)?|half title|copyright( page)?|colophon|imprint|about the publisher|the full project gutenberg licen[cs]e)\.?$"#,
                    options: .regularExpression) != nil
    }

    /// One contents entry's blocks as a chapter. The contents names the chapter; the file
    /// repeats that name as its opening heading (often in two parts, "CHAPTER I" and "The
    /// Air-Ship"), which is consumed rather than read twice.
    static func chapter(_ blocks: [HTMLImporter.Block], tocTitle: String?) -> DocumentChapter {
        var (label, name) = tocTitle.map { HTMLImporter.splitHeading(cleanContentsTitle($0)) } ?? (nil, nil)
        var paragraphs: [String] = []
        var opening = true
        for block in blocks {
            let flat = block.text.replacingOccurrences(of: "\n", with: " ")
            switch block.kind {
            case .heading:
                if opening {
                    let (l, n) = HTMLImporter.splitHeading(block.text)
                    if label == nil, let l { label = l }
                    if name == nil, let n { name = n; continue }
                    if l != nil || HTMLImporter.isBareNumeral(flat) { continue }
                    if let name, normalized(flat) == normalized(name) || normalized(flat).hasSuffix(normalized(name)) { continue }
                    if let tocTitle, normalized(flat) == normalized(tocTitle) { continue }
                    if name == nil { name = flat; continue }
                }
                if HTMLImporter.isBareNumeral(flat) { continue }
                paragraphs.append(flat)
            case .paragraph:
                opening = false
                paragraphs.append(block.text)
            }
        }
        return DocumentChapter(index: 0, title: name ?? label ?? "", paragraphs: paragraphs, label: label)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - The package

    struct Package {
        struct ContentsEntry { var path: String; var fragment: String?; var title: String; var depth: Int = 0 }

        var title: String?
        var author: String?
        var language: String?
        var languageRegion: String?
        var spine: [String] = []
        var contents: [ContentsEntry] = []
        var cover: (path: String, mediaType: String)?

        init(zip: ZipArchive) throws {
            if zip.entry(named: "META-INF/rights.xml") != nil { throw DocumentImporter.Failure.protected }
            if let encryption = try? zip.contents(of: "META-INF/encryption.xml") {
                let text = String(decoding: encryption, as: UTF8.self)
                let algorithms = EPUBImporter.matches(#"Algorithm\s*=\s*["']([^"']+)["']"#, text)
                // An encryption method that is not font obfuscation protects content.
                if algorithms.contains(where: { !EPUBImporter.fontObfuscation.contains($0) }) { throw DocumentImporter.Failure.protected }
            }

            var opfPath = zip.entries.first { $0.name.lowercased().hasSuffix(".opf") }?.name
            if let container = try? zip.contents(of: "META-INF/container.xml") {
                let doc = HTMLParser.parse(String(decoding: container, as: UTF8.self))
                if let path = doc.descendants().first(where: { Self.local($0.name) == "rootfile" })?.attribute("full-path") {
                    opfPath = path
                }
            }
            guard let opfPath, let opfData = try zip.contents(of: opfPath) else {
                throw DocumentImporter.Failure.unreadable("this EPUB has no package file")
            }
            let opf = HTMLParser.parse(HTMLParser.decode(opfData))
            let base = Self.directory(of: opfPath)
            let elements = opf.descendants()
            func named(_ local: String) -> [HTMLNode] { elements.filter { Self.local($0.name) == local } }

            title = named("title").first?.textContent.nilIfEmpty
            author = named("creator").first?.textContent.nilIfEmpty.map(HTMLImporter.personName)
            if let tag = named("language").first?.textContent {
                (language, languageRegion) = LanguageTag.split(tag)
            }

            struct Item { var path: String; var mediaType: String; var properties: String }
            var manifest: [String: Item] = [:]
            for item in named("item") {
                guard let id = item.attribute("id"), let href = item.attribute("href") else { continue }
                manifest[id] = Item(path: Self.resolve(href, from: base), mediaType: item.attribute("media-type") ?? "",
                                    properties: item.attribute("properties") ?? "")
            }
            let spineNode = named("spine").first
            for ref in named("itemref") where ref.attribute("linear")?.lowercased() != "no" {
                guard let id = ref.attribute("idref"), let item = manifest[id],
                      item.mediaType.contains("html") || item.path.lowercased().hasSuffix("html") || item.path.lowercased().hasSuffix(".htm") else { continue }
                spine.append(item.path)
            }

            if let coverItem = manifest.values.first(where: { $0.properties.split(separator: " ").contains("cover-image") })
                ?? named("meta").first(where: { $0.attribute("name") == "cover" }).flatMap({ $0.attribute("content") }).flatMap({ manifest[$0] }),
               coverItem.mediaType.hasPrefix("image/") {
                cover = (coverItem.path, coverItem.mediaType)
            }

            // EPUB 3's navigation document first; EPUB 2's NCX when there is none.
            if let nav = manifest.values.first(where: { $0.properties.split(separator: " ").contains("nav") }),
               let bytes = try? zip.contents(of: nav.path) {
                contents = Self.navContents(HTMLParser.parse(HTMLParser.decode(bytes)), base: Self.directory(of: nav.path))
            }
            if contents.isEmpty,
               let ncx = spineNode?.attribute("toc").flatMap({ manifest[$0] })
                ?? manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" }),
               let bytes = try? zip.contents(of: ncx.path) {
                contents = Self.ncxContents(HTMLParser.parse(HTMLParser.decode(bytes)), base: Self.directory(of: ncx.path))
            }
        }

        static func navContents(_ doc: HTMLNode, base: String) -> [ContentsEntry] {
            let navs = doc.descendants(named: ["nav"])
            guard let toc = navs.first(where: { ($0.attribute("epub:type") ?? $0.attribute("role") ?? "").contains("toc") }) ?? navs.first else { return [] }
            return toc.descendants(named: ["a"]).compactMap { a in
                guard let href = a.attribute("href") else { return nil }
                var e = entry(href: href, title: HTMLImporter.BlockWalker.headingText(a), base: base)
                e?.depth = depth(of: a, counting: "li", within: toc) - 1
                return e
            }
        }

        static func ncxContents(_ doc: HTMLNode, base: String) -> [ContentsEntry] {
            doc.descendants().filter { local($0.name) == "navpoint" }.compactMap { point in
                let label = point.children.first { local($0.name) == "navlabel" }?.textContent ?? ""
                guard let src = point.children.first(where: { local($0.name) == "content" })?.attribute("src") else { return nil }
                var e = entry(href: src, title: label, base: base)
                e?.depth = depth(of: point, counting: "navpoint", within: doc) - 1
                return e
            }
        }

        static func entry(href: String, title: String, base: String) -> ContentsEntry? {
            let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let title = LayoutTextImporter.collapse(title)
            guard let file = parts.first, !file.isEmpty || parts.count > 1, !title.isEmpty else { return nil }
            return ContentsEntry(path: resolve(String(file), from: base),
                                 fragment: parts.count > 1 ? String(parts[1]).removingPercentEncoding ?? String(parts[1]) : nil,
                                 title: title)
        }

        static func depth(of node: HTMLNode, counting name: String, within root: HTMLNode) -> Int {
            var n = 0
            var current: HTMLNode? = node
            while let c = current, c !== root {
                if local(c.name) == name { n += 1 }
                current = c.parent
            }
            return n
        }

        static func local(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }

        static func directory(of path: String) -> String {
            guard let slash = path.lastIndex(of: "/") else { return "" }
            return String(path[...slash])
        }

        /// `../Text/ch1.xhtml` against `OEBPS/nav/` → `OEBPS/Text/ch1.xhtml`.
        static func resolve(_ href: String, from base: String) -> String {
            let decoded = href.removingPercentEncoding ?? href
            var parts: [Substring] = []
            for component in (base + decoded).split(separator: "/", omittingEmptySubsequences: true) {
                if component == "." { continue }
                if component == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
                parts.append(component)
            }
            return parts.joined(separator: "/")
        }
    }

    static func matches(_ pattern: String, _ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
