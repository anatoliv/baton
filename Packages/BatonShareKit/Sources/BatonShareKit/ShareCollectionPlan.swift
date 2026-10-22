import Foundation

/// Which link a set of picked songs makes (specs/collection-sharing.md, decision 7).
///
/// One song goes as a song link, 2 to 12 within the advertised mixtape limits as a mixtape link,
/// anything bigger as an album or playlist link when the service advertises collections, and
/// otherwise the composer says why it does not fit. The song and mixtape paths fetch MP3 at
/// 320 kbps from the music server before they know the exact size, so their fit is judged from a
/// conservative estimate (`mp3Bytes`); a collection seals AAC at the bit rate chosen per track
/// (`ShareCollectionLimits.bitRate`). Pure, so every edge is tested on Linux with the rest of the kit.
public enum ShareCollectionPlan {
    /// One picked song, as the planner needs it.
    public struct Track: Equatable, Sendable {
        public var id: String
        public var title: String
        /// The library's length in seconds; nil or 0 when the server did not say.
        public var seconds: Int?
        /// False for a song that is only a file on this device: the song and mixtape paths need the server.
        public var onServer: Bool
        /// What the song and mixtape paths would fetch (MP3 at 320 kbps), before sealing, at most.
        public var mp3Bytes: Int

        public init(id: String, title: String, seconds: Int?, onServer: Bool = true, mp3Bytes: Int? = nil) {
            self.id = id; self.title = title; self.seconds = seconds; self.onServer = onServer
            self.mp3Bytes = mp3Bytes ?? ShareCollectionPlan.mp3Bytes(seconds: seconds ?? 0)
        }

        var knownSeconds: Int? { seconds.flatMap { $0 > 0 ? $0 : nil } }
    }

    /// What the service advertised that routing depends on.
    public struct Service: Equatable, Sendable {
        public var enabled: Bool
        /// A song link's and a mixtape's duration and sealed-audio caps.
        public var maxSeconds: Int
        public var maxAudioBytes: Int
        public var mixtapes: Bool
        /// The book caps, when the service takes this kind of collection link; nil otherwise.
        public var collection: ShareBookLimits?

        public init(enabled: Bool = true, maxSeconds: Int = ShareLimits.standard.maxDurationSeconds,
                    maxAudioBytes: Int = ShareLimits.standard.maxAudioBytes, mixtapes: Bool = true,
                    collection: ShareBookLimits? = nil) {
            self.enabled = enabled; self.maxSeconds = maxSeconds; self.maxAudioBytes = maxAudioBytes
            self.mixtapes = mixtapes; self.collection = collection
        }

        /// From `GET /v1/share/config`. The song and mixtape paths also hold the standard
        /// 20-minute cap themselves, so the lower of the two is the one that binds.
        public init(config: ShareConfig, kind: ShareCollectionKind) {
            let advertised = config.books == 1 && config.collections == 1
                && (config.collection?.kinds ?? ShareCollectionKind.allCases).contains(kind)
            self.init(enabled: config.enabled,
                      maxSeconds: min(config.maxDurationSeconds, ShareLimits.standard.maxDurationSeconds),
                      maxAudioBytes: min(config.maxAudioBytes, ShareLimits.standard.maxAudioBytes),
                      mixtapes: config.mixtapes == 1, collection: advertised ? config.book : nil)
        }
    }

    /// A collection link that fits: its size and each track's bit rate, in order.
    public struct Collection: Equatable, Sendable {
        public var kind: ShareCollectionKind
        public var seconds: Int
        /// Every track's estimated sealed audio, for the composer's "about 50 MB".
        public var estimatedBytes: Int
        public var bitRates: [Int]
    }

    public enum Route: Equatable, Sendable {
        case song
        case mixtape
        case collection(Collection)
    }

    /// Why the picked songs cannot go, in the composer's words.
    public enum Refusal: Error, Equatable, Sendable {
        case nothingPicked
        case paused
        case unknownLength(String)
        case trackTooLong(String, maxSeconds: Int)
        case tooManyTracks(max: Int)
        case tooLong(seconds: Int, maxSeconds: Int)
        case tooLarge(bytes: Int, maxBytes: Int)
        /// The service takes no album or playlist links, and the picked songs are more than one
        /// song or mixtape link holds; `onlyHere` when that is because a song is only on this device.
        case needsCollection(kind: ShareCollectionKind, maxTracks: Int, maxSeconds: Int, onlyHere: Bool)

        public var message: String {
            switch self {
            case .nothingPicked:
                return "Pick at least one song."
            case .paused:
                return "Sharing is paused for now. Try again later."
            case let .unknownLength(title):
                return "Your music server didn't say how long “\(title)” is, so it can't be shared. Turn it off to send the rest."
            case let .trackTooLong(title, maxSeconds):
                return "“\(title)” is longer than \(ShareCollectionPlan.duration(maxSeconds)), the most one song can be. Turn it off to send the rest."
            case let .tooManyTracks(max):
                return "One link holds up to \(max) songs. Turn some off to send the rest."
            case let .tooLong(seconds, maxSeconds):
                return "These songs last \(ShareCollectionPlan.duration(seconds)); one link holds up to \(ShareCollectionPlan.duration(maxSeconds))."
            case let .tooLarge(bytes, maxBytes):
                return "These songs come to about \(ShareBookPlan.megabytes(bytes)); one link holds up to \(ShareBookPlan.megabytes(maxBytes))."
            case let .needsCollection(kind, maxTracks, maxSeconds, onlyHere):
                let what = kind == .album ? "Album" : "Playlist"
                if onlyHere {
                    return "\(what) links aren't available on the share service yet, and a song that is only on this device can go only in one. Turn it off to send the rest."
                }
                return "\(what) links aren't available on the share service yet. Pick up to \(maxTracks) songs and \(ShareCollectionPlan.duration(maxSeconds)) for a mixtape link."
            }
        }
    }

    /// The link the picked songs make, in this order, or why they cannot be one.
    public static func route(_ tracks: [Track], kind: ShareCollectionKind, service: Service) -> Result<Route, Refusal> {
        guard !tracks.isEmpty else { return .failure(.nothingPicked) }
        guard service.enabled else { return .failure(.paused) }
        if let unknown = tracks.first(where: { $0.knownSeconds == nil }) { return .failure(.unknownLength(unknown.title)) }
        if fitsSongOrMixtape(tracks, service: service) { return .success(tracks.count == 1 ? .song : .mixtape) }
        guard let limits = service.collection else {
            let onlyHere = tracks.contains { !$0.onServer }
            if tracks.count == 1, !onlyHere, tracks[0].knownSeconds! > service.maxSeconds {
                return .failure(.trackTooLong(tracks[0].title, maxSeconds: service.maxSeconds))
            }
            return .failure(.needsCollection(kind: kind, maxTracks: service.mixtapes ? ShareBookPlan.maxChapters : 1,
                                             maxSeconds: service.maxSeconds, onlyHere: onlyHere))
        }
        return collection(tracks, kind: kind, limits: limits).map(Route.collection)
    }

    /// Whether the existing song (one) or mixtape (2 to 12) path takes these songs as they are.
    static func fitsSongOrMixtape(_ tracks: [Track], service: Service) -> Bool {
        let most = service.mixtapes ? ShareBookPlan.maxChapters : 1
        guard (1 ... most).contains(tracks.count), Set(tracks.map(\.id)).count == tracks.count,
              tracks.allSatisfy(\.onServer) else { return false }
        // Saturating: a server can declare any length, and an overflow must refuse, not trap.
        let seconds = tracks.reduce(0) { sum($0, $1.knownSeconds ?? .max) }
        let sealed = tracks.reduce(0) { sum($0, ShareCrypto.sealedLength(plaintextLength: $1.mp3Bytes)) }
        return seconds <= service.maxSeconds && sealed <= service.maxAudioBytes
    }

    /// What a collection link of these songs would hold, within the book caps.
    public static func collection(_ tracks: [Track], kind: ShareCollectionKind,
                                  limits: ShareBookLimits) -> Result<Collection, Refusal> {
        guard !tracks.isEmpty else { return .failure(.nothingPicked) }
        guard tracks.count <= limits.maxChapters else { return .failure(.tooManyTracks(max: limits.maxChapters)) }
        var seconds = 0, bytes = 0, rates = [Int]()
        for track in tracks {
            guard let length = track.knownSeconds else { return .failure(.unknownLength(track.title)) }
            guard length <= limits.maxChapterSeconds,
                  let rate = ShareCollectionLimits.bitRate(forSeconds: length, maxTrackBytes: limits.maxChapterBytes) else {
                return .failure(.trackTooLong(track.title, maxSeconds: longestTrack(limits)))
            }
            seconds += length
            bytes += ShareCrypto.sealedLength(plaintextLength: ShareCollectionLimits.estimatedBytes(seconds: length, bitRate: rate))
            rates.append(rate)
        }
        guard seconds <= limits.maxBookSeconds else { return .failure(.tooLong(seconds: seconds, maxSeconds: limits.maxBookSeconds)) }
        // The manifest (titles, the cover) comes on top; leave it its own cap's room.
        let room = limits.maxBookBytes - limits.maxManifestBytes
        guard bytes <= room else { return .failure(.tooLarge(bytes: bytes, maxBytes: limits.maxBookBytes)) }
        return .success(Collection(kind: kind, seconds: seconds, estimatedBytes: bytes, bitRates: rates))
    }

    /// Why a song cannot be picked at all, for the track picker, or nil when it can. With no
    /// collection links advertised, a song too long for a song link or only on this device can
    /// still be picked: the summary line then says why the selection does not go.
    public static func unavailableReason(_ track: Track, service: Service?) -> String? {
        guard let length = track.knownSeconds else { return "Length unknown" }
        if let limits = service?.collection,
           length > limits.maxChapterSeconds
            || ShareCollectionLimits.bitRate(forSeconds: length, maxTrackBytes: limits.maxChapterBytes) == nil {
            return "Too long to share (over \(duration(longestTrack(limits))))"
        }
        return nil
    }

    /// The longest track a collection link takes, at its lowest bit rate.
    public static func longestTrack(_ limits: ShareBookLimits) -> Int {
        let lowest = ShareCollectionLimits.fallbackBitRates.last ?? ShareCollectionLimits.musicBitRate
        var seconds = Int(Double(limits.maxChapterBytes) * 0.94 / (Double(lowest) / 8))
        while seconds > 1, ShareCollectionLimits.bitRate(forSeconds: seconds, maxTrackBytes: limits.maxChapterBytes) == nil { seconds -= 1 }
        return min(seconds, limits.maxChapterSeconds)
    }

    /// The composer's line for a route: "14 songs · 52 m · about 50 MB · one album link",
    /// "8 songs · 18 m · a mixtape link", "1 song · 4 m · a song link".
    public static func line(_ route: Route, tracks: [Track]) -> String {
        let count = tracks.count == 1 ? "1 song" : "\(tracks.count) songs"
        let seconds = tracks.reduce(0) { sum($0, $1.knownSeconds ?? 0) }
        switch route {
        case .song: return "\(count) · \(duration(seconds)) · a song link"
        case .mixtape: return "\(count) · \(duration(seconds)) · a mixtape link"
        case let .collection(link):
            return "\(count) · \(duration(link.seconds)) · about \(ShareBookPlan.megabytes(link.estimatedBytes)) · one \(link.kind.rawValue) link"
        }
    }

    /// "45 s", "18 m", "1 h 12 m".
    public static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(max(0, seconds)) s" }
        let minutes = Int((Double(seconds) / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m" : "\(minutes) m"
    }

    /// The most the song and mixtape paths can fetch for a song: the file itself when the server
    /// would hand it over untouched (an MP3 at or under 320 kbps whose size is known), else MP3 at
    /// 320 kbps for its length, with room for tags.
    public static func mp3Bytes(seconds: Int, suffix: String? = nil, bitRate: Int? = nil, size: Int? = nil) -> Int {
        if suffix?.lowercased() == "mp3", let bitRate, bitRate > 0, bitRate <= 320, let size, size > 0 { return size }
        return min(max(0, seconds), 100_000_000) * 40_000 + 65_536
    }

    /// `a + b`, or `Int.max` where that would overflow.
    static func sum(_ a: Int, _ b: Int) -> Int {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : value
    }

    /// A title for a selection of songs: their album when they share one, "Songs by <artist>"
    /// when they share an artist, else "Mixtape". Cut to the wire's title limit.
    public static func suggestedTitle(albums: [String?], artists: [String?]) -> String {
        func common(_ values: [String?]) -> String? {
            let cleaned = values.map { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let first = cleaned.first, !first.isEmpty, cleaned.allSatisfy({ $0 == first }) else { return nil }
            return first
        }
        if let album = common(albums) { return ShareBookPlan.truncated(album, to: ShareLimits.maxTitleLength) }
        if let artist = common(artists) { return ShareBookPlan.truncated("Songs by \(artist)", to: ShareLimits.maxTitleLength) }
        return "Mixtape"
    }

    /// A line the wire accepts for a track's title, artist or album (NFC, no control characters,
    /// cut to 200 with an ellipsis); nil for an empty one.
    public static func wireText(_ text: String?) -> String? {
        let out = ShareBookPlan.truncated(text ?? "", to: ShareLimits.maxTitleLength)
        return out.isEmpty ? nil : out
    }
}
