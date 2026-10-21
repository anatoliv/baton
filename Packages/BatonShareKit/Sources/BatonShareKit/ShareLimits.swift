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

    // Whole-book links (`/b/`, specs/book-sharing.md). Owner decision 2026-10-18.
    /// Every sealed byte of one book: its chapters' audio, their read-along text and the manifest.
    public var maxBookBytes = 268_435_456
    public var maxBookChapters = 200
    /// One chapter's sealed audio. Also keeps each upload inside nginx's 27 MB body limit.
    public var maxBookChapterBytes = 26_214_400
    /// One chapter's sealed read-along text.
    public var maxBookTextBytes = 1_048_576
    public var maxBookManifestBytes = 262_144
    public var maxBookChapterSeconds = 86_400
    public var maxBookSeconds = 172_800
    /// Listeners a book link admits: one listening session each.
    public var defaultBookListeners = 10
    public var maxBookListeners = 50
    public var liveBooksPerSharer = 3
    /// The slice of `quotaBytes` that live books may hold together.
    public var bookQuotaBytes: Int64 = 10_737_418_240
    /// How long a book may stay pending before the sweeper deletes it as abandoned. Longer than
    /// `pendingLifetimeSeconds`, because 256 MiB over a slow uplink can take more than an hour.
    public var pendingBookLifetimeSeconds = 21_600

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
    /// `POST /v1/share/books` takes a body of at most this many bytes: a 256 KiB manifest in base64
    /// and 400 blob descriptors fit. The app refuses a larger book before it seals anything more,
    /// and the service refuses a larger body, from this one number.
    public static let maxBookCreateBodyBytes = 524_288

    /// A book listener's transfer allowance: 1.5 times the book, so seeking and replaying a
    /// chapter does not spend a second listener, and one admission cannot pull the book many times.
    public static func bookSessionAllowance(bookBytes: Int) -> Int { bookBytes + bookBytes / 2 }
}
