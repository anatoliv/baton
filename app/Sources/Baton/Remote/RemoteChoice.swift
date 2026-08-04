import Foundation

/// One offered option: what it's called, and the command it runs if picked.
///
/// The command is an ordinary Baton chat command, which is the whole trick —
/// tapping a button, typing "2", and typing `play chill` all converge on
/// `RemoteCommandParser`. No third code path, and nothing to keep in sync.
struct RemoteChoice: Equatable, Sendable {
    var label: String
    var command: String
    /// The fact that decides it — track count, length, why this one. Shown in
    /// the message body, never on the button.
    var detail: String = ""
}

/// A question the agent asked, and the options it offered.
struct RemoteChoicePrompt: Equatable, Sendable {
    static let toolName = "ask_choice"
    /// Telegram's `callback_data` is capped at 64 bytes, so a button can't carry
    /// "play Space Ambient, Psychill, Psybient Mix". It carries `pick 2`, and
    /// the pending prompt turns that back into the command — which also makes a
    /// typed "2" and a tap literally the same message.
    static func payload(for index: Int) -> String { "pick \(index + 1)" }

    var question: String
    var options: [RemoteChoice]
    /// Index of the option to take if nobody answers. Always valid.
    var recommended: Int

    var recommendedChoice: RemoteChoice { options[recommended] }

    // MARK: From the model

    init?(arguments: [String: RemoteArgument]) {
        guard case let .string(question)? = arguments["question"], !question.isEmpty
        else { return nil }

        // Options arrive flattened. Nested arrays-of-objects survive neither
        // `RemoteArgument` nor half the OpenAI-compatible servers people point
        // Baton at, and a schema that only works on some providers is worse
        // than a plainer one that works everywhere.
        var options: [RemoteChoice] = []
        for index in 1 ... 4 {
            guard case let .string(label)? = arguments["label_\(index)"], !label.isEmpty
            else { continue }
            // The command is optional: a label is a thing you can play, so
            // "play <label>" is the obvious reading and asking for both raises
            // the bar to calling this tool at all. `repair` handles the rest.
            var command = label
            if case let .string(given)? = arguments["command_\(index)"], !given.isEmpty {
                command = given
            }
            var detail = ""
            if case let .string(why)? = arguments["detail_\(index)"] { detail = why }
            options.append(RemoteChoice(
                label: label, command: Self.repair(command, label: label), detail: detail))
        }
        guard options.count >= 2 else { return nil }

        var recommended = 0
        if case let .int(value)? = arguments["recommended"], (1 ... options.count).contains(value) {
            recommended = value - 1
        }

        self.question = question
        self.options = options
        self.recommended = recommended
    }

    /// Turn a command written as a *tool name* into the chat command it meant.
    ///
    /// Observed against a real model: asked for the command to run, it answered
    /// `"music_play"` — the name of the tool it would have called — with the
    /// artist only in the label. Left alone that parses as plain English and
    /// costs a round trip to rediscover what the label already said. The schema
    /// now spells out what's wanted, but a prompt is a request and this is the
    /// guarantee: the option a person taps has to do something.
    static func repair(_ command: String, label: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1)
        guard let head = parts.first, let verb = toolVerbs[String(head).lowercased()] else {
            // Not a tool name. If it starts with a verb Baton knows it is
            // already a command; otherwise it is a bare subject ("DIDO", a
            // label used as the command), which only means one thing here.
            if case .tool = RemoteCommandParser.parse(trimmed) { return trimmed }
            return trimmed.isEmpty ? trimmed : "play \(trimmed)"
        }
        // `music_play DIDO` → `play DIDO`; a bare `music_play` has to borrow the
        // label, which is the only description of the option there is.
        let rest = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespaces)
            : label.trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? verb : "\(verb) \(rest)"
    }

    /// The tool names a model is most likely to reach for here, and the chat
    /// verb each one means.
    private static let toolVerbs: [String: String] = [
        "music_play": "play", "music_queue_add": "queue", "music_play_next": "playnext",
        "music_play_playlist": "playlist", "music_build_mix": "mix",
        "music_start_radio": "radio", "music_search": "search",
    ]

    init(question: String, options: [RemoteChoice], recommended: Int = 0) {
        self.question = question
        self.options = options
        self.recommended = options.indices.contains(recommended) ? recommended : 0
    }

    // MARK: Rendering

    /// The message body. The options are numbered here even though buttons
    /// exist, because buttons don't survive a forwarded message, a screen
    /// reader, or a client that renders them badly — and "2" must always work.
    func rendered() -> String {
        var lines = [question]
        for (index, option) in options.enumerated() {
            let marker = "*\(index + 1).* \(option.label)"
            lines.append(option.detail.isEmpty ? marker : "\(marker) — \(option.detail)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: The tool the model calls

    /// Deliberately flat (`label_1`, `command_1`, …) rather than an array of
    /// objects — see the note in `init(arguments:)`.
    static var schema: [String: Any] {
        var properties: [String: Any] = [
            "question": [
                "type": "string",
                "description": "The question, in one short line. Must be answerable with a single word or number.",
            ],
            "recommended": [
                "type": "integer",
                "description": "Which option (1-based) is the best answer. Taken automatically if the person doesn't reply, so always set it to the one you would pick.",
            ],
        ]
        for index in 1 ... 4 {
            properties["label_\(index)"] = [
                "type": "string",
                "description": "Option \(index): a two-or-three word button label.",
            ]
            properties["command_\(index)"] = [
                "type": "string",
                "description": "Option \(index): what to TYPE in the chat if this is picked — a verb and its subject, like 'play DIDO', 'playlist trance', 'mix ambient 45', 'radio Armin van Buuren'. Not a tool name: write 'play DIDO', never 'music_play'.",
            ]
            properties["detail_\(index)"] = [
                "type": "string",
                "description": "Option \(index): the fact that decides it — track count, length, why this one. A few words.",
            ]
        }
        return [
            "name": toolName,
            "description": """
            Ask the owner to choose between 2–4 genuinely different options, \
            instead of guessing. Ends your turn: the options are shown as \
            buttons and the answer arrives as a new message. Use only when the \
            answer changes what plays and you cannot settle it by looking. \
            Always set `recommended` — if nobody answers, that option runs by \
            itself.
            """,
            "input_schema": [
                "type": "object",
                "properties": properties,
                // Only what a question cannot exist without. Every optional
                // field here is one more reason for a model to reach for a
                // different tool instead.
                "required": ["question", "label_1", "label_2"],
            ],
        ]
    }
}

// MARK: - Pending prompts

/// The questions currently waiting for an answer, one per chat.
///
/// Holds two things a stateless router can't: what "2" refers to, and a timer
/// that acts on the recommended option when nobody replies — silence is an
/// answer people give constantly, and stopping dead on it is what makes an
/// assistant feel broken.
@MainActor
final class RemotePendingChoices {
    /// Long enough to read four options on a phone and decide; short enough
    /// that the music starts while you still care.
    static let autoPickAfter: TimeInterval = 75

    private struct Entry {
        var prompt: RemoteChoicePrompt
        var timer: Task<Void, Never>?
    }

    private var entries: [String: Entry] = [:]

    func prompt(for key: String) -> RemoteChoicePrompt? { entries[key]?.prompt }

    /// Remember a question and arm its auto-pick.
    func store(_ prompt: RemoteChoicePrompt, key: String, timer: Task<Void, Never>?) {
        entries[key]?.timer?.cancel()
        entries[key] = Entry(prompt: prompt, timer: timer)
    }

    /// Forget the question and disarm the timer. Called on *any* message from
    /// the chat, not just an answer: someone who has moved on to another request
    /// should not have music start under them a minute later.
    @discardableResult
    func clear(key: String) -> RemoteChoicePrompt? {
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        entry.timer?.cancel()
        return entry.prompt
    }

    /// Resolve a reply against the pending question. Accepts a tapped button
    /// (`pick 2`), a bare number, an ordinal, or enough of a label to be
    /// unambiguous — because people answer "the ambient one", not "2".
    nonisolated static func resolve(_ text: String, in prompt: RemoteChoicePrompt) -> RemoteChoice? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!,"))
            .lowercased()
        guard !cleaned.isEmpty else { return nil }

        if let index = index(inPickCommand: cleaned), prompt.options.indices.contains(index) {
            return prompt.options[index]
        }
        if let number = Int(cleaned), prompt.options.indices.contains(number - 1) {
            return prompt.options[number - 1]
        }
        if let index = ordinals[cleaned], prompt.options.indices.contains(index) {
            return prompt.options[index]
        }
        if cleaned == "last", let last = prompt.options.last { return last }
        // "yes" / "either" / "whatever" are consent, not indecision — take the
        // recommendation rather than asking again.
        if agreement.contains(cleaned) { return prompt.recommendedChoice }

        // Label match, but only when exactly one option matches: with "chillout"
        // and "chill" on offer, a guess is worse than falling through to the
        // normal command path.
        let matches = prompt.options.filter { option in
            let label = option.label.lowercased()
            return label == cleaned || label.contains(cleaned) || cleaned.contains(label)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    nonisolated private static func index(inPickCommand text: String) -> Int? {
        let parts = text.split(separator: " ")
        guard parts.count == 2, parts[0] == "pick" || parts[0] == "/pick",
              let number = Int(parts[1]) else { return nil }
        return number - 1
    }

    nonisolated(unsafe) private static let ordinals: [String: Int] = [
        "first": 0, "1st": 0, "the first": 0, "one": 0,
        "second": 1, "2nd": 1, "the second": 1, "two": 1,
        "third": 2, "3rd": 2, "the third": 2, "three": 2,
        "fourth": 3, "4th": 3, "the fourth": 3, "four": 3,
    ]

    nonisolated(unsafe) private static let agreement: Set<String> = [
        "yes", "yeah", "yep", "y", "ok", "okay", "sure", "go", "go on", "do it",
        "either", "whatever", "any", "you pick", "you choose", "surprise me",
    ]
}
