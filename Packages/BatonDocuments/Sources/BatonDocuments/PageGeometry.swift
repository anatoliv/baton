import Foundation

extension LayoutTextImporter {
    /// One line of a page as a PDF renderer places it.
    public struct PlacedLine: Sendable, Equatable {
        public var text: String
        public var minX: Double
        public var minY: Double   // PDF space: larger is higher on the page
        public var width: Double
        public init(text: String, minX: Double, minY: Double, width: Double) {
            self.text = text; self.minX = minX; self.minY = minY; self.width = width
        }
    }

    /// Lays each page's placed lines out as `pdftotext -layout` prints them, which is what the
    /// paragraph and heading rules read: leading spaces for the distance from the left margin,
    /// and a blank line where the vertical gap is larger than the usual line spacing.
    ///
    /// The margin, character width and line spacing are measured over the whole document, not
    /// per page: on a page of short dialogue most lines are paragraph starts, so the commonest
    /// position on that page is the indent, not the margin.
    public static func layoutText(ofPages pages: [[PlacedLine]]) -> [String] {
        let pages = pages.map { page in
            page.map { line -> PlacedLine in
                var l = line
                l.text = line.text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")
                while let last = l.text.last, last == " " || last == "\t" { l.text.removeLast() }
                return l
            }
            .filter { !$0.text.isEmpty }
            .sorted { $0.minY > $1.minY }
        }
        let all = pages.flatMap { $0 }
        guard !all.isEmpty else { return pages.map { _ in "" } }

        // The margin: the leftmost position that a real share of lines start at, both 5% of all
        // lines and a quarter of the commonest position. Stray lines further left (hanging
        // numbers, a drop cap) do not move it, even in a short document where 5% is two lines.
        var starts: [Double: Int] = [:]
        for line in all { starts[(line.minX * 2).rounded() / 2, default: 0] += 1 }
        let commonest = starts.values.max() ?? 0
        let threshold = max(2, all.count / 20, (commonest + 3) / 4)
        let margin = starts.filter { $0.value >= threshold }.keys.min() ?? all.map(\.minX).min()!
        let charWidth = median(all.filter { $0.text.count >= 40 }.map { $0.width / Double($0.text.count) }) ?? 6
        let step = median(pages.flatMap { page in
            zip(page, page.dropFirst()).map { $0.minY - $1.minY }.filter { $0 > 0 }
        }) ?? 14

        return pages.map { page in
            var out: [String] = []
            for (i, line) in page.enumerated() {
                if i > 0, page[i - 1].minY - line.minY > step * 1.6 { out.append("") }
                let columns = max(0, Int(((line.minX - margin) / charWidth).rounded()))
                out.append(String(repeating: " ", count: columns) + line.text)
            }
            return out.joined(separator: "\n")
        }
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
