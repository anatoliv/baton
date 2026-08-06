import BatonAgentKit
import BatonMCPProtocol
import BatonSubsonicKit
import BatonSubsonicModels
import Foundation

// The Baton agent gateway: the music friend's home-server brain
// (docs/plan-ios-app.md, Phase 4). The phone POSTs a chat turn; the gateway runs
// the same RemoteAgent loop the Mac app ships, with a server-side tool surface
// bound directly to Navidrome. Keys stay home; the phone holds only the gateway
// token.
//
// Curation tools (search, similar, playlists, genres) run here against the server.
// Playback happens where the speakers are: a device holds an authenticated
// long-poll (`/v1/device/poll`) and the playback tools dispatch to it, so "play
// something mellow" reaches the phone. With no device listening, those tools say
// so rather than pretending.
//
// Configuration (environment):
//   BATON_GATEWAY_TOKEN   bearer token clients must present (required)
//   BATON_GATEWAY_PORT    listen port (default 8788)
//   NAVIDROME_URL/USER/PASSWORD   the library it curates from (required)
//   BATON_LLM_PROVIDER    anthropic | openai-compatible (default anthropic)
//   BATON_LLM_BASE_URL    override endpoint (e.g. LiteLLM on gpu-host)
//   BATON_LLM_MODEL       model id (default claude-haiku-4-5-20251001)
//   BATON_LLM_API_KEY     key for the provider

let env = ProcessInfo.processInfo.environment

guard let token = env["BATON_GATEWAY_TOKEN"], !token.isEmpty else {
    FileHandle.standardError.write(Data("BATON_GATEWAY_TOKEN is required (clients authenticate with it).\n".utf8))
    exit(2)
}
guard let serverURLRaw = env["NAVIDROME_URL"], let serverURL = URL(string: serverURLRaw),
      let user = env["NAVIDROME_USER"], let password = env["NAVIDROME_PASSWORD"] else {
    FileHandle.standardError.write(Data("NAVIDROME_URL, NAVIDROME_USER and NAVIDROME_PASSWORD are required.\n".utf8))
    exit(2)
}
let port = UInt16(env["BATON_GATEWAY_PORT"] ?? "") ?? 8788

let credentials = NavidromeCredentials(baseURL: serverURL, username: user, secret: password, authMode: .tokenSalt)
let client = NavidromeClient(credentials: credentials)

var llmConfig = RemoteControlSettings.NaturalLanguageConfig()
llmConfig.isEnabled = true
llmConfig.isAgentEnabled = true
llmConfig.provider = (env["BATON_LLM_PROVIDER"] == "openai-compatible") ? .openAICompatible : .anthropic
llmConfig.model = env["BATON_LLM_MODEL"] ?? "claude-haiku-4-5-20251001"
if let base = env["BATON_LLM_BASE_URL"] { llmConfig.baseURL = base }
llmConfig.apiKey = env["BATON_LLM_API_KEY"] ?? ""

let deviceLink = DeviceLink()
let surface = GatewayToolSurface(client: client, devices: deviceLink)

/// Where shared preferences live.
///
/// Defaults under the XDG data directory rather than the working directory: run by hand
/// from a checkout, cwd is fine, but under systemd or Docker it is `/` — so the file would
/// land somewhere surprising or unwritable, and settings would silently vanish on restart.
/// `BATON_STATE_FILE` overrides it for a mounted volume.
let stateFileURL: URL = {
    let env = ProcessInfo.processInfo.environment
    if let path = env["BATON_STATE_FILE"] { return URL(fileURLWithPath: path) }
    let base = env["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share")
    let directory = base.appendingPathComponent("baton")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("baton-state.json")
}()

FileHandle.standardOutput.write(Data("baton-gateway listening on :\(port) → \(serverURL.host() ?? "?")\n".utf8))

try DefaultTransport().serve(port: port) { request in
    await handle(request)
}

// MARK: - Routing

@MainActor @Sendable
func handle(_ request: HTTPRequestMessage) async -> Data {
    if request.method == "GET", request.path == "/health" {
        let ok = (try? await client.ping()) != nil
        return httpResponse(status: "200 OK", body: #"{"status":"\#(ok ? "ok" : "navidrome-unreachable")"}"#)
    }
    // Everything else is authenticated, constant-time.
    let presented = request.bearerToken ?? ""
    guard BatonMCPAuth.constantTimeEquals(presented, token) else {
        return httpResponse(status: "401 Unauthorized", body: #"{"error":"bad token"}"#)
    }
    // Device link: the player parks here waiting for something to do.
    // Shared preferences: the settings that are yours rather than a device's — EQ curve,
    // radio bans, crossfade, the agent's non-secret config. Navidrome has nowhere to keep
    // these (there is no client-preference API), and iCloud would drag a provisioning
    // profile into the Mac's Developer ID release flow, so the gateway is the one place
    // both apps already authenticate to.
    //
    // Persisted to disk rather than held in memory: a gateway restart is routine, and
    // silently losing someone's settings because a container bounced would be worse than
    // not syncing them at all.
    if request.method == "GET", request.path == "/v1/state" {
        let body = (try? String(contentsOf: stateFileURL, encoding: .utf8)) ?? "{}"
        return httpResponse(status: "200 OK", body: body)
    }
    if request.method == "PUT", request.path == "/v1/state" {
        // Validated as JSON before it lands: a truncated PUT must not leave a file that
        // every future GET chokes on.
        guard (try? JSONSerialization.jsonObject(with: request.body)) != nil else {
            return httpResponse(status: "400 Bad Request", body: #"{"error":"body must be JSON"}"#)
        }
        do {
            try request.body.write(to: stateFileURL, options: .atomic)
            return httpResponse(status: "200 OK", body: #"{"ok":true}"#)
        } catch {
            return httpResponse(status: "500 Internal Server Error", body: #"{"error":"could not persist state"}"#)
        }
    }
    if request.method == "GET", request.path == "/v1/device/poll" {
        if let command = await deviceLink.awaitCommand() {
            let data = (try? JSONSerialization.data(withJSONObject: command.json)) ?? Data("{}".utf8)
            return httpResponse(status: "200 OK", body: String(data: data, encoding: .utf8) ?? "{}")
        } else {
            return httpResponse(status: "204 No Content", body: "")
        }
    }
    if request.method == "POST", request.path == "/v1/device/result" {
        if let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
           let id = json["id"] as? String {
            await deviceLink.deliverResult(
                id: id,
                text: json["text"] as? String ?? "",
                isError: json["is_error"] as? Bool ?? false
            )
        }
        return httpResponse(status: "200 OK", body: #"{"ok":true}"#)
    }
    guard request.method == "POST", request.path == "/v1/agent" else {
        return httpResponse(status: "404 Not Found", body: #"{"error":"unknown route"}"#)
    }
    guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
          let message = json["message"] as? String, !message.isEmpty else {
        return httpResponse(status: "400 Bad Request", body: #"{"error":"message is required"}"#)
    }
    do {
        let outcome = try await RemoteAgent.run(
            message: message,
            history: [],
            playerContext: json["player_context"] as? String,
            config: llmConfig,
            tools: RemoteAgent.toolSchemas(definitions: surface.definitions()),
            runTool: { call in
                await surface.run(name: call.name, arguments: call.jsonArguments, sessionID: nil)
            }
        )
        let reply: [String: Any] = ["text": outcome.text, "tools_run": outcome.toolsRun]
        let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
        return httpResponse(status: "200 OK", body: String(data: data, encoding: .utf8) ?? "{}")
    } catch {
        return httpResponse(status: "502 Bad Gateway", body: #"{"error":"\#(String(describing: error))"}"#)
    }
}

// MARK: - The server-side tool surface

/// Curation tools bound straight to Navidrome. Playback verbs exist so the model
/// never invents them — they answer that playback lives on the user's devices
/// (dispatching to a connected phone/Mac is the next step).
@MainActor
final class GatewayToolSurface: RemoteToolSurface {
    private let client: NavidromeClient
    private let devices: DeviceLink
    private var lastResults: [NavidromeSong] = []

    init(client: NavidromeClient, devices: DeviceLink) {
        self.client = client
        self.devices = devices
    }

    func definitions() -> [[String: Any]] {
        [
            ["name": "music_search", "description": "Search the library for songs, albums, artists.",
             "inputSchema": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]],
            ["name": "music_similar_songs", "description": "Songs similar to the most recent search's first result.",
             "inputSchema": ["type": "object", "properties": [:]]],
            ["name": "music_list_playlists", "description": "The user's playlists.",
             "inputSchema": ["type": "object", "properties": [:]]],
            ["name": "music_list_genres", "description": "Genres in the library.",
             "inputSchema": ["type": "object", "properties": [:]]],
            ["name": "music_random", "description": "Random songs, optionally by genre.",
             "inputSchema": ["type": "object", "properties": ["genre": ["type": "string"]]]],
            ["name": "music_play", "description": "Play something on the user's device — pass what to play.",
             "inputSchema": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]],
            ["name": "music_pause", "description": "Pause playback on the user's device.",
             "inputSchema": ["type": "object", "properties": [:]]],
            ["name": "music_next", "description": "Skip to the next track on the user's device.",
             "inputSchema": ["type": "object", "properties": [:]]],
            ["name": "music_now_playing", "description": "What is playing on the user's device right now.",
             "inputSchema": ["type": "object", "properties": [:]]],
        ]
    }

    func run(name: String, arguments: [String: Any], sessionID: String?) async -> (text: String, isError: Bool) {
        switch name {
        case "music_search":
            let query = arguments["query"] as? String ?? ""
            guard let results = try? await client.search3(query: query) else {
                return ("The library didn't answer — is Navidrome up?", true)
            }
            lastResults = results.songs
            if results.songs.isEmpty { return ("Nothing matched \"\(query)\".", false) }
            let listing = results.songs.prefix(10).enumerated()
                .map { "\($0.offset + 1). \($0.element.title) — \($0.element.artist ?? "?")" }
                .joined(separator: "\n")
            return ("Found \(results.songs.count) songs:\n\(listing)", false)
        case "music_similar_songs":
            guard let seed = lastResults.first else { return ("Search first, then ask for similar.", false) }
            let similar = (try? await client.getSimilarSongs(id: seed.id)) ?? []
            if similar.isEmpty { return ("The server has no similarity data for \(seed.title).", false) }
            return ("Similar to \(seed.title):\n" + similar.prefix(10).map { "• \($0.title) — \($0.artist ?? "?")" }.joined(separator: "\n"), false)
        case "music_list_playlists":
            let lists = (try? await client.getPlaylists()) ?? []
            return (lists.isEmpty ? "No playlists yet." : lists.map { "• \($0.name) (\($0.songCount))" }.joined(separator: "\n"), false)
        case "music_list_genres":
            let genres = (try? await client.getGenres()) ?? []
            return (genres.prefix(30).map(\.name).joined(separator: ", "), false)
        case "music_random":
            let genre = arguments["genre"] as? String
            let songs = (try? await client.getRandomSongs(count: 10, genre: genre)) ?? []
            lastResults = songs
            return (songs.map { "• \($0.title) — \($0.artist ?? "?")" }.joined(separator: "\n"), false)
        case "music_play", "music_pause", "music_next", "music_now_playing":
            // Playback belongs to the device with the speakers. Dispatch and wait;
            // if nothing is listening, say so instead of claiming success.
            let argumentsJSON = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
            guard let result = await devices.dispatch(name: name, argumentsJSON: argumentsJSON) else {
                return ("No Baton device is connected right now — open Baton on your phone and I'll play it there. I can still search and build you something from here.", false)
            }
            return result
        default:
            return ("The gateway doesn't have \(name).", true)
        }
    }
}
