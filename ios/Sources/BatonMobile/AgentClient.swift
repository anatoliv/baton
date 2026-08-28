import BatonPlaybackKit
import BatonSubsonicModels
import Foundation
import OSLog

private let agentLog = Logger(subsystem: "io.tonebox.baton", category: "MusicFriend")

/// The phone's music-friend routing — which brain answers, and what happens when
/// it can't. The *loop* is `BatonAgentKit.RemoteAgent`, the same one the Mac runs
/// and the gateway serves; this type owns only the provider architecture from
/// docs/plan-ios-app.md: named profiles over two dialects (the self-hosted gateway,
/// or the Anthropic Messages API directly), a fallback hop with tonebox's error
/// predicate, and its degraded latch so cellular users don't pay a failing round
/// trip on every message.
///
/// Gateway route: the server runs the loop against server-side tools and returns an
/// answer. Direct route: the identical loop runs here, driving this phone's player.
/// One brain, two homes — the phone never has its own dialect of the conversation.
@MainActor
final class AgentClient {
    /// Where a message goes: the self-hosted gateway, or straight to Anthropic.
    struct Profile: Equatable {
        /// `direct` covers both model-provider dialects — which one is in play is
        /// `AgentConfig.provider`, exactly as on the Mac.
        enum Dialect: String { case gateway, direct }
        var dialect: Dialect
        var baseURL: URL
        var model: String
        /// Keychain account holding the bearer/API key (never the key itself).
        var keyAccount: String
    }

    struct Reply {
        var text: String
        var toolCallsMade: Int
        /// The calls with their arguments. A count cannot explain a wrong track; the query
        /// that was actually sent usually can.
        var toolCalls: [FriendExchange.Action] = []
        /// True when something the model did actually started playback — the only honest
        /// basis for recording "this is what it played".
        var startedPlayback: Bool = false
    }

    enum AgentError: Error, LocalizedError {
        case notConfigured
        case http(Int, String)
        case config(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Add an API key (or gateway) in Settings first."
            case .http(let code, let hint): "The model endpoint answered HTTP \(code). \(hint)"
            case .config(let detail): detail
            }
        }
    }

    private let tools: AgentTools
    private let player: StreamingPlaybackController
    let config: AgentConfig
    /// After a successful failover, route straight to the fallback until the user
    /// touches configuration — the degraded latch.
    private var degradedToFallback = false

    /// What this person has told the friend it got wrong, as a prompt block.
    ///
    /// A closure rather than a stored value: corrections change while the app runs, and a
    /// snapshot taken at construction would mean a thumbs-down never affected anything
    /// until the next launch — which is the version of this feature that looks finished
    /// and does nothing.
    var learnedCorrections: (@MainActor () -> String?)?

    init(tools: AgentTools, player: StreamingPlaybackController, config: AgentConfig) {
        self.tools = tools
        self.player = player
        self.config = config
    }

    func resetConversation() {
        history = []
    }

    /// Configuration is read fresh per send, so Settings edits apply immediately
    /// (and clear the degraded latch).
    func clearDegradedLatch() { degradedToFallback = false }

    var primaryProfile: Profile? { Self.makePrimaryProfile(config) }
    /// The configured gateway, if any — also what the device link polls.
    var gatewayProfile: Profile? { Self.makeGatewayProfile(config) }
    var directProfile: Profile? { Self.makeDirectProfile(config) }

    // Profile resolution is static and pure: the device link needs it without a
    // client, and it is the part worth testing on its own.

    /// The route decides. A gateway address left over from an earlier setup must not
    /// quietly win back the routing after someone switches to a direct provider.
    static func makePrimaryProfile(_ config: AgentConfig) -> Profile? {
        switch config.route {
        case .gateway: makeGatewayProfile(config) ?? makeDirectProfile(config)
        case .direct: makeDirectProfile(config)
        }
    }

    static func makeGatewayProfile(_ config: AgentConfig) -> Profile? {
        let raw = config.gatewayURL.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, let url = URL(string: raw) else { return nil }
        return Profile(dialect: .gateway, baseURL: url, model: config.model,
                       keyAccount: "baton.agent.gatewayToken")
    }

    static func makeDirectProfile(_ config: AgentConfig) -> Profile? {
        guard !config.apiKey.isEmpty,
              let url = URL(string: config.baseURL.trimmingCharacters(in: .whitespaces)) else { return nil }
        return Profile(dialect: .direct, baseURL: url, model: config.model,
                       keyAccount: "baton.agent.apiKey")
    }

    /// Spends one real request to prove the configuration works, and records the
    /// result against the exact config that passed.
    ///
    /// It has to cost a request. Validating fields catches typos, not a revoked key,
    /// a model id the account can't reach, or a gateway behind a dead tunnel — and
    /// those are precisely the failures worth catching before the Friend tab claims
    /// to work.
    func runConnectionTest() async -> RemoteNaturalLanguage.TestOutcome {
        guard let profile = primaryProfile else {
            return .failed("Nothing is configured yet.")
        }
        let outcome: RemoteNaturalLanguage.TestOutcome
        switch profile.dialect {
        case .direct:
            // Same probe the Mac spends: resolve "pause the music" and check the model
            // picked the matching tool, so a pass means it understood the catalog
            // rather than merely answering 200. Resolution only — nothing executes.
            outcome = await RemoteNaturalLanguage.test(
                config: {
                    var c = config.naturalLanguageConfig
                    c.model = profile.model
                    return c
                }(),
                tools: RemoteAgent.toolSchemas(definitions: tools.definitions())
            )
        case .gateway:
            outcome = await testGateway(profile)
        }
        if case .ok = outcome { config.markVerified() }
        return outcome
    }

    /// The gateway has no resolve-only endpoint, so the probe is a *read-only*
    /// question. It runs the whole path — reachability, token, model, tool dispatch —
    /// and the worst a wrong turn can do is look something up.
    private func testGateway(_ profile: Profile) async -> RemoteNaturalLanguage.TestOutcome {
        do {
            let reply = try await askGateway("What is playing right now?", profile: profile)
            let answer = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .ok(answer.isEmpty ? "Your home server answered." : "Your home server answered: \(answer)")
        } catch let error as AgentError {
            switch error {
            case .http(401, _), .http(403, _):
                return .failed("The gateway rejected the token. Check Gateway token.")
            case .http(404, _):
                return .failed("Something is running at that address, but it isn't a Baton gateway \u{2014} "
                               + "nothing answered at /v1/agent. Check the port: the gateway listens on 8788 by default.")
            case .http(let code, let hint) where code > 0:
                return .failed("The gateway answered HTTP \(code). \(hint)")
            default:
                return .failed(error.localizedDescription)
            }
        } catch let error as URLError {
            return .failed("Couldn't reach the gateway: \(error.localizedDescription)")
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Sends one user message through the loop; returns the assistant's final text.
    /// Primary profile first; one hop to the direct profile on transient failure
    /// (tonebox predicate: config errors fail honestly, they never hop).
    func send(_ message: String) async throws -> Reply {
        guard let primary = primaryProfile else { throw AgentError.notConfigured }
        let fallback = (primary.dialect == .gateway) ? directProfile : nil

        let route: Profile = (degradedToFallback && fallback != nil) ? fallback! : primary
        do {
            return try await runLoop(message, via: route)
        } catch let error as AgentError {
            guard let fallback, route.dialect == .gateway, shouldFallback(on: error) else { throw error }
            agentLog.warning("gateway failed (\(String(describing: error), privacy: .public)); hopping to direct API")
            let reply = try await runLoop(message, via: fallback)
            degradedToFallback = true
            return reply
        }
    }

    /// Config errors (bad key, bad URL) fail identically twice — never hop on those.
    private func shouldFallback(on error: AgentError) -> Bool {
        switch error {
        case .http(let code, _): return code == 429 || (500 ... 599).contains(code)
        case .notConfigured, .config: return false
        }
    }

    // MARK: - The loop

    /// One conversation, dialect-neutral — the kit keeps its own transcript per
    /// call, so history travels here and the same exchange reads identically
    /// whether it ran on the phone or the gateway.
    private var history: [RemoteConversationLog.Turn] = []

    private func runLoop(_ message: String, via profile: Profile) async throws -> Reply {
        switch profile.dialect {
        case .gateway:
            return try await askGateway(message, profile: profile)
        case .direct:
            return try await askDirect(message, profile: profile)
        }
    }

    /// The gateway runs the loop itself (same RemoteAgent, server-side tools),
    /// so the phone posts one turn and renders the answer.
    private func askGateway(_ message: String, profile: Profile) async throws -> Reply {
        var request = URLRequest(url: GatewayAddress.root(profile.baseURL).appendingPathComponent("v1/agent"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = NavidromeKeychain.secret(account: profile.keyAccount) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "message": message,
            "player_context": playerContext(),
            "client": "baton-ios",
        ])
        try guardTransport(request)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentError.http(0, "Non-HTTP response.") }
        guard (200 ... 299).contains(http.statusCode) else {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw AgentError.http(http.statusCode, hint(status: http.statusCode, body: body))
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let text = json["text"] as? String ?? "Done."
        let toolsRun = (json["tools_run"] as? [String])?.count ?? 0
        remember(message, text)
        return Reply(text: text, toolCallsMade: toolsRun)
    }

    /// No gateway (or it is down): run the identical agent loop locally, driving
    /// this phone's own tools. Same prompt, same guards, same tool-result shaping
    /// as the Mac — the loop lives in BatonAgentKit, not here.
    private func askDirect(_ message: String, profile: Profile) async throws -> Reply {
        guard let key = NavidromeKeychain.secret(account: profile.keyAccount), !key.isEmpty else {
            throw AgentError.notConfigured
        }
        var runConfig = self.config.naturalLanguageConfig
        runConfig.apiKey = key
        runConfig.model = profile.model
        runConfig.baseURL = profile.baseURL.absoluteString

        do {
            let outcome = try await RemoteAgent.run(
                message: message,
                history: history,
                playerContext: playerContext(),
                config: runConfig,
                tools: RemoteAgent.toolSchemas(definitions: tools.definitions()),
                runTool: { [tools] call in
                    await tools.run(name: call.name, arguments: call.jsonArguments, sessionID: nil)
                },
                learned: learnedCorrections?()
            )
            let text = outcome.choice?.rendered() ?? outcome.text
            remember(message, text)
            return Reply(text: text, toolCallsMade: outcome.toolsRun.count,
                         toolCalls: outcome.toolCalls,
                         startedPlayback: outcome.toolsRun.contains(where: RemoteAgent.startsPlayback.contains))
        } catch let error as URLError {
            throw AgentError.http(error.errorCode, "The model endpoint was unreachable.")
        } catch {
            throw AgentError.config(String(describing: error))
        }
    }

    /// The player state the model needs to answer "what is this?" or "more like
    /// this" without a second round trip — the same idea the Mac's router uses.
    private func playerContext() -> String {
        guard let song = player.nowPlaying else { return "Player state: nothing is playing right now." }
        let state = player.isPlaying ? "Playing" : "Paused"
        // Collapses to just the title when the artist is a placeholder: telling the model
        // the artist is "unknown" invites it to say so back, and "by unknown" out loud makes
        // the app sound confused about its own library.
        return "Player state: \(state) \(DisplayName.titleWithArtist(title: song.title, artist: song.artist))."
    }

    private func remember(_ message: String, _ reply: String) {
        history.append(.init(role: "user", text: message))
        history.append(.init(role: "assistant", text: reply))
        // Keep the tail only: a long transcript costs tokens on every turn and
        // the friend is a conversation, not an archive.
        if history.count > 12 { history.removeFirst(history.count - 12) }
    }

    /// Plaintext only to the LAN (tandemclip's rule) — a bearer key must never
    /// cross the public internet in the clear.
    private func guardTransport(_ request: URLRequest) throws {
        if request.url?.scheme == "http", !Self.isPrivateHost(request.url?.host() ?? "") {
            throw AgentError.config("Refusing to send your key over plain HTTP to a public host.")
        }
    }

    private func hint(status: Int, body: String) -> String {
        switch status {
        case 401, 403: return "Check the API key in Settings."
        case 429: return "Rate limited — trying the fallback if one is configured."
        case 404: return "Check the endpoint URL — the path wasn't found."
        default: return body.isEmpty ? "" : body
        }
    }

    /// localhost / .local / RFC-1918 — the hosts a self-hosted setup legitimately uses.
    nonisolated static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        if host.hasPrefix("172."), let second = Int(host.split(separator: ".").dropFirst().first ?? ""),
           (16 ... 31).contains(second) { return true }
        return false
    }
}
