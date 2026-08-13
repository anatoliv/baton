import BatonSubsonicKit
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

    /// Per-source opt-out, under the master switch rather than replacing it.
    ///
    /// **Defaults to on**, which is the only choice that leaves existing installs behaving
    /// as they did: the master switch is still what decides whether anything leaves the
    /// machine at all, and this says which of the four to ask once it has. It is a separate
    /// question from whether a source is *configured* — "I have a Last.fm key and don't want
    /// Last.fm results" was previously unsayable, as was "don't consult MusicBrainz".
    public static func enabledKey(for source: Source) -> String {
        "baton.discovery.source.\(source.rawValue)"
    }

    public static func isEnabled(_ source: Source) -> Bool {
        UserDefaults.standard.object(forKey: enabledKey(for: source)) as? Bool ?? true
    }

    public static func setEnabled(_ enabled: Bool, for source: Source) {
        UserDefaults.standard.set(enabled, forKey: enabledKey(for: source))
    }

    /// The key a source needs, or nil for one that needs none.
    public static func keyDefaultsKey(for source: Source) -> String? {
        switch source {
        case .lastFM: lastFMKeyKey
        case .youTube: youTubeKeyKey
        case .musicBrainz, .listenBrainz: nil
        }
    }

    /// The stored API key for a source, from the Keychain.
    ///
    /// These are credentials, and they used to sit in a plain defaults domain — on the Mac,
    /// a plist any process running as you can read. `NavidromeKeychain` already solved this
    /// exact problem for the server secret, **including the migration**: it reads the
    /// Keychain first, and on a miss lifts a legacy `UserDefaults` value stored under the
    /// same name, writes it to the Keychain and deletes the plaintext. Passing the old
    /// defaults key as the account is therefore the whole migration, it is idempotent by
    /// construction, and it is code that already had to be right once.
    static func configuredKey(_ key: String) -> String? {
        let value = NavidromeKeychain.secret(account: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    /// Store (or clear) a source's API key. An empty value deletes the item rather than
    /// leaving an empty secret behind.
    public static func setKey(_ value: String, for source: Source) {
        guard let account = keyDefaultsKey(for: source) else { return }
        NavidromeKeychain.setSecret(value.trimmingCharacters(in: .whitespacesAndNewlines),
                                    account: account)
    }

    /// The stored key for a source, for a settings field to show and edit.
    public static func key(for source: Source) -> String {
        guard let account = keyDefaultsKey(for: source) else { return "" }
        return NavidromeKeychain.secret(account: account) ?? ""
    }

    /// Whether this source would be asked right now, and if not, which of the two reasons.
    public static func availability(of source: Source) -> Availability {
        guard isEnabled(source) else { return .turnedOff }
        guard let keyName = keyDefaultsKey(for: source) else { return .ready }
        return configuredKey(keyName) != nil ? .ready : .needsKey
    }

    /// Off because you said so, and off because it cannot work, are different facts, and a
    /// UI that renders one string for both tells a user to add an API key to a source they
    /// deliberately switched off.
    public enum Availability: Equatable, Sendable {
        case ready
        case turnedOff
        case needsKey

        public var isAvailable: Bool { self == .ready }
    }

    /// Which sources would answer right now, and why the quiet ones are quiet. The UI shows
    /// this instead of pretending a missing key is a broken feature.
    public static func sourceStatus() -> [SourceStatus] {
        Source.allCases.map { source in
            let availability = availability(of: source)
            return SourceStatus(source: source, availability: availability,
                                detail: detail(for: source, availability: availability))
        }
    }

    static func detail(for source: Source, availability: Availability) -> String {
        switch availability {
        case .turnedOff:
            return "Off — you switched this source off in Settings."
        case .needsKey:
            return "Off — add a \(source.label) API key to switch it on."
        case .ready:
            return keyDefaultsKey(for: source) == nil ? "No account needed." : "Ready."
        }
    }

    public struct SourceStatus: Equatable, Sendable {
        public let source: Source
        public let availability: Availability
        public let detail: String

        public var isAvailable: Bool { availability.isAvailable }
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

    // MARK: - Connection test

    /// What a test found. Deliberately more than a boolean: "off", "the key is wrong" and
    /// "the service is down" call for three different actions from the person reading it,
    /// and a green tick that only means "the field is not empty" is the thing this replaces.
    public enum TestResult: Equatable, Sendable {
        case ready(String)
        case keyRejected(String)
        case rateLimited(String)
        case unreachable(String)
        case notConfigured(String)

        public var isReady: Bool { if case .ready = self { true } else { false } }
        public var message: String {
            switch self {
            case .ready(let m), .keyRejected(let m), .rateLimited(let m),
                 .unreachable(let m), .notConfigured(let m): m
            }
        }
    }

    /// Ask the source the question it exists to answer, and report what came back.
    ///
    /// The lesson this borrows is the agent eval's: *answering the port is not the same as
    /// being able to serve*. A key that is present proves nothing, a 200 on a health page
    /// proves nothing about a key, and either would let a wrong key sit unnoticed until
    /// results quietly stopped including that source. So each test performs the real query
    /// with the real credential and reads the real answer.
    ///
    /// Keyless sources are tested too, and that is not ceremony — MusicBrainz and
    /// ListenBrainz are the two actually producing the results in the sheet, so "is the
    /// thing that works still working" is worth being able to ask.
    public static func test(_ source: Source, session: URLSession = .shared) async -> TestResult {
        switch source {
        case .musicBrainz:
            var components = URLComponents(string: "https://musicbrainz.org/ws/2/artist")
            components?.queryItems = [
                URLQueryItem(name: "query", value: "artist:Radiohead"),
                URLQueryItem(name: "fmt", value: "json"),
                URLQueryItem(name: "limit", value: "1"),
            ]
            guard let data = await get(components?.url, session: session),
                  parseArtistMBID(data) != nil else {
                return .unreachable("MusicBrainz did not answer a test lookup.")
            }
            return .ready("Answering — a test lookup resolved an artist.")

        case .listenBrainz:
            // Radiohead's MBID, so the request is the same shape the feature makes.
            let suggestions = await similarArtists(mbid: "a74b1b7f-71a5-4011-9441-d0b5e4122711",
                                                   session: session)
            return suggestions.isEmpty
                ? .unreachable("ListenBrainz returned nothing for a known artist — likely down.")
                : .ready("Answering — \(suggestions.count) similar artists for a test lookup.")

        case .lastFM:
            guard let key = configuredKey(lastFMKeyKey) else {
                return .notConfigured("No Last.fm API key yet.")
            }
            var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")
            components?.queryItems = [
                URLQueryItem(name: "method", value: "artist.getsimilar"),
                URLQueryItem(name: "artist", value: "Radiohead"),
                URLQueryItem(name: "api_key", value: key),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "limit", value: "1"),
            ]
            guard let url = components?.url else { return .unreachable("Bad Last.fm URL.") }
            return await probe(url, session: session, service: "Last.fm") { data in
                // Last.fm answers a bad key with HTTP 403 *and* a JSON error body, so the
                // body is what to read: `{"error":10,"message":"Invalid API key"}`.
                struct Error: Decodable { let error: Int?; let message: String? }
                if let decoded = try? JSONDecoder().decode(Error.self, from: data),
                   let code = decoded.error {
                    return code == 29
                        ? .rateLimited("Last.fm is rate-limiting this key.")
                        : .keyRejected(decoded.message.map { "Last.fm: \($0)" } ?? "Last.fm rejected the key.")
                }
                return .ready("Key accepted — a test lookup returned results.")
            }

        case .youTube:
            guard let key = configuredKey(youTubeKeyKey) else {
                return .notConfigured("No YouTube API key yet.")
            }
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")
            components?.queryItems = [
                URLQueryItem(name: "part", value: "snippet"),
                URLQueryItem(name: "q", value: "Radiohead"),
                URLQueryItem(name: "type", value: "video"),
                URLQueryItem(name: "maxResults", value: "1"),
                URLQueryItem(name: "key", value: key),
            ]
            guard let url = components?.url else { return .unreachable("Bad YouTube URL.") }
            return await probe(url, session: session, service: "YouTube") { data in
                struct Response: Decodable {
                    struct Failure: Decodable { let message: String?; let errors: [Detail]? }
                    struct Detail: Decodable { let reason: String? }
                    let error: Failure?
                }
                if let decoded = try? JSONDecoder().decode(Response.self, from: data),
                   let failure = decoded.error {
                    let reason = failure.errors?.first?.reason ?? ""
                    if reason.contains("quota") || reason == "rateLimitExceeded" {
                        return .rateLimited("YouTube quota exhausted for this key.")
                    }
                    return .keyRejected(failure.message.map { "YouTube: \($0)" } ?? "YouTube rejected the key.")
                }
                return .ready("Key accepted — a test search returned results.")
            }
        }
    }

    /// One request, with the body handed to the caller whatever the status code says.
    ///
    /// The status alone is not the answer: both keyed services report a bad key with a JSON
    /// body, and Last.fm pairs it with a 403 that would otherwise read as "unreachable".
    private static func probe(_ url: URL, session: URLSession, service: String,
                              interpret: (Data) -> TestResult) async -> TestResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // Same identifying agent the lookups use: MusicBrainz blocks generic ones outright,
        // and a test that gets blocked for a reason the real request never hits is a lie.
        request.setValue("Baton/1.0 ( https://baton.tonebox.io )", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if status == 429 { return .rateLimited("\(service) is rate-limiting this key.") }
            let verdict = interpret(data)
            // A 5xx with a body we could not read is the service's problem, not the key's.
            if case .ready = verdict, status >= 500 {
                return .unreachable("\(service) answered \(status).")
            }
            return verdict
        } catch {
            return .unreachable("\(service) could not be reached: \(error.localizedDescription)")
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

        // The keyless spine: identity, then who sits next to it. Both halves are asked only
        // if their source is switched on — MusicBrainz resolves the identity ListenBrainz
        // needs, so turning MusicBrainz off necessarily silences ListenBrainz too, and the
        // status strings say as much rather than leaving it to be discovered.
        if isEnabled(.musicBrainz), isEnabled(.listenBrainz),
           let mbid = await artistMBID(for: artistName, session: session) {
            suggestions += await similarArtists(mbid: mbid, session: session)
        }

        if isEnabled(.lastFM), let key = configuredKey(lastFMKeyKey), let title, !title.isEmpty {
            suggestions += await lastFMSimilarTracks(title: title, artist: artistName,
                                                     key: key, session: session)
        }
        if isEnabled(.youTube), let key = configuredKey(youTubeKeyKey) {
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
