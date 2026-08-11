import AppKit
import SwiftUI
import Testing
@testable import Baton

/// The listening-trend strip, checked as pixels.
///
/// `299140d` fixed a strip that drew a 0.5pt stub under *every* empty day, so a week with
/// one or two plays rendered as a row of dashes with a stray block — a broken rule rather
/// than a chart. The fix replaced the per-day stubs with one continuous baseline. It was
/// built, reasoned about, and shipped without anyone seeing it, because two running copies
/// of Baton blocked the screenshot.
///
/// The difference between the two versions is precisely a gap: per-day stubs inherit the
/// 1pt spacing between bars, so the bottom row comes out dashed, while one rule spans the
/// full width unbroken. That is a fact about pixels, so this asserts it on pixels — and
/// writes the PNG out as well, because the point of the exercise was to be able to look.
@MainActor
@Suite("Listening trend sparkline")
struct SparklineRenderTests {
    private let width: CGFloat = 120
    private let height: CGFloat = 22
    private let scale: CGFloat = 2

    private func render(_ values: [Double]) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(
            content: Sparkline(values: values).frame(width: width, height: height)
        )
        renderer.scale = scale
        let image = try #require(renderer.nsImage)
        let data = try #require(image.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: data))
    }

    /// Columns carrying ink on a given row, counted from the bottom.
    private func inkColumns(_ rep: NSBitmapImageRep, rowFromBottom: Int) -> Set<Int> {
        let y = rep.pixelsHigh - 1 - rowFromBottom
        var columns: Set<Int> = []
        for x in 0..<rep.pixelsWide {
            if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 {
                columns.insert(x)
            }
        }
        return columns
    }

    private func writePNG(_ rep: NSBitmapImageRep, _ name: String) throws {
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/baton-\(name).png"))
    }

    @Test("A quiet week draws one unbroken baseline, not a dash per empty day")
    func quietWeekHasNoDashes() throws {
        // Two days with plays out of seven — past the guard that now requires two, and
        // exactly the shape that used to render as dashes.
        let rep = try render([0, 3, 0, 0, 5, 0, 0])
        try writePNG(rep, "sparkline-quiet-week")

        let baseline = inkColumns(rep, rowFromBottom: 0)
        #expect(baseline.count == rep.pixelsWide,
                """
                the baseline is broken: \(baseline.count) of \(rep.pixelsWide) columns \
                carry ink. Gaps here are the per-day stubs returning — that is the dashed \
                rule this test exists to catch.
                """)
    }

    @Test("Empty days draw no bar of their own")
    func emptyDaysAreEmpty() throws {
        let rep = try render([0, 3, 0, 0, 5, 0, 0])

        // Well above the baseline, only the two days with plays may have ink. Five of
        // seven columns empty means at most ~2/7 of the width can be inked; allow room
        // for bar corner radii and antialiasing but nothing like a stub per day.
        let midRow = Int(height * scale / 2)
        let mid = inkColumns(rep, rowFromBottom: midRow)
        #expect(mid.count < rep.pixelsWide / 2,
                "ink at half height in \(mid.count) of \(rep.pixelsWide) columns — empty days are drawing something")
        #expect(!mid.isEmpty, "the two days with plays must draw bars that reach half height")
    }

    @Test("A busy week still fills the strip")
    func busyWeekDraws() throws {
        // The counter-case, so the test above can't be satisfied by drawing nothing at all.
        let rep = try render([4, 6, 5, 7, 6, 5, 8])
        try writePNG(rep, "sparkline-busy-week")

        let midRow = Int(height * scale / 2)
        let mid = inkColumns(rep, rowFromBottom: midRow)
        #expect(mid.count > rep.pixelsWide / 2,
                "a week of steady listening should ink most of the strip at half height")
    }
}
