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

    /// No home server unless a test hands one in, so nothing here reaches this Mac's real gateway.
    private func library(gateway: @escaping @MainActor () -> GatewayBookClient? = { nil }) -> DocumentLibrary {
        let clippings = ClippingStore(directory: root.appendingPathComponent("Clippings"),
                                      defaults: ThrowawayDefaults.make("mcp-docs"))
        let library = DocumentLibrary(clippings: clippings, directory: root.appendingPathComponent("Books"),
                                      synthesizer: DocumentLibraryTests.FakeKokoro(),
                                      retry: .init(initialDelay: 0.02, maximumDelay: 0.05),
                                      gateway: gateway)
        library.start(force: true)
        return library
    }

    private func markdown(_ name: String = "two-rooms.md") throws -> URL {
        let url = root.appendingPathComponent(name)
        try "# Two Rooms\n\n## The Cell\n\nA small room, like the cell of a bee.\n\n## The Surface\n\nThe light at the top was grey. (\(name))"
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
        let properties = schema["properties"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(properties.keys), ["path", "url", "voice", "tone", "where"])
        let place = try XCTUnwrap(properties["where"] as? [String: Any])
        XCTAssertEqual(place["enum"] as? [String], ["this_mac", "home_server"])
        XCTAssertTrue((place["description"] as? String ?? "").contains("Ask each time"))
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

    /// M8.7: an agent's `tone` styles a Chatterbox narrator; a Kokoro narrator's book is unstyled
    /// (and keeps its job id), and no tone means the engine's defaults.
    func testTheAgentsToneStylesAChatterboxNarrator() async throws {
        let library = library()
        let styled = try object(try await BatonMCPDocumentTools.run(["path": try markdown().path,
                                                                      "voice": "chatterbox:Emily.wav",
                                                                      "tone": "dark, ominous"], library: library))
        let styledJob = try XCTUnwrap(library.store.load(XCTUnwrap(styled["job_id"] as? String)))
        XCTAssertEqual(styledJob.book.voices.style, SpeechStyle(exaggeration: 0.7, cfgWeight: 0.3))
        let reported = try XCTUnwrap(styled["expressive_style"] as? [String: Any])
        XCTAssertEqual(reported["exaggeration"] as? Double, 0.7)
        XCTAssertEqual(reported["cfg_weight"] as? Double, 0.3)

        let kokoro = try object(try await BatonMCPDocumentTools.run(["path": try markdown("kokoro.md").path,
                                                                      "voice": "kokoro:bf_emma",
                                                                      "tone": "dark, ominous"], library: library))
        let kokoroJob = try XCTUnwrap(library.store.load(XCTUnwrap(kokoro["job_id"] as? String)))
        XCTAssertNil(kokoroJob.book.voices.style)
        XCTAssertNil(kokoro["expressive_style"])

        let plain = try object(try await BatonMCPDocumentTools.run(["path": try markdown("plain.md").path,
                                                                     "voice": "chatterbox:Emily.wav"], library: library))
        XCTAssertNil(try XCTUnwrap(library.store.load(XCTUnwrap(plain["job_id"] as? String))).book.voices.style)
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

    // MARK: Where the book is made (Settings → Speech → Make books on)

    private func homeServer(_ fake: DocumentLibraryHomeServerTests.FakeGateway) -> @MainActor () -> GatewayBookClient? {
        { GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { fake.answer($0) } }
    }

    /// A gateway that is set up and does not answer.
    private let silent: @MainActor () -> GatewayBookClient? = {
        GatewayBookClient(baseURL: URL(string: "http://gateway.test:8788")!, token: "t") { _ in throw URLError(.cannotConnectToHost) }
    }

    private func make(_ args: [String: Any] = [:], on library: DocumentLibrary,
                      setting: BookVoiceSettings.MakeBooksOn, file: String = "two-rooms.md") async throws -> [String: Any] {
        var all = args
        all["path"] = try markdown(file).path
        return try object(try await BatonMCPDocumentTools.run(all, library: library, makeBooksOn: setting))
    }

    func testThisMacMakesItHereAndTheArgumentDoesNotOverrideTheSetting() async throws {
        let fake = DocumentLibraryHomeServerTests.FakeGateway()
        let library = library(gateway: homeServer(fake))
        let reply = try await make(["where": "home_server"], on: library, setting: .thisMac)
        XCTAssertEqual(reply["made_on"] as? String, "this Mac")
        XCTAssertEqual(reply["note"] as? String, "Make books on is set to This Mac in Settings, Speech, so `where` was not used.")
        XCTAssertEqual(library.jobs.first?.renderer, .thisMac)
        XCTAssertFalse(fake.seen.contains { $0.hasPrefix("PUT") }, "\(fake.seen)")
    }

    func testHomeServerSendsItToTheHomeServer() async throws {
        let fake = DocumentLibraryHomeServerTests.FakeGateway()
        let library = library(gateway: homeServer(fake))
        let reply = try await make(on: library, setting: .homeServer)
        let jobID = try XCTUnwrap(reply["job_id"] as? String)
        XCTAssertEqual(reply["made_on"] as? String, "the Baton server")
        XCTAssertNil(reply["note"])
        XCTAssertTrue(fake.seen.contains("PUT /v1/books/\(jobID)"), "\(fake.seen)")
        XCTAssertEqual(library.jobs.first { $0.id == jobID }?.renderer, .homeServer)
        XCTAssertNil(library.store.load(jobID), "nothing rendered on this Mac")
    }

    func testHomeServerFallsBackToThisMacWhenItDoesNotAnswer() async throws {
        let gateways: [@MainActor () -> GatewayBookClient?] = [silent, { nil }]
        for gateway in gateways {
            let library = library(gateway: gateway)
            let reply = try await make(on: library, setting: .homeServer, file: "fallback-\(UUID().uuidString).md")
            let jobID = try XCTUnwrap(reply["job_id"] as? String)
            XCTAssertEqual(reply["made_on"] as? String, "this Mac")
            XCTAssertEqual(reply["note"] as? String, "The Baton server is not answering, so this Mac makes it.")
            XCTAssertNotNil(library.store.load(jobID), "made here instead")
            library.stop()
        }
    }

    func testAskEachTimeMakesItHereUnlessTheCallSaysWhere() async throws {
        let fake = DocumentLibraryHomeServerTests.FakeGateway()
        let library = library(gateway: homeServer(fake))

        let plain = try await make(on: library, setting: .ask)
        XCTAssertEqual(plain["made_on"] as? String, "this Mac")
        XCTAssertNil(plain["note"])
        XCTAssertTrue(fake.seen.isEmpty, "the home server is not even asked: \(fake.seen)")

        let here = try await make(["where": "this_mac"], on: library, setting: .ask, file: "here.md")
        XCTAssertEqual(here["made_on"] as? String, "this Mac")
        XCTAssertNil(here["note"])

        let there = try await make(["where": "home_server"], on: library, setting: .ask, file: "there.md")
        XCTAssertEqual(there["made_on"] as? String, "the Baton server")
        let thereID = try XCTUnwrap(there["job_id"] as? String)
        XCTAssertTrue(fake.seen.contains("PUT /v1/books/\(thereID)"), "\(fake.seen)")

        let quiet = self.library(gateway: silent)
        let fellBack = try await make(["where": "home_server"], on: quiet, setting: .ask, file: "quiet.md")
        XCTAssertEqual(fellBack["made_on"] as? String, "this Mac")
        XCTAssertEqual(fellBack["note"] as? String, "The Baton server is not answering, so this Mac makes it.")
    }

    func testAnUnknownPlaceIsRefusedBeforeAnythingIsMade() async throws {
        let library = library()
        do {
            _ = try await make(["where": "the cloud"], on: library, setting: .ask)
            XCTFail("expected a refusal")
        } catch let error as BatonMCPToolError {
            XCTAssertEqual(error.message, "`where` must be 'this_mac' or 'home_server'.")
        }
        XCTAssertTrue(library.jobs.isEmpty)
    }
}

/// What the injected fetch was asked for. Written once from the fetch, read after it returns.
private final class AskedURL: @unchecked Sendable {
    var url: URL?
}
