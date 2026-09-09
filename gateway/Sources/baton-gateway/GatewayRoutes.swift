import BatonAgentKit
import BatonGatewayCore
import BatonMCPProtocol
import BatonSubsonicKit
import BatonSubsonicModels
import Foundation

/// The gateway's handlers, and the table that names which path reaches which one.
///
/// Split out of `main.swift` with the dispatch itself (S-F24). The dispatch went to
/// `BatonGatewayCore.Router`, where a test can reach it; the handlers stayed here, because
/// they need the Navidrome client, the agent loop and the on-disk stores, none of which the
/// core target depends on.
///
/// Dependencies are held rather than captured from top-level `let`s. A handler that reads a
/// global declared in `main.swift` compiles, but it also means the only way to exercise one
/// is to start the whole process, which is the shape this card exists to undo.
@MainActor
struct GatewayRoutes {
    let token: String
    let healthClient: NavidromeClient
    let healthProbeTimeout: TimeInterval
    let startedAt: Date
    let deviceLink: DeviceLink
    let stateStore: StateStore
    let fileStore: FileStore
    let surface: GatewayToolSurface
    let llmConfig: RemoteControlSettings.NaturalLanguageConfig

    /// The table, in priority order. `/v1/files` is listed before the `/v1/files/` prefix so
    /// the exact row wins; every other row is an exact path and order does not matter.
    ///
    /// `PUT /v1/files/{id}` is deliberately absent: an upload never reaches the router,
    /// because the transport streams its body to disk first and calls `handleUpload`. Leaving
    /// it out of the table means a `PUT` that somehow arrives here is refused with 405 rather
    /// than being handled twice.
    func router() -> Router {
        Router(token: token, routes: [
            Router.Route(methods: ["GET"], pattern: .exact("/health"), isPublic: true,
                         handler: { _, _ in await self.health() }),
            Router.Route(methods: ["GET"], pattern: .exact("/v1/state"),
                         handler: { _, _ in self.readState() }),
            Router.Route(methods: ["PUT"], pattern: .exact("/v1/state"),
                         handler: { request, _ in self.writeState(request) }),
            Router.Route(methods: ["GET"], pattern: .exact("/v1/files"),
                         handler: { _, _ in self.listFiles() }),
            Router.Route(methods: ["GET", "DELETE"], pattern: .prefix("/v1/files/"),
                         handler: { request, id in self.file(request, id: id) }),
            Router.Route(methods: ["GET"], pattern: .exact("/v1/device/poll"),
                         handler: { _, _ in await self.devicePoll() }),
            Router.Route(methods: ["POST"], pattern: .exact("/v1/device/result"),
                         handler: { request, _ in await self.deviceResult(request) }),
            Router.Route(methods: ["POST"], pattern: .exact("/v1/agent"),
                         handler: { request, _ in await self.agent(request) }),
        ])
    }

    // MARK: - Health

    /// Bounded, because it used to answer in two minutes. See `healthClient`.
    ///
    /// **Yes, an unauthenticated route makes an outbound call, and it stays that way.** The
    /// probe is the whole reason this route is worth polling: without it `/health` can only
    /// say "a process is listening", which the TCP connection already said. What it adds is
    /// the distinction between a gateway that is up and one that is up and *blind* - the
    /// state the whole of TBX-5068 was spent identifying by hand. What was unreasonable was
    /// the cost: an anonymous caller could park a request here for two minutes. One ping and
    /// at most two seconds is a fair price for the only signal the route carries, on a LAN
    /// service that is not exposed to the internet. If it ever is, the next step is a cached
    /// last-probe result with a short TTL rather than dropping the probe: a health check
    /// that has stopped checking anything is the failure mode, not the fix.
    func health() async -> Data {
        let navidrome = await HealthProbe.run(timeout: healthProbeTimeout) {
            try await self.healthClient.ping()
        }
        // Device-poll counters ride along. The empty poll is dropped from the
        // request log on purpose, and it is the *only* trace `awaitCommand` leaves, so
        // without these a gateway holding a poll open every 25 seconds and one nothing has
        // touched in a week produce byte-identical logs. Read in one actor hop, so the
        // numbers agree with the waiter list they came from.
        let body = GatewayHealth.body(
            navidrome: navidrome,
            startedAt: startedAt,
            polls: await deviceLink.pollStats
        )
        return httpResponse(status: "200 OK", body: body)
    }

    // MARK: - Shared preferences

    /// Shared preferences: the settings that are yours rather than a device's - EQ curve,
    /// radio bans, crossfade, the agent's non-secret config. Navidrome has nowhere to keep
    /// these (there is no client-preference API), and iCloud would drag a provisioning
    /// profile into the Mac's Developer ID release flow, so the gateway is the one place
    /// both apps already authenticate to.
    ///
    /// Persisted to disk rather than held in memory: a gateway restart is routine, and
    /// silently losing someone's settings because a container bounced would be worse than
    /// not syncing them at all.
    ///
    /// Both answers carry the document's revision and this gateway's own clock. The revision
    /// is what makes a read-modify-write safe: before it, a device that merged and pushed
    /// could not tell that the other device had written in between, and the second push
    /// simply replaced the first. The clock is what lets two devices order their edits at
    /// all: they used to compare timestamps each had stamped with its own clock, so a device
    /// an hour ahead won every conflict for a key until the other edited past that future
    /// time (S-F17).
    func readState() -> Data {
        let state = stateStore.read()
        return httpResponse(status: "200 OK", contentType: "application/json",
                            payload: Data(state.body.utf8),
                            extraHeaders: StateStore.responseHeaders(revision: state.revision))
    }

    func writeState(_ request: HTTPRequestMessage) -> Data {
        // Validated as JSON before it lands: a truncated PUT must not leave a file that
        // every future GET chokes on.
        guard (try? JSONSerialization.jsonObject(with: request.body)) != nil else {
            return httpResponse(status: "400 Bad Request", body: #"{"error":"body must be JSON"}"#)
        }
        // Absent from an older client, and accepted without it. Refusing an unversioned PUT
        // would break sync on every device that had not been updated yet, which is worse than
        // the race.
        let expected = request.headers[StateStore.revisionHeader.lowercased()].flatMap(Int.init)
        switch stateStore.write(request.body, ifRevision: expected) {
        case let .written(revision):
            return httpResponse(status: "200 OK", contentType: "application/json",
                                payload: Data(#"{"ok":true}"#.utf8),
                                extraHeaders: StateStore.responseHeaders(revision: revision))
        case let .stale(current):
            // A distinguishable status on purpose: the client's answer is to read the
            // document again and re-merge, which it cannot decide to do if this looks like
            // any other error.
            return httpResponse(
                status: "409 Conflict", contentType: "application/json",
                payload: Data(jsonObject(["error": "stale revision", "revision": current]).utf8),
                extraHeaders: StateStore.responseHeaders(revision: current))
        case .failed:
            return httpResponse(status: "500 Internal Server Error",
                                body: #"{"error":"could not persist state"}"#)
        }
    }

    // MARK: - Files

    /// Files parked for another device. A Mac exports a reading and puts it here;
    /// the phone collects it. Nothing here knows what a reading is: podcast audio and
    /// downloaded tracks want the same road, and a second transport per file type is how a
    /// household ends up with three half-working ones.
    func listFiles() -> Data {
        let listing = fileStore.list()
        let data = (try? JSONEncoder.gatewayISO8601.encode(listing)) ?? Data("[]".utf8)
        return httpResponse(status: "200 OK", body: String(data: data, encoding: .utf8) ?? "[]")
    }

    func file(_ request: HTTPRequestMessage, id: String) -> Data {
        switch request.method.uppercased() {
        case "DELETE":
            fileStore.remove(id: id)
            return httpResponse(status: "200 OK", body: #"{"ok":true}"#)
        default:
            guard let meta = fileStore.metadata(id: id), let url = fileStore.blobURL(id: id),
                  let payload = try? Data(contentsOf: url) else {
                return httpResponse(status: "404 Not Found", body: #"{"error":"no such file"}"#)
            }
            // The digest travels in a header so the receiver can verify what it just
            // downloaded. The gateway never checks it: end-to-end beats hop-by-hop, and it
            // means a store nobody fully trusts still cannot hand over bad bytes without
            // being caught.
            var headers = ["X-Baton-Name": meta.name]
            if let sha = meta.sha256 { headers["X-Baton-SHA256"] = sha }
            return httpResponse(status: "200 OK", contentType: meta.contentType,
                                payload: payload, extraHeaders: headers)
        }
    }

    /// Publish a body the transport has already streamed to disk.
    ///
    /// Authenticated here rather than in the transport, and that ordering is deliberate: the
    /// body is written to a staging file *before* the token is checked, so an unauthenticated
    /// caller can make the gateway write up to one file's worth of bytes. The alternative,
    /// parsing and checking auth mid-stream, puts credential handling inside the framing
    /// code, which is worse. What keeps it safe is that the staging file is deleted on every
    /// path out of here, so nothing accumulates.
    func handleUpload(_ request: StreamingUpload.Request, _ staged: URL) async -> Data {
        func fail(_ status: String, _ message: String) -> Data {
            try? FileManager.default.removeItem(at: staged)
            return httpErrorResponse(status: status, message: message)
        }
        // `Request.bearerToken`, the same parse every other route uses. The hand-rolled
        // `replacingOccurrences(of: "Bearer ", with: "")` here was case-sensitive, so a
        // spec-legal `authorization: bearer <token>` was accepted on GET /v1/files and
        // refused on this route (TBX-5308, S-F26).
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

    // MARK: - Device link

    /// Device link: the player parks here waiting for something to do.
    func devicePoll() async -> Data {
        if let command = await deviceLink.awaitCommand() {
            let data = (try? JSONSerialization.data(withJSONObject: command.json)) ?? Data("{}".utf8)
            return httpResponse(status: "200 OK", body: String(data: data, encoding: .utf8) ?? "{}")
        }
        return httpResponse(status: "204 No Content", body: "")
    }

    func deviceResult(_ request: HTTPRequestMessage) async -> Data {
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

    // MARK: - Agent

    func agent(_ request: HTTPRequestMessage) async -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let message = json["message"] as? String, !message.isEmpty else {
            return httpErrorResponse(status: "400 Bad Request", message: "message is required")
        }
        // Which conversation this turn belongs to, so `music_similar_songs` seeds from *its*
        // search rather than from whatever the last caller happened to look up (TBX-5308,
        // S-F26). Optional: a client that sends nothing shares one slot, which is the
        // behaviour it had before.
        let sessionID = json["session_id"] as? String
        do {
            let outcome = try await RemoteAgent.run(
                message: message,
                history: [],
                playerContext: json["player_context"] as? String,
                config: llmConfig,
                tools: RemoteAgent.toolSchemas(definitions: surface.definitions()),
                runTool: { call in
                    await self.surface.run(name: call.name, arguments: call.jsonArguments,
                                           sessionID: sessionID)
                }
            )
            let reply: [String: Any] = ["text": outcome.text, "tools_run": outcome.toolsRun]
            return httpResponse(status: "200 OK", body: jsonObject(reply))
        } catch {
            // Serialised, not interpolated into a JSON literal. `RemoteNaturalLanguage.Failure`
            // carries the provider's own text, which reliably contains quotes and newlines, so
            // the body used to be invalid JSON, the phone fell back to a generic message, and
            // "your credit balance is too low" never reached anybody (TBX-5308, S-F26).
            return httpErrorResponse(status: "502 Bad Gateway", message: String(describing: error))
        }
    }
}

extension JSONEncoder {
    /// ISO-8601 dates on the wire. The default is a float since 2001, which is unreadable in
    /// a log and a trap for any client that is not Foundation.
    static var gatewayISO8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
