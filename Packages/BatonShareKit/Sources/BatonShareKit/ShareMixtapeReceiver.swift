import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A container's independent, bounded recipient channel. It never admits a second session implicitly.
public struct ShareMixtapeReceiver: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case incomplete, pending, unknown, expired, capped, unsupported, invalidData, network, unavailable, tooLarge
        case sessionRequired, transferBudget
    }
    public struct Details: Equatable, Sendable {
        fileprivate let authenticatedInvitation: ShareInvitation
        public var invitationID: String { authenticatedInvitation.id }
        public let share: PublicMixtape
        public let manifest: ShareMixtapeManifest
    }
    public let base: URL
    private let transport: any ShareReceiverTransport
    public init(base: URL = ShareLink.defaultBase, transport: any ShareReceiverTransport = BoundedShareReceiverTransport()) throws {
        self.base = try ShareReceiverClient(base: base, transport: transport).base
        self.transport = transport
    }
    public func details(_ invitation: ShareInvitation) async throws -> Details {
        guard invitation.kind == .mixtape, let key = invitation.key else { throw Failure.incomplete }
        let data = try await request(invitation.id, maximumBytes: 196_608)
        guard let share = try? JSONDecoder().decode(PublicMixtape.self, from: data),
              share.status == .ready || share.status == .pending,
              ShareDate.date(share.expiresAt) != nil, (0...1000).contains(share.remainingPlays) else { throw Failure.invalidData }
        let manifest: ShareMixtapeManifest
        do { manifest = try share.open(rootKey: key) }
        catch { throw Failure.invalidData }
        try Task.checkCancellation()
        return .init(authenticatedInvitation: invitation, share: share, manifest: manifest)
    }
    /// Only explicit Play/confirmed allowance renewal calls this method.
    public func admit(_ invitation: ShareInvitation, details: Details) async throws -> MixtapeSession {
        guard invitation.kind == .mixtape, invitation.key != nil, details.authenticatedInvitation == invitation else { throw Failure.incomplete }
        guard details.share.status == .ready else { throw Failure.pending }
        let data = try await request(invitation.id, suffix: "/sessions", maximumBytes: 4096, method: "POST")
        guard let session = try? JSONDecoder().decode(MixtapeSession.self, from: data),
              validToken(session.token), ShareDate.date(session.expiresAt) != nil,
              session.remainingBytes == details.manifest.tracks.reduce(0, { $0 + $1.audioBytes }),
              (0...1000).contains(session.remainingPlays) else { throw Failure.invalidData }
        return session
    }
    public func audio(_ invitation: ShareInvitation, details: Details, trackID: String, session: MixtapeSession) async throws -> Data {
        guard invitation.kind == .mixtape, let key = invitation.key, details.authenticatedInvitation == invitation, validToken(session.token),
              let track = details.manifest.tracks.first(where: { $0.id == trackID }) else { throw Failure.invalidData }
        let bytes = try await request(invitation.id, suffix: "/tracks/\(track.id)", maximumBytes: track.audioBytes, token: session.token)
        try Task.checkCancellation()
        do { return try details.manifest.openAudio(bytes, trackID: track.id, rootKey: key) }
        catch { throw Failure.invalidData }
    }
    public func react(_ id: String, session: MixtapeSession, reaction: ReactionRequest) async throws {
        _ = try await request(id, suffix: "/reactions", maximumBytes: 4096, method: "POST", body: JSONEncoder().encode(reaction.validated()), token: session.token)
    }
    public func event(_ id: String, session: MixtapeSession, event: PlayerEvent) async {
        guard (try? event.props()) != nil, let body = try? JSONEncoder().encode(event) else { return }
        _ = try? await request(id, suffix: "/events", maximumBytes: 4096, method: "POST", body: body, token: session.token)
    }
    private func validToken(_ token: String) -> Bool {
        guard token.count == 43, let bytes = Base64URL.decode(token) else { return false }
        return bytes.count == 32 && Base64URL.encode(bytes) == token
    }
    private func request(_ id: String, suffix: String = "", maximumBytes: Int, method: String = "GET", body: Data? = nil, token: String? = nil) async throws -> Data {
        guard ShareLink.isValidID(id), token == nil || validToken(token!) else { throw Failure.invalidData }
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.path = "/v1/share/m/\(id)\(suffix)"; parts.fragment = nil; parts.query = nil
        guard let url = parts.url else { throw Failure.invalidData }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method; request.httpBody = body; request.httpShouldHandleCookies = false
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let response: ShareReceiverResponse
        do { response = try await transport.send(request, maximumBytes: max(maximumBytes, 4096), maximumErrorBytes: 4096) }
        catch is CancellationError { throw CancellationError() }
        catch let error as ShareReceiverClient.Failure { throw error == .tooLarge ? Failure.tooLarge : Failure.network }
        catch { throw Failure.network }
        if (200...299).contains(response.status) {
            guard response.body.count <= maximumBytes else { throw Failure.tooLarge }
            return response.body
        }
        guard response.body.count <= 4096 else { throw Failure.tooLarge }
        let code = (try? JSONDecoder().decode(ShareErrorBody.self, from: response.body))?.code
        switch response.status {
        case 404: throw Failure.unknown
        case 401: throw Failure.sessionRequired
        case 410: throw code == "play_cap" ? Failure.capped : Failure.expired
        case 409 where code == "unsupported": throw Failure.unsupported
        case 409 where code == "transfer_budget": throw Failure.transferBudget
        default: throw Failure.unavailable
        }
    }
}
