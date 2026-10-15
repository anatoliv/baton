import Foundation

/// A small, forgiving HTML (and XHTML) parser: bytes in, a tree of elements and text out.
///
/// Why not `NSAttributedString(html:)`: it starts WebKit on the main thread, is not on Linux,
/// and runs the page's styles (`specs/document-clippings.md`, *Importers*). Why not
/// `XMLParser`: real web pages are not well-formed XML, and one stray `<br>` makes it give up.
/// What follows is the part of the HTML parsing rules a reader needs: void elements, raw-text
/// elements, the paragraph and list items a new block implicitly closes, entities, and
/// end tags that do not match being ignored rather than fatal. The EPUB importer reads its
/// chapters with it too, since EPUB chapters are XHTML.
final class HTMLNode {
    enum Kind { case document, element, text }

    let kind: Kind
    /// Lowercased tag name; empty for text and the document.
    let name: String
    var attributes: [String: String]
    /// Text nodes only, entities already decoded, whitespace as written.
    var text: String
    var children: [HTMLNode] = []
    weak var parent: HTMLNode?

    init(kind: Kind, name: String = "", attributes: [String: String] = [:], text: String = "") {
        self.kind = kind
        self.name = name
        self.attributes = attributes
        self.text = text
    }

    func append(_ child: HTMLNode) {
        child.parent = self
        children.append(child)
    }

    func attribute(_ name: String) -> String? { attributes[name] }

    /// Every element below this one, depth first, in document order.
    func descendants(named names: Set<String>? = nil) -> [HTMLNode] {
        var out: [HTMLNode] = []
        var stack = Array(children.reversed())
        while let node = stack.popLast() {
            if node.kind == .element {
                if names == nil || names!.contains(node.name) { out.append(node) }
                stack.append(contentsOf: node.children.reversed())
            }
        }
        return out
    }

    func first(named name: String) -> HTMLNode? {
        descendants(named: [name]).first
    }

    /// All text below this node, whitespace collapsed.
    var textContent: String {
        var parts: [String] = []
        var stack: [HTMLNode] = [self]
        while let node = stack.popLast() {
            if node.kind == .text { parts.append(node.text) }
            stack.append(contentsOf: node.children.reversed())
        }
        return LayoutTextImporter.collapse(parts.joined())
    }

    func detach() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        self.parent = nil
    }
}

enum HTMLParser {
    static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input",
                                            "link", "meta", "param", "source", "track", "wbr"]
    /// Content is taken as it is, up to the matching end tag: no tags inside.
    static let rawTextElements: Set<String> = ["script", "style", "textarea", "title", "xmp", "iframe",
                                               "noembed", "noframes", "template"]
    /// A start tag of one of these closes an open `<p>`.
    static let closesParagraph: Set<String> = ["address", "article", "aside", "blockquote", "center", "details",
                                               "dialog", "dir", "div", "dl", "fieldset", "figcaption", "figure",
                                               "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header",
                                               "hgroup", "hr", "main", "menu", "nav", "ol", "p", "pre", "section",
                                               "table", "ul", "li", "dd", "dt"]

    static func parse(_ html: String) -> HTMLNode {
        let bytes = Array(html.utf8)
        let document = HTMLNode(kind: .document)
        var stack: [HTMLNode] = [document]
        var i = 0
        var textStart = 0

        func flushText(upTo end: Int) {
            guard end > textStart else { return }
            let raw = String(decoding: bytes[textStart..<end], as: UTF8.self)
            stack.last!.append(HTMLNode(kind: .text, text: decodeEntities(raw)))
        }

        func popTo(_ index: Int) { stack.removeSubrange(index...) }

        /// The innermost open element with this name, not looking past `boundary` names.
        func openIndex(of name: String, boundary: Set<String> = []) -> Int? {
            var j = stack.count - 1
            while j > 0 {
                if stack[j].name == name { return j }
                if boundary.contains(stack[j].name) { return nil }
                j -= 1
            }
            return nil
        }

        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "<"), i + 1 < bytes.count else { i += 1; continue }
            let next = bytes[i + 1]

            // Comments, doctype, processing instructions, CDATA.
            if next == UInt8(ascii: "!") || next == UInt8(ascii: "?") {
                flushText(upTo: i)
                if matches(bytes, at: i, "<!--") {
                    i = find(bytes, "-->", from: i + 4).map { $0 + 3 } ?? bytes.count
                } else if matches(bytes, at: i, "<![CDATA[") {
                    let end = find(bytes, "]]>", from: i + 9) ?? bytes.count
                    stack.last!.append(HTMLNode(kind: .text, text: String(decoding: bytes[(i + 9)..<end], as: UTF8.self)))
                    i = min(end + 3, bytes.count)
                } else {
                    i = (find(bytes, ">", from: i) ?? bytes.count - 1) + 1
                }
                textStart = i
                continue
            }

            // End tag.
            if next == UInt8(ascii: "/") {
                var j = i + 2
                let nameStart = j
                while j < bytes.count, isNameByte(bytes[j]) { j += 1 }
                guard j > nameStart else { i += 1; continue }
                flushText(upTo: i)
                let name = String(decoding: bytes[nameStart..<j], as: UTF8.self).lowercased()
                i = (find(bytes, ">", from: j) ?? bytes.count - 1) + 1
                textStart = i
                if let index = openIndex(of: name) { popTo(index) }
                continue
            }

            // Start tag.
            guard isLetter(next) else { i += 1; continue }
            flushText(upTo: i)
            var j = i + 1
            while j < bytes.count, isNameByte(bytes[j]) { j += 1 }
            let name = String(decoding: bytes[(i + 1)..<j], as: UTF8.self).lowercased()
            var attributes: [String: String] = [:]
            var selfClosing = false
            while j < bytes.count, bytes[j] != UInt8(ascii: ">") {
                if bytes[j] == UInt8(ascii: "/") { selfClosing = true; j += 1; continue }
                if isSpace(bytes[j]) { j += 1; continue }
                selfClosing = false
                let keyStart = j
                while j < bytes.count, !isSpace(bytes[j]), bytes[j] != UInt8(ascii: "="),
                      bytes[j] != UInt8(ascii: ">"), bytes[j] != UInt8(ascii: "/") { j += 1 }
                let key = String(decoding: bytes[keyStart..<j], as: UTF8.self).lowercased()
                while j < bytes.count, isSpace(bytes[j]) { j += 1 }
                var value = ""
                if j < bytes.count, bytes[j] == UInt8(ascii: "=") {
                    j += 1
                    while j < bytes.count, isSpace(bytes[j]) { j += 1 }
                    if j < bytes.count, bytes[j] == UInt8(ascii: "\"") || bytes[j] == UInt8(ascii: "'") {
                        let quote = bytes[j]
                        let valueStart = j + 1
                        j = valueStart
                        while j < bytes.count, bytes[j] != quote { j += 1 }
                        value = String(decoding: bytes[valueStart..<min(j, bytes.count)], as: UTF8.self)
                        j += 1
                    } else {
                        let valueStart = j
                        while j < bytes.count, !isSpace(bytes[j]), bytes[j] != UInt8(ascii: ">") { j += 1 }
                        value = String(decoding: bytes[valueStart..<j], as: UTF8.self)
                    }
                }
                if !key.isEmpty, attributes[key] == nil { attributes[key] = decodeEntities(value) }
            }
            i = min(j + 1, bytes.count)
            textStart = i

            // Implied end tags.
            if closesParagraph.contains(name), let p = openIndex(of: "p", boundary: ["table", "button", "td", "th"]) {
                popTo(p)
            }
            switch name {
            case "li":
                if let li = openIndex(of: "li", boundary: ["ul", "ol", "menu"]) { popTo(li) }
            case "dt", "dd":
                if let d = openIndex(of: "dd", boundary: ["dl"]) ?? openIndex(of: "dt", boundary: ["dl"]) { popTo(d) }
            case "tr":
                if let tr = openIndex(of: "tr", boundary: ["table"]) { popTo(tr) }
            case "td", "th":
                if let cell = openIndex(of: "td", boundary: ["tr", "table"]) ?? openIndex(of: "th", boundary: ["tr", "table"]) {
                    popTo(cell)
                }
            case "option":
                if let o = openIndex(of: "option", boundary: ["select"]) { popTo(o) }
            default:
                break
            }

            let element = HTMLNode(kind: .element, name: name, attributes: attributes)
            stack.last!.append(element)
            if voidElements.contains(name) || selfClosing { continue }

            if rawTextElements.contains(name) {
                let end = findEndTag(bytes, name, from: i) ?? bytes.count
                let raw = String(decoding: bytes[i..<end], as: UTF8.self)
                if !raw.isEmpty {
                    element.append(HTMLNode(kind: .text, text: name == "title" || name == "textarea" ? decodeEntities(raw) : raw))
                }
                i = end < bytes.count ? (find(bytes, ">", from: end).map { $0 + 1 } ?? bytes.count) : bytes.count
                textStart = i
                continue
            }
            stack.append(element)
        }
        flushText(upTo: bytes.count)
        return document
    }

    // MARK: - Bytes

    private static func isLetter(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    private static func isNameByte(_ b: UInt8) -> Bool {
        isLetter(b) || (b >= 0x30 && b <= 0x39) || b == UInt8(ascii: "-") || b == UInt8(ascii: ":") || b == UInt8(ascii: "_")
    }

    private static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C
    }

    private static func matches(_ bytes: [UInt8], at i: Int, _ literal: String) -> Bool {
        let l = Array(literal.utf8)
        guard i + l.count <= bytes.count else { return false }
        for k in 0..<l.count where bytes[i + k] != l[k] { return false }
        return true
    }

    private static func find(_ bytes: [UInt8], _ literal: String, from start: Int) -> Int? {
        let l = Array(literal.utf8)
        guard !l.isEmpty, start < bytes.count else { return nil }
        var i = start
        while i + l.count <= bytes.count {
            if bytes[i] == l[0], matches(bytes, at: i, literal) { return i }
            i += 1
        }
        return nil
    }

    /// The `</name` that ends a raw-text element, any case.
    private static func findEndTag(_ bytes: [UInt8], _ name: String, from start: Int) -> Int? {
        let n = Array(name.utf8)
        var i = start
        while i + 2 + n.count <= bytes.count {
            if bytes[i] == UInt8(ascii: "<"), bytes[i + 1] == UInt8(ascii: "/") {
                var same = true
                for k in 0..<n.count where (bytes[i + 2 + k] | 0x20) != n[k] { same = false; break }
                if same { return i }
            }
            i += 1
        }
        return nil
    }

    // MARK: - Entities

    /// `&amp;`, `&#8212;`, `&#x2014;` and the named entities a book or article actually uses.
    /// An unknown name is left as written, as browsers do.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            guard c == "&" else { out.append(c); i += 1; continue }
            var j = i + 1
            var name = ""
            while j < scalars.count, j - i <= 32, scalars[j] != ";", scalars[j] != "&",
                  !CharacterSet.whitespacesAndNewlines.contains(scalars[j]) {
                name.unicodeScalars.append(scalars[j])
                j += 1
            }
            let terminated = j < scalars.count && scalars[j] == ";"
            if let value = entityValue(name), terminated || name.hasPrefix("#") || legacyBare.contains(name),
               let scalar = Unicode.Scalar(value) {
                out.append(scalar)
                i = terminated ? j + 1 : j
            } else {
                out.append(c)
                i += 1
            }
        }
        return String(out)
    }

    /// Entities browsers still accept without the semicolon.
    private static let legacyBare: Set<String> = ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg"]

    private static func entityValue(_ name: String) -> UInt32? {
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            return UInt32(name.dropFirst(2), radix: 16).map(fixWindows1252)
        }
        if name.hasPrefix("#") {
            return UInt32(name.dropFirst()).map(fixWindows1252)
        }
        return namedEntities[name]
    }

    /// `&#151;` means an em dash on the web, because pages were written in Windows-1252 and
    /// numbered by its code points. Browsers map the C1 range the same way.
    private static func fixWindows1252(_ value: UInt32) -> UInt32 {
        let map: [UInt32: UInt32] = [128: 0x20AC, 130: 0x201A, 132: 0x201E, 133: 0x2026, 134: 0x2020, 135: 0x2021,
                                     139: 0x2039, 145: 0x2018, 146: 0x2019, 147: 0x201C, 148: 0x201D,
                                     149: 0x2022, 150: 0x2013, 151: 0x2014, 153: 0x2122, 155: 0x203A]
        if value == 0 { return 0xFFFD }
        return map[value] ?? value
    }

    static let namedEntities: [String: UInt32] = {
        var table: [String: UInt32] = [
            "quot": 34, "amp": 38, "apos": 39, "lt": 60, "gt": 62,
            "OElig": 338, "oelig": 339, "Scaron": 352, "scaron": 353, "Yuml": 376, "fnof": 402,
            "circ": 710, "tilde": 732, "ensp": 0x2002, "emsp": 0x2003, "thinsp": 0x2009,
            "zwnj": 0x200C, "zwj": 0x200D, "lrm": 0x200E, "rlm": 0x200F,
            "ndash": 0x2013, "mdash": 0x2014, "lsquo": 0x2018, "rsquo": 0x2019, "sbquo": 0x201A,
            "ldquo": 0x201C, "rdquo": 0x201D, "bdquo": 0x201E, "dagger": 0x2020, "Dagger": 0x2021,
            "bull": 0x2022, "hellip": 0x2026, "permil": 0x2030, "prime": 0x2032, "Prime": 0x2033,
            "lsaquo": 0x2039, "rsaquo": 0x203A, "oline": 0x203E, "frasl": 0x2044, "euro": 0x20AC,
            "trade": 0x2122, "larr": 0x2190, "rarr": 0x2192, "minus": 0x2212,
        ]
        // HTML 4's Latin-1 names, in code point order from 160.
        let latin1 = """
        nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg plusmn \
        sup2 sup3 acute micro para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest Agrave \
        Aacute Acirc Atilde Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml \
        ETH Ntilde Ograve Oacute Ocirc Otilde Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN \
        szlig agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml igrave iacute \
        icirc iuml eth ntilde ograve oacute ocirc otilde ouml divide oslash ugrave uacute ucirc uuml \
        yacute thorn yuml
        """
        for (offset, name) in latin1.split(separator: " ").enumerated() { table[String(name)] = UInt32(160 + offset) }
        let greek = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigmaf sigma tau upsilon phi chi psi omega"
        for (offset, name) in greek.split(separator: " ").enumerated() { table[String(name)] = UInt32(945 + offset) }
        return table
    }()

    // MARK: - Encoding

    /// The page's text, in the encoding it declares: the HTTP header's charset first, then a
    /// byte-order mark, then `<meta charset>` in the first few kilobytes, then UTF-8, and
    /// Windows-1252 for bytes that are not UTF-8 (what browsers assume for an undeclared page).
    static func decode(_ data: Data, contentType: String? = nil) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data, encoding: .utf16LittleEndian) ?? "" }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16BigEndian) ?? "" }
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        let declared = contentType.flatMap { LayoutTextImporter.firstMatch(#"(?i)charset\s*=\s*"?([\w-]+)"#, $0)?[1] }
            ?? LayoutTextImporter.firstMatch(#"(?i)<meta[^>]+charset\s*=\s*["']?([\w-]+)"#, head)?[1]
            ?? LayoutTextImporter.firstMatch(#"(?i)<\?xml[^>]+encoding\s*=\s*["']([\w-]+)"#, head)?[1]
        switch declared?.lowercased() {
        case "iso-8859-1", "latin1", "latin-1", "windows-1252", "cp1252", "us-ascii", "ascii":
            return windows1252(data)
        case "utf-16", "utf-16le":
            if let s = String(data: data, encoding: .utf16LittleEndian) { return s }
        default:
            break
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        return windows1252(data)
    }

    /// Windows-1252 by hand: Foundation on Linux has no decoder for it. It is Latin-1 with
    /// typographic punctuation in 0x80...0x9F, which is also how browsers read a page that
    /// says ISO-8859-1.
    static func windows1252(_ data: Data) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in data {
            let value = (0x80...0x9F).contains(byte) ? fixWindows1252(UInt32(byte)) : UInt32(byte)
            scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
        }
        return String(scalars)
    }
}
