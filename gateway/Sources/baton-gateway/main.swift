import BatonAgentKit
import BatonGatewayCore
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
// This file is wiring only. The routes and their handlers are `GatewayRoutes`; the
// dispatch that chooses between them is `BatonGatewayCore.Router`, which is where a test
// can reach it (S-F24). Anything that ends up here again should be asked whether it could
// ever be asserted on, because top-level code cannot be imported by a test target.
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

/// The shared preference document and the revision that orders writes to it. See `StateStore`.
let stateStore = StateStore(fileURL: stateFileURL)

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

let routes = GatewayRoutes(
    token: token,
    healthClient: healthClient,
    healthProbeTimeout: healthProbeTimeout,
    startedAt: startedAt,
    deviceLink: deviceLink,
    stateStore: stateStore,
    fileStore: fileStore,
    surface: surface,
    llmConfig: llmConfig
)
let router = routes.router()

FileHandle.standardOutput.write(Data("baton-gateway listening on :\(port) → \(serverURL.host() ?? "?")\n".utf8))
FileHandle.standardOutput.write(Data("state file: \(stateFileURL.path)\n".utf8))

// The transport logs every response it sends, uploads included (TBX-5308, S-F26). It used to be
// wrapped around the router, which the streaming upload never reaches — so the one route that
// writes caller-controlled bytes to disk before checking a token left no trace at all.
try DefaultTransport(stagingDirectory: uploadStagingDirectory).serve(port: port) { request in
    await router.dispatch(request)
} upload: { request, staged in
    await routes.handleUpload(request, staged)
}
