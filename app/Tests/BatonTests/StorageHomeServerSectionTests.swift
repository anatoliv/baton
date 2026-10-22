import BatonDocuments
import Foundation
import XCTest
@testable import Baton

/// Settings > Storage, the Home Server section (M6.4): what it shows for a listing read
/// through `HomeServerBooks.listing()` from a gateway's `GET /v1/books` answer, its footer, and
/// what it says when no home server is set up, while it asks, and when the asking fails.
@MainActor
final class StorageHomeServerSectionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-storage-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let november2 = Date(timeIntervalSince1970: 1_793_620_800)   // 2 November 2026, 12:00 UTC

    /// A home server whose every request gets `status` and `body`.
    private func homeServer(status: Int, body: [String: Any]) throws -> HomeServerBooks {
        let data = try JSONSerialization.data(withJSONObject: body)
        let client = GatewayBookClient(baseURL: URL(string: "http://home.test:8788")!, token: "t") { request in
            (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"),
                                      defaults: ThrowawayDefaults.make("storage-server-clips"))
        return HomeServerBooks(directory: root, clippings: clippings, gateway: { client })
    }

    private func summary(_ id: String, _ title: String, status: String, bytes: Int,
                         pauseReason: String? = nil, removesAt: Date? = nil) -> [String: Any] {
        var book: [String: Any] = ["id": id, "title": title, "status": status, "chapters": [] as [Any],
                                   "bytes": bytes, "createdAt": "2026-10-01T09:00:00Z"]
        if let pauseReason { book["pauseReason"] = pauseReason }
        if let removesAt {
            book["finishedAt"] = "2026-10-03T09:00:00Z"
            book["removesAt"] = ISO8601DateFormatter().string(from: removesAt)
        }
        return book
    }

    // MARK: - A listing

    func testEachBookOnTheHomeServerIsARowWithWhatIsHappeningToItAndItsSize() async throws {
        let server = try homeServer(status: 200, body: [
            "books": [
                summary("b1", "The Machine Stops", status: "ready", bytes: 2_400_000, removesAt: Self.november2),
                summary("b2", "Two Rooms", status: "rendering", bytes: 830_000),
                summary("b3", "The Cell", status: "paused", bytes: 12_000_000, pauseReason: "the voice server is busy"),
                summary("b4", "Notes", status: "ready", bytes: 640),
            ],
            "used_bytes": 15_231_000, "maximum_bytes": 4 * 1024 * 1024 * 1024,
            "keep_finished_days": 30, "available": true,
        ])
        let read = await server.listing()
        let listing = try XCTUnwrap(read, "the listing is read")
        XCTAssertNil(server.problem)

        let content = BatonStoragePane.homeServerContent(configured: server.isConfigured, listing: listing,
                                                         asking: false, problem: server.problem)
        XCTAssertEqual(content, .books([
            .init(id: "b1", title: "The Machine Stops", status: "Finished · " + BookShelf.keptUntilText(Self.november2), size: "2 MB"),
            .init(id: "b2", title: "Two Rooms", status: "Being made", size: "830 KB"),
            .init(id: "b3", title: "The Cell", status: "Paused: the voice server is busy", size: "12 MB"),
            .init(id: "b4", title: "Notes", status: "Ready", size: "640 bytes"),
        ]))
        XCTAssertEqual(BatonStoragePane.serverFooter(listing),
                       "Using 15 MB of 4.3 GB. Finished books are kept there for 30 days, and a book you have not finished is never removed.")
    }

    func testAFailedBookSaysStopped() async throws {
        let server = try homeServer(status: 200, body: [
            "books": [summary("b5", "Refused", status: "failed", bytes: 0)],
            "used_bytes": 0, "maximum_bytes": 0, "keep_finished_days": 0, "available": true,
        ])
        let read = await server.listing()
        let listing = try XCTUnwrap(read)
        XCTAssertEqual(BatonStoragePane.homeServerContent(configured: true, listing: listing, asking: false, problem: nil),
                       .books([.init(id: "b5", title: "Refused", status: "Stopped", size: "0 bytes")]))
    }

    func testAnEmptyServerWithBooksOffSaysSoInTheFooter() async throws {
        let server = try homeServer(status: 200, body: [
            "books": [] as [Any], "used_bytes": 0, "maximum_bytes": 0, "keep_finished_days": 0,
            "available": false, "unavailable_reason": "ffmpeg is not installed on the gateway",
        ])
        let read = await server.listing()
        let listing = try XCTUnwrap(read)
        XCTAssertEqual(BatonStoragePane.homeServerContent(configured: true, listing: listing, asking: false, problem: nil),
                       .books([]))
        XCTAssertEqual(BatonStoragePane.serverFooter(listing),
                       "Using 0 bytes. Books are off there: ffmpeg is not installed on the gateway.",
                       "no ceiling and no keep rule: neither is claimed")
    }

    func testAListingAlreadyShownStaysWhileRefreshAsksAgain() async throws {
        let server = try homeServer(status: 200, body: [
            "books": [] as [Any], "used_bytes": 0, "maximum_bytes": 0, "keep_finished_days": 0, "available": true,
        ])
        let read = await server.listing()
        let listing = try XCTUnwrap(read)
        XCTAssertEqual(BatonStoragePane.homeServerContent(configured: true, listing: listing, asking: true, problem: nil),
                       .books([]), "an empty listing is still a listing: the view says the home server has no books")
        XCTAssertEqual(BatonStoragePane.noServerBooksText, "The Baton server has no books.")
        XCTAssertEqual(BatonStoragePane.homeServerContent(configured: true, listing: nil, asking: true, problem: nil),
                       .asking, "nothing shown yet: it says it is asking")
    }

    // MARK: - Not set up, and failures

    func testWithNoHomeServerItSaysEveryBookIsKeptOnThisMac() async {
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"),
                                      defaults: ThrowawayDefaults.make("storage-server-none"))
        let server = HomeServerBooks(directory: root, clippings: clippings, gateway: { nil })
        XCTAssertFalse(server.isConfigured)
        let listing = await server.listing()
        XCTAssertNil(listing, "nothing is asked")
        XCTAssertEqual(BatonStoragePane.homeServerContent(configured: server.isConfigured, listing: listing,
                                                          asking: false, problem: server.problem),
                       .notConfigured)
        XCTAssertEqual(BatonStoragePane.notConfiguredText,
                       "No Baton server is set up, so every book is made and kept on this Mac.")
    }

    func testARefusedTokenIsSaidInAListenersWords() async throws {
        let server = try homeServer(status: 401, body: ["error": "unauthorized"])
        let listing = await server.listing()
        XCTAssertNil(listing)
        XCTAssertEqual(BatonStoragePane.homeServerContent(configured: server.isConfigured, listing: listing,
                                                          asking: false, problem: server.problem),
                       .problem("The Baton server could not be asked: the Baton server didn't accept Baton's token."))
    }

    func testBooksOffOnTheServerAndAnUnknownFailureAreEachSaid() async throws {
        let off = try homeServer(status: 503, body: ["error": "books are off"])
        _ = await off.listing()
        XCTAssertEqual(BatonStoragePane.homeServerContent(configured: true, listing: nil, asking: false, problem: off.problem),
                       .problem("The Baton server could not be asked: books are off on the Baton server."))
        XCTAssertEqual(BatonStoragePane.homeServerContent(configured: true, listing: nil, asking: false, problem: nil),
                       .problem("The Baton server could not be asked: it isn't answering."),
                       "no reason recorded: still a sentence")
    }
}
