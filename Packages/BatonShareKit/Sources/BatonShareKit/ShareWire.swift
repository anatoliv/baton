import Foundation

// The request and response bodies of `specs/song-sharing.md` §3–§4, defined once for both ends.

/// A field that broke a rule. The service turns it into `400 {code: "invalid"}` naming the field.
public struct ShareValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    public let field: String
    public let message: String

    public init(_ field: String, _ message: String) {
        self.field = field
        self.message = message
    }

    public var description: String { "\(field): \(message)" }
}

// MARK: - Metadata (§3)

public struct ShareMetadata: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var durationSeconds: Int
    public var from: String
    public var note: String
    public var accent: String?
    public var peaks: [Int]
    /// Optional MusicBrainz recording identity. Older shares omit it.
    public var recordingID: String?

    public init(title: String, artist: String = "", album: String = "", durationSeconds: Int,
                from: String = "", note: String = "", accent: String? = nil, peaks: [Int] = [], recordingID: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.from = from
        self.note = note
        self.accent = accent
        self.peaks = peaks
        self.recordingID = recordingID
    }

    /// Tolerates missing optional fields, so an older or terser client still decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        durationSeconds = try c.decode(Int.self, forKey: .durationSeconds)
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        accent = try c.decodeIfPresent(String.self, forKey: .accent)
        peaks = try c.decodeIfPresent([Int].self, forKey: .peaks) ?? []
        recordingID = try c.decodeIfPresent(String.self, forKey: .recordingID)
    }

    /// The metadata after normalization, or the first rule it breaks.
    public func validated(limits: ShareLimits = .standard) throws -> ShareMetadata {
        var copy = self
        copy.title = try ShareText.clean(title, field: "title", max: ShareLimits.maxTitleLength)
        guard !copy.title.isEmpty else { throw ShareValidationError("title", "is required") }
        copy.artist = try ShareText.clean(artist, field: "artist", max: ShareLimits.maxTitleLength)
        copy.album = try ShareText.clean(album, field: "album", max: ShareLimits.maxTitleLength)
        copy.from = try ShareText.clean(from, field: "from", max: ShareLimits.maxFromLength)
        copy.note = try ShareText.clean(note, field: "note", max: ShareLimits.maxNoteLength,
                                        allowNewlines: true)
        guard (1 ... limits.maxDurationSeconds).contains(durationSeconds) else {
            throw ShareValidationError("durationSeconds", "must be from 1 to \(limits.maxDurationSeconds)")
        }
        if let accent {
            guard ShareText.isHexColor(accent) else {
                throw ShareValidationError("accent", "must be #RRGGBB")
            }
            copy.accent = accent.uppercased()
        }
        guard peaks.count <= ShareLimits.maxPeaks, peaks.allSatisfy({ (0 ... 255).contains($0) }) else {
            throw ShareValidationError("peaks", "at most \(ShareLimits.maxPeaks) values, each from 0 to 255")
        }
        if let recordingID {
            guard let identity = UUID(uuidString: recordingID), recordingID.count == 36 else {
                throw ShareValidationError("recordingID", "must be a MusicBrainz recording UUID")
            }
            copy.recordingID = identity.uuidString.lowercased()
        }
        return copy
    }
}

/// The text rules every free-form field shares.
public enum ShareText {
    /// NFC-normalized, trimmed, length-checked in Unicode scalars; control characters refused,
    /// except a newline where `allowNewlines` says so.
    public static func clean(_ text: String, field: String, max: Int,
                             allowNewlines: Bool = false) throws -> String {
        let normalized = text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for scalar in normalized.unicodeScalars {
            let isControl = scalar.value < 0x20 || (0x7F ... 0x9F).contains(scalar.value)
            if isControl && !(allowNewlines && scalar == "\n") {
                throw ShareValidationError(field, "contains a control character")
            }
        }
        guard normalized.unicodeScalars.count <= max else {
            throw ShareValidationError(field, "is longer than \(max) characters")
        }
        return normalized
    }

    public static func isHexColor(_ text: String) -> Bool {
        text.utf8.count == 7 && text.first == "#"
            && text.utf8.dropFirst().allSatisfy { (48 ... 57).contains($0) || (65 ... 70).contains($0) || (97 ... 102).contains($0) }
    }
}

/// Track length, coarsened, for private shares where the exact duration is encrypted.
public enum DurationBucket: String, Codable, Sendable, CaseIterable {
    case underOne = "<1m"
    case oneToThree = "1-3m"
    case threeToFive = "3-5m"
    case fiveToTen = "5-10m"
    case overTen = ">10m"

    public init(seconds: Int) {
        switch seconds {
        case ..<60: self = .underOne
        case ..<180: self = .oneToThree
        case ..<300: self = .threeToFive
        case ..<600: self = .fiveToTen
        default: self = .overTen
        }
    }
}

// MARK: - Sharer routes (§4.1)

public struct ShareClientInfo: Codable, Equatable, Sendable {
    public static let platforms: Set<String> = ["macos", "ios"]
    public var platform: String
    public var appVersion: String

    public init(platform: String, appVersion: String) {
        self.platform = platform
        self.appVersion = appVersion
    }
}

/// A share attempt that failed before it reached the server, reported with the next create.
public struct ShareFailureReport: Codable, Equatable, Sendable {
    public static let reasons: Set<String> = ["transcode", "too_large", "network", "quota", "other"]
    public var reason: String

    public init(reason: String) { self.reason = reason }
}

public struct CreateShareRequest: Codable, Equatable, Sendable {
    public var expiresInSeconds: Int
    public var playCap: Int
    public var preview: ShareMetadata?
    public var encryptedMeta: String?
    public var durationBucket: DurationBucket?
    public var audioBytes: Int
    public var audioSHA256: String
    public var client: ShareClientInfo
    public var recentFailures: [ShareFailureReport]?
    /// Explicit per-share consent. Absence never opts an older sender into preservation.
    public var reviewPreservationConsent: String?
    public static let reviewConsentVersion = "review-v1"

    public init(expiresInSeconds: Int, playCap: Int, preview: ShareMetadata?, encryptedMeta: String?,
                durationBucket: DurationBucket?, audioBytes: Int, audioSHA256: String,
                client: ShareClientInfo, recentFailures: [ShareFailureReport]? = nil,
                reviewPreservationConsent: String? = nil) {
        self.expiresInSeconds = expiresInSeconds
        self.playCap = playCap
        self.preview = preview
        self.encryptedMeta = encryptedMeta
        self.durationBucket = durationBucket
        self.audioBytes = audioBytes
        self.audioSHA256 = audioSHA256
        self.client = client
        self.recentFailures = recentFailures
        self.reviewPreservationConsent = reviewPreservationConsent
    }

    public var isPrivate: Bool { preview == nil }

    /// The bucket for reporting, whichever mode the share is in.
    public var effectiveDurationBucket: DurationBucket? {
        preview.map { DurationBucket(seconds: $0.durationSeconds) } ?? durationBucket
    }

    /// The request after every rule in the spec, or the first one it breaks.
    public func validated(limits: ShareLimits = .standard) throws -> CreateShareRequest {
        var copy = self
        guard reviewPreservationConsent == nil || reviewPreservationConsent == Self.reviewConsentVersion else {
            throw ShareValidationError("reviewPreservationConsent", "unsupported consent version")
        }
        guard limits.expiryChoices.contains(expiresInSeconds) else {
            throw ShareValidationError("expiresInSeconds", "must be one of \(limits.expiryChoices)")
        }
        guard (1 ... limits.maxPlayCap).contains(playCap) else {
            throw ShareValidationError("playCap", "must be from 1 to \(limits.maxPlayCap)")
        }
        switch (preview, encryptedMeta) {
        case let (preview?, nil):
            copy.preview = try preview.validated(limits: limits)
            copy.durationBucket = nil
        case let (nil, meta?):
            guard let bytes = Data(base64Encoded: meta), bytes.count <= 64 * 1024 else {
                throw ShareValidationError("encryptedMeta", "must be base64, at most 64 KiB")
            }
            do {
                _ = try ShareCrypto.layout(headerBytes: Array([UInt8](bytes).prefix(ShareCrypto.headerLength)),
                                           totalLength: bytes.count)
            } catch {
                throw ShareValidationError("encryptedMeta", "is not a BSH1 stream")
            }
            guard durationBucket != nil else {
                throw ShareValidationError("durationBucket", "is required for a private share")
            }
        default:
            throw ShareValidationError("preview", "exactly one of preview and encryptedMeta is required")
        }
        guard (ShareCrypto.headerLength + ShareCrypto.tagLength ... limits.maxAudioBytes).contains(audioBytes) else {
            throw ShareValidationError("audioBytes", "must be at most \(limits.maxAudioBytes)")
        }
        guard ShareBookManifest.isLowerHex(audioSHA256) else {
            throw ShareValidationError("audioSHA256", "must be 64 lowercase hex characters")
        }
        guard ShareClientInfo.platforms.contains(client.platform) else {
            throw ShareValidationError("client.platform", "must be macos or ios")
        }
        copy.client.appVersion = try ShareText.clean(client.appVersion, field: "client.appVersion", max: 40)
        if let failures = recentFailures {
            guard failures.count <= ShareLimits.maxRecentFailures,
                  failures.allSatisfy({ ShareFailureReport.reasons.contains($0.reason) })
            else {
                throw ShareValidationError("recentFailures", "at most \(ShareLimits.maxRecentFailures), known reasons only")
            }
        }
        return copy
    }
}

public struct CreateShareResponse: Codable, Equatable, Sendable {
    public struct Uploads: Codable, Equatable, Sendable {
        public var audio: String
        public var art: String
        public var card: String

        public init(audio: String, art: String, card: String) {
            self.audio = audio
            self.art = art
            self.card = card
        }
    }

    public var id: String
    public var url: String
    public var expiresAt: String
    public var uploads: Uploads

    public init(id: String, url: String, expiresAt: String, uploads: Uploads) {
        self.id = id
        self.url = url
        self.expiresAt = expiresAt
        self.uploads = uploads
    }
}

public enum ShareStatus: String, Codable, Sendable {
    case pending, ready, expired, revoked
}

public struct ShareStats: Codable, Equatable, Sendable {
    public var opens = 0
    public var listeners = 0
    public var plays = 0
    public var listened30s = 0
    public var completed = 0
    public var fetches = 0

    public init() {}
}

public struct ShareReaction: Codable, Equatable, Sendable {
    public var emoji: String
    public var name: String
    public var reply: String
    public var at: String

    public init(emoji: String, name: String, reply: String, at: String) {
        self.emoji = emoji
        self.name = name
        self.reply = reply
        self.at = at
    }
}

public struct ShareSummary: Codable, Equatable, Sendable {
    public var id: String
    public var status: ShareStatus
    public var createdAt: String
    public var expiresAt: String
    public var playCap: Int
    public var preview: ShareMetadata?
    public var stats: ShareStats
    public var reactions: [ShareReaction]
    /// Present while the service holds the link for review; voluntary revoke remains available.
    public var actionRequired: String?

    public init(id: String, status: ShareStatus, createdAt: String, expiresAt: String, playCap: Int,
                preview: ShareMetadata?, stats: ShareStats, reactions: [ShareReaction], actionRequired: String? = nil) {
        self.id = id
        self.status = status
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.playCap = playCap
        self.preview = preview
        self.stats = stats
        self.reactions = reactions
        self.actionRequired = actionRequired
    }
}

public struct ShareList: Codable, Equatable, Sendable {
    public var shares: [ShareSummary]

    public init(shares: [ShareSummary]) { self.shares = shares }
}

public struct PatchShareRequest: Codable, Equatable, Sendable {
    public var extendBySeconds: Int?
    public var playCap: Int?

    public init(extendBySeconds: Int? = nil, playCap: Int? = nil) {
        self.extendBySeconds = extendBySeconds
        self.playCap = playCap
    }
}

// MARK: - Public routes (§4.2)

public struct PublicShare: Codable, Equatable, Sendable {
    public var status: ShareStatus
    public var preview: ShareMetadata?
    public var encryptedMeta: String?
    public var audioBytes: Int
    public var hasArt: Bool
    public var hasCard: Bool
    public var expiresAt: String

    public init(status: ShareStatus, preview: ShareMetadata?, encryptedMeta: String?, audioBytes: Int,
                hasArt: Bool, hasCard: Bool, expiresAt: String) {
        self.status = status
        self.preview = preview
        self.encryptedMeta = encryptedMeta
        self.audioBytes = audioBytes
        self.hasArt = hasArt
        self.hasCard = hasCard
        self.expiresAt = expiresAt
    }
}

public struct ShareConfig: Codable, Equatable, Sendable {
    public var mixtapes: Int?
    /// 1 when the service takes whole-book links (`/b/`); absent means unsupported.
    public var books: Int?
    /// The book caps, advertised with `books`, so the composer holds no second copy of them.
    public var book: ShareBookLimits?
    /// 1 when the service also takes album and playlist links on `/b/` (specs/collection-sharing.md);
    /// advertised only with `books`, whose caps a collection shares.
    public var collections: Int?
    public var collection: ShareCollectionLimits?
    public var appAttest: ShareAttestationPolicy?
    public var reactionPush: ReactionPushAdvertisement?
    public var enabled: Bool
    public var maxAudioBytes: Int
    public var maxDurationSeconds: Int
    public var expiryChoices: [Int]
    public var defaultExpirySeconds: Int
    public var defaultPlayCap: Int
    public var maxPlayCap: Int
    public var reactions: [String]

    public init(enabled: Bool, limits: ShareLimits) {
        self.enabled = enabled
        maxAudioBytes = limits.maxAudioBytes
        maxDurationSeconds = limits.maxDurationSeconds
        expiryChoices = limits.expiryChoices
        defaultExpirySeconds = limits.defaultExpirySeconds
        defaultPlayCap = limits.defaultPlayCap
        maxPlayCap = limits.maxPlayCap
        reactions = ShareLimits.reactions
    }
}

/// A beacon from the web player, or from the app for the two in-app events.
public struct PlayerEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case playStarted = "play_started"
        case played30s = "play_30s"
        case playCompleted = "play_completed"
        case decryptFailed = "decrypt_failed"
        case getBatonClicked = "get_baton_clicked"
        case foundInLibrary = "found_in_library"
    }

    public static let decryptReasons: Set<String> = ["missing_key", "auth", "truncated", "format"]
    public static let getBatonTargets: Set<String> = ["app_store", "mac_download", "about"]

    public var type: Kind
    public var ms: Int?
    public var reason: String?
    public var target: String?
    public var found: Bool?

    public init(type: Kind, ms: Int? = nil, reason: String? = nil, target: String? = nil, found: Bool? = nil) {
        self.type = type
        self.ms = ms
        self.reason = reason
        self.target = target
        self.found = found
    }

    /// Only the keys the spec lists for this type, each from its allowed set; anything else is
    /// dropped rather than stored. Returns the `props` object to record.
    public func props() throws -> [String: PropValue] {
        switch type {
        case .playStarted:
            guard let ms else { return [:] }
            return ["ms": .int(min(max(ms, 0), 600_000))]
        case .played30s, .playCompleted:
            return [:]
        case .decryptFailed:
            guard let reason, PlayerEvent.decryptReasons.contains(reason) else {
                throw ShareValidationError("reason", "unknown decrypt failure")
            }
            return ["reason": .string(reason)]
        case .getBatonClicked:
            guard let target, PlayerEvent.getBatonTargets.contains(target) else {
                throw ShareValidationError("target", "unknown target")
            }
            return ["target": .string(target)]
        case .foundInLibrary:
            guard let found else { throw ShareValidationError("found", "is required") }
            return ["found": .bool(found)]
        }
    }
}

/// A value in an event's `props`. Deliberately small: there is nothing an event needs to carry
/// that is not one of these.
public enum PropValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Int.self) { self = .int(value) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(value): try c.encode(value)
        case let .int(value): try c.encode(value)
        case let .bool(value): try c.encode(value)
        }
    }
}

public struct ReactionRequest: Codable, Equatable, Sendable {
    public var emoji: String
    public var name: String?
    public var reply: String?

    public init(emoji: String, name: String? = nil, reply: String? = nil) {
        self.emoji = emoji
        self.name = name
        self.reply = reply
    }

    public func validated() throws -> ReactionRequest {
        guard ShareLimits.reactions.contains(emoji) else {
            throw ShareValidationError("emoji", "must be one of \(ShareLimits.reactions.joined(separator: " "))")
        }
        return ReactionRequest(
            emoji: emoji,
            name: try ShareText.clean(name ?? "", field: "name", max: ShareLimits.maxReactionNameLength),
            reply: try ShareText.clean(reply ?? "", field: "reply", max: ShareLimits.maxReplyLength,
                                       allowNewlines: true))
    }
}

public struct ShareErrorBody: Codable, Equatable, Sendable {
    public var error: String
    public var code: String

    public init(error: String, code: String) {
        self.error = error
        self.code = code
    }
}

/// Timestamps on the wire: ISO 8601, UTC, whole seconds.
public enum ShareDate {
    public static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
