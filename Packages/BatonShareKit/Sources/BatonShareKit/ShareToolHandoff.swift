import Foundation

/// A local, ready-to-copy message. Creating a share never sends it to a contact.
/// The recipient stays in the tool response; it is not uploaded or added to the ledger.
public enum ShareToolHandoff {
    public static let recipientDescription = "The person the user wants to share with, for example Maya. Used only to prepare a message to copy; Baton does not look up contacts or send messages. Omit when no recipient was named."

    public static let agentInstructions = """
    When asked to share a song or "send this to Maya", use music_share; do not start playback. \
    Omit query for the current song, and put a named recipient in recipient. The result is a \
    link and a ready-to-copy message, not a delivery receipt. Say the link is ready for them \
    to send, include the complete link with its # key, and never claim it was sent. Do not \
    look up contacts, call another messaging tool, or remember the recipient. If the tool \
    refuses first-share consent, explain the manual Share step without changing consent.
    """

    public enum ValidationError: LocalizedError, Equatable {
        case invalidRecipient

        public var errorDescription: String? {
            "recipient must be a name of at most 80 characters on one line."
        }
    }

    /// Validate before song resolution/upload, including malformed non-string tool arguments.
    public static func recipient(from arguments: [String: Any]) throws -> String? {
        guard let raw = arguments["recipient"] else { return nil }
        guard let value = raw as? String else { throw ValidationError.invalidRecipient }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard name.count <= 80,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
                      || $0.properties.generalCategory == .format
              })
        else { throw ValidationError.invalidRecipient }
        return name
    }

    public static func result(link: String, title: String, artist: String,
                              expiresAt: Date, recipient: String?) -> [String: String] {
        let greeting = recipient.map { "\($0), " } ?? ""
        let song = artist.isEmpty ? title : "\(title) by \(artist)"
        var result = [
            "link": link,
            "title": title,
            "artist": artist,
            "expires_at": ShareDate.string(expiresAt),
            "delivery_status": "not_sent",
            "message": "\(greeting)listen to \(song).\n\(link)",
            "how_to_send": "This link is ready to copy and send. Baton has not sent a message. Keep the link exactly as it is: the part after # is the key; without it the song cannot be played.",
        ]
        if let recipient { result["recipient"] = recipient }
        return result
    }
}
