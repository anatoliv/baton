import Foundation

/// Remembers which agent is talking, per MCP connection, so a spoken summary can
/// announce its source.
///
/// Several agents run at once here (a Cursor window per repo, Claude Code, a
/// background drain), and `SpeechPlaybackEngine` queues utterances FIFO so they
/// take turns rather than overlapping. Taking turns isn't enough on its own: with
/// four agents speaking you can hear *that* something finished without knowing
/// *whose* work it was.
///
/// So `speak_summary` accepts a short `session` label. Two decisions make it
/// pleasant rather than grating:
///
/// 1. **Sticky.** The label is remembered against the MCP session id the server
///    minted at `initialize`, so an agent passes it once and every later summary
///    on that connection inherits it. After the first call the agent can't forget.
/// 2. **Only spoken when the speaker changes.** Hearing "Global services" before
///    each of six consecutive updates from the same agent is noise. The prefix is
///    added when the label differs from whoever spoke last.
///
/// Labels are per-run state, not settings: they die with the process, which is
/// correct because MCP session ids do too.
@MainActor
final class SpeechSessionLabels {
    /// MCP session id → the label that connection last declared.
    private var labels: [String: String] = [:]
    /// Label of the most recent summary actually spoken, for change detection.
    private(set) var lastSpokenLabel: String?

    /// Cap on a label, in characters. A session name is an identifier, not a
    /// sentence — and it's spoken aloud before every handoff between agents.
    static let maxLabelChars = 40

    /// Longest history we keep. A backstop against a client that reconnects in a
    /// loop; connections are already capped by the server's session registry.
    static let maxTrackedSessions = 64

    /// Normalizes a caller-supplied label: trims, collapses whitespace, truncates.
    /// Returns nil for anything empty, so a blank label is the same as none.
    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxLabelChars))
    }

    /// Records a label for this connection. Passing nil leaves any existing label
    /// alone — that's what makes it sticky across later calls.
    func declare(_ raw: String?, forSession sessionID: String?) {
        guard let sessionID, let label = Self.normalize(raw) else { return }
        if labels.count >= Self.maxTrackedSessions, labels[sessionID] == nil {
            labels.removeValue(forKey: labels.keys.first!)
        }
        labels[sessionID] = label
    }

    /// The label in effect for this connection, if any.
    func label(forSession sessionID: String?) -> String? {
        guard let sessionID else { return nil }
        return labels[sessionID]
    }

    /// Forget a connection's label. Called when the server ends the session.
    func forget(_ sessionID: String) {
        labels.removeValue(forKey: sessionID)
    }

    /// Builds the text to synthesize, prefixing the label only when the speaker
    /// has changed since the last summary. Marks it as the last speaker.
    ///
    /// `text` is returned unchanged when there's no label or the same agent spoke
    /// last, so the common case (one agent, a run of updates) is unaffected.
    func announce(text: String, label: String?) -> String {
        defer { lastSpokenLabel = label ?? lastSpokenLabel }
        guard let label, label != lastSpokenLabel else { return text }
        return Self.prefixed(label: label, text: text)
    }

    /// Pure joiner, exposed for tests. Uses an em-dash-free separator that TTS
    /// engines reliably read as a pause.
    static func prefixed(label: String, text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A period after the label makes every engine pause; a colon or dash is
        // read inconsistently (sometimes silently, sometimes spoken).
        let separator = label.hasSuffix(".") ? " " : ". "
        return label + separator + trimmed
    }

    /// Test seam: pretend `label` spoke last.
    func setLastSpokenLabelForTesting(_ label: String?) {
        lastSpokenLabel = label
    }
}
