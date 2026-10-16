import BatonMCPProtocol
import Foundation

/// A privileged deployment must establish device/token provenance. An install bearer alone
/// does not prove token possession. The verifier must be bounded/local: the service lock is held.
/// No permissive production implementation or default is provided.
protocol ReactionPushRegistrationAdmission: Sendable {
    func admits(ownerDigest: String, deviceID: String, token: Data,
                topic: String, environment: PushEnvironment, proof: Data, now: Int64) -> Bool
}

private struct ReactionPushRegistrationResponse: Encodable {
    let revision: String
    let expiresAtMilliseconds: Int64
}

extension ShareService {
    func reactionPushRegistration(_ request: HTTPRequestMessage, deviceID: String) throws -> ShareResponse {
        // Hide the optional namespace on ordinary deployments, including cleanup-only restarts.
        guard let push = reactionPushStore else { return .error(404, "not_found", "No such route.") }
        guard let owner = sharer(bearer: request.bearerToken), try store.sharerExists(digest: owner.digest) else {
            return .error(401, "unauthorized", "An existing installation is required.")
        }
        guard UUID(uuidString: deviceID)?.uuidString == deviceID else {
            return .error(400, "invalid", "Invalid device registration.")
        }
        // Opt-out remains available while sharing or collection is paused, with no key or proof.
        if request.method.uppercased() == "DELETE" {
            guard request.body.isEmpty else { return .error(400, "invalid", "An empty body is required.") }
            try push.optOut(owner: owner.digest, deviceID: deviceID)
            return .noContent
        }
        guard config.enabled, push.policy.enabled, let admission = reactionPushAdmission else {
            return .error(503, "push_disabled", "Reaction notifications are unavailable.")
        }
        if let denial = try enforcementCreateDenial(owner) { return denial }
        guard request.body.count <= 8192,
              let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              Set(json.keys) == ["token", "topic", "environment", "proof"],
              let tokenText = json["token"] as? String, let token = Data(base64Encoded: tokenText),
              token.base64EncodedString() == tokenText, (1 ... 1024).contains(token.count),
              let topic = json["topic"] as? String,
              let environmentText = json["environment"] as? String,
              let environment = PushEnvironment(rawValue: environmentText),
              push.policy.topics[topic] == environment,
              let proofText = json["proof"] as? String, let proof = Data(base64Encoded: proofText),
              proof.base64EncodedString() == proofText, (1 ... 4096).contains(proof.count)
        else { return .error(400, "invalid", "Invalid device registration.") }
        let timestamp = now * 1000
        guard admission.admits(ownerDigest: owner.digest, deviceID: deviceID, token: token,
                               topic: topic, environment: environment, proof: proof, now: timestamp) else {
            return .error(401, "push_integrity", "Device registration could not be verified.")
        }
        do {
            let revision = try push.register(owner: owner.digest, deviceID: deviceID, token: token,
                                              topic: topic, environment: environment, now: timestamp)
            return .json(ReactionPushRegistrationResponse(revision: revision,
                expiresAtMilliseconds: timestamp + push.policy.registrationTTL))
        } catch let failure as ReactionPushFailure {
            switch failure {
            case .capacity, .rateLimited: return .error(429, "push_limit", "Try again later.")
            case .disabled, .keyUnavailable: return .error(503, "push_disabled", "Reaction notifications are unavailable.")
            case .invalid: return .error(400, "invalid", "Invalid device registration.")
            }
        }
    }
}
