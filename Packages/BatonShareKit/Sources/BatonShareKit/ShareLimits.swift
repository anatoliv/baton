import Foundation

/// Every number in `specs/song-sharing.md` §6, in one place.
///
/// The service reads overrides for the operational ones from its environment. The client-facing
/// ones reach the app through `GET /v1/share/config`, so a cap changed on the server is the cap
/// the composer enforces, rather than a second constant in the app drifting from this one.
public struct ShareLimits: Codable, Equatable, Sendable {
    public var maxAudioBytes = 26_214_400
    public var maxArtBytes = 524_288
    public var maxCardBytes = 1_048_576
    public var maxDurationSeconds = 1200
    public var expiryChoices = [86400, 604_800, 2_592_000]
    public var defaultExpirySeconds = 604_800
    public var maxExpirySeconds = 2_592_000
    public var defaultPlayCap = 100
    public var maxPlayCap = 1000

    public var createsPerSharerPerDay = 20
    public var liveSharesPerSharer = 60
    public var createsPerNetworkPerDay = 50
    public var newSharersPerNetworkPerDay = 5
    public var eventsPerVisitorPerMinute = 30
    public var reactionsPerVisitorPerDay = 5

    public var pendingLifetimeSeconds = 3600
    public var retentionDays = 400
    public var quotaBytes: Int64 = 21_474_836_480

    public init() {}

    public static let standard = ShareLimits()

    /// The reactions a friend can send back.
    public static let reactions = ["❤️", "🔥", "😂", "🙏", "😮"]

    public static let maxTitleLength = 200
    public static let maxFromLength = 60
    public static let maxNoteLength = 280
    public static let maxPeaks = 512
    public static let maxReactionNameLength = 40
    public static let maxReplyLength = 280
    public static let maxRecentFailures = 10
}
