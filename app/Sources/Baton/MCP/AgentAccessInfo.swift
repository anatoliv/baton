import BatonSubsonicKit
import Foundation

/// The agent-facing connection facts the running MCP server advertises in its `mcp.json` discovery
/// file, parsed for display in the Settings → Agents pane so a user can see how (and whether) AI
/// agents can reach Baton, and copy the endpoint + token. Reading the file (rather than the live
/// server object) keeps the pane decoupled and reflects exactly what agents themselves discover.
///
struct AgentAccessInfo: Equatable {
    var url: String
    var token: String
    var unixSocket: String?
    var pid: Int?
    var version: String?

    /// Parse `mcp.json` from a discovery `directory`. Returns nil when the file is absent or
    /// missing its required fields (server not running / never started). Pure — unit-testable.
    static func load(from directory: URL) -> AgentAccessInfo? {
        let file = directory.appendingPathComponent("mcp.json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = obj["url"] as? String,
              let token = obj["token"] as? String
        else { return nil }
        return AgentAccessInfo(
            url: url,
            token: token,
            unixSocket: (obj["fastPath"] as? [String: Any])?["unixSocket"] as? String,
            pid: obj["pid"] as? Int,
            version: (obj["app"] as? [String: Any])?["version"] as? String
        )
    }

    /// The discovery directory agents look in — `~/Library/Application Support/Baton`.
    static var discoveryDirectory: URL? { BatonStorage.supportDirectory() }

    /// Load from the default discovery directory.
    static func loadCurrent() -> AgentAccessInfo? {
        discoveryDirectory.flatMap { load(from: $0) }
    }

    /// What the Token row shows when the eye is closed. One spelling, so the row and the
    /// snippet below it cannot disagree about what "hidden" looks like.
    static let maskedToken = String(repeating: "•", count: 24)

    /// A ready-to-paste MCP client config for the running server (Streamable HTTP + bearer
    /// token), with the token hidden unless `revealingToken` is true.
    ///
    /// The masking on the Token row exists so a screenshot or a screen-share of Settings does
    /// not hand over full remote control of playback. This code block sat two sections below
    /// it with the same token in plain text, on the same screen, so the eye toggle protected
    /// nothing (shot `23-settings-agents.jpg`). Copy still copies the real thing: the point is
    /// what is *displayed*, not what is copied.
    ///
    /// A method on the model rather than a private helper in the view, so the masking has a
    /// test — a privacy control nobody can assert on is a privacy control that quietly stops
    /// working.
    func clientConfigSnippet(revealingToken: Bool) -> String {
        """
        {
          "mcpServers": {
            "baton": {
              "url": "\(url)",
              "headers": { "Authorization": "Bearer \(revealingToken ? token : Self.maskedToken)" }
            }
          }
        }
        """
    }
}
