import BatonDocuments
import Foundation

/// The `import_document` MCP tool: an agent hands Baton a file, and Baton makes it a narrated
/// book in Clippings (document clippings, M3.6).
///
/// The counterpart of `read_aloud` for things too long to hear in one sitting. `read_aloud`
/// takes text the agent already extracted; this takes the file itself, because Baton now
/// extracts documents better than an agent pasting text would: page numbers, running heads and
/// line-end hyphens removed, chapters found, the title and author taken from the first page.
/// Nothing is read aloud now. The book renders in the background, chapter 1 first, and appears
/// in Clippings, exactly as Import Document… does it.
///
/// Listed only while `baton.documents.enabled` is on.
@MainActor
enum BatonMCPDocumentTools {
    static func definition() -> [String: Any] {
        [
            "name": "import_document",
            "description": """
            Turn a document into a narrated audiobook in Baton's Clippings. Pass `path` (a PDF, \
            EPUB, HTML, Markdown or plain text file on this Mac) or `url` (a web page, read as an \
            article without its navigation, or a link to a PDF or text file). \
            Baton finds the title, author and chapters itself, removes page numbers and running \
            heads, joins words broken across lines, and leaves out anything shaped like a \
            credential. It then narrates the book chapter by chapter in the background, chapter 1 \
            first (usually ready in a minute or two), using the TTS host in Baton's Speech \
            settings. Nothing is played now: the book appears in Clippings, where it plays like \
            an album. Returns a job id, what was found (title, author, chapters, warnings) and \
            the estimated length and size. Use `read_aloud` instead to hear something right away.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute path to a .pdf, .epub, .html, .md or .txt file on this Mac."],
                    "url": ["type": "string", "description": "An http or https address: a web page (its article is read) or a link to a PDF or text file."],
                    "voice": ["type": "string", "description": "Optional narrator as 'engine:voice', e.g. 'kokoro:bf_emma'. Omit to use the default voice for the book's language."],
                ],
                "required": [],
            ],
        ]
    }

    static func run(_ args: [String: Any], library: DocumentLibrary,
                    fetch: @escaping DocumentImporter.Fetch = { try await URLSession.shared.data(for: $0) })
        async throws -> String {
        let path = (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let link = (args["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard path.isEmpty != link.isEmpty else {
            throw BatonMCPToolError(message: "import_document needs exactly one of `path` or `url`.")
        }

        let document: ImportedDocument
        let source: String
        do {
            if !path.isEmpty {
                let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: file.path) else {
                    throw BatonMCPToolError(message: "No file at \(file.path).")
                }
                guard DocumentLibrary.canImport(file) else {
                    throw BatonMCPToolError(message: "Baton can import PDF, EPUB, HTML, Markdown and plain text files; \(file.lastPathComponent) is none of those.")
                }
                document = try await DocumentLibrary.importDocument(at: file)
                source = file.lastPathComponent
            } else {
                guard let url = URL(string: link), DocumentLibrary.isWebLink(url) else {
                    throw BatonMCPToolError(message: "`url` must be an http or https link.")
                }
                document = try await DocumentLibrary.importDocument(fromWeb: url, fetch: fetch)
                source = url.host ?? link
            }
        } catch let failure as DocumentImporter.Failure {
            throw BatonMCPToolError(message: failure.description)
        }
        guard !document.chapters.isEmpty else {
            throw BatonMCPToolError(message: "Nothing to read aloud was found in \(source).")
        }

        let requested = (args["voice"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let voice = requested.isEmpty ? DocumentLibrary.languageDefaultVoice(for: document) : requested
        let book = DocumentSpeech.prepare(document, voices: VoicePlan(narrator: voice))
        let jobID = try await library.submit(book)
        let estimate = ListeningEstimate(document)
        documentsLog.notice("import_document: \"\(document.title, privacy: .public)\" submitted by an agent")

        return BatonMCPToolCatalog.jsonText([
            "status": "rendering",
            "job_id": jobID,
            "title": document.title,
            "author": document.author ?? "",
            "chapters": document.chapters.map(\.title),
            "estimated_length": estimate.durationText,
            "estimated_size": estimate.sizeText,
            "voice": voice,
            "made_on": "this Mac",
            "warnings": document.warnings.map(DocumentImportSheet.text(for:)),
        ])
    }
}
