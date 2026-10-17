import BatonAgentKit
import BatonDocuments
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
//   BATON_LLM_LOCAL       1 when that model is on your network under a name the address rule
//                         cannot read (a Docker service, a bare host name); book tasks need it local
//   BATON_TTS_KOKORO_URL  Kokoro for rendering books (default http://127.0.0.1:8880)
//   BATON_TTS_CHATTERBOX_URL  Chatterbox, if a book's voices use it (optional)
//   BATON_TTS_OPENAI_URL  an OpenAI-compatible speech server such as Qwen3-TTS (optional), with
//                         BATON_TTS_OPENAI_MODEL (default qwen3-tts) and BATON_TTS_OPENAI_KEY_FILE
//                         or BATON_TTS_OPENAI_KEY when it asks for a key (`SpeechEngineConfig`)
//   BATON_RENDER_CONCURRENCY  TTS requests in flight per book (default 2)
//   BATON_BOOKS_MAX_BYTES     space for rendered books (default 4 GiB)
//   BATON_BOOKS_KEEP_FINISHED_DAYS  how long a finished book's audio stays (default 30)
//   BATON_FFMPEG          ffmpeg to encode chapters with (default: from PATH)

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

/// Books (`specs/document-clippings.md`). Beside the state file like everything else persisted.
/// Off, and saying why on every book route, when ffmpeg is missing: accepting a book that can
/// never be encoded would be the quiet failure the rest of the design avoids.
let booksDirectory = stateFileURL.deletingLastPathComponent().appendingPathComponent("books", isDirectory: true)
let bookStore = BookStore(
    directory: booksDirectory,
    maximumBytes: Int(env["BATON_BOOKS_MAX_BYTES"] ?? "") ?? BookStore.defaultMaximumBytes,
    keepFinished: (Double(env["BATON_BOOKS_KEEP_FINISHED_DAYS"] ?? "") ?? 30) * 86_400
)
let ttsConfig = SpeechEngineConfig.load(env)
for problem in ttsConfig.problems { FileHandle.standardError.write(Data("TTS: \(problem)\n".utf8)) }
let ttsEndpoints = ttsConfig.endpoints
let synthesizer = HTTPSpeechSynthesizer(endpoints: ttsEndpoints)
let ffmpegPath = FFmpegMuxer.locate(env["BATON_FFMPEG"] ?? "ffmpeg")
let bookRenderer: BookRenderer? = ffmpegPath.map { path in
    BookRenderer(store: bookStore, cacheDirectory: booksDirectory.appendingPathComponent("cache", isDirectory: true),
                 synthesizer: synthesizer, muxer: FFmpegMuxer(executable: path),
                 concurrency: Int(env["BATON_RENDER_CONCURRENCY"] ?? "") ?? 2,
                 log: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) })
}
let books = BookRoutes(renderer: bookRenderer, store: bookStore, synthesizer: synthesizer,
                       unavailableReason: ffmpegPath == nil ? "ffmpeg is not installed on the gateway" : nil,
                       exporter: ffmpegPath.map { FFmpegMuxer(executable: $0) },
                       voices: VoiceListing(endpoints: ttsEndpoints),
                       completion: BookCompletionRoute(
                           source: BookCompletionRoute.source(provider: env["BATON_LLM_PROVIDER"], baseURL: llmConfig.baseURL,
                                                              model: llmConfig.model),
                           apiKey: llmConfig.apiKey.isEmpty ? nil : llmConfig.apiKey,
                           declaredLocal: env["BATON_LLM_LOCAL"] == "1"))
if let bookRenderer {
    Task { await bookRenderer.startIfNeeded() }   // resumes any book left unfinished
    FileHandle.standardOutput.write(Data("books: \(booksDirectory.path), TTS \(Dictionary(ttsEndpoints.map { ($0.engine, $0.baseURL.absoluteString) }, uniquingKeysWith: { a, _ in a }))\n".utf8))
} else {
    FileHandle.standardOutput.write(Data("books: off (ffmpeg not found)\n".utf8))
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
    llmConfig: llmConfig,
    books: books
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
