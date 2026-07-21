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
    static var discoveryDirectory: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("Baton", isDirectory: true)
    }

    /// Load from the default discovery directory.
    static func loadCurrent() -> AgentAccessInfo? {
        discoveryDirectory.flatMap { load(from: $0) }
    }
}
