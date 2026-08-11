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
    private var pollTask: Task<Void, Never>?

    init(tools: AgentTools, config: AgentConfig) {
        self.tools = tools
        self.config = config
    }

    /// Starts polling if a gateway is configured. Idempotent.
    func start() {
        guard pollTask == nil, let profile = AgentClient.makeGatewayProfile(config) else { return }
        pollTask = Task { [weak self] in
            await self?.pollLoop(profile: profile)
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollLoop(profile: AgentClient.Profile) async {
        guard let token = NavidromeKeychain.secret(account: profile.keyAccount), !token.isEmpty else { return }
        // A dedicated session: the poll deliberately hangs for ~25s, which is not
        // a timeout the shared session should learn.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 40
        let session = URLSession(configuration: configuration)

        while !Task.isCancelled {
            do {
                guard let command = try await poll(profile: profile, token: token, session: session) else {
                    continue // the hold expired with nothing to do — poll again
                }
                let result = await tools.run(
                    name: command.name, arguments: command.arguments, sessionID: nil
                )
                try await postResult(
                    id: command.id, text: result.text, isError: result.isError,
                    profile: profile, token: token, session: session
                )
            } catch is CancellationError {
                return
            } catch {
                // The gateway is down or the network moved. Back off rather than
                // spin: the chat path falls back to the direct API meanwhile.
                linkLog.debug("poll failed: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private struct DeviceCommand {
        let id: String
        let name: String
        let arguments: [String: Any]
    }

    private func poll(
        profile: AgentClient.Profile, token: String, session: URLSession
    ) async throws -> DeviceCommand? {
        var request = URLRequest(url: profile.baseURL.appendingPathComponent("v1/device/poll"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String, let name = json["name"] as? String
        else { return nil }
        return DeviceCommand(id: id, name: name, arguments: json["arguments"] as? [String: Any] ?? [:])
    }

    private func postResult(
        id: String, text: String, isError: Bool,
        profile: AgentClient.Profile, token: String, session: URLSession
    ) async throws {
        var request = URLRequest(url: profile.baseURL.appendingPathComponent("v1/device/result"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "id": id, "text": text, "is_error": isError,
        ])
        _ = try await session.data(for: request)
    }
}
