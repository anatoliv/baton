import BatonShareKit
import Foundation

/// Private operator protocol. It carries references and revisions, never notices, keys,
/// install secrets, addresses or plaintext music. It is not part of the public share wire.
public enum EnforcementAction: String, Codable, Sendable {
    case disableShare = "disable-share"
    case restoreShare = "restore-share"
    case suspendSharer = "suspend-sharer"
    case unsuspendSharer = "unsuspend-sharer"
    case purgeDisabledShare = "purge-disabled-share"
    case reviewPreservation = "review-preservation"
}

public struct EnforcementConfiguration: Sendable {
    public let token: String
    public let retentionSeconds: Int64
    public let auditRetentionSeconds: Int64
    public let reasonCodes: Set<String>
    public let maximumAffectedShares: Int
    public let planLifetimeSeconds: Int64 = 600

    public init(token: String, retentionSeconds: Int64, auditRetentionSeconds: Int64,
                reasonCodes: Set<String>, maximumAffectedShares: Int = 100) throws {
        guard token.range(of: "^[A-Za-z0-9_-]{32,256}$", options: .regularExpression) != nil,
              (1 ... 90 * 86400).contains(retentionSeconds),
              (3600 ... 90 * 86400).contains(auditRetentionSeconds),
              !reasonCodes.isEmpty, reasonCodes.count <= 32,
              reasonCodes.allSatisfy({ Self.isReference($0) }),
              (1 ... 200).contains(maximumAffectedShares)
        else { throw ConfigurationError("invalid explicit enforcement configuration") }
        self.token = token
        self.retentionSeconds = retentionSeconds
        self.auditRetentionSeconds = auditRetentionSeconds
        self.reasonCodes = reasonCodes
        self.maximumAffectedShares = maximumAffectedShares
    }

    static func isReference(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil
    }

    static func fromEnvironment(_ env: [String: String]) throws -> EnforcementConfiguration? {
        guard env["BATON_SHARE_ENFORCEMENT_ENABLED"] == "1" else { return nil }
        guard let token = env["BATON_SHARE_OPERATOR_TOKEN"],
              let retention = env["BATON_SHARE_ENFORCEMENT_RETENTION_SECONDS"].flatMap(Int64.init),
              let audit = env["BATON_SHARE_ENFORCEMENT_AUDIT_SECONDS"].flatMap(Int64.init),
              let reasons = env["BATON_SHARE_ENFORCEMENT_REASON_CODES"],
              env["BATON_SHARE_ADMIN_TOKEN"] != token
        else { throw ConfigurationError("enforcement requires its own capability and explicit bounded retention/reason codes") }
        let maximum: Int
        if let text = env["BATON_SHARE_ENFORCEMENT_MAX_SHARES"] {
            guard let parsed = Int(text) else { throw ConfigurationError("invalid enforcement scope bound") }
            maximum = parsed
        } else { maximum = 100 }
        return try EnforcementConfiguration(token: token, retentionSeconds: retention,
                                            auditRetentionSeconds: audit,
                                            reasonCodes: Set(reasons.split(separator: ",", omittingEmptySubsequences: false).map(String.init)),
                                            maximumAffectedShares: maximum)
    }
}

public struct EnforcementRequest: Codable, Equatable, Sendable {
    public var operationID: String
    public var action: EnforcementAction
    public var shareID: String?
    public var suspensionReference: String? = nil
    public var caseReference: String
    public var reasonCode: String
    public var reviewUntil: Int64? = nil
    public var preservationDeadline: Int64? = nil
    public var courtReviewRequired: Bool? = nil
    public var expectedRevision: Int64? = nil

    func validated(configuration: EnforcementConfiguration) throws -> EnforcementRequest {
        let validTarget = shareID.map(ShareLink.isValidID) == true && suspensionReference == nil
            || shareID == nil && action == .unsuspendSharer && suspensionReference.map(ShareLink.isValidID) == true
        guard let uuid = UUID(uuidString: operationID), validTarget,
              EnforcementConfiguration.isReference(caseReference),
              configuration.reasonCodes.contains(reasonCode)
        else { throw EnforcementFailure.invalid }
        let preservationAction = action == .disableShare || action == .suspendSharer || action == .reviewPreservation
        let hasDates = reviewUntil != nil || preservationDeadline != nil
        guard (!hasDates || (preservationAction && reviewUntil != nil && preservationDeadline != nil)),
              courtReviewRequired == nil || preservationAction,
              expectedRevision == nil || action == .reviewPreservation,
              action != .reviewPreservation || (hasDates && courtReviewRequired != nil && expectedRevision != nil),
              expectedRevision.map({ $0 > 0 }) ?? true,
              reviewUntil.map({ (1 ... 253_402_127_999).contains($0) }) ?? true,
              preservationDeadline.map({ (1 ... 253_402_300_799).contains($0) }) ?? true,
              !hasDates || preservationDeadline! >= reviewUntil! + 2 * 86400
        else { throw EnforcementFailure.invalid }
        var request = self
        request.operationID = uuid.uuidString.lowercased()
        return request
    }
}

public struct EnforcementAffectedShare: Codable, Equatable, Sendable {
    public let id: String
    public let revision: Int64
    public let stateFingerprint: String
    public let expiresAt: Int64
    public let retentionDeadline: Int64
    public let storedBytes: Int64
    public let restorable: Bool
    public let restorationBlock: String?
    public var remainingLifetimeSeconds: Int64? = nil
    public var preservationStartedAt: Int64? = nil
    public var preservationCeiling: Int64? = nil
    public var reviewUntil: Int64? = nil
    public var courtReviewRequired: Bool? = nil
}

public struct EnforcementPlan: Codable, Equatable, Sendable {
    public let request: EnforcementRequest
    public let plannedAt: Int64
    public let validUntil: Int64
    public let targetFingerprint: String
    public let sharerRevision: Int64
    public let affected: [EnforcementAffectedShare]
    public var signature: String
}

public struct EnforcementReceipt: Codable, Equatable, Sendable {
    public let operationID: String
    public let action: EnforcementAction
    public let caseReference: String
    public let affectedCount: Int
    public let outcome: String
    public let completedAt: Int64
    public let boundary: String
    public var suspensionReference: String? = nil

    static let transferBoundary = "Changes govern subsequent requests only; completed downloads, crawler caches and already-open transfers cannot be recalled."
}

public struct EnforcementRecovery: Codable, Equatable, Sendable {
    public let receipt: EnforcementReceipt
    public let cleanupPending: Int
    public let cleanupFailed: Int
}

enum EnforcementFailure: Error {
    case invalid, notFound, conflict, scopeTooLarge, quota
}

/// Minimal private inventory: references have no authority without the current operator token.
public struct EnforcementSuspension: Codable, Equatable, Sendable {
    public let reference: String
    public let revision: Int64
}
public struct EnforcementSuspensions: Codable, Equatable, Sendable {
    public let suspensions: [EnforcementSuspension]
    public let nextCursor: String?
}
