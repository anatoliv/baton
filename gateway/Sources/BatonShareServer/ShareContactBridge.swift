import BatonGatewayCore
import BatonMCPProtocol
import BatonShareKit
import Foundation

/// A verifier only. Reader, signing, custody and SMTP secrets are never mounted here.
public struct ShareContactConfiguration: Sendable {
    let readerDigest: String
    let relayPort: UInt16?
    public init(readerDigest: String, relayPort: UInt16? = nil) throws {
        guard readerDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw ConfigurationError("invalid contact reader verifier")
        }
        guard relayPort != 0 else { throw ConfigurationError("invalid contact relay port") }
        self.readerDigest = readerDigest
        self.relayPort = relayPort
    }
}

extension ShareService {
    static let contactSchema = """
        CREATE TABLE IF NOT EXISTS contact_authorizations(
            digest TEXT PRIMARY KEY, installation TEXT NOT NULL, purpose TEXT NOT NULL,
            shares TEXT NOT NULL, expires INTEGER NOT NULL);
        """

    func contactRoute(_ request: HTTPRequestMessage, peer: ConnectionPeer) throws -> ShareResponse {
        let hidden = ShareResponse.error(404, "not_found", "No such route.")
        guard let capability = config.contactBridge, request.method == "POST", request.query.isEmpty,
              request.body.count <= 32768,
              let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { return hidden }
        if request.path == "/v1/share/contact/authorization" {
            guard let owner = sharer(bearer: request.bearerToken) else {
                return .error(401, "unauthorized", "Installation authorization required.")
            }
            guard Set(object.keys) == ["purpose", "include"],
                  let purpose = object["purpose"] as? String,
                  ["enroll", "verify", "withdraw", "status", "caseAccess"].contains(purpose),
                  let include = object["include"] as? [String], include.count <= 200,
                  purpose == "enroll" || include.isEmpty else {
                return .error(400, "invalid", "Invalid authorization request.")
            }
            guard limiter.allow("contact:" + owner.digest, limit: 100, per: 3600, now: now) else {
                return .error(429, "rate_limited", "Try again later.")
            }
            for id in include { guard try owned(id, by: owner) != nil else { return hidden } }
            try store.database.run("DELETE FROM contact_authorizations WHERE expires<=?", [.int(now)])
            guard try store.database.scalar("SELECT COUNT(*) FROM contact_authorizations") < 10000 else {
                return .error(503, "unavailable", "Try again later.")
            }
            let token = Base64URL.encode(ShareCrypto.newKey() + ShareCrypto.newKey())
            try store.database.run("INSERT INTO contact_authorizations VALUES(?,?,?,?,?)", [
                .text(ShareHash.secretDigest(token)), .text(owner.digest), .text(purpose),
                .text(ShareStore.json(include)), .int(now + 60)])
            return .json(["authorization": token])
        }
        guard peer == .loopback,
              !request.headers.keys.contains(where: { key in
                  let key = key.lowercased()
                  return key == "forwarded" || key == "cf-connecting-ip" || key == "x-real-ip" || key.hasPrefix("x-forwarded-")
              }), let reader = request.bearerToken, (32...256).contains(reader.count),
              BatonMCPAuth.constantTimeEquals(ShareHash.secretDigest(reader), capability.readerDigest) else { return hidden }
        if request.path == "/v1/share/admin/contact/installation" {
            guard Set(object.keys) == ["authorization", "purpose"], let token = object["authorization"] as? String,
                  token.count == 43, Base64URL.decode(token)?.count == 32, let purpose = object["purpose"] as? String else { return hidden }
            return try store.database.transaction {
                let digest = ShareHash.secretDigest(token)
                guard let row = try store.database.query("SELECT * FROM contact_authorizations WHERE digest=? AND purpose=? AND expires>?", [
                    .text(digest), .text(purpose), .int(now)]).first,
                    let installation = row["installation"]?.text, let shares = row["shares"]?.text,
                    let included = try? JSONDecoder().decode([String].self, from: Data(shares.utf8)) else { return hidden }
                try store.database.run("DELETE FROM contact_authorizations WHERE digest=?", [.text(digest)])
                return .json(ContactInstallation(installation: installation, shares: included, issued: (row["expires"]?.int ?? 0) - 60, expires: row["expires"]?.int ?? 0))
            }
        }
        if request.path == "/v1/share/admin/contact/actions" {
            guard Set(object.keys) == ["after"], let cursor = object["after"] as? String,
                  cursor.isEmpty || UUID(uuidString: cursor) != nil else { return hidden }
            guard let row = try store.database.query("SELECT operation_id,receipt,contact_revisions FROM enforcement_operations WHERE operation_id>? ORDER BY operation_id LIMIT 1", [.text(cursor)]).first,
                  let operation = row["operation_id"]?.text, let text = row["receipt"]?.text,
                  let receipt = try? JSONDecoder().decode(EnforcementReceipt.self, from: Data(text.utf8)),
                  let captured = row["contact_revisions"]?.text,
                  let revisions = try? JSONDecoder().decode([String: Int64].self, from: Data(captured.utf8)) else {
                return .json(ContactActions(entries: [], next: ""))
            }
            var entries: [ContactRequired] = []
            if ["applied", "purgeQueued"].contains(receipt.outcome) {
                var unavailableScope = false
                for (id, revision) in revisions.sorted(by: { $0.key < $1.key }) {
                    if let record = try store.share(id: id) {
                        entries.append(ContactRequired(installation: record.sharerDigest, case: receipt.caseReference,
                            operation: operation, share: id, revision: revision))
                    } else {
                        unavailableScope = true
                    }
                }
                if entries.isEmpty || unavailableScope {
                    // Expired/missing historical recipient scope remains manual work.
                    entries.append(ContactRequired(installation: "", case: receipt.caseReference,
                        operation: operation, share: "", revision: 0))
                }
            }
            return .json(ContactActions(entries: entries, next: operation))
        }
        guard request.path == "/v1/share/admin/contact/action", Set(object.keys) == ["operation", "share"],
              let operation = object["operation"] as? String, UUID(uuidString: operation) != nil,
              let share = object["share"] as? String, ShareLink.isValidID(share),
              let row = try store.database.query("SELECT affected_ids,contact_revisions FROM enforcement_operations WHERE operation_id=?", [.text(operation)]).first,
              let idsText = row["affected_ids"]?.text,
              let ids = try? JSONDecoder().decode([String].self, from: Data(idsText.utf8)), ids.contains(share),
              let receipt = try store.enforcementOperation(id: operation)?.receipt,
              ["applied", "purgeQueued"].contains(receipt.outcome),
              let record = try store.share(id: share), let state = try store.enforcementState(id: share),
              state.caseReference == receipt.caseReference,
              let revisionsText = row["contact_revisions"]?.text,
              let revisions = try? JSONDecoder().decode([String: Int64].self, from: Data(revisionsText.utf8)),
              let revision = revisions[share], revision == (try ShareStore.contactRevision(overlay: state.revision,
                  installation: store.sharerRevision(digest: record.sharerDigest)))
              else { return hidden }
        return .json(ContactAction(installation: record.sharerDigest, case: receipt.caseReference, operation: operation,
            share: share, created: record.createdAt, revision: revision, action: receipt.action.rawValue))
    }
}

extension ShareStore {
    /// Injective pairing within the admitted integer bounds; no revision radix alias.
    static func contactRevision(overlay: Int64, installation: Int64) throws -> Int64 {
        guard (0...1_000_000_000).contains(overlay), (0...1_000_000_000).contains(installation) else {
            throw ConfigurationError("contact revision bound exceeded")
        }
        let total = overlay + installation
        return total * (total + 1) / 2 + installation
    }
}

private struct ContactInstallation: Encodable {
    let installation: String
    let shares: [String]
    let issued: Int64
    let expires: Int64
}
private struct ContactAction: Encodable {
    let installation: String
    let `case`: String
    let operation: String
    let share: String
    let created: Int64
    let revision: Int64
    let action: String
}

private struct ContactRequired: Encodable {
    let installation: String
    let `case`: String
    let operation: String
    let share: String
    let revision: Int64
}
private struct ContactActions: Encodable {
    let entries: [ContactRequired]
    let next: String
}
