import Foundation
import OSLog

private let discoveryLog = Logger(subsystem: "io.tonebox.baton", category: "Discovery")

/// Looking for music you don't have yet.
///
/// Baton's `music_similar_songs` answers "what else in *my library* sounds like this". This
/// is the same question pointed outward: what exists that you haven't got. They are one
/// feature with two ranges, and they should read that way — same phrasing, same shape of
/// answer, different place to look.
///
/// ## Why it is off until you say so
///
/// Everything else in Baton talks to your own server and, if you set one up, a model
/// provider you chose. This talks to strangers: MusicBrainz, ListenBrainz, and — when you
/// give them keys — Last.fm and YouTube. Asking them "what sounds like Aura?" tells them you
/// were listening to Aura. That is a small disclosure and an obvious one, but it is still
/// yours to make, so it is a setting rather than an assumption, and it is off.
///
/// ## What answers without a key
///
/// Two of the four sources need nothing at all, which is what makes this worth shipping
/// rather than a settings screen with a hole in it:
///
/// - **MusicBrainz** turns "Radiohead" into an identity every other service agrees on. No
///   key, no account.
/// - **ListenBrainz** turns that identity into a hundred related artists, ranked by how
///   often real people listen to them in the same sitting. No key, no account.
///
/// The other two are switched on by configuring them, and their absence is a *state*, not a
/// failure: with no Last.fm key, Last.fm is simply a source that is off, and the feature
/// says so instead of reporting an error nobody caused.
public enum ExternalDiscovery {
    // MARK: - Settings

    /// The master opt-in. Off means nothing here makes a single request.
    public static let enabledKey = "baton.discovery.external"
    /// Optional. Adds Last.fm's track-level similarity, which is finer-grained than
    /// ListenBrainz's artist-level data.
    public static let lastFMKeyKey = "baton.discovery.lastfm.key"
    /// Optional. Adds YouTube results, which are the ones you can actually open and play.
    public static let youTubeKeyKey = "baton.discovery.youtube.key"

    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static func configuredKey(_ key: String) -> String? {
        let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    /// Which sources would answer right now, and why the quiet ones are quiet. The UI shows
    /// this instead of pretending a missing key is a broken feature.
    public static func sourceStatus() -> [SourceStatus] {
        [
            SourceStatus(source: .musicBrainz, isAvailable: true,
                         detail: "No account needed."),
            SourceStatus(source: .listenBrainz, isAvailable: true,
                         detail: "No account needed."),
            SourceStatus(source: .lastFM, isAvailable: configuredKey(lastFMKeyKey) != nil,
                         detail: configuredKey(lastFMKeyKey) != nil
                             ? "Ready." : "Off — add a Last.fm API key to switch it on."),
            SourceStatus(source: .youTube, isAvailable: configuredKey(youTubeKeyKey) != nil,
                         detail: configuredKey(youTubeKeyKey) != nil
                             ? "Ready." : "Off — add a YouTube API key to switch it on."),
        ]
    }

    public struct SourceStatus: Equatable, Sendable {
        public let source: Source
        public let isAvailable: Bool
        public let detail: String
    }

    // MARK: - Results

    public enum Source: String, Sendable, CaseIterable {
        case musicBrainz, listenBrainz, lastFM, youTube

        public var label: String {
            switch self {
            case .musicBrainz: "MusicBrainz"
            case .listenBrainz: "ListenBrainz"
            case .lastFM: "Last.fm"
            case .youTube: "YouTube"
            }
        }
    }

    /// One thing you could go and listen to.
    ///
    /// Deliberately carries a `url` wherever the source gives one: the point of this feature
    /// is that a result is something you can *act on*, not a name you then have to go and
    /// search for yourself.
    public struct Suggestion: Identifiable, Equatable, Sendable {
        public let title: String
        public let artist: String?
        public let source: Source
        public let url: URL?
        /// The source's own confidence, normalised to 0…1 for ranking across sources.
        public let score: Double
        /// True when this artist already appears in the user's library, which turns
        /// "discover" into "you already have this" — worth saying rather than hiding.
        public var isInLibrary: Bool = false

        public var id: String { "\(source.rawValue)|\(artist ?? "")|\(title)" }

        public init(title: String, artist: String?, source: Source, url: URL?,
                    score: Double, isInLibrary: Bool = false) {
            self.title = title
            self.artist = artist
            self.source = source
            self.url = url
            self.score = score
            self.isInLibrary = isInLibrary
        }
    }

    public struct Findings: Equatable, Sendable {
        public var suggestions: [Suggestion]
        /// Sources that were not asked, and why — so the UI can say "YouTube is off"
        /// rather than silently returning less.
        public var quietSources: [SourceStatus]

        public init(suggestions: [Suggestion], quietSources: [SourceStatus]) {
            self.suggestions = suggestions
            self.quietSources = quietSources
        }
    }

    public enum Failure: Error, Equatable {
        /// Not an error the user made — the feature is simply off.
        case notEnabled
        case noArtist
    }

    // MARK: - The lookup

    /// Everything the reachable catalogues can say about "more like this".
    ///
    /// Artist is required and title is not, because the keyless path is artist-shaped:
    /// ListenBrainz's recording-level index is sparse enough that asking it about one track
    /// usually returns nothing, while its artist-level data is dense and genuinely good.
    /// Last.fm and YouTube use the title when there is one.
    public static func similar(toTitle title: String?,
                               artist: String?,
                               limit: Int = 25,
                               session: URLSession = .shared) async throws -> Findings {
        guard isEnabled else { throw Failure.notEnabled }
        let artistName = artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !artistName.isEmpty else { throw Failure.noArtist }

        var suggestions: [Suggestion] = []

        // The keyless spine: identity, then who sits next to it.
        if let mbid = await artistMBID(for: artistName, session: session) {
            suggestions += await similarArtists(mbid: mbid, session: session)
        }

        if let key = configuredKey(lastFMKeyKey), let title, !title.isEmpty {
            suggestions += await lastFMSimilarTracks(title: title, artist: artistName,
                                                     key: key, session: session)
        }
        if let key = configuredKey(youTubeKeyKey) {
            let query = title.map { "\($0) \(artistName)" } ?? artistName
            suggestions += await youTubeResults(query: query, key: key, session: session)
        }

        let ranked = deduplicated(suggestions).sorted { $0.score > $1.score }
        return Findings(suggestions: Array(ranked.prefix(limit)),
                        quietSources: sourceStatus().filter { !$0.isAvailable })
    }

    /// Same title + artist from two sources is one suggestion, kept at its best score.
    /// Which source it came from stops mattering the moment you have somewhere to click.
    static func deduplicated(_ suggestions: [Suggestion]) -> [Suggestion] {
        var best: [String: Suggestion] = [:]
        for suggestion in suggestions {
            let key = normalized("\(suggestion.artist ?? "") \(suggestion.title)")
            if let existing = best[key] {
                // Openable beats un-openable, whatever the scores say — the point of the
                // feature is a result you can act on. Only when both are equally openable
                // does the score decide.
                let bothOpenable = (existing.url != nil) == (suggestion.url != nil)
                let newlyOpenable = existing.url == nil && suggestion.url != nil
                let preferNew = newlyOpenable || (bothOpenable && suggestion.score > existing.score)
                if preferNew { best[key] = suggestion }
            } else {
                best[key] = suggestion
            }
        }
        return Array(best.values)
    }

    static func normalized(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                locale: Locale(identifier: "en_US_POSIX"))
        return String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ").joined(separator: " ")
    }

    // MARK: - MusicBrainz (identity, no key)

    static func artistMBID(for artist: String, session: URLSession) async -> String? {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/artist")
        components?.queryItems = [
            URLQueryItem(name: "query", value: "artist:\(artist)"),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let data = await get(components?.url, session: session) else { return nil }
        return parseArtistMBID(data)
    }

    static func parseArtistMBID(_ data: Data) -> String? {
        struct Response: Decodable {
            struct Artist: Decodable { let id: String; let score: Int? }
            let artists: [Artist]?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let first = decoded.artists?.first else { return nil }
        // A weak name match is worse than no match: it sends the whole lookup off after
        // somebody else's discography.
        guard (first.score ?? 0) >= 80 else { return nil }
        return first.id
    }

    // MARK: - ListenBrainz (similarity, no key)

    /// The algorithm name is part of the URL and the service validates it against an enum,
    /// so a wrong one is a 400 rather than a sensible default.
    ///
    /// Note this is the *similar-artists* enum. The similar-recordings endpoint next door
    /// accepts a different set, and passing one endpoint's value to the other is a 400 that
    /// this code would swallow as "no results" — which is exactly how the first version of
    /// this file came back empty while the same query worked by hand.
    static let listenBrainzAlgorithm =
        "session_based_days_7500_session_300_contribution_5_threshold_10_limit_100_filter_True_skip_30"

    static func similarArtists(mbid: String, session: URLSession) async -> [Suggestion] {
        var components = URLComponents(string: "https://labs.api.listenbrainz.org/similar-artists/json")
        components?.queryItems = [
            URLQueryItem(name: "artist_mbids", value: mbid),
            URLQueryItem(name: "algorithm", value: listenBrainzAlgorithm),
        ]
        guard let data = await get(components?.url, session: session) else { return [] }
        return parseSimilarArtists(data)
    }

    static func parseSimilarArtists(_ data: Data) -> [Suggestion] {
        struct Row: Decodable {
            let artist_mbid: String?
            let name: String?
            let score: Double?
        }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [] }
        // Scores come back as raw listener counts in the thousands. Divide by the best one
        // so they can be compared with Last.fm's 0…1 without one drowning the other.
        let top = rows.compactMap(\.score).max() ?? 1
        return rows.compactMap { row in
            guard let name = row.name, !name.isEmpty else { return nil }
            let url = row.artist_mbid.flatMap { URL(string: "https://musicbrainz.org/artist/\($0)") }
            return Suggestion(title: name, artist: nil, source: .listenBrainz, url: url,
                              score: top > 0 ? (row.score ?? 0) / top : 0)
        }
    }

    // MARK: - Last.fm (track similarity, needs a key)

    static func lastFMSimilarTracks(title: String, artist: String, key: String,
                                    session: URLSession) async -> [Suggestion] {
        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")
        components?.queryItems = [
            URLQueryItem(name: "method", value: "track.getsimilar"),
            URLQueryItem(name: "track", value: title),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: "25"),
        ]
        guard let data = await get(components?.url, session: session) else { return [] }
        return parseLastFM(data)
    }

    static func parseLastFM(_ data: Data) -> [Suggestion] {
        struct Response: Decodable {
            struct Similar: Decodable {
                struct Track: Decodable {
                    struct Artist: Decodable { let name: String? }
                    let name: String?
                    let url: String?
                    let match: Double?
                    let artist: Artist?
                }
                let track: [Track]?
            }
            let similartracks: Similar?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let tracks = decoded.similartracks?.track else { return [] }
        return tracks.compactMap { track in
            guard let name = track.name, !name.isEmpty else { return nil }
            return Suggestion(title: name, artist: track.artist?.name, source: .lastFM,
                              url: track.url.flatMap(URL.init(string:)),
                              score: track.match ?? 0)
        }
    }

    // MARK: - YouTube (something to actually press play on, needs a key)

    static func youTubeResults(query: String, key: String, session: URLSession) async -> [Suggestion] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")
        components?.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "videoCategoryId", value: "10"), // Music
            URLQueryItem(name: "maxResults", value: "10"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "key", value: key),
        ]
        guard let data = await get(components?.url, session: session) else { return [] }
        return parseYouTube(data)
    }

    static func parseYouTube(_ data: Data) -> [Suggestion] {
        struct Response: Decodable {
            struct Item: Decodable {
                struct ID: Decodable { let videoId: String? }
                struct Snippet: Decodable { let title: String?; let channelTitle: String? }
                let id: ID?
                let snippet: Snippet?
            }
            let items: [Item]?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let items = decoded.items else { return [] }
        // YouTube returns relevance order without a score, so position becomes the score —
        // first result 1.0, tapering off. Kept just under a perfect match so a source that
        // reports real confidence can still outrank it.
        return items.enumerated().compactMap { index, item in
            guard let title = item.snippet?.title, let videoID = item.id?.videoId else { return nil }
            return Suggestion(title: title, artist: item.snippet?.channelTitle, source: .youTube,
                              url: URL(string: "https://www.youtube.com/watch?v=\(videoID)"),
                              score: max(0, 0.95 - Double(index) * 0.05))
        }
    }

    // MARK: - Transport

    private static func get(_ url: URL?, session: URLSession) async -> Data? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        // MusicBrainz *requires* a identifying User-Agent and blocks generic ones;
        // ListenBrainz asks for the same courtesy.
        request.setValue("Baton/1.0 ( https://baton.tonebox.io )", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                discoveryLog.debug("discovery lookup returned a non-200")
                return nil
            }
            return data
        } catch {
            discoveryLog.debug("discovery lookup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
