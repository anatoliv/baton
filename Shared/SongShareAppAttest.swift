#if os(iOS)
import BatonShareKit
import DeviceCheck
import Foundation
import CryptoKit

/// Invoked only during explicit sharing, after the server advertises a configured
/// policy. Nothing enrolls on app launch or in the background upload delegate.
@MainActor
protocol SongShareAttestDevice {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

@MainActor
private struct AppleSongShareAttestDevice: SongShareAttestDevice {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }
    func generateKey() async throws -> String { try await DCAppAttestService.shared.generateKey() }
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
    }
}

@MainActor
final class SongShareAppAttest {
    private let directory: URL
    private let service: any SongShareAttestDevice
    private let configuration: URLSessionConfiguration
    init(directory: URL, device: (any SongShareAttestDevice)? = nil, configuration: URLSessionConfiguration = .ephemeral) {
        self.directory = directory
        self.service = device ?? AppleSongShareAttestDevice()
        self.configuration = configuration
    }

    func proof(client: ShareClient, policy: ShareAttestationPolicy, body: Data, requestID: String, path: String = "/v1/share/shares") async throws -> ShareAttestationProof? {
        // Unsupported platforms remain explicitly unverified under the approved
        // Mac-compatible contract. An API/verification error never silently falls back.
        guard policy.audience == ShareAttestationPolicy.origin(client.base) else { throw URLError(.badServerResponse) }
        guard service.isSupported else { return nil }
        let stateURL = directory.appendingPathComponent(ShareHash.sha256Hex(Data(
            (policy.audience + policy.appID + policy.environment + ShareHash.secretDigest(client.secret)).utf8)) + ".json")
        var state: KeyState
        if FileManager.default.fileExists(atPath: stateURL.path) {
            // A protected-file read failure must preserve the existing identity.
            state = try JSONDecoder().decode(KeyState.self, from: Data(contentsOf: stateURL))
        } else {
            state = KeyState(keyID: try await service.generateKey())
            try save(state, at: stateURL)
        }
        let keyID = state.keyID
        do {
            let status: Status = try await send(client, "status", ShareAttestationChallengeRequest(purpose: "enroll", keyID: keyID))
            if !status.registered {
                // Apple enrollment is a one-time operation. Persist both the object
                // and its exact server nonce before submitting, so a lost response
                // can be retried without invoking attestKey again after relaunch.
                if state.enrollment == nil {
                    let challenge: ShareAttestationChallenge = try await send(client, "challenge", ShareAttestationChallengeRequest(purpose: "enroll", keyID: keyID))
                    let object = try await service.attestKey(keyID, clientDataHash: Data(SHA256.hash(data: Data(challenge.nonce.utf8))))
                    guard object.count <= 32768 else { throw URLError(.badServerResponse) }
                    state.enrollment = .init(keyID: keyID, challengeID: challenge.id, object: object.base64EncodedString())
                    state.enrollmentExpiresAt = ShareDate.date(challenge.expiresAt)
                    try save(state, at: stateURL)
                }
                guard let enrollment = state.enrollment, let expiry = state.enrollmentExpiresAt, expiry > Date() else {
                    // An expired nonce cannot attest this one-time key again. Keep
                    // replacement enrollment an explicit subsequent user attempt.
                    try FileManager.default.removeItem(at: stateURL)
                    throw URLError(.timedOut)
                }
                let _: Status = try await send(client, "enroll", enrollment)
            }
            if state.enrollment != nil {
                state.enrollment = nil; state.enrollmentExpiresAt = nil
                try save(state, at: stateURL)
            }
            let challenge: ShareAttestationChallenge = try await send(client, "challenge", ShareAttestationChallengeRequest(purpose: "create", keyID: keyID))
            let envelope = ShareAttestationEnvelope.data(challenge: challenge, policy: policy, secret: client.secret, requestID: requestID, body: body, path: path)
            let assertion = try await service.generateAssertion(keyID, clientDataHash: Data(SHA256.hash(data: envelope)))
            return .init(keyID: keyID, challengeID: challenge.id, requestID: requestID, assertion: assertion.base64EncodedString())
        } catch let error as DCError {
            if error.code == .invalidKey { try? FileManager.default.removeItem(at: stateURL) }
            // A later explicit user attempt can enroll a replacement after invalidKey;
            // never spin against Apple or automatically replace a key on network errors.
            throw error
        }
    }

    private struct KeyState: Codable {
        var keyID: String
        var enrollment: ShareAttestationEnrollment?
        var enrollmentExpiresAt: Date?
    }
    private func save(_ state: KeyState, at url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var parent = directory, resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        try parent.setResourceValues(resource)
        try BackgroundShareUploadStore.writeProtected(JSONEncoder().encode(state), to: url)
    }
    private struct Status: Codable { var registered: Bool }
    private func send<Request: Encodable, Response: Decodable>(_ client: ShareClient, _ action: String, _ body: Request) async throws -> Response {
        var request = URLRequest(url: client.base.appendingPathComponent("v1/share/attestation/\(action)"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("Bearer \(client.secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let session = URLSession(configuration: configuration, delegate: AppAttestNoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 65536 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

private final class AppAttestNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
#endif
