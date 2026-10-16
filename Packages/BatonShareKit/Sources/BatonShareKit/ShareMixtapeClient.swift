import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PreparedMixtape: Sendable {
    public struct Input: Sendable {
        public let audio: Data
        public let metadata: ShareMetadata
        public init(audio: Data, metadata: ShareMetadata) { self.audio = audio; self.metadata = metadata }
    }
    public let key: Data
    public let request: CreateMixtapeRequest
    public let manifest: ShareMixtapeManifest
    public let sealedTracks: [String: Data]
    public static func make(tracks: [Input], title: String, preview: MixtapePreview?, expiresInSeconds: Int,
                            playCap: Int, client: ShareClientInfo, reviewPreservationConsent: String? = nil,
                            limits: ShareLimits = .standard, key: Data = ShareCrypto.newKey()) throws -> Self {
        guard (2...12).contains(tracks.count), key.count == 16 else { throw ShareValidationError("tracks", "select 2 to 12 tracks") }
        var bytes = 0, duration = 0, descriptors = [ShareMixtapeManifest.Track](), sealed = [String: Data]()
        for input in tracks {
            let metadata = try input.metadata.validated(limits: limits)
            guard metadata.durationSeconds <= limits.maxDurationSeconds - duration,
                  input.audio.count <= limits.maxAudioBytes - bytes else { throw ShareValidationError("tracks", "aggregate size or duration exceeded") }
            var id = Base64URL.encode(ShareCrypto.newKey())
            while sealed[id] != nil { id = Base64URL.encode(ShareCrypto.newKey()) }
            let audio = try ShareCrypto.seal(input.audio, key: ShareMixtapeCrypto.trackKey(rootKey: key, trackID: id), purpose: .audio)
            guard audio.count <= limits.maxAudioBytes - bytes else { throw ShareValidationError("audio", "aggregate encrypted size exceeded") }
            bytes += audio.count; duration += metadata.durationSeconds; sealed[id] = audio
            descriptors.append(.init(id: id, metadata: metadata, audioBytes: audio.count, audioSHA256: ShareHash.sha256Hex(audio)))
        }
        let manifest = try ShareMixtapeManifest(title: title, tracks: descriptors).validated(limits: limits)
        let request = try CreateMixtapeRequest(encryptedManifest: manifest.seal(rootKey: key).base64EncodedString(), tracks: Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, .init(audioBytes: $0.audioBytes, audioSHA256: $0.audioSHA256)) }), totalDurationSeconds: duration,
            expiresInSeconds: expiresInSeconds, playCap: playCap, preview: preview, client: client, reviewPreservationConsent: reviewPreservationConsent).validated(limits: limits)
        return .init(key: key, request: request, manifest: manifest, sealedTracks: sealed)
    }
    public func encodedRequest() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(request)
    }
}

extension ShareClient {
    public func mixtapeConfiguration() async throws -> ShareConfig {
        try await mixtapeSend("GET", "/v1/share/config", maximumBytes: 16_384, authenticated: false)
    }
    public func createMixtape(body: Data, proof: ShareAttestationProof? = nil) async throws -> CreateMixtapeResponse {
        guard body.count <= 100_000 else { throw Failure.unexpected(0) }
        let result: CreateMixtapeResponse = try await mixtapeSend("POST", "/v1/share/mixtapes", body: body, proof: proof)
        guard ShareLink.isValidID(result.id), let url = URL(string: result.url), Self.sameMixtapeOrigin(url, base),
              url.path == "/m/\(result.id)", url.query == nil, url.fragment == nil,
              ShareDate.date(result.expiresAt) != nil, (2...12).contains(result.uploads.count),
              result.uploads.allSatisfy({ ShareMixtapeCrypto.isCanonicalTrackID($0.key) && $0.value == "/v1/share/mixtapes/\(result.id)/tracks/\($0.key)" }) else { throw Failure.unexpected(0) }
        return result
    }
    public func uploadMixtape(_ id: String, trackID: String, data: Data) async throws {
        guard ShareLink.isValidID(id), ShareMixtapeCrypto.isCanonicalTrackID(trackID), data.count <= ShareLimits.standard.maxAudioBytes else { throw Failure.unexpected(0) }
        let _: [String: Bool] = try await mixtapeSend("PUT", "/v1/share/mixtapes/\(id)/tracks/\(trackID)", body: data, contentType: "application/octet-stream")
    }
    public func finalizeMixtape(_ id: String) async throws -> MixtapeSummary {
        guard ShareLink.isValidID(id) else { throw Failure.unexpected(0) }
        return try await mixtapeSend("POST", "/v1/share/mixtapes/\(id)/finalize")
    }
    public func mixtape(_ id: String) async throws -> MixtapeSummary {
        guard ShareLink.isValidID(id) else { throw Failure.unexpected(0) }
        return try await mixtapeSend("GET", "/v1/share/mixtapes/\(id)")
    }
    public func listMixtapes() async throws -> [MixtapeSummary] {
        let list: MixtapeList = try await mixtapeSend("GET", "/v1/share/mixtapes", maximumBytes: 1_048_576)
        return list.mixtapes
    }
    public func extendMixtape(_ id: String, bySeconds seconds: Int) async throws -> MixtapeSummary {
        guard ShareLink.isValidID(id) else { throw Failure.unexpected(0) }
        return try await mixtapeSend("PATCH", "/v1/share/mixtapes/\(id)", body: JSONEncoder().encode(PatchShareRequest(extendBySeconds: seconds)))
    }
    public func revokeMixtape(_ id: String) async throws {
        guard ShareLink.isValidID(id) else { throw Failure.unexpected(0) }
        _ = try await mixtapeRaw("DELETE", "/v1/share/mixtapes/\(id)", body: nil, contentType: nil, proof: nil, maximumBytes: 4096)
    }
    public func shareMixtape(_ prepared: PreparedMixtape, progress: (@Sendable (Double) -> Void)? = nil) async throws -> (link: URL, summary: MixtapeSummary) {
        guard try await mixtapeConfiguration().mixtapes == 1 else { throw Failure.service(status: 409, code: "unsupported", message: "This service does not support mixtapes.") }
        let created = try await createMixtape(body: prepared.encodedRequest())
        guard Set(created.uploads.keys) == Set(prepared.sealedTracks.keys) else { throw Failure.unexpected(0) }
        for (index, track) in prepared.manifest.tracks.enumerated() {
            try await uploadMixtape(created.id, trackID: track.id, data: prepared.sealedTracks[track.id]!)
            progress?(Double(index + 1) / Double(prepared.manifest.tracks.count + 1))
        }
        let summary = try await finalizeMixtape(created.id)
        progress?(1)
        return (ShareInvitation(id: created.id, key: prepared.key, kind: .mixtape).url(base: base), summary)
    }
    private static func sameMixtapeOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme == rhs.scheme && lhs.host == rhs.host && lhs.port == rhs.port && lhs.user == nil && lhs.password == nil
    }
    private func mixtapeSend<T: Decodable>(_ method: String, _ path: String, body: Data? = nil,
        contentType: String = "application/json", proof: ShareAttestationProof? = nil, maximumBytes: Int = 196_608, authenticated: Bool = true) async throws -> T {
        let data = try await mixtapeRaw(method, path, body: body, contentType: body == nil ? nil : contentType, proof: proof, maximumBytes: maximumBytes, authenticated: authenticated)
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { throw Failure.unexpected(0) }
        return decoded
    }
    private func mixtapeRaw(_ method: String, _ path: String, body: Data?, contentType: String?, proof: ShareAttestationProof?, maximumBytes: Int, authenticated: Bool = true) async throws -> Data {
        // Reuse the recipient's vetted origin policy; authenticated requests have no foreign URL input.
        _ = try ShareReceiverClient(base: base)
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL, Self.sameMixtapeOrigin(url, base), url.query == nil, url.fragment == nil else { throw Failure.unexpected(0) }
        let configuration = session.configuration
        configuration.timeoutIntervalForResource = body.map { $0.count > 1_000_000 ? 300 : 30 } ?? 30
        let transport = BoundedShareReceiverTransport(makeConfiguration: { configuration })
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: configuration.timeoutIntervalForResource)
        request.httpMethod = method; request.httpBody = body; request.httpShouldHandleCookies = false
        if authenticated { request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization") }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let proof { request.setValue(try proof.headerValue(), forHTTPHeaderField: ShareAttestationProof.header) }
        let response: ShareReceiverResponse
        do { response = try await transport.send(request, maximumBytes: maximumBytes, maximumErrorBytes: 4096) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Failure.transport("Mixtape transfer unavailable.") }
        guard (200...299).contains(response.status) else {
            guard response.body.count <= 4096 else { throw Failure.unexpected(0) }
            let code = (try? JSONDecoder().decode(ShareErrorBody.self, from: response.body))?.code ?? "unavailable"
            let known: Set<String> = ["unsupported", "busy", "state", "incomplete", "invalid", "checksum", "conflict", "action_required", "share_disabled", "rate_limited", "app_attest_invalid"]
            throw Failure.service(status: response.status, code: known.contains(code) ? code : "unavailable", message: "Mixtape request unavailable.")
        }
        return response.body
    }
}
