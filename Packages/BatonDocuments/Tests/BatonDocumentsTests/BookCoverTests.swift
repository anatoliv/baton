import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BatonDocuments
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// Book covers: Open Library's answer read and ranked, what may be downloaded, the
/// designed cover's determinism and its refusal without an author, every picture re-encoded
/// before it is kept, and the home server's record of a cover.
final class BookCoverTests: XCTestCase {

    // MARK: - Open Library

    func testTheSearchSendsOnlyTheTitleAndAuthor() throws {
        let url = try XCTUnwrap(OpenLibraryCovers.searchURL(title: "  The Machine Stops ", author: "E. M. Forster"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "openlibrary.org")
        XCTAssertEqual(url.path, "/search.json")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["title", "author", "limit", "fields"])
        XCTAssertEqual(items.first { $0.name == "title" }?.value, "The Machine Stops")
        XCTAssertEqual(items.first { $0.name == "author" }?.value, "E. M. Forster")

        let noAuthor = try XCTUnwrap(OpenLibraryCovers.searchURL(title: "Notes", author: "Unknown"))
        XCTAssertEqual(URLComponents(url: noAuthor, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name),
                       ["title", "limit", "fields"], "a placeholder author is not sent")
        XCTAssertNil(OpenLibraryCovers.searchURL(title: "   ", author: "Anyone"))
    }

    /// The live answer for "The Machine Stops" by E. M. Forster, recorded 2026-10-16: five works,
    /// one without a picture.
    func testTheLiveAnswerIsReadIntoCandidatesBestFirst() throws {
        let data = try ZipArchiveTests.fixture("openlibrary-search-machine-stops.json")
        let candidates = try OpenLibraryCovers.candidates(from: data, title: "The Machine Stops", author: "E. M. Forster")
        XCTAssertEqual(candidates.map(\.coverID), [7_793_883, 10_439_713, 12_015_296, 2_338_382],
                       "the work with no cover_i is dropped; the exact titles come before the collection")
        let first = try XCTUnwrap(candidates.first)
        XCTAssertEqual(first.title, "The Machine Stops")
        XCTAssertEqual(first.authors, ["E. M. Forster"])
        XCTAssertEqual(first.year, 1909)
        XCTAssertEqual(first.caption, "E. M. Forster, 1909")
        XCTAssertEqual(first.imageURL(.large).absoluteString, "https://covers.openlibrary.org/b/id/7793883-L.jpg?default=false")
        XCTAssertEqual(first.imageURL(.medium).absoluteString, "https://covers.openlibrary.org/b/id/7793883-M.jpg?default=false")
    }

    func testCandidatesPreferTheExactTitleThenTheAuthorAndKeepOpenLibrarysOrderAmongEquals() throws {
        let docs: [[String: Any]] = [
            ["title": "Frankenstein: A Graphic Novel", "author_name": ["Gary Reed"], "cover_i": 1],
            ["title": "Frankenstein", "author_name": ["Someone Else"], "cover_i": 2],
            ["title": "Frankenstein", "author_name": ["Mary Wollstonecraft Shelley"], "cover_i": 3],
            ["title": "Frankenstein", "author_name": ["Mary Shelley"], "cover_i": 3], // the same picture again
            ["title": "The Modern Prometheus", "author_name": ["Mary Shelley"], "cover_i": 4],
            ["title": "FRANKENSTEIN!", "author_name": ["M. Shelley"], "cover_i": 5],
            ["title": "Frankenstein", "author_name": ["Mary Shelley"]], // no picture
        ]
        let data = try JSONSerialization.data(withJSONObject: ["docs": docs])
        let candidates = try OpenLibraryCovers.candidates(from: data, title: "Frankenstein", author: "Mary Shelley")
        XCTAssertEqual(candidates.map(\.coverID), [3, 5, 2, 1, 4])
        XCTAssertEqual(try OpenLibraryCovers.candidates(from: data, title: "Frankenstein", author: "Mary Shelley", limit: 2).count, 2)
    }

    func testAnAnswerWithNoCoversIsEmptyAndAnUnreadableOneIsSaid() throws {
        let none = try JSONSerialization.data(withJSONObject: ["numFound": 0, "docs": []])
        XCTAssertEqual(try OpenLibraryCovers.candidates(from: none, title: "Obscure", author: nil), [])
        XCTAssertThrowsError(try OpenLibraryCovers.candidates(from: Data("<html>busy</html>".utf8), title: "x", author: nil)) {
            XCTAssertEqual($0 as? OpenLibraryCovers.Failure, .unreadable)
        }
    }

    func testOnlyAnHTTPSCoverFromOpenLibraryOfACoversSizeIsTaken() {
        let cover = URL(string: "https://covers.openlibrary.org/b/id/1-L.jpg")!
        XCTAssertTrue(OpenLibraryCovers.acceptsDownload(from: cover, status: 200, bytes: 15_000))
        XCTAssertTrue(OpenLibraryCovers.acceptsDownload(from: URL(string: "https://ia800100.us.archive.org/x/1-L.jpg"),
                                                        status: 200, bytes: 15_000), "Open Library keeps some pictures on archive.org")
        XCTAssertFalse(OpenLibraryCovers.acceptsDownload(from: URL(string: "http://covers.openlibrary.org/b/id/1-L.jpg"),
                                                         status: 200, bytes: 15_000), "never over plain HTTP")
        XCTAssertFalse(OpenLibraryCovers.acceptsDownload(from: URL(string: "https://evil.example/1-L.jpg"), status: 200, bytes: 15_000))
        XCTAssertFalse(OpenLibraryCovers.acceptsDownload(from: URL(string: "https://notarchive.org/1.jpg"), status: 200, bytes: 15_000))
        XCTAssertFalse(OpenLibraryCovers.acceptsDownload(from: cover, status: 404, bytes: 15_000))
        XCTAssertFalse(OpenLibraryCovers.acceptsDownload(from: cover, status: 200, bytes: 0))
        XCTAssertFalse(OpenLibraryCovers.acceptsDownload(from: cover, status: 200, bytes: BookCoverImage.maximumSourceBytes + 1))
    }

    // MARK: - When Open Library does not answer

    func testATimeoutIsSlowAndEverythingElseThatKeepsTheAnswerAwayIsOffline() async {
        func search(_ error: Error) async -> Result<[OpenLibraryCovers.Candidate], OpenLibraryCovers.Failure> {
            await OpenLibraryCovers.search(title: "The Machine Stops", author: "E. M. Forster") { _ in throw error }
        }
        let timedOut = await search(URLError(.timedOut))
        XCTAssertEqual(timedOut, .failure(.slow))
        for code in [URLError.Code.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                     .dnsLookupFailed, .secureConnectionFailed] {
            let answer = await search(URLError(code))
            XCTAssertEqual(answer, .failure(.offline), "\(code)")
        }
        XCTAssertEqual(OpenLibraryCovers.Failure.slow.description, "Open Library is taking too long to answer. Try again later.")
        XCTAssertEqual(OpenLibraryCovers.Failure.offline.description,
                       "Baton couldn't reach Open Library. Check the connection and try again.")
        let busy = await OpenLibraryCovers.search(title: "x", author: nil) { url in
            (Data(), HTTPURLResponse(url: url, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        XCTAssertEqual(busy, .failure(.http(503)))
        let none = await OpenLibraryCovers.search(title: " ", author: nil) { _ in XCTFail("nothing is sent without a title"); throw URLError(.unknown) }
        XCTAssertEqual(none, .failure(.noTitle))
    }

    #if canImport(Darwin)
    /// The same through a real URLSession: a loopback port nothing listens on is "couldn't
    /// reach", and one that takes the connection and never answers is "taking too long".
    func testARealSessionAgainstLoopbackSaysOfflineOrSlow() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 2
        let session = URLSession(configuration: configuration)
        let fetch: OpenLibraryCovers.Fetch = { try await session.data(from: $0) }

        let closed = try XCTUnwrap(URL(string: "http://127.0.0.1:\(try Self.closedPort())/search.json"))
        let refused = await OpenLibraryCovers.search(title: "The Machine Stops", author: nil, endpoint: closed, fetch: fetch)
        XCTAssertEqual(refused, .failure(.offline))

        let silent = try SilentListener()
        defer { silent.close() }
        let hanging = try XCTUnwrap(URL(string: "http://127.0.0.1:\(silent.port)/search.json"))
        let started = Date()
        let slow = await OpenLibraryCovers.search(title: "The Machine Stops", author: nil, endpoint: hanging, fetch: fetch)
        XCTAssertEqual(slow, .failure(.slow))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "bounded by the session's timeout")
    }

    /// A port that was free a moment ago: bound, read, closed.
    private static func closedPort() throws -> Int {
        let listener = try SilentListener()
        let port = listener.port
        listener.close()
        return port
    }

    /// Listens on 127.0.0.1 and never accepts: the kernel completes the connection, nobody answers.
    private final class SilentListener {
        let fd: Int32
        let port: Int

        init() throws {
            let socketFD = socket(AF_INET, SOCK_STREAM, 0)
            guard socketFD >= 0 else { throw URLError(.cannotConnectToHost) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = 0
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, length) }
            }
            guard bound == 0, Darwin.listen(socketFD, 4) == 0 else { Darwin.close(socketFD); throw URLError(.cannotConnectToHost) }
            _ = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
            }
            fd = socketFD
            port = Int(UInt16(bigEndian: address.sin_port))
        }

        func close() { Darwin.close(fd) }
    }
    #endif

    // MARK: - Reading a download with a cap

    /// The cap holds while the bytes arrive: past it the read stops, the transfer is cancelled,
    /// and nothing more is taken from the stream.
    func testADownloadPastTheCapIsRefusedWhileItArrives() async throws {
        let limit = 1_000
        var produced = 0
        let stream = AsyncStream<UInt8> { continuation in
            for _ in 0..<(limit * 50) { continuation.yield(0x41) }
            continuation.finish()
        }.map { byte -> UInt8 in produced += 1; return byte }
        final class Flag: @unchecked Sendable { var on = false }
        let cancelled = Flag()
        do {
            _ = try await OpenLibraryCovers.collect(stream, limit: limit) { cancelled.on = true }
            XCTFail("a download past the cap is refused")
        } catch let failure as OpenLibraryCovers.Failure {
            XCTAssertEqual(failure, .notAnImage)
        }
        XCTAssertTrue(cancelled.on)
        XCTAssertEqual(produced, limit + 1, "read stops at the first byte past the cap")

        let small = AsyncStream<UInt8> { c in for b in [UInt8](repeating: 7, count: 10) { c.yield(b) }; c.finish() }
        let kept = try await OpenLibraryCovers.collect(small, limit: limit)
        XCTAssertEqual(kept, Data(repeating: 7, count: 10))
    }

    // MARK: - The home server's revision

    func testEveryCoverChangeOnTheHomeServerCountsARevision() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("baton-cover-rev-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BookStore(directory: dir)
        let book = PreparedBook(documentID: String(repeating: "a", count: 64), title: "T", author: "A", language: "en",
                                voices: VoicePlan(narrator: "kokoro:af_heart"), chapters: [])
        let id = BookJob.id(for: book)
        try store.save(BookJob(id: id, book: book))
        let second = Date(timeIntervalSince1970: 2_000_000_000)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1])
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 2])
        XCTAssertEqual(try store.setCover(jpeg, kind: .jpeg, of: id, now: second).revision, 1)
        XCTAssertEqual(try store.setCover(png, kind: .png, of: id, now: second).revision, 2, "the same second, a new revision")
        XCTAssertEqual(try store.removeCover(of: id, now: second).revision, 3)
        XCTAssertEqual(store.summary(of: try XCTUnwrap(store.load(id))).cover?.revision, 3)

        // A record written before revisions reads with none, and the next change starts at 1.
        let old = #"{"bytes":5,"changedAt":"2026-10-16T17:00:00Z","kind":"jpeg","sha256":"abc"}"#
        try Data(old.utf8).write(to: try XCTUnwrap(store.jobDirectory(id)).appendingPathComponent("cover.json"))
        XCTAssertNil(store.cover(of: id)?.revision)
        XCTAssertEqual(try store.setCover(jpeg, kind: .jpeg, of: id, now: second).revision, 1)
        // And a listing with revisions still reads in a client that ignores them (sorted JSON keys).
        let listed = try BookJSON.encoder.encode(try XCTUnwrap(store.cover(of: id)))
        XCTAssertTrue(String(decoding: listed, as: UTF8.self).contains(#""revision":1"#))
    }

    // MARK: - A designed cover

    func testTheSameBookAlwaysGetsTheSameDesign() throws {
        let a = try BookCoverDesign.make(title: "The Machine Stops", author: "E. M. Forster")
        let b = try BookCoverDesign.make(title: "  The   Machine Stops ", author: "E. M.  Forster")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.title, "The Machine Stops")
        // Pinned: a hash that changed between releases would repaint every made cover.
        XCTAssertEqual(BookCoverDesign.fnv1a("machine stops"), 0x1FEC_FE3A_82ED_B533)
        XCTAssertEqual(a.seed, BookCoverDesign.fnv1a("machine stops"))
        let titles = ["Pride and Prejudice", "Frankenstein", "Middlemarch", "Dracula", "Emma", "Persuasion", "Ulysses",
                      "Moby-Dick", "Walden", "Beowulf", "Candide", "Hamlet"]
        let designs = try titles.map { try BookCoverDesign.make(title: $0, author: "Someone") }
        XCTAssertGreaterThan(Set(designs.map(\.palette.name)).count, 4, "the palette comes from the title")
        XCTAssertGreaterThan(Set(designs.map(\.motif)).count, 1)
    }

    func testNoCoverIsMadeWithoutBothTitleAndAuthor() {
        XCTAssertThrowsError(try BookCoverDesign.make(title: "Notes", author: nil)) {
            XCTAssertEqual($0 as? BookCoverDesign.Refusal, .noAuthor)
        }
        for placeholder in ["", "  ", "Unknown", "unknown author", "Anonymous"] {
            XCTAssertEqual(BookCoverDesign.refusal(title: "Notes", author: placeholder), .noAuthor, placeholder)
        }
        XCTAssertEqual(BookCoverDesign.refusal(title: " ", author: "Someone"), .noTitle)
        XCTAssertNil(BookCoverDesign.refusal(title: "Notes", author: "Someone"))
        XCTAssertEqual(BookCoverDesign.Refusal.noAuthor.description, "needs the book's author")
    }

    func testEveryPaletteIsLegible() {
        for palette in BookCoverDesign.palettes {
            XCTAssertGreaterThanOrEqual(BookCoverDesign.RGB.contrast(palette.ink, palette.background), 7, palette.name)
            XCTAssertGreaterThanOrEqual(BookCoverDesign.RGB.contrast(palette.accent, palette.background), 1.6, palette.name)
        }
    }

    #if canImport(ImageIO)
    func testADesignedCoverIsTheSameBytesEveryTime() throws {
        let design = try BookCoverDesign.make(title: "The Machine Stops", author: "E. M. Forster")
        let first = try BookCoverImaging.render(design)
        let second = try BookCoverImaging.render(try BookCoverDesign.make(title: "The Machine Stops", author: "E. M. Forster"))
        XCTAssertEqual(first, second)
        XCTAssertEqual(BookCoverImage.kind(of: first), .png)
        XCTAssertLessThanOrEqual(first.count, BookCoverImage.maximumBytes)
        let size = try XCTUnwrap(BookCoverImaging.pixelSize(of: first))
        XCTAssertEqual(size.width, 600)
        XCTAssertEqual(size.height, 900)
        let other = try BookCoverImaging.render(try BookCoverDesign.make(title: "The Machine Stops", author: "Someone Else"))
        XCTAssertNotEqual(first, other, "the author is on the cover")
        // A long title still renders, every word whole.
        let long = try BookCoverDesign.make(title: "The Strange Case of Dr Jekyll and Mr Hyde and Other Tales of Terror",
                                            author: "Robert Louis Stevenson")
        XCTAssertNoThrow(try BookCoverImaging.render(long))
        if let out = ProcessInfo.processInfo.environment["BATON_COVER_SAMPLES"] {
            try first.write(to: URL(fileURLWithPath: out).appendingPathComponent("machine-stops.png"))
            try BookCoverImaging.render(long).write(to: URL(fileURLWithPath: out).appendingPathComponent("jekyll.png"))
            for title in ["Frankenstein", "Pride and Prejudice", "Middlemarch", "Emma", "Walden", "Persuasion", "Dracula", "Ulysses"] {
                let design = try BookCoverDesign.make(title: title, author: "Sample Author")
                try BookCoverImaging.render(design).write(to: URL(fileURLWithPath: out)
                    .appendingPathComponent("\(design.motif.rawValue)-\(design.palette.name)-\(title).png"))
            }
        }
    }

    // MARK: - Every picture re-encoded

    func testAPictureIsReencodedAsABoundedJPEGWithoutItsMetadata() throws {
        let big = try picture(width: 3_000, height: 2_000, type: "public.jpeg", gps: true)
        let clean = try BookCoverImaging.sanitize(big)
        XCTAssertEqual(BookCoverImage.kind(of: clean), .jpeg)
        let size = try XCTUnwrap(BookCoverImaging.pixelSize(of: clean))
        XCTAssertEqual(max(size.width, size.height), BookCoverImage.maximumSide)
        XCTAssertLessThanOrEqual(abs(size.width * 2 - size.height * 3), 3, "the shape is kept")
        XCTAssertLessThanOrEqual(clean.count, BookCoverImage.maximumBytes)
        let properties = try XCTUnwrap(CGImageSourceCreateWithData(clean as CFData, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] })
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary], "where the picture was taken does not travel")

        let small = try BookCoverImaging.sanitize(try picture(width: 300, height: 450, type: "public.png", gps: false))
        XCTAssertEqual(BookCoverImage.kind(of: small), .jpeg)
        XCTAssertEqual(BookCoverImaging.pixelSize(of: small)?.width, 300, "a small picture is not enlarged")
    }

    func testWhatIsNotAPictureIsRefusedBeforeItIsKept() throws {
        XCTAssertThrowsError(try BookCoverImaging.sanitize(Data("<html><script>alert(1)</script></html>".utf8))) {
            XCTAssertEqual($0 as? BookCoverImaging.Failure, .notAnImage)
        }
        XCTAssertThrowsError(try BookCoverImaging.sanitize(Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]))) {
            XCTAssertEqual($0 as? BookCoverImaging.Failure, .notAnImage, "a JPEG signature on nothing")
        }
        XCTAssertThrowsError(try BookCoverImaging.sanitize(Data())) { XCTAssertEqual($0 as? BookCoverImaging.Failure, .tooLarge) }
        XCTAssertThrowsError(try BookCoverImaging.sanitize(Data(count: BookCoverImage.maximumSourceBytes + 1))) {
            XCTAssertEqual($0 as? BookCoverImaging.Failure, .tooLarge)
        }
        XCTAssertThrowsError(try BookCoverImaging.sanitize(try picture(width: 12, height: 12, type: "public.png", gps: false))) {
            XCTAssertEqual($0 as? BookCoverImaging.Failure, .tooSmall)
        }
    }

    private func picture(width: Int, height: Int, type: String, gps: Bool) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if gps {
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 40.7, kCGImagePropertyGPSLatitudeRef: "N",
                                                         kCGImagePropertyGPSLongitude: 74.0, kCGImagePropertyGPSLongitudeRef: "W"]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        if gps {
            let written = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            XCTAssertNotNil(written?[kCGImagePropertyGPSDictionary], "the fixture really carries a location")
        }
        return data as Data
    }
    #endif

    // MARK: - The home server's record

    func testTheSignatureDecidesTheKind() {
        XCTAssertEqual(BookCoverImage.kind(of: Data([0xFF, 0xD8, 0xFF, 0xDB])), .jpeg)
        XCTAssertEqual(BookCoverImage.kind(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])), .png)
        XCTAssertNil(BookCoverImage.kind(of: Data("GIF89a".utf8)))
        XCTAssertNil(BookCoverImage.kind(of: Data([0xFF, 0xD8])))
        XCTAssertEqual(BookCoverImage.Kind(mimeType: "image/JPEG; charset=binary"), .jpeg)
    }

    func testASummaryFromAGatewayBeforeCoversStillReads() throws {
        let old = #"{"id":"a","title":"T","status":"ready","chapters":[],"bytes":0,"createdAt":"2026-10-01T00:00:00Z"}"#
        let summary = try BookJSON.decoder.decode(BookJob.Summary.self, from: Data(old.utf8))
        XCTAssertNil(summary.cover)
    }
}
