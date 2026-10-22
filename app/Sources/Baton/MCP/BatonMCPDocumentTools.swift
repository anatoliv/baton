import BatonDocuments
import Foundation

/// The `import_document` MCP tool: an agent hands Baton a file, and Baton makes it a narrated
/// book in Books (document clippings, M3.6; Books since an internal task).
///
/// The counterpart of `read_aloud` for things too long to hear in one sitting. `read_aloud`
/// takes text the agent already extracted; this takes the file itself, because Baton now
/// extracts documents better than an agent pasting text would: page numbers, running heads and
/// line-end hyphens removed, chapters found, the title and author taken from the first page.
/// Nothing is read aloud now. The book renders in the background, chapter 1 first, and appears
/// in Books, exactly as Import Document… does it.
///
/// Listed only while `baton.documents.enabled` is on.
@MainActor
enum BatonMCPDocumentTools {
    static func definition() -> [String: Any] {
        [
            "name": "import_document",
            "description": """
            Turn a document into a narrated audiobook in Baton's Books. Pass `path` (a PDF, \
            EPUB, HTML, Markdown or plain text file on this Mac) or `url` (a web page, read as an \
            article without its navigation, or a link to a PDF or text file). \
            Baton finds the title, author and chapters itself, removes page numbers and running \
            heads, joins words broken across lines, and leaves out anything shaped like a \
            credential. It then narrates the book chapter by chapter in the background, chapter 1 \
            first (usually ready in a minute or two). It is made where Settings, Speech, Make \
            books on says: on this Mac, or on the Baton server, which carries on while the Mac \
            sleeps; when that is Ask each time, on this Mac unless you pass `where`. If the Baton \
            server does not answer, this Mac makes it. Nothing is played now: the book appears \
            in Books, where it plays like an album. Returns a job id, where the book is being \
            made (`made_on`), what was found (title, author, chapters, warnings) and the \
            estimated length and size. Use `read_aloud` instead to hear something right away.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute path to a .pdf, .epub, .html, .md or .txt file on this Mac."],
                    "url": ["type": "string", "description": "An http or https address: a web page (its article is read) or a link to a PDF or text file."],
                    "voice": ["type": "string", "description": "Optional narrator as 'engine:voice', e.g. 'kokoro:bf_emma'. Omit to use the default voice for the book's language."],
                    "tone": ["type": "string", "description": "Optional: the book's tone in a few words, e.g. 'dark, ominous' or 'calm, measured'. A Chatterbox narrator reads more or less expressively to suit it; Kokoro voices ignore it."],
                    "where": [
                        "type": "string",
                        "enum": [Place.thisMac.rawValue, Place.homeServer.rawValue],
                        "description": "Optional: where to make the book, 'this_mac' or 'home_server' (the person's Baton server, the Baton program they run at home). Used only when Make books on in Baton's Speech settings is Ask each time; otherwise that setting decides. Without it, Ask each time makes the book on this Mac.",
                    ],
                ],
                "required": [],
            ],
        ]
    }

    /// The `where` argument's two values.
    enum Place: String {
        case thisMac = "this_mac"
        case homeServer = "home_server"
    }

    /// Where the book is made, before the home server is asked: Settings → Speech → Make books
    /// on decides, and only Ask each time lets the agent's `where` choose. With
    /// neither, this Mac, which is what the tool always did.
    static func wanted(_ setting: BookVoiceSettings.MakeBooksOn, place: Place?) -> DocumentLibrary.Renderer {
        switch setting {
        case .thisMac: .thisMac
        case .homeServer: .homeServer
        case .ask: place == .homeServer ? .homeServer : .thisMac
        }
    }

    /// `makeBooksOn` is the setting, passed in so tests need not write Baton's defaults.
    static func run(_ args: [String: Any], library: DocumentLibrary,
                    makeBooksOn: BookVoiceSettings.MakeBooksOn = BookVoiceSettings.makeBooksOn,
                    fetch: @escaping DocumentImporter.Fetch = DocumentImporter.pageFetch)
        async throws -> String {
        let path = (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let link = (args["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard path.isEmpty != link.isEmpty else {
            throw BatonMCPToolError(message: "import_document needs exactly one of `path` or `url`.")
        }
        let rawPlace = (args["where"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let place = Place(rawValue: rawPlace.lowercased())
        guard rawPlace.isEmpty || place != nil else {
            throw BatonMCPToolError(message: "`where` must be 'this_mac' or 'home_server'.")
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
        let tone = (args["tone"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = VoicePlan.forBook(narrator: voice, tone: tone)
        let book = DocumentSpeech.prepare(document, voices: plan)
        var renderer = wanted(makeBooksOn, place: place)
        var note: String?
        if renderer == .homeServer, !(await library.homeServerAvailable()) {
            renderer = .thisMac
            note = BookVoiceSettings.homeServerFallbackNote
        } else if makeBooksOn != .ask, let place, wanted(.ask, place: place) != renderer {
            note = "Make books on is set to \(makeBooksOn.title) in Settings, Speech, so `where` was not used."
        }
        let jobID = try await library.submit(book, on: renderer)
        let estimate = ListeningEstimate(document)
        documentsLog.notice("import_document: \"\(document.title, privacy: .private)\" submitted by an agent, made on \(renderer.rawValue, privacy: .public)")

        var reply: [String: Any] = [
            "status": "rendering",
            "job_id": jobID,
            "title": document.title,
            "author": document.author ?? "",
            "chapters": document.chapters.map(\.title),
            "estimated_length": estimate.durationText,
            "estimated_size": estimate.sizeText,
            "voice": voice,
            "made_on": renderer == .homeServer ? "the Baton server" : "this Mac",
            "warnings": document.warnings.map(DocumentImportSheet.text(for:)),
        ]
        if let note { reply["note"] = note }
        if let style = plan.style {
            reply["expressive_style"] = ["exaggeration": style.exaggeration, "cfg_weight": style.cfgWeight]
        }
        return BatonMCPToolCatalog.jsonText(reply)
    }
}
