import Foundation

/// Remembers which agent is talking, per MCP connection, so a spoken summary can
/// say where it came from.
///
/// Several agents run at once here (a Cursor window per repo, Claude Code, a
/// background drain), and `SpeechPlaybackEngine` queues utterances FIFO so they
/// take turns rather than overlapping. Taking turns isn't enough on its own: with
/// four agents speaking you can hear *that* something finished without knowing
/// *whose* work it was.
///
/// So `speak_summary` accepts a short `session` label, remembered **stickily**
/// against the MCP session id the server minted at `initialize`: an agent passes
/// it once and every later summary on that connection inherits it, so after the
/// first call it can't forget.
///
/// **The label is shown, not spoken.** It used to be prefixed into the synthesized
/// text whenever the speaker changed, which meant it was absent from exactly the
/// summaries where you were already oriented and present on the ones where a name
/// cost you a second of listening. The speaking HUD now carries it above the
/// transcript (`SpeechPlaybackEngine.currentSessionLabel`), where it is there for
/// every summary and free to read. Telling agents apart *by ear* is a separate
/// job, and belongs to per-session voices rather than to a spoken name.
///
/// Labels are per-run state, not settings: they die with the process, which is
/// correct because MCP session ids do too.
@MainActor
final class SpeechSessionLabels {
    /// MCP session id → the label that connection last declared.
    private var labels: [String: String] = [:]

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

}
