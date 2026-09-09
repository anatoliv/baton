import Foundation
import OSLog
import UIKit

private let linkLog = Logger(subsystem: "io.tonebox.baton", category: "DeviceLink")

/// Makes this phone the gateway's hands. While Baton is in the foreground it
/// holds an authenticated long-poll open; commands the server-side agent issues
/// ("play something mellow") arrive here and run against this phone's player,
/// and the answer goes back so the agent can report truthfully.
///
/// Foreground-only by design: iOS suspends background sockets within seconds,
/// and a music player that silently held the network open would be a battery
/// bug, not a feature. Ask from the phone and the loop runs locally anyway.
@MainActor
final class GatewayDeviceLink {
    private let tools: AgentTools
    private let config: AgentConfig
    private let makeSession: () -> URLSession
    private let token: (String) -> String?
    private var pollTask: Task<Void, Never>?

    /// Whether a poll loop is running. `SessionPurge` and the tests both need to know, and
    /// "is the app still holding an authenticated socket open" is not a question that should
    /// only be answerable by reading the code.
    var isRunning: Bool { pollTask != nil }

    /// The shortest gap between two polls once the gateway has answered with anything other
    /// than an empty hold, and the longest that gap is allowed to grow to.
    ///
    /// Both exist because there was no gap at all: `poll` returned nil for every response
    /// that was not a well-formed 200 with a command in it, and the loop read nil as "the
    /// hold expired, go again". A gateway answering 404 or 500 as fast as the LAN allows
    /// therefore produced an unbounded request loop for as long as the app was on screen.
    static let minimumBackoff: Duration = .seconds(1)
    static let maximumBackoff: Duration = .seconds(60)

    init(
        tools: AgentTools,
        config: AgentConfig,
        makeSession: @escaping () -> URLSession = GatewayDeviceLink.defaultSession,
        token: @escaping (String) -> String? = { NavidromeKeychain.secret(account: $0) }
    ) {
        self.tools = tools
        self.config = config
        self.makeSession = makeSession
        self.token = token
    }

    /// A dedicated session: the poll deliberately hangs for ~25s, which is not
    /// a timeout the shared session should learn.
    nonisolated static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 40
        return URLSession(configuration: configuration)
    }

    /// Bumped by every start and every stop, so a loop that finishes on its own can only
    /// clear the handle if it is still the current one.
    private var generation = 0

    /// Starts polling if a gateway is configured. Idempotent.
    func start() {
        guard pollTask == nil, let profile = AgentClient.makeGatewayProfile(config) else { return }
        generation += 1
        let mine = generation
        pollTask = Task { [weak self] in
            await self?.pollLoop(profile: profile)
            guard let self, self.generation == mine else { return }
            self.pollTask = nil
        }
    }

    func stop() {
        generation += 1
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - What an answer means

    /// The four things the gateway's answer can mean, kept apart because the old code
    /// collapsed all of them into nil and treated the result as "nothing to do".
    enum PollResult: Equatable {
        /// A well-formed command to run.
        case command
        /// The hold expired with nothing queued — the ordinary case, poll again at once.
        case idle
        /// The token is not accepted. Stop; retrying cannot fix it and the credential may
        /// have been revoked by a disconnect on this very device.
        case unauthorized
        /// Anything else: a 404 from an older gateway, a 500, an unparseable body.
        case transient
    }

    /// Pure, so the classification can be proven without a server.
    static func classify(status: Int, hasCommand: Bool) -> PollResult {
        switch status {
        case 401, 403: .unauthorized
        case 200: hasCommand ? .command : .idle
        case 204: .idle
        default: .transient
        }
    }

    private func pollLoop(profile: AgentClient.Profile) async {
        let session = makeSession()
        var backoff = Self.minimumBackoff

        while !Task.isCancelled {
            // Read fresh every iteration, never captured once. A token captured before the
            // loop outlived the credential: "Disconnect and delete my data" deletes the
            // Keychain item, and the loop went on presenting the deleted token and running
            // whatever commands came back against the local player.
            guard let token = token(profile.keyAccount), !token.isEmpty else {
                linkLog.debug("no gateway token; stopping the device link")
                return
            }
            do {
                switch try await poll(profile: profile, token: token, session: session) {
                case let .command(id, name, arguments):
                    backoff = Self.minimumBackoff
                    let result = await tools.run(name: name, arguments: arguments, sessionID: nil)
                    try await postResult(
                        id: id, text: result.text, isError: result.isError,
                        profile: profile, token: token, session: session
                    )
                case .idle:
                    backoff = Self.minimumBackoff
                case .unauthorized:
                    linkLog.notice("gateway rejected our token; stopping the device link")
                    return
                case .transient:
                    try await Task.sleep(for: backoff)
                    backoff = Self.escalate(backoff)
                }
            } catch is CancellationError {
                return
            } catch {
                // The gateway is down or the network moved. Back off rather than
                // spin: the chat path falls back to the direct API meanwhile.
                linkLog.debug("poll failed: \(error.localizedDescription, privacy: .public)")
                do { try await Task.sleep(for: backoff) } catch { return }
                backoff = Self.escalate(backoff)
            }
        }
    }

    /// Doubling, with a ceiling. Pure so the ceiling is provable.
    static func escalate(_ current: Duration) -> Duration {
        min(current * 2, maximumBackoff)
    }

    private enum Answer {
        case command(id: String, name: String, arguments: [String: Any])
        case idle
        case unauthorized
        case transient
    }

    private func poll(
        profile: AgentClient.Profile, token: String, session: URLSession
    ) async throws -> Answer {
        var request = URLRequest(url: GatewayAddress.root(profile.baseURL).appendingPathComponent("v1/device/poll"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let id = (json ?? [:])["id"] as? String
        let name = (json ?? [:])["name"] as? String
        switch Self.classify(status: status, hasCommand: id != nil && name != nil) {
        case .command:
            guard let id, let name else { return .idle }
            return .command(id: id, name: name,
                            arguments: (json ?? [:])["arguments"] as? [String: Any] ?? [:])
        case .idle: return .idle
        case .unauthorized: return .unauthorized
        case .transient: return .transient
        }
    }

    private func postResult(
        id: String, text: String, isError: Bool,
        profile: AgentClient.Profile, token: String, session: URLSession
    ) async throws {
        var request = URLRequest(url: GatewayAddress.root(profile.baseURL).appendingPathComponent("v1/device/result"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "id": id, "text": text, "is_error": isError,
        ])
        _ = try await session.data(for: request)
    }
}
