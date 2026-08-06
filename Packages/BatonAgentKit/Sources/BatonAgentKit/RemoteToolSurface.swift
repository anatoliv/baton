import Foundation
import BatonSubsonicKit
import BatonSubsonicModels

/// What the agent stack needs from a tool implementation: the schemas it shows the
/// model, and execution. The Mac app adapts its MCP catalog (the full 36-tool
/// surface bound to MusicModel); the gateway and the iPhone bring their own
/// implementations of the same shape — one brain, several hands.
@MainActor
public protocol RemoteToolSurface {
    func definitions() -> [[String: Any]]
    func run(name: String, arguments: [String: Any], sessionID: String?) async -> (text: String, isError: Bool)
}
