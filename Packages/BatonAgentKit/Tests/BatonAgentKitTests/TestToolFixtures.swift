import Foundation
@testable import BatonAgentKit

/// A minimal stand-in for the Mac app's MCP catalog: enough schema surface for the
/// agent loop and live eval to converse. The REAL catalog's schema shapes are
/// asserted app-side (RemoteCommandTests), where the catalog lives.
enum TestToolFixtures {
    static var definitions: [[String: Any]] { [
        ["name": "music_search", "description": "Search the library.",
         "inputSchema": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]],
        ["name": "music_play", "description": "Play from a search.",
         "inputSchema": ["type": "object", "properties": ["query": ["type": "string"]]]],
        ["name": "music_pause", "description": "Pause playback.",
         "inputSchema": ["type": "object", "properties": [:]]],
        ["name": "music_now_playing", "description": "What is playing.",
         "inputSchema": ["type": "object", "properties": [:]]],
        ["name": "music_rate", "description": "Rate 0-5.",
         "inputSchema": ["type": "object", "properties": ["stars": ["type": "integer"]]]],
        ["name": "music_similar_songs", "description": "Similar songs.",
         "inputSchema": ["type": "object", "properties": [:]]],
    ] }
}
