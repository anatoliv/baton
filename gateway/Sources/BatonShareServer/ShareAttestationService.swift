import BatonShareKit
import BatonMCPProtocol
import Foundation

extension ShareService {
    static let attestationSchema = """
    CREATE TABLE IF NOT EXISTS app_attest_challenges(
      id TEXT PRIMARY KEY, nonce TEXT NOT NULL, digest TEXT NOT NULL, key_id TEXT NOT NULL,
      purpose TEXT NOT NULL, expires_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS app_attest_keys(
      key_id TEXT PRIMARY KEY, digest TEXT NOT NULL, environment TEXT NOT NULL,
      public_key TEXT NOT NULL, receipt TEXT NOT NULL, counter INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL, used_at INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS app_attest_keys_owner_used ON app_attest_keys(digest, used_at);
    CREATE TABLE IF NOT EXISTS app_attest_creates(
      request_id TEXT PRIMARY KEY, digest TEXT NOT NULL, body_hash TEXT NOT NULL,
      proof_hash TEXT NOT NULL, response TEXT NOT NULL, expires_at INTEGER NOT NULL);
    """

    /// Called under the service lock by both periodic/startup sweeps and API
    /// requests. Retention does not depend on verification remaining enabled.
    func sweepAttestation(now: Int64) throws {
        try store.database.run("DELETE FROM app_attest_challenges WHERE expires_at <= ?", [.int(now)])
        try store.database.run("DELETE FROM app_attest_creates WHERE expires_at <= ?", [.int(now)])
        try store.database.run("DELETE FROM app_attest_keys WHERE used_at <= ?", [.int(now - 90 * 86400)])
    }

    func attestationRoute(_ request: HTTPRequestMessage, action: String, who: ShareRequester) throws -> ShareResponse {
        guard let verifier = attestationVerifier else { return .error(404, "not_found", "No such route.") }
        guard request.method == "POST" else { return .error(405, "method", "Method not allowed.") }
        guard let sharer = sharer(bearer: request.bearerToken) else { return .error(401, "unauthorized", "Missing install secret.") }
        guard request.body.count <= 49152 else { return .error(413, "invalid", "Request too large.") }
        let network = salt.hash(["attest", who.address], now: now)
        guard limiter.allow("attest:\(network)", limit: 30, per: 60, now: now) else { return .error(429, "rate_limited", "Try again later.") }
        try sweepAttestation(now: now)
        if action == "challenge" || action == "status" {
            guard let body = try? JSONDecoder().decode(ShareAttestationChallengeRequest.self, from: request.body) else { throw AppAttestError.invalid }
            guard let id = Data(base64Encoded: body.keyID), id.count == 32 else { throw AppAttestError.invalid }
            let registered = try store.database.query("SELECT digest, environment FROM app_attest_keys WHERE key_id = ?", [.text(body.keyID)]).first
            if let registered, registered["digest"]?.text != sharer.digest || registered["environment"]?.text != verifier.config.policy.environment {
                throw AppAttestError.invalid
            }
            if action == "status" { return .json(["registered": registered != nil]) }
            guard ["enroll", "create"].contains(body.purpose), body.purpose != "create" || registered != nil else { throw AppAttestError.invalid }
            guard try store.database.scalar("SELECT COUNT(*) FROM app_attest_challenges") < 4096,
                  try store.database.scalar("SELECT COUNT(*) FROM app_attest_challenges WHERE digest = ?", [.text(sharer.digest)]) < 4 else {
                return .error(429, "rate_limited", "Try again later.")
            }
            let challenge = ShareAttestationChallenge(id: UUID().uuidString, nonce: ShareClient.newSecret(),
                expiresAt: ShareDate.string(Date(timeIntervalSince1970: TimeInterval(now + 300))))
            try store.database.run("INSERT INTO app_attest_challenges VALUES(?,?,?,?,?,?)", [
                .text(challenge.id), .text(challenge.nonce), .text(sharer.digest), .text(body.keyID), .text(body.purpose), .int(now + 300)])
            return .json(challenge)
        }
        guard action == "enroll" else { return .error(404, "not_found", "No such route.") }
        guard let body = try? JSONDecoder().decode(ShareAttestationEnrollment.self, from: request.body) else { throw AppAttestError.invalid }
        let challenge = try attestChallenge(body.challengeID, key: body.keyID, digest: sharer.digest, purpose: "enroll")
        guard let object = Data(base64Encoded: body.object), object.count <= 32768 else { throw AppAttestError.invalid }
        guard try store.database.scalar("SELECT COUNT(*) FROM app_attest_keys WHERE key_id = ?", [.text(body.keyID)]) == 0 else { throw AppAttestError.invalid }
        guard try store.database.scalar("SELECT COUNT(*) FROM app_attest_keys") < 8192 else {
            return .error(429, "rate_limited", "Try again later.")
        }
        let verified = try verifier.attest(object: object, keyID: body.keyID, challenge: Data(challenge.nonce.utf8), now: Date(timeIntervalSince1970: TimeInterval(now)))
        try store.database.transaction {
            // Only verified enrollment can evict this install's oldest key.
            let previous = try store.database.query("SELECT key_id FROM app_attest_keys WHERE digest = ? ORDER BY used_at DESC, created_at DESC", [.text(sharer.digest)])
            for row in previous.dropFirst(2) {
                if let key = row["key_id"]?.text { try store.database.run("DELETE FROM app_attest_keys WHERE key_id = ?", [.text(key)]) }
            }
            try store.database.run("INSERT INTO app_attest_keys VALUES(?,?,?,?,?,0,?,?)", [
                .text(body.keyID), .text(sharer.digest), .text(verifier.config.policy.environment),
                .text(verified.publicKey.base64EncodedString()), .text(verified.receipt.base64EncodedString()), .int(now), .int(now)])
            try store.database.run("DELETE FROM app_attest_challenges WHERE id = ?", [.text(challenge.id)])
        }
        return .json(["registered": true])
    }

    func attestChallenge(_ id: String, key: String, digest: String, purpose: String) throws -> ShareAttestationChallenge {
        guard UUID(uuidString: id) != nil,
              let row = try store.database.query("SELECT * FROM app_attest_challenges WHERE id = ?", [.text(id)]).first,
              row["digest"]?.text == digest, row["key_id"]?.text == key, row["purpose"]?.text == purpose,
              let nonce = row["nonce"]?.text, let expiry = row["expires_at"]?.int, expiry > now else { throw AppAttestError.invalid }
        return .init(id: id, nonce: nonce, expiresAt: ShareDate.string(Date(timeIntervalSince1970: TimeInterval(expiry))))
    }

    struct VerifiedCreate {
        var proof: ShareAttestationProof
        var counter: Int64
        var bodyHash: String
        var proofHash: String
    }

    func verifyCreate(_ request: HTTPRequestMessage, sharer: Sharer) throws -> (verified: VerifiedCreate?, replay: ShareResponse?) {
        guard let header = request.headers[ShareAttestationProof.header.lowercased()] else { return (nil, nil) }
        guard let verifier = attestationVerifier, header.count <= 16384,
              let bytes = Data(base64Encoded: header), let proof = try? JSONDecoder().decode(ShareAttestationProof.self, from: bytes),
              UUID(uuidString: proof.requestID) != nil, let assertion = Data(base64Encoded: proof.assertion) else { throw AppAttestError.invalid }
        let bodyHash = ShareHash.sha256Hex(request.body), proofHash = ShareHash.sha256Hex(bytes)
        if let row = try store.database.query("SELECT * FROM app_attest_creates WHERE request_id = ?", [.text(proof.requestID)]).first {
            guard row["digest"]?.text == sharer.digest, row["body_hash"]?.text == bodyHash, row["proof_hash"]?.text == proofHash,
                  row["expires_at"]?.int ?? 0 > now, let json = row["response"]?.text,
                  let response = try? JSONDecoder().decode(CreateShareResponse.self, from: Data(json.utf8)) else { throw AppAttestError.invalid }
            return (nil, .json(response, status: 201))
        }
        let challenge = try attestChallenge(proof.challengeID, key: proof.keyID, digest: sharer.digest, purpose: "create")
        guard let key = try store.database.query("SELECT * FROM app_attest_keys WHERE key_id = ?", [.text(proof.keyID)]).first,
              key["digest"]?.text == sharer.digest, key["environment"]?.text == verifier.config.policy.environment,
              let encoded = key["public_key"]?.text, let publicKey = Data(base64Encoded: encoded), let previous = key["counter"]?.int,
              let secret = request.bearerToken else { throw AppAttestError.invalid }
        let envelope = ShareAttestationEnvelope.data(challenge: challenge, policy: verifier.config.policy, secret: secret,
                                                     requestID: proof.requestID, body: request.body)
        let counter = try verifier.assertion(object: assertion, publicKey: publicKey, envelope: envelope, previousCounter: previous)
        return (.init(proof: proof, counter: counter, bodyHash: bodyHash, proofHash: proofHash), nil)
    }

    func commitVerifiedCreate(_ verified: VerifiedCreate, response: ShareResponse, digest: String) throws {
        guard response.status == 201, let json = String(data: response.body, encoding: .utf8) else { throw AppAttestError.invalid }
        guard try store.database.run("UPDATE app_attest_keys SET counter = ?, used_at = ? WHERE key_id = ? AND digest = ? AND counter < ?", [
            .int(verified.counter), .int(now), .text(verified.proof.keyID), .text(digest), .int(verified.counter)]) == 1,
              try store.database.run("DELETE FROM app_attest_challenges WHERE id = ? AND expires_at > ?", [.text(verified.proof.challengeID), .int(now)]) == 1 else { throw AppAttestError.invalid }
        try store.database.run("INSERT INTO app_attest_creates VALUES(?,?,?,?,?,?)", [
            .text(verified.proof.requestID), .text(digest), .text(verified.bodyHash), .text(verified.proofHash), .text(json), .int(now + 86400)])
    }
}
