import AVFoundation
import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation
import XCTest
@testable import Baton

/// M6.6 on the Mac: a finished book on the home server says when it will be removed there,
/// from the summary's `removesAt`, and that date is read back as soon as the book is marked
/// finished and again after a relaunch.
@MainActor
final class BookRetentionTests: XCTestCase {

    private var root: URL!
    private var clippings: ClippingStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"),
                                  defaults: ThrowawayDefaults.make("retention"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let november2 = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 11, day: 2, hour: 12))!

    private func book() throws -> PreparedBook {
        let url = root.appendingPathComponent("book.md")
        try "# The Machine Stops\n\n## Chapter 1\n\nSome words.\n\n## Chapter 2\n\nMore words.".write(to: url, atomically: true, encoding: .utf8)
        return DocumentSpeech.prepare(try DocumentImporter.importFile(at: url), voices: VoicePlan(narrator: "kokoro:bf_emma"))
    }

    private func summary(_ job: BookJob, removesAt: Date?) -> BookJob.Summary {
        var summary = job.summary
        summary.removesAt = removesAt
        return summary
    }

    // MARK: - The row

    func testKeptUntilIsWordedAsADate() {
        let now = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 15))!
        XCTAssertEqual(BookShelf.keptUntilText(Self.november2, now: now, locale: Locale(identifier: "en_US")), "Kept until November 2")
        let nextYear = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2027, month: 1, day: 9))!
        XCTAssertEqual(BookShelf.keptUntilText(nextYear, now: now, locale: Locale(identifier: "en_US")), "Kept until January 9, 2027",
                       "the year is said once it is not this one")
    }

    func testAFinishedHomeServerBookShowsWhenItIsKeptUntil() throws {
        let book = try book()
        var job = BookJob(id: "job-1", book: book)
        job.status = .ready
        job.finishedAt = Date()
        let remote = DocumentLibrary.Job(documentID: book.documentID, summary: summary(job, removesAt: Self.november2), renderer: .homeServer)

        var ledger = clippings.ledger
        ledger.setFinished(true, documentID: book.documentID)
        let finished = try XCTUnwrap(BookShelf.entries(items: [], jobs: [remote], ledger: ledger).compactMap { if case let .book(b) = $0 { b } else { nil } }.first)
        XCTAssertEqual(finished.removesAt, Self.november2)
        XCTAssertEqual(finished.keptUntilText, BookShelf.keptUntilText(Self.november2))

        let unfinished = try XCTUnwrap(BookShelf.entries(items: [], jobs: [remote], ledger: ClippingLedger()).compactMap { if case let .book(b) = $0 { b } else { nil } }.first)
        XCTAssertNil(unfinished.keptUntilText, "nothing is said before the book is finished")
    }

    // MARK: - The home server

    /// A gateway that accepts the submission, takes the finished mark, and from then on answers
    /// the status with `removesAt`.
    private final class FakeGateway: @unchecked Sendable {
        var job: BookJob
        var finishedAt: Date?
        var removesAt: Date?
        var calls: [String] = []
        var gone = false
        init(job: BookJob) { self.job = job }

        func transport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url!.path
            calls.append("\(request.httpMethod!) \(path)")
            func ok(_ data: Data, status: Int = 200) -> (Data, HTTPURLResponse) {
                (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            if gone { return ok(Data("{\"error\":\"no such book\"}".utf8), status: 404) }
            if path.hasSuffix("/finished") {
                finishedAt = Date()
                return ok(Data("{}".utf8))
            }
            var summary = job.summary
            summary.removesAt = finishedAt.map { _ in removesAt! }
            return ok(try BookJSON.encoder.encode(summary))
        }
    }

    private func tone(seconds: Double) throws -> URL {
        let url = root.appendingPathComponent("tone-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(24_000 * seconds))!
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
        return url
    }

    func testMarkingABookFinishedReadsItsRetentionDateBack() async throws {
        let book = try book()
        let gateway = FakeGateway(job: BookJob(id: BookJob.id(for: book), book: book))
        gateway.removesAt = Self.november2
        let client = GatewayBookClient(baseURL: URL(string: "http://home.test")!, token: "t", transport: gateway.transport)
        let books = HomeServerBooks(directory: root, clippings: clippings, gateway: { client })
        let id = try await books.submit(book)
        XCTAssertNil(books.summaries[id]?.removesAt)

        await books.markFinished(jobID: id)
        XCTAssertEqual(books.summaries[id]?.removesAt, Self.november2)
        XCTAssertEqual(gateway.calls.suffix(2), ["POST /v1/books/\(id)/finished", "GET /v1/books/\(id)"])
    }

    func testACollectedBookIsAskedAboutOnceAfterARelaunchAndForgottenOnceTheServerRemovedIt() async throws {
        let book = try book()
        let gateway = FakeGateway(job: BookJob(id: BookJob.id(for: book), book: book))
        gateway.removesAt = Self.november2
        gateway.finishedAt = Date()
        let client = GatewayBookClient(baseURL: URL(string: "http://home.test")!, token: "t", transport: gateway.transport)
        let first = HomeServerBooks(directory: root, clippings: clippings, gateway: { client })
        let id = try await first.submit(book)
        for index in book.chapters.indices {
            try clippings.adopt(try tone(seconds: 1), title: "Chapter \(index + 1)", durationSeconds: 1,
                                chapter: .init(documentID: book.documentID, documentTitle: book.title, author: nil,
                                               chapterIndex: index, chapterTitle: "Chapter \(index + 1)"))
        }

        // A relaunch: a new instance over the same file knows the record but no summary.
        let relaunched = HomeServerBooks(directory: root, clippings: clippings, gateway: { client })
        XCTAssertTrue(relaunched.isCollected(try XCTUnwrap(relaunched.record(forJob: id))))
        XCTAssertNil(relaunched.summaries[id])
        // Each round also lists the home server's books to adopt others'; only the
        // calls about this book count here.
        let bookCalls = { gateway.calls.filter { $0 != "GET /v1/books" }.count }
        let before = bookCalls()
        await relaunched.collect()
        XCTAssertEqual(relaunched.summaries[id]?.removesAt, Self.november2)
        XCTAssertEqual(bookCalls(), before + 1, "one status call, no chapter fetched")
        await relaunched.collect()
        XCTAssertEqual(bookCalls(), before + 1, "and not asked again while the summary is known")

        gateway.gone = true
        let later = HomeServerBooks(directory: root, clippings: clippings, gateway: { client })
        await later.collect()
        XCTAssertNil(later.record(forJob: id), "removed on the server: the record goes")
        XCTAssertNil(later.problem, "retention happening is not a problem to report")
        XCTAssertEqual(clippings.chapters(ofDocument: book.documentID).count, book.chapters.count, "the chapters stay")
    }
}
