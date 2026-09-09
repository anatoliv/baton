import BatonAgentKit
import BatonMCPProtocol
import BatonSubsonicKit
import BatonSubsonicModels
import BatonGatewayCore
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
//   BATON_LLM_BASE_URL    override endpoint (e.g. a LiteLLM or Ollama box on your LAN)
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

/// How long `/health` waits for Navidrome before answering anyway.
///
/// Two seconds, and the number is chosen against the measured healthy path: the whole route,
/// ping included, answers in **100-400 ms** on the LAN. Two seconds is five to twenty times that,
/// so a cold TLS handshake or a briefly busy server still reports `ok` — while sitting far inside
/// the patience of anything that would poll this (curl's own default is no timeout at all, and
/// uptime checkers give 10-30 s). It is also short enough that a person running `curl` learns
/// something rather than reaching for Ctrl-C, which is the failure this card is about.
let healthProbeTimeout: TimeInterval = 2

/// A second client, for the health probe only, on a session that gives up quickly.
///
/// **Why not tighten the shared one.** `NavidromeClient` and its session defaults live in
/// `Packages/BatonSubsonicKit`, which the Mac app and the iPhone app both compile — a session-level
/// change there is a change to real playback and library browsing, which legitimately wait longer
/// than a health check should. Even the gateway's own `client` above serves agent tool calls
/// (search, playlists, radio) that want the ordinary timeouts. So the fast-fail is scoped to the
/// one caller that needs it, and no shared code is touched.
///
/// The 1.5 s here is the *per-attempt* bound and is deliberately not the promise: `performJSON`
/// retries an idempotent GET once after 300 ms, so the transport alone could still spend
/// 1.5 + 0.3 + 1.5 s. `HealthProbe` holds the outer 2 s wall clock; this just makes the abandoned
/// attempt give up rather than linger, and lets a single clean failure report its own error
/// instead of hitting the deadline.
let healthClient: NavidromeClient = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 1.5
    config.timeoutIntervalForResource = 3
    #if !os(Linux)
    config.waitsForConnectivity = false  // swift-corelibs-foundation exposes this read-only
    #endif
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return NavidromeClient(credentials: credentials, session: URLSession(configuration: config))
}()

var llmConfig = RemoteControlSettings.NaturalLanguageConfig()
llmConfig.isEnabled = true
llmConfig.isAgentEnabled = true
llmConfig.provider = (env["BATON_LLM_PROVIDER"] == "openai-compatible") ? .openAICompatible : .anthropic
llmConfig.model = env["BATON_LLM_MODEL"] ?? "claude-haiku-4-5-20251001"
if let base = env["BATON_LLM_BASE_URL"] { llmConfig.baseURL = base }
llmConfig.apiKey = env["BATON_LLM_API_KEY"] ?? ""

let deviceLink = DeviceLink()
let surface = GatewayToolSurface(client: client, devices: deviceLink)

/// When this process started, so `/health`'s counters mean something. They live in
/// memory and a container restart zeroes them, so "0 polls" is only bad news alongside an uptime
/// long enough for a poll to have happened.
let startedAt = Date()

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

/// Where files parked for another device live. Beside the state file, so one mounted
/// volume covers everything the gateway persists.
let filesDirectory: URL = stateFileURL.deletingLastPathComponent()
    .appendingPathComponent("files", isDirectory: true)
let fileStore = FileStore(directory: filesDirectory)

/// The staging area for uploads in flight. Beside the store rather than in `/tmp`, so a commit is
/// a rename within one filesystem — which is what makes it atomic — rather than a copy across two.
let uploadStagingDirectory: URL = filesDirectory.appendingPathComponent("staging", isDirectory: true)

// Anything staged is litter, because no upload can be in flight before the listener starts
// (TBX-5308, S-F13). A process kill or a container stop mid-upload used to leave its partial file
// behind for ever: `FileStore.prune` cannot see these, since `list()` filters on `.json` in the
// parent directory. Before the listener, so a fresh ceiling is not spent on old rubbish.
let sweptUploads = StreamingUpload.sweepStaging(directory: uploadStagingDirectory)
if sweptUploads > 0 {
    FileHandle.standardOutput.write(
        Data("swept \(sweptUploads) abandoned upload(s) from \(uploadStagingDirectory.path)\n".utf8))
}

FileHandle.standardOutput.write(Data("baton-gateway listening on :\(port) → \(serverURL.host() ?? "?")\n".utf8))
FileHandle.standardOutput.write(Data("state file: \(stateFileURL.path)\n".utf8))

// The transport logs every response it sends, uploads included (TBX-5308, S-F26). It used to be
// wrapped around the router, which the streaming upload never reaches — so the one route that
// writes caller-controlled bytes to disk before checking a token left no trace at all.
try DefaultTransport(stagingDirectory: uploadStagingDirectory).serve(port: port) { request in
    await route(request)
} upload: { request, staged in
    await handleUpload(request, staged)
}

// MARK: - Files

extension JSONEncoder {
    /// ISO-8601 dates on the wire. The default is a float since 2001, which is unreadable in a
    /// log and a trap for any client that is not Foundation.
    static var gatewayISO8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

/// Publish a body the transport has already streamed to disk.
///
/// Authenticated here rather than in the transport, and that ordering is deliberate: the body is
/// written to a staging file *before* the token is checked, so an unauthenticated caller can make
/// the gateway write up to one file's worth of bytes. The alternative — parsing and checking auth
/// mid-stream — puts credential handling inside the framing code, which is worse. What keeps it
/// safe is that the staging file is deleted on every path out of here, so nothing accumulates.
@MainActor @Sendable
func handleUpload(_ request: StreamingUpload.Request, _ staged: URL) async -> Data {
    func fail(_ status: String, _ message: String) -> Data {
        try? FileManager.default.removeItem(at: staged)
        return httpErrorResponse(status: status, message: message)
    }
    // `Request.bearerToken`, the same parse every other route uses. The hand-rolled
    // `replacingOccurrences(of: "Bearer ", with: "")` here was case-sensitive, so a spec-legal
    // `authorization: bearer <token>` was accepted on GET /v1/files and refused on this route
    // (TBX-5308, S-F26).
    guard BatonMCPAuth.constantTimeEquals(request.bearerToken ?? "", token) else {
        return fail("401 Unauthorized", "bad token")
    }
    let id = String(request.path.dropFirst("/v1/files/".count))
    do {
        let meta = try fileStore.commit(
            staged: staged,
            id: id,
            name: request.header("x-baton-name") ?? "file",
            contentType: request.header("content-type") ?? "application/octet-stream",
            sha256: request.header("x-baton-sha256"),
            origin: request.header("x-baton-origin")
        )
        let data = (try? JSONEncoder.gatewayISO8601.encode(meta)) ?? Data("{}".utf8)
        return httpResponse(status: "201 Created", body: String(data: data, encoding: .utf8) ?? "{}")
    } catch FileStore.StoreError.badID {
        return fail("400 Bad Request", "bad file id")
    } catch let FileStore.StoreError.tooLarge(limit) {
        return fail("413 Payload Too Large", "at most \(limit) bytes")
    } catch {
        return fail("500 Internal Server Error", "could not store the file")
    }
}

// MARK: - Routing

/// The routes. One line per request is written by the transport, for every response it sends
/// (TBX-4045, and TBX-5308 for the uploads it used to miss) — see `RequestLog.write`.
@MainActor @Sendable
func route(_ request: HTTPRequestMessage) async -> Data {
    if request.method == "GET", request.path == "/health" {
        // Bounded, because it used to answer in two minutes. See `healthClient`.
        //
        // **Yes, an unauthenticated route makes an outbound call, and it stays that way.** The
        // probe is the whole reason this route is worth polling: without it `/health` can only
        // say "a process is listening", which the TCP connection already said. What it adds is
        // the distinction between a gateway that is up and one that is up and *blind* — the
        // state the whole of TBX-5068 was spent identifying by hand. What was unreasonable was
        // the cost: an anonymous caller could park a request here for two minutes. One ping and
        // at most two seconds is a fair price for the only signal the route carries, on a LAN
        // service that is not exposed to the internet. If it ever is, the next step is a cached
        // last-probe result with a short TTL rather than dropping the probe — a health check
        // that has stopped checking anything is the failure mode, not the fix.
        let navidrome = await HealthProbe.run(timeout: healthProbeTimeout) {
            try await healthClient.ping()
        }
        // Device-poll counters ride along. The empty poll is dropped from the request
        // log on purpose, and it is the *only* trace `awaitCommand` leaves — so without these,
        // a gateway holding a poll open every 25 seconds and one nothing has touched in a week
        // produce byte-identical logs. Read in one actor hop, so the numbers agree with the
        // waiter list they came from.
        let body = GatewayHealth.body(
            navidrome: navidrome,
            startedAt: startedAt,
            polls: await deviceLink.pollStats
        )
        return httpResponse(status: "200 OK", body: body)
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
    // Files parked for another device. A Mac exports a reading and puts it here; the
    // phone collects it. Nothing here knows what a reading is — podcast audio and downloaded
    // tracks want the same road, and a second transport per file type is how a household ends up
    // with three half-working ones.
    //
    // The PUT is absent from this switch on purpose: an upload never reaches `handle`, because
    // its body is streamed to disk by the transport before any of this runs. See `handleUpload`.
    if request.method == "GET", request.path == "/v1/files" {
        let listing = fileStore.list()
        let data = (try? JSONEncoder.gatewayISO8601.encode(listing)) ?? Data("[]".utf8)
        return httpResponse(status: "200 OK", body: String(data: data, encoding: .utf8) ?? "[]")
    }
    if request.path.hasPrefix("/v1/files/") {
        let id = String(request.path.dropFirst("/v1/files/".count))
        switch request.method {
        case "GET":
            guard let meta = fileStore.metadata(id: id), let url = fileStore.blobURL(id: id),
                  let payload = try? Data(contentsOf: url) else {
                return httpResponse(status: "404 Not Found", body: #"{"error":"no such file"}"#)
            }
            // The digest travels in a header so the receiver can verify what it just downloaded.
            // The gateway never checks it: end-to-end beats hop-by-hop, and it means a store
            // nobody fully trusts still cannot hand over bad bytes without being caught.
            var headers = ["X-Baton-Name": meta.name]
            if let sha = meta.sha256 { headers["X-Baton-SHA256"] = sha }
            return httpResponse(status: "200 OK", contentType: meta.contentType,
                                payload: payload, extraHeaders: headers)
        case "DELETE":
            fileStore.remove(id: id)
            return httpResponse(status: "200 OK", body: #"{"ok":true}"#)
        default:
            return httpResponse(status: "405 Method Not Allowed", body: #"{"error":"GET or DELETE"}"#)
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
        return httpErrorResponse(status: "400 Bad Request", message: "message is required")
    }
    // Which conversation this turn belongs to, so `music_similar_songs` seeds from *its* search
    // rather than from whatever the last caller happened to look up (TBX-5308, S-F26). Optional:
    // a client that sends nothing shares one slot, which is the behaviour it had before.
    let sessionID = json["session_id"] as? String
    do {
        let outcome = try await RemoteAgent.run(
            message: message,
            history: [],
            playerContext: json["player_context"] as? String,
            config: llmConfig,
            tools: RemoteAgent.toolSchemas(definitions: surface.definitions()),
            runTool: { call in
                await surface.run(name: call.name, arguments: call.jsonArguments, sessionID: sessionID)
            }
        )
        let reply: [String: Any] = ["text": outcome.text, "tools_run": outcome.toolsRun]
        return httpResponse(status: "200 OK", body: jsonObject(reply))
    } catch {
        // Serialised, not interpolated into a JSON literal. `RemoteNaturalLanguage.Failure`
        // carries the provider's own text, which reliably contains quotes and newlines — so the
        // body used to be invalid JSON, the phone fell back to a generic message, and "your
        // credit balance is too low" never reached anybody (TBX-5308, S-F26).
        return httpErrorResponse(status: "502 Bad Gateway", message: String(describing: error))
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
    /// The last search, per conversation. One shared field made `music_similar_songs` seed from
    /// whoever searched most recently (TBX-5308, S-F26).
    private let lastResults = SearchSeedStore<[NavidromeSong]>()

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
            lastResults.remember(results.songs, for: sessionID)
            if results.songs.isEmpty { return ("Nothing matched \"\(query)\".", false) }
            let listing = results.songs.prefix(10).enumerated()
                .map { "\($0.offset + 1). \($0.element.title) — \($0.element.artist ?? "?")" }
                .joined(separator: "\n")
            return ("Found \(results.songs.count) songs:\n\(listing)", false)
        case "music_similar_songs":
            guard let seed = lastResults.seed(for: sessionID)?.first else {
                return ("Search first, then ask for similar.", false)
            }
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
            lastResults.remember(songs, for: sessionID)
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
