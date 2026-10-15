import BatonDocuments
import BatonPlaybackKit
import BatonSubsonicKit
import Foundation
import XCTest
@testable import Baton

/// `import_document` (M3.6): an agent hands over a file or a link and gets a job id and what was
/// found. Pinned here rather than in the schema snapshot, because it is listed only while
/// `baton.documents.enabled` is on.
@MainActor
final class MCPDocumentToolTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("baton-mcp-docs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func library() -> DocumentLibrary {
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"),
                                      defaults: ThrowawayDefaults.make("mcp-docs"))
        let library = DocumentLibrary(clippings: clippings, directory: root.appendingPathComponent("Books"),
                                      synthesizer: DocumentLibraryTests.FakeKokoro(),
                                      retry: .init(initialDelay: 0.02, maximumDelay: 0.05))
        library.start(force: true)
        return library
    }

    private func markdown(_ name: String = "two-rooms.md") throws -> URL {
        let url = root.appendingPathComponent(name)
        try "# Two Rooms\n\n## The Cell\n\nA small room, like the cell of a bee.\n\n## The Surface\n\nThe light at the top was grey."
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testListedOnlyWhenAskedAndNeverUnderTestByDefault() throws {
        let names = { (defs: [[String: Any]]) in Set(defs.compactMap { $0["name"] as? String }) }
        XCTAssertFalse(names(BatonMCPToolCatalog.definitions()).contains("import_document"),
                       "the published surface under test must not depend on this Mac's flag")
        XCTAssertFalse(names(BatonMCPToolCatalog.definitions(includeDocuments: false)).contains("import_document"))

        let tool = try XCTUnwrap(BatonMCPToolCatalog.definitions(includeDocuments: true)
            .first { $0["name"] as? String == "import_document" })
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        XCTAssertEqual(Set((schema["properties"] as? [String: Any] ?? [:]).keys), ["path", "url", "voice"])
        XCTAssertEqual(schema["required"] as? [String], [])
        let annotations = try XCTUnwrap(tool["annotations"] as? [String: Any])
        XCTAssertEqual(annotations["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(annotations["openWorldHint"] as? Bool, true)
    }

    func testAFileBecomesABookAndTheAgentIsToldWhatWasFound() async throws {
        let library = library()
        let reply = try object(try await BatonMCPDocumentTools.run(["path": try markdown().path,
                                                                     "voice": "kokoro:bf_emma"], library: library))
        XCTAssertEqual(reply["status"] as? String, "rendering")
        XCTAssertEqual(reply["title"] as? String, "Two Rooms")
        XCTAssertEqual(reply["chapters"] as? [String], ["The Cell", "The Surface"])
        XCTAssertEqual(reply["voice"] as? String, "kokoro:bf_emma")
        let jobID = try XCTUnwrap(reply["job_id"] as? String)
        XCTAssertTrue(library.jobs.contains { $0.id == jobID })
    }

    /// A web page, read as an article: the navigation and the footer are not the book.
    func testALinkToAWebPageIsReadAsAnArticle() async throws {
        let library = library()
        let page = """
        <html><head><title>Two Rooms | Example Magazine</title></head><body>
        <nav><a href="/">Home</a> <a href="/subscribe">Subscribe</a></nav>
        <article><h1>Two Rooms</h1>
        <p>Imagine, if you can, a small room, hexagonal in shape, like the cell of a bee. It is lighted
        neither by window nor by lamp, yet it is filled with a soft radiance.</p>
        <p>An electric bell rang. The woman touched a switch and the music was silent.</p>
        </article><footer>Copyright Example Magazine. Cookie settings.</footer></body></html>
        """
        let asked = AskedURL()
        let reply = try object(try await BatonMCPDocumentTools.run(
            ["url": "https://example.com/two-rooms"], library: library,
            fetch: { request in
                asked.url = request.url
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                               headerFields: ["Content-Type": "text/html; charset=utf-8"])!
                return (Data(page.utf8), response)
            }))
        XCTAssertEqual(asked.url?.absoluteString, "https://example.com/two-rooms")
        XCTAssertEqual(reply["status"] as? String, "rendering")
        XCTAssertTrue((reply["title"] as? String ?? "").contains("Two Rooms"), "\(reply["title"] ?? "")")
        let job = try XCTUnwrap(library.jobs.first)
        let words = try XCTUnwrap(library.store.list().first { $0.id == job.id }?.book.chapters
            .flatMap(\.segments).map(\.text).joined(separator: " "))
        XCTAssertTrue(words.contains("hexagonal in shape"))
        XCTAssertFalse(words.contains("Subscribe") || words.contains("Cookie settings"), words)
    }

    func testWhatTheMacImports() {
        for ok in ["a.pdf", "a.epub", "a.html", "a.htm", "a.md", "a.txt"] {
            XCTAssertTrue(DocumentLibrary.canImport(URL(fileURLWithPath: "/tmp/" + ok)), ok)
        }
        for no in ["a.docx", "a.rtf", "a.mp3"] {
            XCTAssertFalse(DocumentLibrary.canImport(URL(fileURLWithPath: "/tmp/" + no)), no)
        }
        XCTAssertTrue(DocumentLibrary.canImport(URL(string: "https://example.com/an-article")!))
        XCTAssertFalse(DocumentLibrary.canImport(URL(string: "ftp://example.com/a.pdf")!))
    }

    func testWhatItRefusesAndWhy() async throws {
        let library = library()
        func message(_ args: [String: Any]) async -> String {
            do {
                _ = try await BatonMCPDocumentTools.run(args, library: library, fetch: { _ in throw URLError(.badURL) })
                return "no error"
            } catch let error as BatonMCPToolError {
                return error.message
            } catch {
                return "\(error)"
            }
        }
        let neither = await message([:])
        XCTAssertTrue(neither.contains("exactly one"), neither)
        let both = await message(["path": "/tmp/a.pdf", "url": "https://example.com/a.pdf"])
        XCTAssertTrue(both.contains("exactly one"), both)
        let missing = await message(["path": root.appendingPathComponent("nothing.pdf").path])
        XCTAssertTrue(missing.hasPrefix("No file at"), missing)
        let notHTTP = await message(["url": "ftp://example.com/a.pdf"])
        XCTAssertTrue(notHTTP.contains("http or https"), notHTTP)
        let docx = root.appendingPathComponent("letter.docx")
        try Data("x".utf8).write(to: docx)
        let unsupported = await message(["path": docx.path])
        XCTAssertTrue(unsupported.contains("PDF, EPUB, HTML, Markdown and plain text"), unsupported)
        XCTAssertTrue(library.jobs.isEmpty, "nothing refused was submitted")
    }
}

/// What the injected fetch was asked for. Written once from the fetch, read after it returns.
private final class AskedURL: @unchecked Sendable {
    var url: URL?
}
