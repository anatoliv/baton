import BatonGatewayCore
import BatonMCPProtocol
import BatonShareKit
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

extension ShareService {
    func enforcementRoute(_ request: HTTPRequestMessage, peer: ConnectionPeer) throws -> ShareResponse {
        let hidden = ShareResponse.error(404, "not_found", "No such route.")
        guard peer == .loopback, let capability = config.enforcement,
              config.adminToken != capability.token,
              !request.headers.keys.contains(where: { key in
                  let key = key.lowercased()
                  return key == "forwarded" || key == "cf-connecting-ip" || key == "x-real-ip"
                      || key.hasPrefix("x-forwarded-")
              }), request.query.isEmpty,
              BatonMCPAuth.constantTimeEquals(request.bearerToken ?? "", capability.token)
        else { return hidden }
        let prefix = "/v1/share/admin/enforcement/"
        guard request.path.hasPrefix(prefix) else { return hidden }
        let path = String(request.path.dropFirst(prefix.count))
        if request.method == "GET", path == "suspensions" || path.hasPrefix("suspensions/") {
            let cursor = path == "suspensions" ? nil : String(path.dropFirst("suspensions/".count))
            guard request.body.isEmpty, cursor == nil || ShareLink.isValidID(cursor!) else { throw EnforcementFailure.invalid }
            return .json(try store.suspensionInventory(after: cursor, maximum: capability.maximumAffectedShares))
        }
        if path.hasPrefix("operations/"), request.method == "GET" {
            let id = String(path.dropFirst("operations/".count))
            guard let uuid = UUID(uuidString: id),
                  let recovery = try store.enforcementRecovery(id: uuid.uuidString.lowercased()) else { return hidden }
            return .json(recovery)
        }
        guard request.method == "POST", path == "plan" || path == "apply" else { return hidden }
        guard !request.body.isEmpty, request.body.count <= 65_536 else { throw EnforcementFailure.invalid }
        if path == "plan" {
            let body = try decodeEnforcementRequest(request.body)
            let plan = try enforcementPlan(body.validated(configuration: capability), plannedAt: now,
                                           capability: capability)
            return .json(plan)
        }
        let keys: Set<String> = ["request", "plannedAt", "validUntil", "targetFingerprint", "sharerRevision", "affected", "signature"]
        let plan = try strictDecode(EnforcementPlan.self, data: request.body, keys: keys)
        guard let object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let requestBody = object["request"] as? [String: Any],
              validRequestKeys(Set(requestBody.keys)),
              plan.affected.count <= capability.maximumAffectedShares
        else { throw EnforcementFailure.invalid }
        guard let affected = object["affected"] as? [[String: Any]], affected.allSatisfy({ share in
            let keys = Set(share.keys)
            let required: Set<String> = ["id", "revision", "stateFingerprint", "expiresAt", "retentionDeadline", "storedBytes", "restorable"]
            return required.isSubset(of: keys) && keys.isSubset(of: required.union(["restorationBlock",
                "remainingLifetimeSeconds", "preservationStartedAt", "preservationCeiling", "reviewUntil", "courtReviewRequired"]))
        }) else { throw EnforcementFailure.invalid }
        let receipt = try applyEnforcement(plan, capability: capability)
        // An immutable receipt says purgeQueued, never that optional file cleanup succeeded.
        // Recovery separately reports the durable cleanup queue's current state.
        try store.performEnforcementCleanup(now: now)
        return .json(receipt)
    }

    private func validRequestKeys(_ keys: Set<String>) -> Bool {
        let common: Set<String> = ["operationID", "action", "caseReference", "reasonCode"]
        let optional: Set<String> = ["reviewUntil", "preservationDeadline", "courtReviewRequired", "expectedRevision"]
        let base = keys.subtracting(optional)
        return base == common.union(["shareID"]) || base == common.union(["suspensionReference"])
    }

    private func decodeEnforcementRequest(_ data: Data) throws -> EnforcementRequest {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              validRequestKeys(Set(object.keys)),
              let value = try? JSONDecoder().decode(EnforcementRequest.self, from: data) else { throw EnforcementFailure.invalid }
        return value
    }

    private func strictDecode<T: Decodable>(_ type: T.Type, data: Data, keys: Set<String>) throws -> T {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == keys, let value = try? JSONDecoder().decode(type, from: data)
        else { throw EnforcementFailure.invalid }
        return value
    }

    private func signature(_ plan: EnforcementPlan, capability: EnforcementConfiguration) -> String {
        var unsigned = plan
        unsigned.signature = ""
        let message = Data(("baton-enforcement-plan-v1\n" + ShareStore.json(unsigned)).utf8)
        let bytes = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(capability.token.utf8)))
        return Data(bytes).map { String(format: "%02x", $0) }.joined()
    }

    func enforcementPlan(_ request: EnforcementRequest, plannedAt: Int64,
                         capability: EnforcementConfiguration) throws -> EnforcementPlan {
        if let reference = request.suspensionReference {
            guard request.action == .unsuspendSharer, let digest = try store.suspensionDigest(reference: reference) else { throw EnforcementFailure.notFound }
            let revision = try store.sharerRevision(digest: digest)
            // No digest-derived proof or stable public identity: this binds a random active
            // reference and its current revision in the existing private signed protocol.
            let fingerprint = ShareHash.sha256Hex(Data("baton-suspension-v1\n\(reference)\n\(revision)".utf8))
            var plan = EnforcementPlan(request: request, plannedAt: plannedAt,
                validUntil: plannedAt + capability.planLifetimeSeconds, targetFingerprint: fingerprint,
                sharerRevision: revision, affected: [], signature: "")
            plan.signature = signature(plan, capability: capability)
            return plan
        }
        guard let id = request.shareID, let target = try store.share(id: id) else { throw EnforcementFailure.notFound }
        let scope: [ShareRecord]
        switch request.action {
        case .suspendSharer: scope = try store.enforcementScope(digest: target.sharerDigest, maximum: capability.maximumAffectedShares)
        case .unsuspendSharer: scope = []
        default: scope = [target]
        }
        let affected = try scope.map { record in
            let state = try store.enforcementState(id: record.id)
            let reason = try restorationBlock(record, state: state)
            let preservation = try preservationDetails(record, state: state, request: request,
                                                       plannedAt: plannedAt, capability: capability)
            let deadline: Int64
            if request.action == .suspendSharer, let state, state.disabled {
                deadline = state.deadline
            } else {
                deadline = preservation?.deadline ?? min(record.expiresAt, plannedAt + capability.retentionSeconds,
                                                          state?.disabled == true ? state!.deadline : Int64.max)
            }
            return EnforcementAffectedShare(id: record.id, revision: state?.revision ?? 0,
                                            stateFingerprint: try store.enforcementFingerprint(id: record.id),
                                            expiresAt: record.expiresAt, retentionDeadline: deadline,
                                            storedBytes: record.storedBytes, restorable: reason == nil,
                                            restorationBlock: reason,
                                            remainingLifetimeSeconds: preservation?.remaining,
                                            preservationStartedAt: preservation?.startedAt,
                                            preservationCeiling: preservation?.ceiling,
                                            reviewUntil: preservation?.reviewUntil,
                                            courtReviewRequired: preservation?.courtReviewRequired)
        }
        var plan = EnforcementPlan(request: request, plannedAt: plannedAt,
                                   validUntil: plannedAt + capability.planLifetimeSeconds,
                                   targetFingerprint: try store.enforcementFingerprint(id: target.id),
                                   sharerRevision: try store.sharerRevision(digest: target.sharerDigest),
                                   affected: affected, signature: "")
        plan.signature = signature(plan, capability: capability)
        return plan
    }

    private struct PreservationDetails {
        let deadline: Int64
        let startedAt: Int64
        let remaining: Int64
        let ceiling: Int64
        let reviewUntil: Int64
        let courtReviewRequired: Bool
    }

    /// No legal calendar is inferred here. Dates are supplied by a human reviewing the case.
    private func preservationDetails(_ record: ShareRecord, state: ShareEnforcementState?,
                                     request: EnforcementRequest, plannedAt: Int64,
                                     capability: EnforcementConfiguration) throws -> PreservationDetails? {
        let disabling = request.action == .disableShare || request.action == .suspendSharer
        let reviewing = request.action == .reviewPreservation
        let paused = state?.hasPausedLifetime == true && state?.disabled == true
            && state?.purged == false && record.status == .ready
        if reviewing {
            guard paused, state?.purged == false, record.status == .ready,
                  state?.caseReference == request.caseReference,
                  state?.revision == request.expectedRevision, state!.deadline > now
            else { throw EnforcementFailure.conflict }
        }
        let starting = disabling && state?.disabled != true && record.status == .ready
            && record.reviewPreservationConsent == CreateShareRequest.reviewConsentVersion
        guard paused || starting else { return nil }
        if paused, request.action == .restoreShare, state!.caseReference != request.caseReference {
            throw EnforcementFailure.conflict
        }
        if starting {
            guard record.expiresAt > now, request.reviewUntil != nil, request.preservationDeadline != nil
            else { throw EnforcementFailure.conflict }
        }
        let startedAt = state.map({ $0.disabledAt > 0 ? $0.disabledAt : plannedAt }) ?? plannedAt
        let ceiling = startedAt + 90 * 86400
        let changing = starting || reviewing
        let deadline = changing ? request.preservationDeadline! : state!.deadline
        let reviewUntil = changing ? request.reviewUntil! : state!.reviewUntil
        if changing {
            guard reviewUntil > now, deadline > now, deadline <= ceiling,
                  deadline <= startedAt + capability.retentionSeconds,
                  deadline >= reviewUntil + 2 * 86400
            else { throw EnforcementFailure.conflict }
            guard try store.storedBytes() <= config.limits.quotaBytes else { throw EnforcementFailure.quota }
        } else if request.action == .disableShare {
            // Repeated disable/suspension cannot alter a case's dates, court flag or start.
            guard request.reviewUntil == nil && request.preservationDeadline == nil && request.courtReviewRequired == nil,
                  state!.caseReference == request.caseReference else { throw EnforcementFailure.conflict }
        }
        return PreservationDetails(deadline: deadline, startedAt: startedAt,
            remaining: paused ? state!.remainingSeconds : record.expiresAt - plannedAt,
            ceiling: ceiling, reviewUntil: reviewUntil,
            courtReviewRequired: changing ? request.courtReviewRequired ?? false : state!.courtReviewRequired)
    }

    private func restorationBlock(_ record: ShareRecord, state: ShareEnforcementState?) throws -> String? {
        guard let state, state.disabled else { return "notDisabled" }
        if state.purged { return "purged" }
        if record.status != .ready { return record.status == .pending ? "incomplete" : "ended" }
        if state.deadline <= now || (!state.hasPausedLifetime && record.expiresAt <= now) { return "expired" }
        if state.hasPausedLifetime && state.courtReviewRequired { return "courtReview" }
        if state.hasPausedLifetime && record.isCapped { return "spentCap" }
        if try store.isSuspended(digest: record.sharerDigest) { return "suspended" }
        if record.isMixtape { return try store.mixtapeMaterialComplete(record, limits: config.limits) ? nil : "missingMaterial" }
        guard record.audioStored else { return "missingMaterial" }
        var bytes: Int64 = 0
        let kinds: [ShareStore.BlobKind] = [.audio] + (record.artType == nil ? [] : [.art]) + (record.cardType == nil ? [] : [.card])
        for kind in kinds {
            let file = store.blobURL(id: record.id, kind: kind)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.int64Value > 0 else { return "missingMaterial" }
            bytes += size.int64Value
            if kind == .audio {
                guard size.int64Value == Int64(record.audioBytes) else { return "missingMaterial" }
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                var hash = ShareHash.Running()
                while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(chunk) }
                if hash.finalizeHex() != record.audioSHA256 { return "missingMaterial" }
            }
        }
        return bytes == record.storedBytes ? nil : "missingMaterial"
    }

    func applyEnforcement(_ plan: EnforcementPlan, capability: EnforcementConfiguration) throws -> EnforcementReceipt {
        guard plan.request == (try plan.request.validated(configuration: capability)),
              BatonMCPAuth.constantTimeEquals(plan.signature, signature(plan, capability: capability))
        else { throw EnforcementFailure.conflict }
        let fingerprint = ShareHash.sha256Hex(Data(ShareStore.json(plan).utf8))
        if let previous = try store.enforcementOperation(id: plan.request.operationID) {
            guard previous.fingerprint == fingerprint else { throw EnforcementFailure.conflict }
            return previous.receipt
        }
        guard plan.plannedAt <= now, now < plan.validUntil,
              plan.validUntil == plan.plannedAt + capability.planLifetimeSeconds else { throw EnforcementFailure.conflict }
        return try store.database.transaction {
            let current: EnforcementPlan
            do { current = try enforcementPlan(plan.request, plannedAt: plan.plannedAt, capability: capability) }
            catch EnforcementFailure.notFound { throw EnforcementFailure.conflict }
            guard current == plan else { throw EnforcementFailure.conflict }
            let target = try plan.request.shareID.flatMap { try store.share(id: $0) }
            let digest = try plan.request.suspensionReference.flatMap { try store.suspensionDigest(reference: $0) } ?? target?.sharerDigest
            guard let digest else { throw EnforcementFailure.conflict }
            let request = plan.request
            var outcome = "applied"
            var count = plan.affected.count
            switch request.action {
            case .disableShare:
                guard let target else { throw EnforcementFailure.invalid }
                let alreadyPurged = try store.enforcementState(id: target.id)?.purged == true
                if (target.status != .ready && target.status != .pending) || alreadyPurged {
                    outcome = "unavailable"; count = 0
                } else {
                    try store.setEnforcement(id: target.id, disabled: true, purged: false,
                                             deadline: plan.affected[0].retentionDeadline, caseReference: request.caseReference,
                                             caseUntil: max(now + capability.auditRetentionSeconds, plan.affected[0].retentionDeadline))
                    try applyPreservation(plan.affected[0], record: target)
                }
            case .restoreShare:
                guard let target else { throw EnforcementFailure.invalid }
                guard plan.affected.count == 1 else { throw EnforcementFailure.invalid }
                if !plan.affected[0].restorable { outcome = "unrestorable"; count = 0 }
                else {
                    if let state = try store.enforcementState(id: target.id), state.hasPausedLifetime {
                        try store.setExpiry(id: target.id, now + state.remainingSeconds)
                    }
                    try store.setEnforcement(id: target.id, disabled: false, purged: false,
                                             deadline: plan.affected[0].retentionDeadline, caseReference: request.caseReference, caseUntil: now + capability.auditRetentionSeconds)
                    let firstDisable = try store.enforcementState(id: target.id)?.disabledAt ?? 0
                    try store.setPreservation(id: target.id, startedAt: firstDisable, remaining: 0, reviewUntil: 0, courtReviewRequired: false)
                }
            case .suspendSharer:
                try store.setSuspension(digest: digest, suspended: true, caseReference: request.caseReference, now: now, caseUntil: now + capability.auditRetentionSeconds)
                for share in plan.affected {
                    // Existing cases stay intact; a new installation case cannot rewrite them.
                    if try store.enforcementState(id: share.id)?.disabled == true { continue }
                    try store.setEnforcement(id: share.id, disabled: true, purged: false,
                                             deadline: share.retentionDeadline, caseReference: request.caseReference,
                                             caseUntil: max(now + capability.auditRetentionSeconds, share.retentionDeadline))
                    if let record = try store.share(id: share.id) { try applyPreservation(share, record: record) }
                }
            case .unsuspendSharer:
                try store.setSuspension(digest: digest, suspended: false, caseReference: request.caseReference, now: now, caseUntil: now + capability.auditRetentionSeconds)
            case .reviewPreservation:
                guard let target, let share = plan.affected.first else { throw EnforcementFailure.invalid }
                try store.setEnforcement(id: target.id, disabled: true, purged: false,
                    deadline: share.retentionDeadline, caseReference: request.caseReference,
                    caseUntil: max(now + capability.auditRetentionSeconds, share.retentionDeadline))
                try applyPreservation(share, record: target)
            case .purgeDisabledShare:
                guard let target else { throw EnforcementFailure.invalid }
                guard let state = try store.enforcementState(id: target.id), state.disabled else { throw EnforcementFailure.conflict }
                if state.purged { outcome = "alreadyPurged"; count = 0 }
                else {
                    try store.setEnforcement(id: target.id, disabled: true, purged: true, deadline: now, caseReference: request.caseReference, caseUntil: now + capability.auditRetentionSeconds)
                    try store.enqueueEnforcementCleanup(id: target.id, as: .expired, now: now, operationID: request.operationID)
                    outcome = "purgeQueued"
                }
            }
            let receipt = EnforcementReceipt(operationID: request.operationID, action: request.action,
                                             caseReference: request.caseReference, affectedCount: count,
                                             outcome: outcome, completedAt: now,
                                             boundary: EnforcementReceipt.transferBoundary,
                                             suspensionReference: request.action == .suspendSharer ? try store.suspensionReference(digest: digest) : nil)
            try store.recordEnforcement(fingerprint: fingerprint, receipt: receipt, plan: plan,
                                        retainUntil: now + capability.auditRetentionSeconds)
            return receipt
        }
    }

    private func applyPreservation(_ share: EnforcementAffectedShare, record: ShareRecord) throws {
        guard share.preservationStartedAt != nil, let remaining = share.remainingLifetimeSeconds,
              let reviewUntil = share.reviewUntil, let courtReviewRequired = share.courtReviewRequired else { return }
        let existing = try store.enforcementState(id: record.id)
        let alreadyPaused = existing?.hasPausedLifetime == true
        // Account for time spent reviewing the plan; it is never granted back to the sender.
        let appliedStart = existing.map({ $0.disabledAt > 0 ? $0.disabledAt : now }) ?? now
        let appliedRemaining = alreadyPaused ? remaining : record.expiresAt - now
        guard appliedRemaining > 0 else { throw EnforcementFailure.conflict }
        try store.setPreservation(id: record.id, startedAt: appliedStart, remaining: appliedRemaining,
                                  reviewUntil: reviewUntil, courtReviewRequired: courtReviewRequired)
    }

    func enforcementWriteDenial(_ record: ShareRecord) throws -> ShareResponse? {
        try store.isEnforced(record) ? .error(403, "action_required", "This link requires review. You can still revoke it.") : nil
    }

    func enforcementCreateDenial(_ sharer: Sharer) throws -> ShareResponse? {
        try store.isSuspended(digest: sharer.digest) ? .error(403, "action_required", "Sharing from this installation requires review.") : nil
    }

    func endedEnforcementRecord(_ record: ShareRecord) -> ShareRecord {
        var ended = record
        ended.status = .expired
        ended.preview = nil
        ended.encryptedMeta = nil
        ended.artType = nil
        ended.cardType = nil
        ended.audioStored = false
        return ended
    }

    func enforcementOwnerList(_ records: [ShareRecord]) throws -> ShareResponse {
        let shares = try records.map { record in
            let disabled = try store.isEnforced(record)
            let projection = disabled ? endedEnforcementRecord(record) : record
            // Keep the owned wire status stable so the sender may still voluntarily revoke.
            var owned = projection
            owned.status = record.status
            let summary = try summary(owned)
            let state = try store.enforcementState(id: record.id)
            var notice = disabled ? "This link requires review. You can still revoke it." : nil
            if disabled, let state, state.hasPausedLifetime, !state.purged {
                let deadline = ShareDate.string(Date(timeIntervalSince1970: TimeInterval(state.deadline)))
                notice = "This link is disabled for review. Its encrypted song and share details are privately preserved until \(deadline) and count toward storage quota. \(state.remainingSeconds) seconds of link lifetime remain paused. Reviewed restoration resumes only that time; spent play limits stay spent. Revoke deletes the server copy."
            }
            return EnforcementOwnerSummary(summary: summary,
                actionRequired: notice)
        }
        return .json(EnforcementOwnerList(shares: shares))
    }
}

private struct EnforcementOwnerList: Encodable {
    let shares: [EnforcementOwnerSummary]
}

private struct EnforcementOwnerSummary: Encodable {
    let summary: ShareSummary
    let actionRequired: String?
    enum CodingKeys: String, CodingKey { case actionRequired }
    func encode(to encoder: Encoder) throws {
        try summary.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(actionRequired, forKey: .actionRequired)
    }
}
