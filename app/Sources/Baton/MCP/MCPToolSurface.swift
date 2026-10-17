import Foundation

/// The app's implementation of the agent stack's tool seam: the full MCP catalog,
/// bound to the live MusicModel — chat, Siri and MCP all drive the same 36 tools.
@MainActor
struct MCPToolSurface: RemoteToolSurface {
    let music: MusicModel
    let focus: BatonAudioFocusRegistry

    /// The catalog the chat and Siri were measured with: the app tools are the MCP
    /// server's alone, so a chat model is not handed thirty more tools, or the ones that delete,
    /// revoke or share, without its own evaluation.
    func definitions() -> [[String: Any]] { Self.chatDefinitions() }

    /// The catalog every chat path sends a provider: this surface, and Settings → Remote → Test.
    static func chatDefinitions() -> [[String: Any]] {
        BatonMCPToolCatalog.definitions().filter { !BatonMCPAppTools.names.contains($0["name"] as? String ?? "") }
    }

    func run(name: String, arguments: [String: Any], sessionID: String?) async -> (text: String, isError: Bool) {
        guard !BatonMCPAppTools.names.contains(name) else { return ("Unknown tool \"\(name)\".", true) }
        return await BatonMCPToolCatalog.run(name: name, arguments: arguments, music: music, focus: focus, sessionID: sessionID)
    }
}
