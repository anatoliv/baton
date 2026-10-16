import Foundation

/// Optional integrity signal, independent of caller-supplied platform and bearer ownership.
public struct ShareAttestationPolicy: Codable, Equatable, Sendable {
    public var appID: String
    public var environment: String
    public var audience: String
    public init(appID: String, environment: String, audience: String) {
        self.appID = appID; self.environment = environment; self.audience = audience
    }
    public static func origin(_ url: URL) -> String? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { return nil }
        parts.scheme = scheme; parts.host = host; parts.path = ""
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        return parts.string
    }
}

public struct ShareAttestationChallengeRequest: Codable, Sendable {
    public var purpose: String
    public var keyID: String
    public init(purpose: String, keyID: String) { self.purpose = purpose; self.keyID = keyID }
}

public struct ShareAttestationChallenge: Codable, Sendable {
    public var id: String
    public var nonce: String
    public var expiresAt: String
    public init(id: String, nonce: String, expiresAt: String) {
        self.id = id; self.nonce = nonce; self.expiresAt = expiresAt
    }
}

public struct ShareAttestationEnrollment: Codable, Sendable {
    public var keyID: String
    public var challengeID: String
    public var object: String
    public init(keyID: String, challengeID: String, object: String) {
        self.keyID = keyID; self.challengeID = challengeID; self.object = object
    }
}

public struct ShareAttestationProof: Codable, Equatable, Sendable {
    public var keyID: String
    public var challengeID: String
    public var requestID: String
    public var assertion: String
    public init(keyID: String, challengeID: String, requestID: String, assertion: String) {
        self.keyID = keyID; self.challengeID = challengeID; self.requestID = requestID; self.assertion = assertion
    }
    public static let header = "X-Baton-App-Attest"
    public func headerValue() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self).base64EncodedString()
    }
}

public enum ShareAttestationEnvelope {
    /// Length-prefixed UTF-8 components avoid JSON canonicalization and delimiter ambiguity.
    public static func data(challenge: ShareAttestationChallenge, policy: ShareAttestationPolicy,
                            secret: String, requestID: String, body: Data, path: String = "/v1/share/shares") -> Data {
        let parts = ["baton-share-app-attest-v1", "POST", path, policy.appID,
                     policy.environment, policy.audience, challenge.id, challenge.nonce, ShareHash.secretDigest(secret),
                     requestID, ShareHash.sha256Hex(body)]
        var result = Data()
        for part in parts {
            let bytes = Data(part.utf8)
            var count = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { result.append(contentsOf: $0) }
            result.append(bytes)
        }
        return result
    }
}
