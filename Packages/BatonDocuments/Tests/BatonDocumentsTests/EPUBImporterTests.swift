import Foundation
import XCTest
@testable import BatonDocuments

/// The zip reader and inflate against archives written by other implementations (Python's
/// zlib in the fixtures, Info-ZIP's `zip` when the machine has it), and the EPUB reader on
/// fixtures built to have each structure real EPUBs have. `make-epub-fixtures.py` writes them.
final class ZipArchiveTests: XCTestCase {
    static func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// Every entry at every level inflates to the right size and CRC (the CRC was computed by
    /// zlib over the original bytes, so a wrong byte anywhere fails), and the levels agree.
    func testInflateAgreesWithZlibAtEveryLevel() throws {
        var prose: [Int: Data] = [:]
        for level in [0, 1, 6, 9] {
            let zip = try ZipArchive(Self.fixture("inflate-level\(level).zip"))
            XCTAssertEqual(zip.entries.map(\.name), ["empty.bin", "short.txt", "prose.txt", "noise.bin", "far.bin", "runs.bin"])
            for entry in zip.entries {
                XCTAssertEqual(entry.method, 8, "level \(level): \(entry.name) is deflated")
                let data = try zip.contents(of: entry)
                XCTAssertEqual(data.count, entry.uncompressedSize)
            }
            prose[level] = try zip.contents(of: "prose.txt")
            XCTAssertEqual(try zip.contents(of: "short.txt"), Data("Hi.".utf8))
        }
        XCTAssertEqual(prose[1], prose[6])
        XCTAssertEqual(prose[6], prose[9])
        XCTAssertEqual(prose[0], prose[9]?.prefix(20000))
    }

    func testDamageIsCaughtNotReturned() throws {
        var bytes = [UInt8](try Self.fixture("inflate-level6.zip"))
        let zip = try ZipArchive(Data(bytes))
        let entry = try XCTUnwrap(zip.entry(named: "prose.txt"))
        // Flip a byte inside the compressed prose.
        let start = entry.localHeaderOffset + 30 + "prose.txt".utf8.count
        bytes[start + entry.compressedSize / 2] ^= 0x5A
        XCTAssertThrowsError(try ZipArchive(Data(bytes)).contents(of: entry))
        XCTAssertThrowsError(try ZipArchive(Data("not a zip at all, just some words".utf8))) { error in
            XCTAssertEqual(error as? ZipArchive.Failure, .notAZip)
        }
    }

    /// Info-ZIP has its own deflate, unrelated to zlib's: the second opinion.
    func testArchivesWrittenByInfoZip() throws {
        let zipTool = ["/usr/bin/zip", "/opt/homebrew/bin/zip", "/usr/local/bin/zip"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let zipTool else { throw XCTSkip("no zip command on this machine") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var generator = SystemRandomNumberGenerator()
        let files: [String: Data] = [
            "text.txt": Data(String(repeating: "The machine stops, and the room is quiet again. ", count: 2000).utf8),
            "noise.bin": Data((0..<30000).map { _ in UInt8.random(in: 0...255, using: &generator) }),
            "mixed.bin": Data((0..<40000).map { i in i % 997 < 500 ? UInt8(i % 7) : UInt8.random(in: 0...255, using: &generator) }),
        ]
        for (name, data) in files { try data.write(to: dir.appendingPathComponent(name)) }
        for level in ["-0", "-1", "-9"] {
            let archive = dir.appendingPathComponent("a\(level).zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: zipTool)
            process.currentDirectoryURL = dir
            process.arguments = ["-q", level, archive.lastPathComponent] + files.keys.sorted()
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let zip = try ZipArchive(Data(contentsOf: archive))
            for (name, data) in files { XCTAssertEqual(try zip.contents(of: name), data, "\(name) at \(level)") }
        }
    }
}

extension ZipArchiveTests {
    /// Central-directory entries that all point at one body are the classic zip bomb: each
    /// name inflates the same few kilobytes again. Only the first name is kept.
    func testEntriesSharingOneBodyAreReadOnce() throws {
        let body = TestZip.Body(name: "c0.xhtml", runs: 1000)
        let zip = try ZipArchive(TestZip.archive([body], extraNames: (1..<50).map { (name: "c\($0).xhtml", sharing: 0) }))
        XCTAssertEqual(try zip.contents(of: "c0.xhtml")?.count, body.size)
        XCTAssertNil(try zip.contents(of: "c1.xhtml"), "a second name for the same body")
    }

    /// Each entry is within the per-entry cap, but together they are past the archive's total
    /// (256 MB in use; a small total here, so the test inflates kilobytes, not gigabytes).
    func testAnArchiveInflatesNoMoreThanItsTotal() throws {
        let bodies = (0..<5).map { TestZip.Body(name: "c\($0).xhtml", runs: 1000) }
        let zip = try ZipArchive(TestZip.archive(bodies), maximumInflatedBytes: 4 * bodies[0].size)
        var read = 0
        for body in bodies.prefix(4) { read += try XCTUnwrap(zip.contents(of: body.name)).count }
        XCTAssertEqual(read, 4 * bodies[0].size)
        XCTAssertThrowsError(try zip.contents(of: "c4.xhtml"), "a fifth entry is past the total")
    }
}

/// Zip archives built in memory: each body is one byte and then `runs` copies of the longest
/// match, as fixed-Huffman deflate, so megabytes come from kilobytes.
enum TestZip {
    struct Body {
        var name: String
        var runs: Int
        var size: Int { 1 + 258 * runs }

        var deflated: [UInt8] {
            var out: [UInt8] = []
            var buffer: UInt32 = 0
            var count = 0
            func put(_ value: Int, _ bits: Int, reversed: Bool) {
                for i in 0..<bits {
                    let bit = reversed ? (value >> (bits - 1 - i)) & 1 : (value >> i) & 1
                    buffer |= UInt32(bit) << UInt32(count)
                    count += 1
                    if count == 8 { out.append(UInt8(buffer)); buffer = 0; count = 0 }
                }
            }
            put(1, 1, reversed: false)        // last block
            put(1, 2, reversed: false)        // fixed Huffman
            put(0x30 + 0x61, 8, reversed: true) // literal "a"
            for _ in 0..<runs {
                put(0xC5, 8, reversed: true)  // length 258 (symbol 285)
                put(0, 5, reversed: true)     // distance 1
            }
            put(0, 7, reversed: true)         // end of block (symbol 256)
            if count > 0 { out.append(UInt8(buffer)) }
            return out
        }

        var crc: UInt32 { CRC32.checksum([UInt8](repeating: UInt8(ascii: "a"), count: size)) }
    }

    static func archive(_ bodies: [Body], extraNames: [(name: String, sharing: Int)] = []) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(v >> ($0 * 8) & 0xFF) } }
        var bytes: [UInt8] = []
        var records: [(name: String, crc: Int, compressed: Int, size: Int, offset: Int)] = []
        for body in bodies {
            let payload = body.deflated
            let name = Array(body.name.utf8)
            let crc = Int(body.crc)
            records.append((body.name, crc, payload.count, body.size, bytes.count))
            bytes += le32(0x0403_4B50) + le16(20) + le16(0) + le16(8) + le16(0) + le16(0)
            bytes += le32(crc) + le32(payload.count) + le32(body.size) + le16(name.count) + le16(0) + name + payload
        }
        for extra in extraNames {
            let shared = records[extra.sharing]
            records.append((extra.name, shared.crc, shared.compressed, shared.size, shared.offset))
        }
        let directoryOffset = bytes.count
        for r in records {
            let name = Array(r.name.utf8)
            bytes += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(8) + le16(0) + le16(0)
            bytes += le32(r.crc) + le32(r.compressed) + le32(r.size) + le16(name.count) + le16(0) + le16(0)
            bytes += le16(0) + le16(0) + le32(0) + le32(r.offset) + name
        }
        let directorySize = bytes.count - directoryOffset
        bytes += le32(0x0605_4B50) + le16(0) + le16(0) + le16(records.count) + le16(records.count)
        bytes += le32(directorySize) + le32(directoryOffset) + le16(0)
        return Data(bytes)
    }
}

final class EPUBImporterTests: XCTestCase {
    private func importFixture(_ name: String) throws -> ImportedDocument {
        let data = try ZipArchiveTests.fixture(name)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DocumentImporter.importFile(at: url)
    }

    func testAnEPUB3FollowsItsContentsAcrossAndWithinFiles() throws {
        let doc = try importFixture("epub3-anchors.epub")
        XCTAssertEqual(doc.sourceKind, .epub)
        XCTAssertEqual(doc.title, "The Made-Up Machine")
        XCTAssertEqual(doc.author, "Jane Q. Writer")
        XCTAssertEqual(doc.language, "en")
        XCTAssertEqual(doc.chapters.map(\.title), ["The Air-Ship", "The Mending Apparatus", "The Homeless"],
                       "the contents names the chapter; the file's own heading is consumed")
        XCTAssertEqual(doc.chapters.map(\.label), ["Chapter I", "Chapter II", "III"])
        XCTAssertEqual(doc.chapters.map(\.spokenHeading), ["Chapter I. The Air-Ship", "Chapter II. The Mending Apparatus", "Chapter III. The Homeless"])
        // Chapter I: the drop cap joins its word, the page number is not read.
        XCTAssertEqual(doc.chapters[0].paragraphs.first, "IMAGINE, if you can, a small room.")
        XCTAssertEqual(doc.chapters[0].paragraphs.count, 2)
        // Chapter II stops where chapter III's file begins; its code is left out.
        XCTAssertEqual(doc.chapters[1].paragraphs.count, 2)
        // Chapter III runs on into the next file, which the contents does not name.
        XCTAssertEqual(doc.chapters[2].paragraphs.last, "The last sentence of the book.")
        XCTAssertEqual(doc.chapters[2].paragraphs.count, 3)
        // The title page is shown, the cover and copyright are not read, the notes are not in the reading order.
        XCTAssertEqual(doc.frontMatter, ["by", "Jane Q. Writer", "London, 1909"])
        let all = doc.paragraphs.joined(separator: " ")
        XCTAssertFalse(all.contains("Copyright") || all.contains("not in the reading order") || all.contains("not = read"))
        XCTAssertEqual(doc.warnings, [ImportWarning(.contentSkipped, detail: "1 code block, the Copyright section")])

        let cover = try XCTUnwrap(EPUBImporter.cover(ZipArchiveTests.fixture("epub3-anchors.epub")))
        XCTAssertEqual(cover.mediaType, "image/png")
        XCTAssertEqual(cover.data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testAnEPUB2WithAnNCXAndObfuscatedFonts() throws {
        let doc = try importFixture("epub2-ncx.epub")
        XCTAssertEqual(doc.title, "An Older Book")
        XCTAssertEqual(doc.author, "Jane Austen")
        // "A Section" is a contents entry inside chapter 2, so it is a chapter of its own.
        XCTAssertEqual(doc.chapters.map(\.title), ["Chapter 1", "Chapter 2", "A Section"])
        XCTAssertEqual(doc.chapters.map(\.paragraphs.count), [40, 1, 1])
        XCTAssertEqual(doc.chapters[0].spokenHeading, "Chapter 1", "the heading repeating the contents is not read twice")
        XCTAssertEqual(EPUBImporter.cover(try ZipArchiveTests.fixture("epub2-ncx.epub"))?.mediaType, "image/jpeg")
    }

    /// The fixture with one entry's compressed bytes changed, so it fails to inflate or its checksum.
    private func damaged(_ fixture: String, entry name: String) throws -> Data {
        var bytes = [UInt8](try ZipArchiveTests.fixture(fixture))
        let entry = try XCTUnwrap(ZipArchive(Data(bytes)).entry(named: name))
        let h = entry.localHeaderOffset
        let start = h + 30 + Int(ZipArchive.u16(bytes, h + 26)) + Int(ZipArchive.u16(bytes, h + 28))
        bytes[start + entry.compressedSize / 2] ^= 0x5A
        return Data(bytes)
    }

    /// A chapter file that cannot be read is left out and said so, not dropped in silence.
    func testADamagedChapterFileIsNamedInAWarning() throws {
        let out = try EPUBImporter.read(damaged("epub3-anchors.epub", entry: "OEBPS/text/c3b.xhtml"), fallbackTitle: "book")
        XCTAssertFalse(out.result.chapters.flatMap(\.paragraphs).contains("The last sentence of the book."))
        XCTAssertTrue(out.warnings.contains(ImportWarning(.contentSkipped, detail: "c3b.xhtml, which could not be read")),
                      "\(out.warnings)")
    }

    /// A package file that cannot be read is the importer's own failure, worded for the sheet,
    /// not the zip reader's.
    func testADamagedPackageFileIsUnreadable() throws {
        let data = try damaged("epub3-anchors.epub", entry: "OEBPS/content.opf")
        XCTAssertThrowsError(try EPUBImporter.read(data, fallbackTitle: "book")) { error in
            guard case .unreadable(let why)? = error as? DocumentImporter.Failure else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("package file"), why)
        }
    }

    /// The fixture with one central-directory name changed, so the spine names a file the zip
    /// does not have.
    private func missing(_ fixture: String, entry name: String, renamedTo other: String) throws -> Data {
        var bytes = [UInt8](try ZipArchiveTests.fixture(fixture))
        let target = Array(name.utf8), replacement = Array(other.utf8)
        precondition(target.count == replacement.count)
        var p = 0, renamed = 0
        while p + 46 <= bytes.count {
            if ZipArchive.u32(bytes, p) == 0x0201_4B50 {
                let length = Int(ZipArchive.u16(bytes, p + 28))
                if Array(bytes[(p + 46)..<(p + 46 + length)]) == target {
                    bytes.replaceSubrange((p + 46)..<(p + 46 + length), with: replacement); renamed += 1
                }
            }
            p += 1
        }
        XCTAssertEqual(renamed, 1)
        return Data(bytes)
    }

    /// C3-8 remainder: a spine file the zip does not hold is named in a warning, like a damaged one.
    func testASpineFileMissingFromTheZipIsNamedInAWarning() throws {
        let out = try EPUBImporter.read(missing("epub3-anchors.epub", entry: "OEBPS/text/c3b.xhtml",
                                                renamedTo: "OEBPS/text/c3z.xhtml"), fallbackTitle: "book")
        XCTAssertFalse(out.result.chapters.flatMap(\.paragraphs).contains("The last sentence of the book."))
        XCTAssertTrue(out.warnings.contains(ImportWarning(.contentSkipped, detail: "c3b.xhtml, which could not be read")),
                      "\(out.warnings)")
    }

    /// C3-9: an encryption.xml that cannot be read might protect anything, so the book is refused
    /// rather than read as if it had none.
    func testADamagedEncryptionFileStillRefusesTheBook() throws {
        let data = try damaged("protected.epub", entry: "META-INF/encryption.xml")
        XCTAssertThrowsError(try EPUBImporter.read(data, fallbackTitle: "book")) { error in
            XCTAssertEqual(error as? DocumentImporter.Failure, .protected)
        }
    }

    /// C3-5 remainder: the archive reads the bytes it was given, mapped or not, rather than a
    /// copy of the whole file (a 512 MB EPUB opened for its cover was copied whole).
    func testTheArchiveKeepsTheCallersBytesRatherThanACopy() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "epub3-anchors.epub", withExtension: nil, subdirectory: "Fixtures"))
        let mapped = try Data(contentsOf: url, options: .alwaysMapped)
        let zip = try ZipArchive(mapped)
        let given = mapped.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
        let kept = zip.data.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
        XCTAssertEqual(kept, given)
        XCTAssertNotNil(EPUBImporter.cover(mapped))
    }

    func testAProtectedBookIsRefused() throws {
        XCTAssertThrowsError(try importFixture("protected.epub")) { error in
            XCTAssertEqual(error as? DocumentImporter.Failure, .protected)
        }
    }

    /// Measured on Gutenberg's EPUBs of *Pride and Prejudice*, *Frankenstein* and *Sherlock
    /// Holmes*: their contents' quirks.
    func testContentsTitlesAsGutenbergWritesThem() {
        XCTAssertEqual(EPUBImporter.cleanContentsTitle("I hope Mr. Bingley will like it. CHAPTER II."), "CHAPTER II.")
        XCTAssertEqual(EPUBImporter.cleanContentsTitle("\u{201C}The Post.\u{201D} CHAPTER XLVIII."), "CHAPTER XLVIII.")
        XCTAssertEqual(EPUBImporter.cleanContentsTitle("Chapter IV"), "Chapter IV")
        XCTAssertEqual(EPUBImporter.cleanContentsTitle("Mr. Darcy's Letter"), "Mr. Darcy's Letter")
        XCTAssertTrue(EPUBImporter.sameTitle("or, the Modern Prometheus", "Frankenstein; or, the modern prometheus"))
        XCTAssertTrue(EPUBImporter.sameTitle("Frankenstein", "Frankenstein; or, the modern prometheus"))
        XCTAssertTrue(EPUBImporter.sameTitle("PRIDE. and PREJUDICE", "Pride and Prejudice"))
        XCTAssertFalse(EPUBImporter.sameTitle("Letter 1", "Frankenstein; or, the modern prometheus"))
    }

    func testPathsResolveLikeABrowser() {
        XCTAssertEqual(EPUBImporter.Package.resolve("../text/chapter%201.xhtml", from: "OEBPS/nav/"), "OEBPS/text/chapter 1.xhtml")
        XCTAssertEqual(EPUBImporter.Package.resolve("./a.html", from: ""), "a.html")
        XCTAssertEqual(EPUBImporter.Package.resolve("../../x.html", from: "a/"), "x.html")
    }

    /// A real EPUB when `BATON_LIVE_EPUB` names one on disk: prints what was read, so a person
    /// can judge it (the cloud session runs Gutenberg's).
    func testARealEPUB() throws {
        guard let path = ProcessInfo.processInfo.environment["BATON_LIVE_EPUB"] else {
            throw XCTSkip("set BATON_LIVE_EPUB to the path of an .epub to read a real book")
        }
        let start = Date()
        let doc = try DocumentImporter.importFile(at: URL(fileURLWithPath: path))
        print(String(format: "READ IN %.2f s", Date().timeIntervalSince(start)))
        print("TITLE: \(doc.title) | AUTHOR: \(doc.author ?? "-") | LANG: \(doc.language ?? "-") | WORDS: \(doc.wordCount)")
        print("WARNINGS: \(doc.warnings)")
        print("FRONT: \(doc.frontMatter)")
        for chapter in doc.chapters.prefix(80) {
            print("== \(chapter.spokenHeading) (\(chapter.paragraphs.count) paragraphs)")
            if let first = chapter.paragraphs.first { print("   \(first.prefix(120))") }
        }
        XCTAssertGreaterThan(doc.wordCount, 1000)
    }
}
