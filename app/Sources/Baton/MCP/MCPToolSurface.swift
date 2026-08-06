import Foundation

/// The app's implementation of the agent stack's tool seam: the full MCP catalog,
/// bound to the live MusicModel — chat, Siri and MCP all drive the same 36 tools.
@MainActor
struct MCPToolSurface: RemoteToolSurface {
    let music: MusicModel
    let focus: BatonAudioFocusRegistry

    func definitions() -> [[String: Any]] {
        BatonMCPToolCatalog.definitions()
    }

    func run(name: String, arguments: [String: Any], sessionID: String?) async -> (text: String, isError: Bool) {
        await BatonMCPToolCatalog.run(name: name, arguments: arguments, music: music, focus: focus, sessionID: sessionID)
    }
}
