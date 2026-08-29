import Foundation

/// The `read_aloud` MCP tool: an agent hands Baton text it already has, and Baton reads it.
///
/// **Why this exists instead of Chrome article extraction.** Reading a web page well
/// means getting the article and dropping the nav, the cookie banner and the footer. Baton could
/// do that itself through AppleScript, but `execute javascript` against Chrome only works once
/// the user has ticked View → Developer → "Allow JavaScript from Apple Events" by hand, and it
/// raises an Automation prompt for Chrome specifically. A per-machine hidden toggle can never be
/// a default path.
///
/// An agent driving the browser has already solved that problem for its own reasons: it can read
/// the page, and it knows which part of it is the article. So the extraction happens where the
/// knowledge is, and Baton keeps the part it is good at — preparing text for the ear and speaking
/// it. No permission, no AppleScript, nothing to switch on.
///
/// Everything after the hand-off is the ordinary reading path: the text goes through
/// `ScreenTextReader.capture`, so it is redacted and normalized exactly like a selection, and it
/// reaches `ReadAloudCoordinator` with the same ducking, the same HUD and the same
/// never-persisted rule. This tool adds an entry point, not a second pipeline.
@MainActor
enum BatonMCPReadTools {

    /// A whole article or a terminal scrollback, not a summary — so the cap is far above
    /// `speak_summary`'s. For scale: the Phase 0 probe pulled 79,396 characters out of a Ghostty
    /// window in one go. The limit exists to refuse something pathological, not to shape input.
    static let maxCharacters = 200_000

    static func definition() -> [String: Any] {
        [
            "name": "read_aloud",
            "description": """
            Read text aloud through Baton, on the user's speakers, with the music ducked \
            underneath and a window showing the text with the current sentence highlighted. \
            Use it to hand over something you have already extracted — the article text from a \
            page you are driving, a long file, command output worth listening to. This is for \
            *documents*: for a one- or two-sentence "I finished the task" alert, use \
            `speak_summary` instead, which has the notification and banner delivery modes. \
            Baton prepares the text for the ear before speaking a word of it: anything shaped \
            like a credential is removed, hashes and URLs are shortened, code blocks are \
            announced rather than pronounced, and with `kind: "terminal"` colour codes and \
            shell prompts are stripped. Set `kind` to match where the text came from. Pass \
            `source` (the site, app or file name) — it labels the reading and, when the user \
            has per-app voices on, chooses the voice. `gist: true` summarizes first and reads \
            the summary, which needs a model configured in Baton's Remote settings. Reading \
            starts immediately and returns straight away, and it is not persisted anywhere. \
            Send several and they are read one after another in the order they arrived, so \
            handing over three articles reads all three rather than only the last.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The text to read. An article, a document, a scrollback — not a one-line alert."],
                    "source": ["type": "string", "description": "Where it came from, e.g. 'arstechnica.com' or 'Ghostty'. Shown with the reading and used to pick a voice when per-app voices are on."],
                    "kind": ["type": "string", "description": "'browser' (drop web furniture), 'terminal' (strip ANSI and shell prompts, keep the last command's output), or 'generic' (default). Every option redacts credentials."],
                    "gist": ["type": "boolean", "description": "Summarize first and read the summary rather than the whole thing. Needs a model configured in Baton's Remote settings; says so when there isn't one."],
                ],
                "required": ["text"],
            ],
        ]
    }

    static func run(_ args: [String: Any]) throws -> String {
        guard let text = args["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw BatonMCPToolError(message: "read_aloud needs `text` — the text to read.")
        }
        guard text.count <= maxCharacters else {
            throw BatonMCPToolError(
                message: "That's \(text.count) characters; read_aloud takes up to \(maxCharacters). Send the part worth listening to."
            )
        }

        let kind = (args["kind"] as? String)?.lowercased() ?? "generic"
        // `SourceProfile` is already spelled with exactly these names, so its raw value is the
        // parser — a second mapping here would be one more place for the two to drift apart.
        guard let profile = SpeakableText.SourceProfile(rawValue: kind) else {
            throw BatonMCPToolError(message: "Unknown kind \"\(kind)\" — use 'browser', 'terminal', or 'generic'.")
        }
        let source = (args["source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let gist = args["gist"] as? Bool ?? false

        // Through the shared capture path rather than straight to the coordinator, so this entry
        // gets the same cleaning, the same redaction and the same `lastCapture` record as the
        // Services menu and the hotkey. One pipeline, three doors into it.
        ScreenTextReader.shared.capture(
            text,
            sourceName: (source?.isEmpty == false) ? source : nil,
            profile: profile,
            gist: gist
        )

        // The reading is under way; reporting the *prepared* length would mean preparing it twice,
        // and the agent's useful number is what it sent.
        return BatonMCPToolCatalog.jsonText([
            "status": gist ? "summarizing" : "reading",
            "chars": text.count,
            "kind": kind,
            "source": source ?? "",
        ])
    }
}

