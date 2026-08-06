import Foundation

// The chat wire types: what arrives, and what goes back. Pure values shared by
// the router, the platform bridges and the conversation log — no player, no
// transport, so they build everywhere the agent loop does.

/// One inbound chat message, normalized across platforms.
public struct RemoteInbound: Sendable {
    var platform: RemotePlatform
    /// Platform user id. This — not the display name — is what the allowlist holds.
    var senderID: String
    var senderName: String
    /// Telegram chat id / Discord channel id; where the reply goes.
    var channelID: String
    var text: String
}

/// What to send back.
public struct RemoteReply: Sendable {
    var text: String
    /// The tool errored, or answered with nothing. Used to decide whether a
    /// literal reading is worth a second opinion from the model.
    var isFailure: Bool = false
    /// Whether to attach transport buttons (⏮ ⏯ ⏭ 🔉 🔊). Set for anything that
    /// leaves the user looking at playback state.
    var showsTransport: Bool = false
    /// Options to show as buttons. Set when the agent asked a question.
    var choices: [RemoteChoice] = []

    static func plain(_ text: String) -> RemoteReply { RemoteReply(text: text) }
    static func player(_ text: String) -> RemoteReply { RemoteReply(text: text, showsTransport: true) }

    /// Chat platforms hard-cap message length (Telegram 4096, Discord 2000) and
    /// refuse anything over it — so an unclamped long reply is a LOST reply.
    /// Cuts on a line boundary where one is near, so a truncated list ends with
    /// a whole row rather than half a title.
    static func clamped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let marker = "\n…"
        var cut = String(text.prefix(limit - marker.count))
        if let lastLine = cut.lastIndex(of: "\n"),
           cut.distance(from: lastLine, to: cut.endIndex) < 120 {
            cut = String(cut[cut.startIndex..<lastLine])
        }
        return cut + marker
    }
}
